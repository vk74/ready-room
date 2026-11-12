#!/usr/bin/env bash
# version: 1.1.0
# Orchestrate KB tree .kbz import by calling the primitive scripts only
# (begin → 1.4 MiB chunks → inspect → optional commit). Does not call HTTP
# itself. There is no package size cap. Chunk PUTs start at most 90 times
# per minute. HTTP 429 is not success: wait Retry-After and retry that chunk
# up to 3 times.
# File: kb-trees-import.sh
#
# Changes in v1.1.0:
# - Removed the 80 MiB package check. Chunk size stays 1468006.
# - Pace chunk PUTs at 90 per minute (60000/90 ms between starts). A chunk
#   that overruns the gap starts the next one immediately.
# - HTTP 429 is not success. role-request prints "role-request: HTTP <code>"
#   on stderr and the body on stdout (no response headers). Wait
#   meta.retryAfter seconds — the same integer as Retry-After — and retry
#   that chunk up to 3 times.
#
# Changes in v1.0.0:
# - Initial helper: begin, split with dd bs=1468006, chunk at offset N*size,
#   inspect, commit unless --inspect-only. Dies before begin if the file is
#   larger than 80 MiB. On any failure after begin, best-effort cancel.
#   --inspect-only merges session_id into inspect data so a later commit
#   has the id (inspect envelope itself does not include it).
#
# Usage: kb-trees-import.sh <file.kbz> [--inspect-only]

set -euo pipefail

die() {
  echo "kb-trees-import: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-trees-import.sh <file.kbz> [--inspect-only]" >&2
  exit 1
}

# Last "role-request: HTTP <code>" line. role-request.sh writes this to stderr
# and the response body to stdout. It does not print response headers.
http_code_from_role_request_err() {
  local err_file="$1"
  local line
  line="$(tr -d '\r' < "$err_file" 2>/dev/null | grep -E '^role-request: HTTP [0-9]+$' | tail -n 1 || true)"
  printf '%s' "${line#role-request: HTTP }"
}

[[ $# -ge 1 && $# -le 2 ]] || usage
INFILE="$(printf '%s' "$1" | xargs)"
[[ -n "$INFILE" ]] || usage

INSPECT_ONLY=0
if [[ $# -eq 2 ]]; then
  FLAG="$(printf '%s' "$2" | xargs)"
  [[ "$FLAG" == "--inspect-only" ]] || usage
  INSPECT_ONLY=1
fi

[[ -f "$INFILE" ]] || die "package file not found: ${INFILE}"
[[ -r "$INFILE" ]] || die "package file is not readable: ${INFILE}"

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
command -v dd >/dev/null 2>&1 || die "required command not found: dd"
command -v wc >/dev/null 2>&1 || die "required command not found: wc"

# 1.4 MiB — under the backend 1.5 MiB chunk cap (same as the FE client).
CHUNK_SIZE=1468006
# 90 chunks/minute → 60000/90 ms between PUT starts. jq is already required.
CHUNK_GAP_SEC="$(jq -nr '60/90')"
[[ -n "$CHUNK_GAP_SEC" ]] || die "cannot compute chunk pacing gap"
# Retries after the first 429, not counting that first attempt.
CHUNK_429_RETRIES=3

FILE_BYTES="$(wc -c < "$INFILE" | xargs)"
[[ "$FILE_BYTES" =~ ^[0-9]+$ ]] || die "cannot determine package file size"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN_SH="${SCRIPT_DIR}/kb-trees-import-begin.sh"
CHUNK_SH="${SCRIPT_DIR}/kb-trees-import-chunk.sh"
INSPECT_SH="${SCRIPT_DIR}/kb-trees-import-inspect.sh"
COMMIT_SH="${SCRIPT_DIR}/kb-trees-import-commit.sh"
CANCEL_SH="${SCRIPT_DIR}/kb-trees-import-cancel.sh"

[[ -f "$BEGIN_SH" ]] || die "missing primitive: kb-trees-import-begin.sh"
[[ -f "$CHUNK_SH" ]] || die "missing primitive: kb-trees-import-chunk.sh"
[[ -f "$INSPECT_SH" ]] || die "missing primitive: kb-trees-import-inspect.sh"
[[ -f "$COMMIT_SH" ]] || die "missing primitive: kb-trees-import-commit.sh"
[[ -f "$CANCEL_SH" ]] || die "missing primitive: kb-trees-import-cancel.sh"

SESSION_ID=""
WORK_DIR=""
PACE_PID=""
CHUNK_OUT=""

cleanup_work() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

cancel_session() {
  if [[ -n "${SESSION_ID:-}" ]]; then
    bash "$CANCEL_SH" "$SESSION_ID" >/dev/null 2>&1 || true
  fi
}

fail_after_begin() {
  cancel_session
  exit 1
}

# On success, sets global CHUNK_OUT to the chunk JSON. 429 is never success.
put_chunk_with_retry() {
  local offset="$1"
  local chunk_file="$2"
  local retries_left="$CHUNK_429_RETRIES"
  local attempt_out="" attempt_rc=0 err_file http_code retry_after retry_n
  err_file="${WORK_DIR}/chunk.err"
  while true; do
    set +e
    attempt_out="$(bash "$CHUNK_SH" "$SESSION_ID" "$offset" "$chunk_file" 2>"$err_file")"
    attempt_rc=$?
    set -e
    http_code="$(http_code_from_role_request_err "$err_file")"
    if [[ "$attempt_rc" -eq 0 && "$http_code" != "429" ]]; then
      CHUNK_OUT="$attempt_out"
      return 0
    fi
    if [[ "$http_code" != "429" ]]; then
      printf '%s\n' "$attempt_out"
      if [[ -s "$err_file" ]]; then
        cat "$err_file" >&2
      fi
      fail_after_begin
    fi
    if [[ "$retries_left" -le 0 ]]; then
      echo "kb-trees-import: chunk at offset ${offset} still HTTP 429 after ${CHUNK_429_RETRIES} retries" >&2
      printf '%s\n' "$attempt_out"
      if [[ -s "$err_file" ]]; then
        cat "$err_file" >&2
      fi
      fail_after_begin
    fi
    retry_after="$(printf '%s' "$attempt_out" | jq -r '.meta.retryAfter // empty' 2>/dev/null || true)"
    if [[ ! "$retry_after" =~ ^[0-9]+$ ]]; then
      echo "kb-trees-import: HTTP 429 at offset ${offset} but Retry-After (meta.retryAfter) is missing" >&2
      printf '%s\n' "$attempt_out"
      if [[ -s "$err_file" ]]; then
        cat "$err_file" >&2
      fi
      fail_after_begin
    fi
    retry_n=$((CHUNK_429_RETRIES - retries_left + 1))
    retries_left=$((retries_left - 1))
    echo "kb-trees-import: HTTP 429 at offset ${offset}, waiting ${retry_after}s before retry ${retry_n}/${CHUNK_429_RETRIES}" >&2
    sleep "$retry_after"
  done
}

trap cleanup_work EXIT
trap 'cancel_session; exit 1' INT TERM

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kb-import.XXXXXX")"

set +e
BEGIN_OUT="$(bash "$BEGIN_SH")"
BEGIN_RC=$?
set -e
if [[ "$BEGIN_RC" -ne 0 ]]; then
  printf '%s\n' "$BEGIN_OUT"
  exit 1
fi

SESSION_ID="$(printf '%s' "$BEGIN_OUT" | jq -r '.data.session_id // empty')"
[[ -n "$SESSION_ID" ]] || {
  printf '%s\n' "$BEGIN_OUT"
  die "begin did not return data.session_id"
}

N=0
OFFSET=0
while [[ "$OFFSET" -lt "$FILE_BYTES" ]]; do
  CHUNK_FILE="${WORK_DIR}/chunk-${N}.bin"
  dd if="$INFILE" of="$CHUNK_FILE" bs="$CHUNK_SIZE" skip="$N" count=1 2>/dev/null || true
  CHUNK_BYTES="$(wc -c < "$CHUNK_FILE" | xargs)"
  [[ "$CHUNK_BYTES" =~ ^[0-9]+$ ]] || {
    echo "kb-trees-import: cannot determine chunk size" >&2
    fail_after_begin
  }
  if [[ "$CHUNK_BYTES" -eq 0 ]]; then
    echo "kb-trees-import: empty chunk at offset ${OFFSET}" >&2
    fail_after_begin
  fi

  # Hold this PUT until the previous PUT's start plus the gap. If that PUT
  # (including 429 waits) already overran the gap, wait returns immediately.
  if [[ -n "$PACE_PID" ]]; then
    wait "$PACE_PID" || {
      echo "kb-trees-import: chunk pacing wait failed" >&2
      fail_after_begin
    }
    PACE_PID=""
  fi
  sleep "$CHUNK_GAP_SEC" &
  PACE_PID=$!

  put_chunk_with_retry "$OFFSET" "$CHUNK_FILE"

  TOTAL_SO_FAR="$(printf '%s' "$CHUNK_OUT" | jq -r '.data.total_so_far // empty')"
  EXPECTED=$((OFFSET + CHUNK_BYTES))
  if [[ "$TOTAL_SO_FAR" != "$EXPECTED" ]]; then
    echo "kb-trees-import: offset mismatch: expected total_so_far=${EXPECTED}, got ${TOTAL_SO_FAR}" >&2
    fail_after_begin
  fi

  N=$((N + 1))
  OFFSET=$((N * CHUNK_SIZE))
done

set +e
INSPECT_OUT="$(bash "$INSPECT_SH" "$SESSION_ID")"
INSPECT_RC=$?
set -e
if [[ "$INSPECT_RC" -ne 0 ]]; then
  printf '%s\n' "$INSPECT_OUT"
  fail_after_begin
fi
if [[ "$INSPECT_ONLY" -eq 1 ]]; then
  printf '%s\n' "$INSPECT_OUT" | jq -c --arg sid "$SESSION_ID" '
    .data.session_id = $sid
  '
  exit 0
fi
printf '%s\n' "$INSPECT_OUT"

set +e
COMMIT_OUT="$(bash "$COMMIT_SH" "$SESSION_ID")"
COMMIT_RC=$?
set -e
if [[ "$COMMIT_RC" -ne 0 ]]; then
  printf '%s\n' "$COMMIT_OUT"
  fail_after_begin
fi
printf '%s\n' "$COMMIT_OUT"

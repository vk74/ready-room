#!/usr/bin/env bash
# version: 1.0.2
# Export a KB tree as a raw .kbz zip (not the {success,code,data} envelope).
# Streams the body to disk with curl -o. No client time limit.
# File: kb-trees-export.sh
#
# Changes in v1.0.2:
# - Removed curl --max-time 300. The zip is still written with -o.
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET /api/kb/trees/:id/export via evi-request with -o.
#   Success is PK-zip magic; JSON envelopes are printed and
#   treated as failure. Default output name is kb-tree.kbz (evi-request does
#   not expose Content-Disposition, so the server filename is not used).
#
# Usage: kb-trees-export.sh <tree_id> [out.kbz]

set -euo pipefail

die() {
  echo "kb-trees-export: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-trees-export.sh <tree_id> [out.kbz]" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage
TREE_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$TREE_ID" ]] || usage

if [[ $# -eq 2 ]]; then
  OUT_ARG="$(printf '%s' "$2" | xargs)"
  [[ -n "$OUT_ARG" ]] || usage
else
  OUT_ARG="kb-tree.kbz"
fi

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
command -v dd >/dev/null 2>&1 || die "required command not found: dd"
command -v wc >/dev/null 2>&1 || die "required command not found: wc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the shared auth wrapper: env override, vendored copy, monorepo path.
AUTH_REQUEST_SCRIPT="${REQUEST_SCRIPT:-}"
if [[ -z "$AUTH_REQUEST_SCRIPT" ]]; then
  for candidate in "${SCRIPT_DIR}/_lib/role-request.sh" "${SCRIPT_DIR}/../../role-auth/scripts/role-request.sh"; do
    if [[ -f "$candidate" ]]; then
      AUTH_REQUEST_SCRIPT="$candidate"
      break
    fi
  done
fi
[[ -n "$AUTH_REQUEST_SCRIPT" && -f "$AUTH_REQUEST_SCRIPT" ]] || die "cannot locate role-request.sh (set REQUEST_SCRIPT or restore scripts/_lib/)"

if [[ "$OUT_ARG" == /* ]]; then
  DEST="$OUT_ARG"
else
  DEST="$(pwd)/${OUT_ARG}"
fi
DEST_DIR="$(dirname "$DEST")"
[[ -d "$DEST_DIR" ]] || die "output directory not found: ${DEST_DIR}"

TMPFILE="$(mktemp "${DEST_DIR}/.kb-export.XXXXXX")"
cleanup_tmp() {
  if [[ -n "${TMPFILE:-}" && -f "$TMPFILE" ]]; then
    rm -f "$TMPFILE"
  fi
}
trap cleanup_tmp EXIT

set +e
bash "$AUTH_REQUEST_SCRIPT" GET "/api/kb/trees/${TREE_ID}/export" \
  -o "$TMPFILE" \
  >/dev/null
REQ_RC=$?
set -e

[[ -f "$TMPFILE" ]] || die "export request failed (no response body written)"

MAGIC="$(dd if="$TMPFILE" bs=1 count=2 2>/dev/null || true)"
HEAD="$(dd if="$TMPFILE" bs=1 count=64 2>/dev/null || true)"
TRIMMED="$(printf '%s' "$HEAD" | sed 's/^[[:space:]]*//')"

if [[ "$MAGIC" == "PK" ]]; then
  [[ "$REQ_RC" -eq 0 ]] || die "export request failed (HTTP non-2xx) but body looks like zip"
  mv -f "$TMPFILE" "$DEST"
  TMPFILE=""
  BYTES="$(wc -c < "$DEST" | xargs)"
  [[ "$BYTES" =~ ^[0-9]+$ ]] || die "cannot determine exported file size"
  jq -nc --arg path "$DEST" --argjson bytes "$BYTES" '{path:$path,bytes:$bytes}'
  exit 0
fi

case "$TRIMMED" in
  \{*)
    cat "$TMPFILE"
    printf '\n'
    exit 1
    ;;
esac

if [[ "$REQ_RC" -ne 0 ]]; then
  die "export request failed"
fi
die "unexpected export body (not zip, not JSON)"

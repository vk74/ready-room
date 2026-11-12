#!/usr/bin/env bash
# version: 1.1.1
# Request a presigned upload URL and pending file_id from /api/fs/upload-request.
# File: fs-upload-request.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: builds upload-request payload from entity + local file path.
# - Supports optional --content-type override; otherwise infers MIME type.

set -euo pipefail

die() {
  echo "fs-upload-request: $*" >&2
  exit 1
}

usage() {
  echo "Usage: fs-upload-request.sh <entity_type> <entity_id> <file_path> [--content-type \"<mime>\"]" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

file_size_bytes() {
  local path="$1"
  if stat -f%z "$path" >/dev/null 2>&1; then
    stat -f%z "$path"
    return 0
  fi
  if stat -c%s "$path" >/dev/null 2>&1; then
    stat -c%s "$path"
    return 0
  fi
  die "unable to detect file size for: $path"
}

infer_content_type() {
  local path="$1"
  if command -v file >/dev/null 2>&1; then
    local detected
    detected="$(file --brief --mime-type "$path" 2>/dev/null || true)"
    if [[ -n "$detected" ]]; then
      printf '%s' "$detected"
      return 0
    fi
  fi
  printf '%s' "application/octet-stream"
}

[[ $# -ge 3 ]] || usage

ENTITY_TYPE="$(printf '%s' "$1" | xargs)"
ENTITY_ID="$(printf '%s' "$2" | xargs)"
FILE_PATH="$3"
shift 3

[[ -n "$ENTITY_TYPE" && -n "$ENTITY_ID" ]] || usage
[[ -f "$FILE_PATH" ]] || die "file not found: ${FILE_PATH}"

CONTENT_TYPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --content-type)
      [[ $# -ge 2 ]] || die "missing value for --content-type"
      CONTENT_TYPE="$(printf '%s' "$2" | xargs)"
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_cmd jq

if [[ -z "$CONTENT_TYPE" ]]; then
  CONTENT_TYPE="$(infer_content_type "$FILE_PATH")"
fi

SIZE_BYTES="$(file_size_bytes "$FILE_PATH")"
[[ "$SIZE_BYTES" =~ ^[0-9]+$ ]] || die "invalid file size detected: ${SIZE_BYTES}"

BASENAME="$(basename "$FILE_PATH")"
REQUEST_BODY="$(jq -cn \
  --arg entityType "$ENTITY_TYPE" \
  --arg entityId "$ENTITY_ID" \
  --arg filename "$BASENAME" \
  --arg contentType "$CONTENT_TYPE" \
  --argjson size "$SIZE_BYTES" \
  '{
    entity_type: $entityType,
    entity_id: $entityId,
    original_filename: $filename,
    content_type: $contentType,
    declared_size_bytes: $size
  }'
)"

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

bash "$AUTH_REQUEST_SCRIPT" POST /api/fs/upload-request \
  -H "Content-Type: application/json" \
  --data-binary "$REQUEST_BODY"

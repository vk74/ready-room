#!/usr/bin/env bash
# version: 1.0.1
# Full upload flow: request -> direct PUT -> confirm for one local file.
# File: attachments-upload-flow.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial convenience flow script composing fs-upload-request/put/confirm.
# - Prints confirm response JSON (contains final file_id).

set -euo pipefail

die() {
  echo "attachments-upload-flow: $*" >&2
  exit 1
}

usage() {
  echo "Usage: attachments-upload-flow.sh <entity_type> <entity_id> <file_path> [--content-type \"<mime>\"]" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

[[ $# -ge 3 ]] || usage

ENTITY_TYPE="$1"
ENTITY_ID="$2"
FILE_PATH="$3"
shift 3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_REQUEST_SCRIPT="${SCRIPT_DIR}/fs-upload-request.sh"
UPLOAD_PUT_SCRIPT="${SCRIPT_DIR}/fs-upload-put.sh"
UPLOAD_CONFIRM_SCRIPT="${SCRIPT_DIR}/fs-upload-confirm.sh"

[[ -x "$UPLOAD_REQUEST_SCRIPT" ]] || die "missing executable script: ${UPLOAD_REQUEST_SCRIPT}"
[[ -x "$UPLOAD_PUT_SCRIPT" ]] || die "missing executable script: ${UPLOAD_PUT_SCRIPT}"
[[ -x "$UPLOAD_CONFIRM_SCRIPT" ]] || die "missing executable script: ${UPLOAD_CONFIRM_SCRIPT}"

require_cmd jq

REQUEST_JSON="$(bash "$UPLOAD_REQUEST_SCRIPT" "$ENTITY_TYPE" "$ENTITY_ID" "$FILE_PATH" "$@")"
SUCCESS="$(printf '%s' "$REQUEST_JSON" | jq -r '.success // false' 2>/dev/null || echo false)"
[[ "$SUCCESS" == "true" ]] || die "upload-request failed"

UPLOAD_URL="$(printf '%s' "$REQUEST_JSON" | jq -r '.data.upload_url // empty')"
FILE_ID="$(printf '%s' "$REQUEST_JSON" | jq -r '.data.file_id // empty')"
[[ -n "$UPLOAD_URL" && -n "$FILE_ID" ]] || die "upload-request response missing upload_url or file_id"

HEADERS_FILE="$(mktemp)"
trap 'rm -f "$HEADERS_FILE"' EXIT
printf '%s' "$REQUEST_JSON" | jq '.data.headers // {}' >"$HEADERS_FILE"

bash "$UPLOAD_PUT_SCRIPT" "$UPLOAD_URL" "$FILE_PATH" "$HEADERS_FILE" >/dev/null
bash "$UPLOAD_CONFIRM_SCRIPT" "$FILE_ID"

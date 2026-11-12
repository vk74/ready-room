#!/usr/bin/env bash
# version: 1.1.0
# Upload a local file to presigned storage URL using optional headers JSON.
# File: fs-upload-put.sh
#
# Changes in v1.1.0:
# - Portability: expanding the empty CURL_HEADERS array no longer trips
#   `set -u` on bash 3.2 (macOS default) — uses the ${arr[@]+...} idiom.
#
# Changes in v1.0.0:
# - Initial direct PUT script for presigned upload URLs.
# - Supports optional headers JSON and ignores forbidden Host/Content-Length.

set -euo pipefail

die() {
  echo "fs-upload-put: $*" >&2
  exit 1
}

usage() {
  echo "Usage: fs-upload-put.sh <upload_url> <file_path> [headers.json]" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

[[ $# -ge 2 && $# -le 3 ]] || usage

UPLOAD_URL="$(printf '%s' "$1" | xargs)"
FILE_PATH="$2"
HEADERS_FILE="${3:-}"

[[ -n "$UPLOAD_URL" ]] || usage
[[ -f "$FILE_PATH" ]] || die "file not found: ${FILE_PATH}"

require_cmd curl
require_cmd jq

CURL_HEADERS=()

if [[ -n "$HEADERS_FILE" ]]; then
  [[ -f "$HEADERS_FILE" ]] || die "headers file not found: ${HEADERS_FILE}"
  if ! jq -e 'type=="object"' "$HEADERS_FILE" >/dev/null 2>&1; then
    die "headers file must be a JSON object"
  fi
  while IFS=$'\t' read -r key value; do
    [[ -n "${key:-}" ]] || continue
    lk="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lk" == "host" || "$lk" == "content-length" ]]; then
      continue
    fi
    CURL_HEADERS+=(-H "${key}: ${value}")
  done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' "$HEADERS_FILE")
fi

curl -sS --fail-with-body -X PUT \
  ${CURL_HEADERS[@]+"${CURL_HEADERS[@]}"} \
  --upload-file "$FILE_PATH" \
  "$UPLOAD_URL" >/dev/null

echo '{"success":true,"code":"FS-PUT-SUC-001"}'

#!/usr/bin/env bash
# version: 0.28.3
# Read one page of an entity discussion channel.
# File: chat-channel-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/communications/entity/:entityType/:entityId/channels/:channelKey.

set -euo pipefail

die() {
  echo "chat-channel-get: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: chat-channel-get.sh <entity_type> <entity_id> <channel_key> [--page N] [--items-per-page N]

entity_type and channel_key are 1..64 characters and must not contain /.
entity_id is a UUID.
--page is an integer >= 1. --items-per-page is an integer from 1 to 100.
For a service request, entity_type is service_request and channel_key is requester or internal.
EOF
  exit 1
}

resolve_auth() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
}

trim() {
  printf '%s' "$1" | xargs
}

trim_text() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

char_len() {
  printf '%s' "$1" | wc -m | tr -d '[:space:]'
}

require_path_token() {
  local label="$1"
  local value="$2"
  local len
  [[ -n "$value" ]] || die "$label is required"
  [[ "$value" != */* ]] || die "$label must not contain /"
  len="$(char_len "$value")"
  [[ "$len" -ge 1 && "$len" -le 64 ]] || die "$label must be 1..64 characters"
}

[[ $# -ge 3 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
ENTITY_TYPE="$(trim_text "$1")"
ENTITY_ID="$(trim "$2")"
CHANNEL_KEY="$(trim_text "$3")"
shift 3
require_path_token "entity_type" "$ENTITY_TYPE"
is_uuid "$ENTITY_ID" || die "not a UUID: $ENTITY_ID"
require_path_token "channel_key" "$CHANNEL_KEY"

PAGE=""
ITEMS_PER_PAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --page"
      PAGE="$(trim "$1")"
      ;;
    --items-per-page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --items-per-page"
      ITEMS_PER_PAGE="$(trim "$1")"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
if [[ -n "$PAGE" ]]; then
  [[ "$PAGE" =~ ^[1-9][0-9]*$ ]] || die "page must be an integer >= 1"
fi
if [[ -n "$ITEMS_PER_PAGE" ]]; then
  [[ "$ITEMS_PER_PAGE" =~ ^[1-9][0-9]{0,2}$ ]] || die "items-per-page must be an integer from 1 to 100"
  [[ "$ITEMS_PER_PAGE" -le 100 ]] || die "items-per-page must be an integer from 1 to 100"
fi

resolve_auth
CURL_ARGS=()
if [[ -n "$PAGE" || -n "$ITEMS_PER_PAGE" ]]; then
  CURL_ARGS=(--get)
  if [[ -n "$PAGE" ]]; then
    CURL_ARGS+=(--data-urlencode "page=${PAGE}")
  fi
  if [[ -n "$ITEMS_PER_PAGE" ]]; then
    CURL_ARGS+=(--data-urlencode "itemsPerPage=${ITEMS_PER_PAGE}")
  fi
fi
bash "$AUTH_REQUEST_SCRIPT" GET "/api/communications/entity/${ENTITY_TYPE}/${ENTITY_ID}/channels/${CHANNEL_KEY}" ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

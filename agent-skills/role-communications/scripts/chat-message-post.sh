#!/usr/bin/env bash
# version: 0.28.3
# Post one message on an entity discussion channel.
# File: chat-message-post.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/communications/entity/:entityType/:entityId/channels/:channelKey/messages.

set -euo pipefail

die() {
  echo "chat-message-post: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: chat-message-post.sh <entity_type> <entity_id> <channel_key> <payload.json>

entity_type and channel_key are 1..64 characters and must not contain /.
entity_id is a UUID.
payload.json is an object. body must be a non-empty string after trimming whitespace,
unless hasAttachments is true. If body is present it must be a string of at most 8000 characters.
Optional keys: replyToMessageId, mentionedUserIds.
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

[[ $# -eq 4 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
ENTITY_TYPE="$(trim_text "$1")"
ENTITY_ID="$(trim "$2")"
CHANNEL_KEY="$(trim_text "$3")"
PAYLOAD_FILE="$4"
require_path_token "entity_type" "$ENTITY_TYPE"
is_uuid "$ENTITY_ID" || die "not a UUID: $ENTITY_ID"
require_path_token "channel_key" "$CHANNEL_KEY"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: $PAYLOAD_FILE"
command -v jq >/dev/null 2>&1 || die "required command not found: jq"
jq -e 'type == "object" and (((.body | type == "string" and (gsub("^\\s+|\\s+$"; "") | length > 0))) or (.hasAttachments == true)) and ((has("body") | not) or (.body | type == "string" and length <= 8000))' "$PAYLOAD_FILE" >/dev/null \
  || die "payload must be a JSON object with a non-empty body or hasAttachments true, and body length <= 8000"
resolve_auth
bash "$AUTH_REQUEST_SCRIPT" POST "/api/communications/entity/${ENTITY_TYPE}/${ENTITY_ID}/channels/${CHANNEL_KEY}/messages" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

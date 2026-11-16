#!/usr/bin/env bash
# version: 0.28.3
# Edit one discussion message.
# File: chat-message-update.sh
#
# Changes in v0.28.3:
# - Initial script: PATCH /api/communications/messages/:id with a JSON body.

set -euo pipefail

die() {
  echo "chat-message-update: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: chat-message-update.sh <message_uuid> <payload.json>

payload.json is an object with at least one of body, mentionedUserIds, or hasAttachments.
A key that is omitted is left unchanged.
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

[[ $# -eq 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
MESSAGE_ID="$(trim "$1")"
PAYLOAD_FILE="$2"
[[ "$MESSAGE_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a UUID: $MESSAGE_ID"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: $PAYLOAD_FILE"
command -v jq >/dev/null 2>&1 || die "required command not found: jq"
jq -e 'type == "object" and (has("body") or has("mentionedUserIds") or has("hasAttachments"))' "$PAYLOAD_FILE" >/dev/null \
  || die "payload must be a JSON object with at least one of body, mentionedUserIds, or hasAttachments"
resolve_auth
bash "$AUTH_REQUEST_SCRIPT" PATCH "/api/communications/messages/${MESSAGE_ID}" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

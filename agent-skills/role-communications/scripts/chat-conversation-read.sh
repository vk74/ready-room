#!/usr/bin/env bash
# version: 0.28.3
# Advance the caller read cursor on a discussion conversation.
# File: chat-conversation-read.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/communications/conversations/:id/read.

set -euo pipefail

die() {
  echo "chat-conversation-read: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: chat-conversation-read.sh <conversation_uuid> [<last_read_message_uuid>]

Omit the message id to mark the conversation read through its latest message.
The conversation id comes from the channel payload (conversation_id).
Unread comm notifications for that entity are marked read as part of the same call.
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

[[ $# -ge 1 && $# -le 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
CONVERSATION_ID="$(trim "$1")"
[[ "$CONVERSATION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a UUID: $CONVERSATION_ID"
LAST_ID=""
if [[ $# -eq 2 ]]; then
  LAST_ID="$(trim "$2")"
  [[ "$LAST_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a UUID: $LAST_ID"
fi
command -v jq >/dev/null 2>&1 || die "required command not found: jq"
resolve_auth
TMP_BODY="$(mktemp)"
cleanup() {
  [[ -n "${TMP_BODY:-}" && -f "$TMP_BODY" ]] && rm -f "$TMP_BODY"
}
trap cleanup EXIT
if [[ -n "$LAST_ID" ]]; then
  jq -cn --arg id "$LAST_ID" '{lastReadMessageId: $id}' > "$TMP_BODY"
else
  printf '%s' '{}' > "$TMP_BODY"
fi
bash "$AUTH_REQUEST_SCRIPT" POST "/api/communications/conversations/${CONVERSATION_ID}/read" \
  -H "Content-Type: application/json" \
  --data-binary "@${TMP_BODY}"

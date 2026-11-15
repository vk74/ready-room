#!/usr/bin/env bash
# version: 0.28.3
# Post a message on the requester discussion channel of a service request.
# File: work-request-chat-post.sh
#
# Changes in v0.28.3:
# - Initial script: POST the requester channel messages endpoint with a JSON body.

set -euo pipefail

die() {
  echo "work-request-chat-post: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-request-chat-post.sh <request_uuid> <payload.json>

payload.json: {"body":"...", "replyToMessageId":"<uuid>", "mentionedUserIds":["<uuid>"]}
body is required. replyToMessageId and mentionedUserIds are optional.
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

[[ $# -eq 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
REQUEST_ID="$(trim "$1")"
PAYLOAD_FILE="$2"
[[ "$REQUEST_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a UUID: $REQUEST_ID"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: $PAYLOAD_FILE"
command -v jq >/dev/null 2>&1 || die "required command not found: jq"
jq -e 'type == "object" and (.body | type) == "string" and (.body | length) > 0' "$PAYLOAD_FILE" >/dev/null \
  || die "payload must be a JSON object with a non-empty string body"
resolve_auth
bash "$AUTH_REQUEST_SCRIPT" POST "/api/communications/entity/service_request/${REQUEST_ID}/channels/requester/messages" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

#!/usr/bin/env bash
# version: 0.28.3
# Add or remove the caller emoji reaction on one message.
# File: chat-message-reaction-toggle.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/communications/messages/:id/reactions.

set -euo pipefail

die() {
  echo "chat-message-reaction-toggle: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: chat-message-reaction-toggle.sh <message_uuid> <emoji>

emoji is 1..32 characters. The same call adds the reaction or removes it
when the caller already reacted with that emoji.
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
MESSAGE_ID="$(trim "$1")"
EMOJI="$(trim_text "$2")"
[[ "$MESSAGE_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a UUID: $MESSAGE_ID"
[[ -n "$EMOJI" ]] || die "emoji is required"
command -v jq >/dev/null 2>&1 || die "required command not found: jq"
jq -ne --arg emoji "$EMOJI" '($emoji | length) >= 1 and ($emoji | length) <= 32' >/dev/null \
  || die "emoji must be 1..32 characters"
resolve_auth
TMP_BODY="$(mktemp)"
cleanup() {
  [[ -n "${TMP_BODY:-}" && -f "$TMP_BODY" ]] && rm -f "$TMP_BODY"
}
trap cleanup EXIT
jq -cn --arg emoji "$EMOJI" '{emoji: $emoji}' > "$TMP_BODY"
bash "$AUTH_REQUEST_SCRIPT" POST "/api/communications/messages/${MESSAGE_ID}/reactions" \
  -H "Content-Type: application/json" \
  --data-binary "@${TMP_BODY}"

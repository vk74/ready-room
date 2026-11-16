#!/usr/bin/env bash
# version: 0.28.3
# Remove the pin from one discussion message.
# File: chat-message-unpin.sh
#
# Changes in v0.28.3:
# - Initial script: DELETE /api/communications/messages/:id/pin.

set -euo pipefail

die() {
  echo "chat-message-unpin: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: chat-message-unpin.sh <message_uuid>
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

[[ $# -eq 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
MESSAGE_ID="$(trim "$1")"
[[ "$MESSAGE_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a UUID: $MESSAGE_ID"
resolve_auth
bash "$AUTH_REQUEST_SCRIPT" DELETE "/api/communications/messages/${MESSAGE_ID}/pin"

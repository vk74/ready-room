#!/usr/bin/env bash
# version: 0.28.3
# Fetch one in-app notification owned by the calling principal.
# File: notifications-inbox-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/notifications/inbox/:id.

set -euo pipefail

die() {
  echo "notifications-inbox-get: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: notifications-inbox-get.sh <notification_uuid>
EOF
  exit 1
}

resolve_auth() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  AUTH_REQUEST_SCRIPT="${REQUEST_SCRIPT:-}"
  if [[ -z "$AUTH_REQUEST_SCRIPT" ]]; then
    for candidate in "${SCRIPT_DIR}/role-request.sh" "${SCRIPT_DIR}/_lib/role-request.sh" "${SCRIPT_DIR}/../../role-auth/scripts/role-request.sh"; do
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

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

[[ $# -eq 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
NOTIFICATION_ID="$(trim "$1")"
[[ -n "$NOTIFICATION_ID" ]] || usage
is_uuid "$NOTIFICATION_ID" || die "not a UUID: $NOTIFICATION_ID"

resolve_auth
bash "$AUTH_REQUEST_SCRIPT" GET "/api/notifications/inbox/${NOTIFICATION_ID}"

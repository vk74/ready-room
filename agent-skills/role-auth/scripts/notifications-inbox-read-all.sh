#!/usr/bin/env bash
# version: 0.28.3
# Mark every unread in-app notification as read.
# File: notifications-inbox-read-all.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/notifications/inbox/read-all.

set -euo pipefail

die() {
  echo "notifications-inbox-read-all: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: notifications-inbox-read-all.sh
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

if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h) usage ;;
    *) die "unknown argument: $1" ;;
  esac
fi

resolve_auth
bash "$AUTH_REQUEST_SCRIPT" POST /api/notifications/inbox/read-all

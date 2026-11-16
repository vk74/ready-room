#!/usr/bin/env bash
# version: 0.28.3
# List subjects the calling principal has muted.
# File: notifications-mutes-list.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/notifications/mutes.

set -euo pipefail

die() {
  echo "notifications-mutes-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: notifications-mutes-list.sh
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
bash "$AUTH_REQUEST_SCRIPT" GET /api/notifications/mutes

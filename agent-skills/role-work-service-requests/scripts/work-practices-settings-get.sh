#!/usr/bin/env bash
# version: 0.28.3
# Read standard settings the caller may see, including AdminApp.Practices when settings:read:common is held.
# File: work-practices-settings-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/core/settings.

set -euo pipefail

die() {
  echo "work-practices-settings-get: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-practices-settings-get.sh

Returns data.settings and data.defaults filtered to sections this account may read.
AdminApp.Practices holds escalation.practice_manager.policy, escalation.company_head.policy,
priority.matrix, and time_tracking.require_actual_on_close.
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

[[ $# -eq 0 ]] || usage
resolve_auth
bash "$AUTH_REQUEST_SCRIPT" GET /api/core/settings

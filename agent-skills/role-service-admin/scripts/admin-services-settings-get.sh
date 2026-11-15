#!/usr/bin/env bash
# version: 0.28.3
# Fetch application settings visible to the caller, including AdminApp.Services, AdminApp.Forms, and AdminApp.Practices.
# File: admin-services-settings-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/core/settings.

set -euo pipefail

die() {
  echo "admin-services-settings-get: $*" >&2
  exit 1
}

[[ $# -eq 0 ]] || die "unexpected argument: $1"

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

bash "$AUTH_REQUEST_SCRIPT" GET /api/core/settings

#!/usr/bin/env bash
# version: 0.28.3
# Fetch one admin service by UUID.
# File: admin-services-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/admin/app/services/fetchsingleservice?id=<service_uuid>.

set -euo pipefail

die() {
  echo "admin-services-get: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-services-get.sh <service_uuid>
EOF
  exit 1
}

require_uuid() {
  local label="$1"
  local value="$2"
  case "$value" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      ;;
    *)
      die "${label} must be a UUID"
      ;;
  esac
}

[[ $# -eq 1 ]] || usage
SERVICE_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$SERVICE_ID" ]] || die "service_uuid must not be empty"
require_uuid "service_uuid" "$SERVICE_ID"

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

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/services/fetchsingleservice \
  --get \
  --data-urlencode "id=${SERVICE_ID}"

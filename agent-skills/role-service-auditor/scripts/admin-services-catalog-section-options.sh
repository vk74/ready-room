#!/usr/bin/env bash
# version: 0.28.3
# List catalog sections available for service placement.
# File: admin-services-catalog-section-options.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/admin/app/services/catalog-section-options.

set -euo pipefail

die() {
  echo "admin-services-catalog-section-options: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-services-catalog-section-options.sh" >&2
  exit 1
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h) usage ;;
    *) die "unexpected argument: $1" ;;
  esac
fi

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

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/services/catalog-section-options

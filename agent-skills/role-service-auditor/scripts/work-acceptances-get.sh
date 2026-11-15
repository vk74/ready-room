#!/usr/bin/env bash
# version: 0.28.3
# Fetch one acceptance by UUID.
# File: work-acceptances-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/work/activities/acceptances/<acceptance_uuid>.

set -euo pipefail

die() {
  echo "work-acceptances-get: $*" >&2
  exit 1
}

usage() {
  echo "Usage: work-acceptances-get.sh <acceptance_uuid>" >&2
  exit 1
}

require_id() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || die "${label} must not be empty"
  case "$value" in
    *[/[:space:]?#%]*) die "${label} must not contain path characters" ;;
  esac
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  usage
fi
[[ $# -eq 1 ]] || usage
ACCEPTANCE_ID="$(printf '%s' "$1" | xargs)"
require_id acceptance_uuid "$ACCEPTANCE_ID"

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

bash "$AUTH_REQUEST_SCRIPT" GET "/api/work/activities/acceptances/${ACCEPTANCE_ID}"

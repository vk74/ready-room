#!/usr/bin/env bash
# version: 0.28.3
# Save a definition into a draft form version.
# File: admin-forms-version-save.sh
#
# Changes in v0.28.3:
# - Initial script: PUT /api/admin/app/forms/versions/<version_uuid> with a JSON body.
# - Sends Content-Type: application/json.

set -euo pipefail

die() {
  echo "admin-forms-version-save: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-forms-version-save.sh <version_uuid> <payload.json>
Payload: { "definition": { }, "changeNote": "..." }
definition must be a valid form definition for the form kind. An empty object is not valid.
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

[[ $# -eq 2 ]] || usage
VERSION_ID="$(printf '%s' "$1" | xargs)"
PAYLOAD_FILE="$2"
[[ -n "$VERSION_ID" ]] || usage
require_uuid "version_uuid" "$VERSION_ID"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: ${PAYLOAD_FILE}"

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

bash "$AUTH_REQUEST_SCRIPT" PUT "/api/admin/app/forms/versions/${VERSION_ID}" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

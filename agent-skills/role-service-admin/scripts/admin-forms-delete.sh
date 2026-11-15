#!/usr/bin/env bash
# version: 0.28.3
# Delete a work item form that is not bound to a service and not referenced by requests.
# File: admin-forms-delete.sh
#
# Changes in v0.28.3:
# - Initial script: DELETE /api/admin/app/forms/<form_uuid>.
# - Warns that deletion is destructive.

set -euo pipefail

die() {
  echo "admin-forms-delete: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-forms-delete.sh <form_uuid>
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
FORM_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$FORM_ID" ]] || die "form_uuid must not be empty"
require_uuid "form_uuid" "$FORM_ID"

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

echo "admin-forms-delete: warning: destructive — deletes the form. A form bound to a service, or referenced by a request, is refused." >&2

bash "$AUTH_REQUEST_SCRIPT" DELETE "/api/admin/app/forms/${FORM_ID}"

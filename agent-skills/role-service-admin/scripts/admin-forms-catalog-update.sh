#!/usr/bin/env bash
# version: 0.28.3
# Replace a form's catalog binding, status, order, and catalog translations.
# File: admin-forms-catalog-update.sh
#
# Changes in v0.28.3:
# - Initial script: PUT /api/admin/app/forms/<form_uuid>/catalog with a JSON body.
# - Warns that omitted or null serviceId unbinds the form and that translations replace every catalog translation.
# - Sends Content-Type: application/json.

set -euo pipefail

die() {
  echo "admin-forms-catalog-update: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-forms-catalog-update.sh <form_uuid> <payload.json>
Payload: { "serviceId": "<uuid>|null", "order": 1, "catalogStatus": "draft|active|on hold|discontinued", "translations": [{ "languageCode": "english", "title": "...", "subject": "..." }] }
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
FORM_ID="$(printf '%s' "$1" | xargs)"
PAYLOAD_FILE="$2"
[[ -n "$FORM_ID" ]] || usage
require_uuid "form_uuid" "$FORM_ID"
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

echo "admin-forms-catalog-update: warning: authoritative catalog write — omitted or null serviceId unbinds the form; translations replace every catalog translation; order is ignored when unbound" >&2

bash "$AUTH_REQUEST_SCRIPT" PUT "/api/admin/app/forms/${FORM_ID}/catalog" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

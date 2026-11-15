#!/usr/bin/env bash
# version: 0.28.3
# Update an admin service. Role fields replace junction roles; catalog_section_ids replaces placements.
# File: admin-services-update.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/admin/app/services/update with a JSON body.
# - Warns when translations or role fields are present (junction roles are replaced) and when catalog_section_ids is present (placements are replaced).
# - Sends Content-Type: application/json.

set -euo pipefail

die() {
  echo "admin-services-update: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-services-update.sh <payload.json>" >&2
  echo 'Payload must include "id". Omit catalog_section_ids to keep placements. Omit role fields and translations to keep junction roles.' >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
PAYLOAD_FILE="$1"
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

if command -v jq >/dev/null 2>&1; then
  if jq -e 'has("translations") or has("owner") or has("technical_owner") or has("dispatcher") or has("support_tier1") or has("support_tier2") or has("support_tier3") or has("translation_key") or has("icon_name") or has("comments")' "$PAYLOAD_FILE" >/dev/null 2>&1; then
    echo "admin-services-update: warning: translations or role/identity fields replace junction roles. dispatcher and support_tier1 are required in that payload. translations are upserted for languages with a non-empty name." >&2
  fi
  if jq -e 'has("catalog_section_ids") and .catalog_section_ids != null' "$PAYLOAD_FILE" >/dev/null 2>&1; then
    echo "admin-services-update: warning: catalog_section_ids replaces section placements. Omit the field to keep current sections. An empty array clears them." >&2
  fi
else
  echo "admin-services-update: warning: jq is not available, so this script cannot inspect the payload for junction-role or placement replacement" >&2
fi

bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/app/services/update \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

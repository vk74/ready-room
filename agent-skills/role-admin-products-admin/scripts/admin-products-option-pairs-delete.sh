#!/usr/bin/env bash
# version: 1.0.1
# Delete option-product pairs for a main product.
# File: admin-products-option-pairs-delete.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: POST /api/admin/products/delete-product-option-pairs with JSON payload file.
# - Warns when payload sets all: true (deletes every pair for the main product).

set -euo pipefail

die() {
  echo "admin-products-option-pairs-delete: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-option-pairs-delete.sh <payload.json>" >&2
  echo "Payload: { \"mainProductId\": \"uuid\", \"all\": false, \"selectedOptionIds\": [\"uuid\"] }" >&2
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
  if jq -e '.all == true' "$PAYLOAD_FILE" >/dev/null 2>&1; then
    echo "admin-products-option-pairs-delete: warning: all=true deletes every option pair for mainProductId" >&2
  fi
fi

bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/products/delete-product-option-pairs \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

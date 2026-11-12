#!/usr/bin/env bash
# version: 1.0.1
# Update option-product pairs for a main product.
# File: admin-products-option-pairs-update.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: POST /api/admin/products/update-product-option-pairs with JSON payload file.

set -euo pipefail

die() {
  echo "admin-products-option-pairs-update: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-option-pairs-update.sh <payload.json>" >&2
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

bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/products/update-product-option-pairs \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

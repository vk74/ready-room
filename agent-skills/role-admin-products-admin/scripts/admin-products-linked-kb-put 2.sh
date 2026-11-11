#!/usr/bin/env bash
# version: 1.0.1
# Replace all KB article links for a product (authoritative full set).
# File: admin-products-linked-kb-put.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: PUT /api/admin/products/:productId/linked-kb-articles with JSON payload file.
# - Warns that PUT is authoritative full replace; prefer admin-products-linked-kb-add.sh.

set -euo pipefail

die() {
  echo "admin-products-linked-kb-put: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-linked-kb-put.sh <product_id> <payload.json>" >&2
  echo "Payload: { \"articleIds\": [\"uuid\", ...] }" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
PRODUCT_ID="$(printf '%s' "$1" | xargs)"
PAYLOAD_FILE="$2"
[[ -n "$PRODUCT_ID" ]] || usage
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

echo "admin-products-linked-kb-put: warning: authoritative full replace — unlisted articles are unlinked; prefer admin-products-linked-kb-add.sh to add without dropping existing links" >&2

bash "$AUTH_REQUEST_SCRIPT" PUT "/api/admin/products/${PRODUCT_ID}/linked-kb-articles" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

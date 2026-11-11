#!/usr/bin/env bash
# version: 1.0.1
# Fetch KB articles linked to one product.
# File: admin-products-linked-kb-get.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET /api/admin/products/:productId/linked-kb-articles.

set -euo pipefail

die() {
  echo "admin-products-linked-kb-get: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-linked-kb-get.sh <product_id>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
PRODUCT_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$PRODUCT_ID" ]] || die "product_id must not be empty"

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

bash "$AUTH_REQUEST_SCRIPT" GET "/api/admin/products/${PRODUCT_ID}/linked-kb-articles"

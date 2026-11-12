#!/usr/bin/env bash
# version: 1.0.1
# Bulk import products from a JSON items array.
# File: admin-products-import.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: POST /api/admin/products/import with JSON payload file.
# - Recommends batches of 150 items or fewer (see references/api-contract.md).

set -euo pipefail

die() {
  echo "admin-products-import: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-import.sh <payload.json>" >&2
  echo "Payload: { \"items\": [...], \"overwriteExisting\": false }" >&2
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
  ITEM_COUNT="$(jq '.items | length' "$PAYLOAD_FILE" 2>/dev/null || echo 0)"
  if [[ "$ITEM_COUNT" -gt 150 ]]; then
    echo "admin-products-import: warning: payload has ${ITEM_COUNT} items — recommend batches of 150 or fewer per request" >&2
  fi
fi

bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/products/import \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

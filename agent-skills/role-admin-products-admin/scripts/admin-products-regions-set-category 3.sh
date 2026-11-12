#!/usr/bin/env bash
# version: 1.0.1
# Set one region's taxable category without dropping other region bindings.
# File: admin-products-regions-set-category.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET regions, merge one region_id, PUT full binding set.
# - Use --clear as category_id to remove the binding for that region only.

set -euo pipefail

die() {
  echo "admin-products-regions-set-category: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-regions-set-category.sh <product_id> <region_id> <category_id|--clear>" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
PRODUCT_ID="$(printf '%s' "$1" | xargs)"
TARGET_REGION_ID="$(printf '%s' "$2" | xargs)"
CATEGORY_ARG="$(printf '%s' "$3" | xargs)"
[[ -n "$PRODUCT_ID" && -n "$TARGET_REGION_ID" && -n "$CATEGORY_ARG" ]] || usage

case "$TARGET_REGION_ID" in
  *[!0-9]*)
    die "region_id must be a positive integer"
    ;;
esac

CLEAR_BINDING=0
TARGET_CATEGORY_ID=""
if [[ "$CATEGORY_ARG" == "--clear" ]]; then
  CLEAR_BINDING=1
else
  case "$CATEGORY_ARG" in
    *[!0-9]*)
      die "category_id must be a positive integer or --clear"
      ;;
  esac
  TARGET_CATEGORY_ID="$CATEGORY_ARG"
fi

command -v jq >/dev/null 2>&1 || die "required command not found: jq"

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

LIST_BODY="$(bash "$AUTH_REQUEST_SCRIPT" GET "/api/admin/products/${PRODUCT_ID}/regions")" \
  || die "failed to list regions for product ${PRODUCT_ID}"

REGIONS_JSON="$(printf '%s' "$LIST_BODY" | jq -c '.data // []')" \
  || die "unexpected response shape from GET regions"

if [[ "$CLEAR_BINDING" -eq 1 ]]; then
  PAYLOAD="$(jq -cn \
    --argjson regions "$REGIONS_JSON" \
    --argjson targetRegion "$TARGET_REGION_ID" \
    '
    def binding($rid; $cid):
      { region_id: ($rid | tonumber), category_id: ($cid | tonumber) };
    [
      ($regions[] |
        if (.region_id | tonumber) == ($targetRegion | tonumber) then
          empty
        elif .category_id != null then
          binding(.region_id; .category_id)
        else
          empty
        end)
    ] | { regions: . }
  ')"
else
  PAYLOAD="$(jq -cn \
    --argjson regions "$REGIONS_JSON" \
    --argjson targetRegion "$TARGET_REGION_ID" \
    --argjson targetCategory "$TARGET_CATEGORY_ID" \
    '
    def binding($rid; $cid):
      { region_id: ($rid | tonumber), category_id: ($cid | tonumber) };
    [
      ($regions[] |
        if (.region_id | tonumber) == ($targetRegion | tonumber) then
          binding(.region_id; $targetCategory)
        elif .category_id != null then
          binding(.region_id; .category_id)
        else
          empty
        end)
    ] | { regions: . }
  ')"
fi

BINDING_COUNT="$(printf '%s' "$PAYLOAD" | jq '.regions | length')"
if [[ "$CLEAR_BINDING" -eq 1 ]]; then
  echo "admin-products-regions-set-category: clearing binding for region ${TARGET_REGION_ID}, preserving ${BINDING_COUNT} other binding(s)" >&2
else
  echo "admin-products-regions-set-category: setting region ${TARGET_REGION_ID} to category ${TARGET_CATEGORY_ID}, preserving ${BINDING_COUNT} total binding(s) in PUT payload" >&2
fi

printf '%s' "$PAYLOAD" | bash "$AUTH_REQUEST_SCRIPT" PUT "/api/admin/products/${PRODUCT_ID}/regions" \
  -H "Content-Type: application/json" \
  --data-binary @-

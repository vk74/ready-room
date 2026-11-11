#!/usr/bin/env bash
# version: 1.0.1
# Add KB article links without dropping existing links (preserve-and-add helper).
# File: admin-products-linked-kb-add.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET linked articles, union new ids, PUT authoritative merged set.

set -euo pipefail

die() {
  echo "admin-products-linked-kb-add: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-linked-kb-add.sh <product_id> <article_id> [<article_id>...]" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage
PRODUCT_ID="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$PRODUCT_ID" ]] || usage

NEW_IDS=()
for id in "$@"; do
  trimmed="$(printf '%s' "$id" | xargs)"
  [[ -n "$trimmed" ]] || die "empty article_id argument"
  NEW_IDS+=("$trimmed")
done

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

LIST_BODY="$(bash "$AUTH_REQUEST_SCRIPT" GET "/api/admin/products/${PRODUCT_ID}/linked-kb-articles")" \
  || die "failed to list linked KB articles for product ${PRODUCT_ID}"

CURRENT_IDS_JSON="$(printf '%s' "$LIST_BODY" | jq -c '[.data[]?.article_id // empty] | map(select(. != null and . != ""))')" \
  || die "unexpected response shape from GET linked-kb-articles"

NEW_IDS_JSON="$(printf '%s\n' "${NEW_IDS[@]}" | jq -R . | jq -cs .)"
MERGED_JSON="$(jq -cn --argjson cur "$CURRENT_IDS_JSON" --argjson add "$NEW_IDS_JSON" '$cur + $add | unique')"

PAYLOAD="$(jq -cn --argjson ids "$MERGED_JSON" '{articleIds: $ids}')"
echo "admin-products-linked-kb-add: keeping $(printf '%s' "$CURRENT_IDS_JSON" | jq 'length') existing link(s), adding ${#NEW_IDS[@]} — final set $(printf '%s' "$MERGED_JSON" | jq 'length')" >&2

printf '%s' "$PAYLOAD" | bash "$AUTH_REQUEST_SCRIPT" PUT "/api/admin/products/${PRODUCT_ID}/linked-kb-articles" \
  -H "Content-Type: application/json" \
  --data-binary @-

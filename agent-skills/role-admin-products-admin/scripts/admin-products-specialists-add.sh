#!/usr/bin/env bash
# version: 1.0.1
# Add specialist groups without dropping existing groups (preserve-and-add helper).
# File: admin-products-specialists-add.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET product, union specialistsGroups, POST update with merged list.

set -euo pipefail

die() {
  echo "admin-products-specialists-add: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-specialists-add.sh <product_id> <group_name> [<group_name>...]" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage
PRODUCT_ID="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$PRODUCT_ID" ]] || usage

NEW_GROUPS=()
for name in "$@"; do
  trimmed="$(printf '%s' "$name" | xargs)"
  [[ -n "$trimmed" ]] || die "empty group_name argument"
  NEW_GROUPS+=("$trimmed")
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

FETCH_BODY="$(bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/products/fetch --get --data-urlencode "id=${PRODUCT_ID}")" \
  || die "failed to fetch product ${PRODUCT_ID}"

CURRENT_GROUPS_JSON="$(printf '%s' "$FETCH_BODY" | jq -c '[.data.specialistsGroups[]? // empty] | map(select(. != null and . != ""))')" \
  || die "unexpected response shape from GET fetch"

NEW_GROUPS_JSON="$(printf '%s\n' "${NEW_GROUPS[@]}" | jq -R . | jq -cs .)"
MERGED_JSON="$(jq -cn --argjson cur "$CURRENT_GROUPS_JSON" --argjson add "$NEW_GROUPS_JSON" '$cur + $add | unique')"

PAYLOAD="$(jq -cn --arg pid "$PRODUCT_ID" --argjson groups "$MERGED_JSON" '{productId: $pid, specialistsGroups: $groups}')"
echo "admin-products-specialists-add: keeping $(printf '%s' "$CURRENT_GROUPS_JSON" | jq 'length') existing group(s), adding ${#NEW_GROUPS[@]} — final set $(printf '%s' "$MERGED_JSON" | jq 'length')" >&2

printf '%s' "$PAYLOAD" | bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/products/update \
  -H "Content-Type: application/json" \
  --data-binary @-

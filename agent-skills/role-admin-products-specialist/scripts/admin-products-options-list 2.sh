#!/usr/bin/env bash
# version: 1.1.1
# List candidate option products for pairing (excludes one main product).
# File: admin-products-options-list.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Dropped published from --sort-by choices.
#
# Changes in v1.0.0:
# - Initial script: GET /api/admin/products/fetch-options with optional query flags.

set -euo pipefail

die() {
  echo "admin-products-options-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-products-options-list.sh [--page N] [--items-per-page N] [--search "<text>"]
       [--sort-by product_code|name|status_code|owner] [--sort-desc]
       [--exclude-product-id UUID] [--status CODE] [--language english|russian]
EOF
  exit 1
}

PAGE=""
ITEMS_PER_PAGE=""
SEARCH=""
SORT_BY=""
SORT_DESC=""
EXCLUDE_PRODUCT_ID=""
STATUS=""
LANGUAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --page"
      PAGE="$1"
      ;;
    --items-per-page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --items-per-page"
      ITEMS_PER_PAGE="$1"
      ;;
    --search)
      shift
      [[ $# -gt 0 ]] || die "missing value after --search"
      SEARCH="$1"
      ;;
    --sort-by)
      shift
      [[ $# -gt 0 ]] || die "missing value after --sort-by"
      SORT_BY="$1"
      ;;
    --sort-desc)
      SORT_DESC="true"
      ;;
    --exclude-product-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --exclude-product-id"
      EXCLUDE_PRODUCT_ID="$1"
      ;;
    --status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --status"
      STATUS="$1"
      ;;
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$1"
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

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

CURL_ARGS=(--get)
if [[ -n "$PAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "page=${PAGE}")
fi
if [[ -n "$ITEMS_PER_PAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "itemsPerPage=${ITEMS_PER_PAGE}")
fi
if [[ -n "$SEARCH" ]]; then
  CURL_ARGS+=(--data-urlencode "searchQuery=${SEARCH}")
fi
if [[ -n "$SORT_BY" ]]; then
  CURL_ARGS+=(--data-urlencode "sortBy=${SORT_BY}")
fi
if [[ -n "$SORT_DESC" ]]; then
  CURL_ARGS+=(--data-urlencode "sortDesc=${SORT_DESC}")
fi
if [[ -n "$EXCLUDE_PRODUCT_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "excludeProductId=${EXCLUDE_PRODUCT_ID}")
fi
if [[ -n "$STATUS" ]]; then
  CURL_ARGS+=(--data-urlencode "statusFilter=${STATUS}")
fi
if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "language=${LANGUAGE}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/products/fetch-options ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

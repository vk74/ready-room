#!/usr/bin/env bash
# version: 0.28.3
# List work item forms with optional pagination, search, filters, and sort.
# File: admin-forms-list.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/admin/app/forms/fetch-all.

set -euo pipefail

die() {
  echo "admin-forms-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-forms-list.sh [--page N] [--items-per-page N] [--search "<text>"]
       [--status draft|active]
       [--kind service_request|incident|problem|change|organization]
       [--service-id <uuid>]
       [--catalog-status "draft|active|on hold|discontinued"]
       [--catalog-binding bound|unbound]
       [--sort-by form_id|name|work_item_kind|status|service_name|owner|created_at|updated_at]
       [--sort-desc]
EOF
  exit 1
}

require_positive_int() {
  local label="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      die "${label} must be a positive integer"
      ;;
  esac
  local stripped="$value"
  while [[ "$stripped" == 0* ]]; do
    stripped="${stripped#0}"
  done
  [[ -n "$stripped" ]] || die "${label} must be a positive integer"
}
require_uuid() {
  local label="$1"
  local value="$2"
  case "$value" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      ;;
    *)
      die "${label} must be a UUID"
      ;;
  esac
}

PAGE=""
ITEMS_PER_PAGE=""
SEARCH=""
STATUS=""
KIND=""
SERVICE_ID=""
CATALOG_STATUS=""
CATALOG_BINDING=""
SORT_BY=""
SORT_DESC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --page"
      PAGE="$1"
      require_positive_int "--page" "$PAGE"
      ;;
    --items-per-page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --items-per-page"
      ITEMS_PER_PAGE="$1"
      require_positive_int "--items-per-page" "$ITEMS_PER_PAGE"
      ;;
    --search)
      shift
      [[ $# -gt 0 ]] || die "missing value after --search"
      SEARCH="$1"
      ;;
    --status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --status"
      STATUS="$1"
      case "$STATUS" in
        draft|active) ;;
        *) die "invalid --status: ${STATUS}" ;;
      esac
      ;;
    --kind)
      shift
      [[ $# -gt 0 ]] || die "missing value after --kind"
      KIND="$1"
      case "$KIND" in
        service_request|incident|problem|change|organization) ;;
        *) die "invalid --kind: ${KIND}" ;;
      esac
      ;;
    --service-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --service-id"
      SERVICE_ID="$(printf '%s' "$1" | xargs)"
      require_uuid "--service-id" "$SERVICE_ID"
      ;;
    --catalog-status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --catalog-status"
      CATALOG_STATUS="$1"
      case "$CATALOG_STATUS" in
        draft|active|"on hold"|discontinued) ;;
        *) die "invalid --catalog-status: ${CATALOG_STATUS}" ;;
      esac
      ;;
    --catalog-binding)
      shift
      [[ $# -gt 0 ]] || die "missing value after --catalog-binding"
      CATALOG_BINDING="$1"
      case "$CATALOG_BINDING" in
        bound|unbound) ;;
        *) die "invalid --catalog-binding: ${CATALOG_BINDING}" ;;
      esac
      ;;
    --sort-by)
      shift
      [[ $# -gt 0 ]] || die "missing value after --sort-by"
      SORT_BY="$1"
      case "$SORT_BY" in
        form_id|name|work_item_kind|status|service_name|owner|created_at|updated_at) ;;
        *) die "invalid --sort-by: ${SORT_BY}" ;;
      esac
      ;;
    --sort-desc)
      SORT_DESC="true"
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
if [[ -n "$STATUS" ]]; then
  CURL_ARGS+=(--data-urlencode "statusFilter=${STATUS}")
fi
if [[ -n "$KIND" ]]; then
  CURL_ARGS+=(--data-urlencode "kindFilter=${KIND}")
fi
if [[ -n "$SERVICE_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "serviceId=${SERVICE_ID}")
fi
if [[ -n "$CATALOG_STATUS" ]]; then
  CURL_ARGS+=(--data-urlencode "catalog_status=${CATALOG_STATUS}")
fi
if [[ -n "$CATALOG_BINDING" ]]; then
  CURL_ARGS+=(--data-urlencode "catalogBinding=${CATALOG_BINDING}")
fi
if [[ -n "$SORT_BY" ]]; then
  CURL_ARGS+=(--data-urlencode "sortBy=${SORT_BY}")
fi
if [[ -n "$SORT_DESC" ]]; then
  CURL_ARGS+=(--data-urlencode "sortDesc=${SORT_DESC}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/forms/fetch-all ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

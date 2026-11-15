#!/usr/bin/env bash
# version: 0.28.3
# List work-item forms with optional pagination, search, kind, and catalog filters.
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
       --status, --kind, --catalog-status, and --catalog-binding may be repeated.
EOF
  exit 1
}

one_of() {
  local label="$1"
  local value="$2"
  shift 2
  local allowed
  for allowed in "$@"; do
    [[ "$value" == "$allowed" ]] && return 0
  done
  die "invalid ${label}: ${value}"
}

positive_int() {
  local label="$1"
  local value="$2"
  local max="${3:-}"
  [[ "$value" =~ ^[1-9][0-9]{0,8}$ ]] || die "${label} must be a positive integer"
  if [[ -n "$max" ]] && [[ "$value" -gt "$max" ]]; then
    die "${label} must be <= ${max}"
  fi
}

require_id() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || die "${label} must not be empty"
  case "$value" in
    *[/[:space:]?#%]*) die "${label} must not contain path characters" ;;
  esac
}

PAGE=""
ITEMS_PER_PAGE=""
SEARCH=""
SORT_BY=""
SORT_DESC=""
SERVICE_ID=""
STATUSES=()
KINDS=()
CATALOG_STATUSES=()
BINDINGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --page"
      PAGE="$1"
      positive_int page "$PAGE"
      ;;
    --items-per-page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --items-per-page"
      ITEMS_PER_PAGE="$1"
      positive_int items-per-page "$ITEMS_PER_PAGE" 100
      ;;
    --search)
      shift
      [[ $# -gt 0 ]] || die "missing value after --search"
      SEARCH="$1"
      ;;
    --status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --status"
      one_of status "$1" draft active
      STATUSES+=("$1")
      ;;
    --kind)
      shift
      [[ $# -gt 0 ]] || die "missing value after --kind"
      one_of kind "$1" service_request incident problem change organization
      KINDS+=("$1")
      ;;
    --service-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --service-id"
      SERVICE_ID="$(printf '%s' "$1" | xargs)"
      require_id service-id "$SERVICE_ID"
      ;;
    --catalog-status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --catalog-status"
      one_of catalog-status "$1" draft active "on hold" discontinued
      CATALOG_STATUSES+=("$1")
      ;;
    --catalog-binding)
      shift
      [[ $# -gt 0 ]] || die "missing value after --catalog-binding"
      one_of catalog-binding "$1" bound unbound
      BINDINGS+=("$1")
      ;;
    --sort-by)
      shift
      [[ $# -gt 0 ]] || die "missing value after --sort-by"
      SORT_BY="$1"
      one_of sort-by "$SORT_BY" form_id name work_item_kind status service_name owner created_at updated_at
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
for status in ${STATUSES[@]+"${STATUSES[@]}"}; do
  CURL_ARGS+=(--data-urlencode "statusFilter=${status}")
done
for kind in ${KINDS[@]+"${KINDS[@]}"}; do
  CURL_ARGS+=(--data-urlencode "kindFilter=${kind}")
done
if [[ -n "$SERVICE_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "serviceId=${SERVICE_ID}")
fi
for catalog_status in ${CATALOG_STATUSES[@]+"${CATALOG_STATUSES[@]}"}; do
  CURL_ARGS+=(--data-urlencode "catalog_status=${catalog_status}")
done
for binding in ${BINDINGS[@]+"${BINDINGS[@]}"}; do
  CURL_ARGS+=(--data-urlencode "catalogBinding=${binding}")
done
if [[ -n "$SORT_BY" ]]; then
  CURL_ARGS+=(--data-urlencode "sortBy=${SORT_BY}")
fi
if [[ -n "$SORT_DESC" ]]; then
  CURL_ARGS+=(--data-urlencode "sortDesc=${SORT_DESC}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/forms/fetch-all ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

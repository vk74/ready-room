#!/usr/bin/env bash
# version: 0.28.3
# List admin services with optional pagination, search, sort, status, and language filters.
# File: admin-services-list.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/admin/app/services/fetchallservices.
# - Repeated --status flags are sent as repeated status query parameters.

set -euo pipefail

die() {
  echo "admin-services-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-services-list.sh [--page N] [--items-per-page N] [--search "<text>"]
       [--sort-by service_id|name|status|owner|technical_owner|created_at|modified_at]
       [--sort-desc]
       [--status draft|active|planned_maintenance|emergency_maintenance|archived]
       [--language english|russian]
       --status may be repeated.
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

PAGE=""
ITEMS_PER_PAGE=""
SEARCH=""
SORT_BY=""
SORT_DESC=""
LANGUAGE=""
STATUSES=()

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
    --sort-by)
      shift
      [[ $# -gt 0 ]] || die "missing value after --sort-by"
      SORT_BY="$1"
      case "$SORT_BY" in
        service_id|name|status|owner|technical_owner|created_at|modified_at) ;;
        *) die "invalid --sort-by: ${SORT_BY}" ;;
      esac
      ;;
    --sort-desc)
      SORT_DESC="true"
      ;;
    --status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --status"
      case "$1" in
        draft|active|planned_maintenance|emergency_maintenance|archived) ;;
        *) die "invalid --status: $1" ;;
      esac
      STATUSES+=("$1")
      ;;
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$1"
      case "$LANGUAGE" in
        english|russian) ;;
        *) die "invalid --language: ${LANGUAGE}" ;;
      esac
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
if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "language=${LANGUAGE}")
fi
for status in ${STATUSES[@]+"${STATUSES[@]}"}; do
  CURL_ARGS+=(--data-urlencode "status=${status}")
done

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/services/fetchallservices ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

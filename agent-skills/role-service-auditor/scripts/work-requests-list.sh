#!/usr/bin/env bash
# version: 0.28.3
# List service requests with optional queue, status, urgency, and assignment filters.
# File: work-requests-list.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/work/requests. Repeated --status and --urgency become repeated query params.

set -euo pipefail

die() {
  echo "work-requests-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-requests-list.sh [--scope mine|assigned|team|unassigned|all] [--search "<text>"]
       [--status new|in_progress|paused|resolved|reopened|closed|cancelled|failed]
       [--urgency low|medium|high|critical]
       [--service-id <uuid>]
       [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>]
       [--requester all|me|user] [--requester-user-id <uuid>]
       [--language english|russian] [--page N] [--items-per-page N]
       [--sort-by created_at|request_number|status|urgency|title|priority|service|form|requester|requested_for|assignee|group|resolved_at|closed_at|estimated_minutes|actual_minutes|activities_estimated_minutes|activities_actual_minutes|total_estimated_minutes|total_actual_minutes]
       [--sort-desc]
       --status and --urgency may be repeated.
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
SCOPE=""
ASSIGNEE=""
ASSIGNED_USER_ID=""
ASSIGNED_GROUP_ID=""
REQUESTER=""
REQUESTER_USER_ID=""
SERVICE_ID=""
LANGUAGE=""
STATUSES=()
URGENCIES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      shift
      [[ $# -gt 0 ]] || die "missing value after --scope"
      SCOPE="$1"
      one_of scope "$SCOPE" mine assigned team unassigned all
      ;;
    --search)
      shift
      [[ $# -gt 0 ]] || die "missing value after --search"
      SEARCH="$1"
      ;;
    --status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --status"
      one_of status "$1" new in_progress paused resolved reopened closed cancelled failed
      STATUSES+=("$1")
      ;;
    --urgency)
      shift
      [[ $# -gt 0 ]] || die "missing value after --urgency"
      one_of urgency "$1" low medium high critical
      URGENCIES+=("$1")
      ;;
    --service-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --service-id"
      SERVICE_ID="$(printf '%s' "$1" | xargs)"
      require_id service-id "$SERVICE_ID"
      ;;
    --assignee)
      shift
      [[ $# -gt 0 ]] || die "missing value after --assignee"
      ASSIGNEE="$1"
      one_of assignee "$ASSIGNEE" all me unassigned user
      ;;
    --assigned-user-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --assigned-user-id"
      ASSIGNED_USER_ID="$(printf '%s' "$1" | xargs)"
      require_id assigned-user-id "$ASSIGNED_USER_ID"
      ;;
    --assigned-group-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --assigned-group-id"
      ASSIGNED_GROUP_ID="$(printf '%s' "$1" | xargs)"
      require_id assigned-group-id "$ASSIGNED_GROUP_ID"
      ;;
    --requester)
      shift
      [[ $# -gt 0 ]] || die "missing value after --requester"
      REQUESTER="$1"
      one_of requester "$REQUESTER" all me user
      ;;
    --requester-user-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --requester-user-id"
      REQUESTER_USER_ID="$(printf '%s' "$1" | xargs)"
      require_id requester-user-id "$REQUESTER_USER_ID"
      ;;
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$1"
      one_of language "$LANGUAGE" english russian
      ;;
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
    --sort-by)
      shift
      [[ $# -gt 0 ]] || die "missing value after --sort-by"
      SORT_BY="$1"
      one_of sort-by "$SORT_BY" created_at request_number status urgency title priority service form requester requested_for assignee group resolved_at closed_at estimated_minutes actual_minutes activities_estimated_minutes activities_actual_minutes total_estimated_minutes total_actual_minutes
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
if [[ -n "$SCOPE" ]]; then
  CURL_ARGS+=(--data-urlencode "scope=${SCOPE}")
fi
if [[ -n "$SEARCH" ]]; then
  CURL_ARGS+=(--data-urlencode "search=${SEARCH}")
fi
for status in ${STATUSES[@]+"${STATUSES[@]}"}; do
  CURL_ARGS+=(--data-urlencode "status=${status}")
done
for urgency in ${URGENCIES[@]+"${URGENCIES[@]}"}; do
  CURL_ARGS+=(--data-urlencode "urgency=${urgency}")
done
if [[ -n "$SERVICE_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "serviceId=${SERVICE_ID}")
fi
if [[ -n "$ASSIGNEE" ]]; then
  CURL_ARGS+=(--data-urlencode "assignee=${ASSIGNEE}")
fi
if [[ -n "$ASSIGNED_USER_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "assignedUserId=${ASSIGNED_USER_ID}")
fi
if [[ -n "$ASSIGNED_GROUP_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "assignedGroupId=${ASSIGNED_GROUP_ID}")
fi
if [[ -n "$REQUESTER" ]]; then
  CURL_ARGS+=(--data-urlencode "requester=${REQUESTER}")
fi
if [[ -n "$REQUESTER_USER_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "requesterUserId=${REQUESTER_USER_ID}")
fi
if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "language=${LANGUAGE}")
fi
if [[ -n "$PAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "page=${PAGE}")
fi
if [[ -n "$ITEMS_PER_PAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "itemsPerPage=${ITEMS_PER_PAGE}")
fi
if [[ -n "$SORT_BY" ]]; then
  CURL_ARGS+=(--data-urlencode "sortBy=${SORT_BY}")
fi
if [[ -n "$SORT_DESC" ]]; then
  CURL_ARGS+=(--data-urlencode "sortDesc=${SORT_DESC}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/work/requests ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

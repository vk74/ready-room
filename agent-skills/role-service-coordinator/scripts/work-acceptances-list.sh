#!/usr/bin/env bash
# version: 0.28.3
# List acceptances (GET /api/work/activities/acceptances).
# File: work-acceptances-list.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/work/activities/acceptances with queue filters, paging, and sort.

set -euo pipefail

die() {
  echo "work-acceptances-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-acceptances-list.sh [--scope assigned|team|unassigned|all]
       [--search "<text>"] [--status new|in_progress|complete]...
       [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>]
       [--assigned-group-id <uuid>] [--page N] [--items-per-page N]
       [--sort-by <key>] [--sort-desc [true|false]]

Repeat --status to match any listed value. Search must be at least 2 characters.
Acceptance status has no paused value.
EOF
  exit 1
}

resolve_auth() {
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
}

trim() {
  printf '%s' "$1" | xargs
}

trim_text() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_bool_token() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|0|true|false|yes|no|on|off) return 0 ;;
    *) return 1 ;;
  esac
}

SCOPE=""
SEARCH=""
STATUSES=()
ASSIGNEE=""
ASSIGNED_USER_ID=""
ASSIGNED_GROUP_ID=""
PAGE=""
ITEMS_PER_PAGE=""
SORT_BY=""
SORT_DESC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      ;;
    --scope)
      shift
      [[ $# -gt 0 ]] || die "missing value after --scope"
      SCOPE="$(trim "$1")"
      ;;
    --search)
      shift
      [[ $# -gt 0 ]] || die "missing value after --search"
      SEARCH="$(trim_text "$1")"
      ;;
    --status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --status"
      STATUSES+=("$(trim "$1")")
      ;;
    --assignee)
      shift
      [[ $# -gt 0 ]] || die "missing value after --assignee"
      ASSIGNEE="$(trim "$1")"
      ;;
    --assigned-user-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --assigned-user-id"
      ASSIGNED_USER_ID="$(trim "$1")"
      ;;
    --assigned-group-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --assigned-group-id"
      ASSIGNED_GROUP_ID="$(trim "$1")"
      ;;
    --page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --page"
      PAGE="$(trim "$1")"
      ;;
    --items-per-page)
      shift
      [[ $# -gt 0 ]] || die "missing value after --items-per-page"
      ITEMS_PER_PAGE="$(trim "$1")"
      ;;
    --sort-by)
      shift
      [[ $# -gt 0 ]] || die "missing value after --sort-by"
      SORT_BY="$(trim "$1")"
      ;;
    --sort-desc)
      if [[ $# -ge 2 ]] && is_bool_token "$2"; then
        shift
        SORT_DESC="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
      else
        SORT_DESC="true"
      fi
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
resolve_auth

if [[ -n "$SCOPE" ]]; then
  case "$SCOPE" in
    assigned|team|unassigned|all) ;;
    *) die "scope must be one of: assigned, team, unassigned, all" ;;
  esac
fi
if [[ ${#STATUSES[@]} -gt 0 ]]; then
  for item in "${STATUSES[@]}"; do
    case "$item" in
      new|in_progress|complete) ;;
      *) die "status must be one of: new, in_progress, complete" ;;
    esac
  done
fi
if [[ -n "$ASSIGNEE" ]]; then
  case "$ASSIGNEE" in
    all|me|unassigned|user) ;;
    *) die "assignee must be one of: all, me, unassigned, user" ;;
  esac
fi
if [[ -n "$ASSIGNED_USER_ID" ]]; then
  is_uuid "$ASSIGNED_USER_ID" || die "assigned-user-id must be a UUID"
fi
if [[ -n "$ASSIGNED_GROUP_ID" ]]; then
  is_uuid "$ASSIGNED_GROUP_ID" || die "assigned-group-id must be a UUID"
fi
if [[ -n "$SEARCH" ]]; then
  search_chars="$(printf '%s' "$SEARCH" | jq -Rr 'length')"
  [[ "$search_chars" -ge 2 ]] || die "search must be at least 2 characters"
fi
if [[ -n "$PAGE" ]]; then
  [[ "$PAGE" =~ ^[1-9][0-9]*$ ]] || die "page must be an integer >= 1"
fi
if [[ -n "$ITEMS_PER_PAGE" ]]; then
  [[ "$ITEMS_PER_PAGE" =~ ^[1-9][0-9]*$ ]] || die "items-per-page must be an integer 1..100"
  [[ "$ITEMS_PER_PAGE" -le 100 ]] || die "items-per-page must be an integer 1..100"
fi
if [[ -n "$SORT_DESC" ]]; then
  case "$SORT_DESC" in
    1|true|yes|on) SORT_DESC="true" ;;
    0|false|no|off) SORT_DESC="false" ;;
    *) die "sort-desc must be true or false" ;;
  esac
fi

CURL_ARGS=(--get)
if [[ -n "$SCOPE" ]]; then
  CURL_ARGS+=(--data-urlencode "scope=${SCOPE}")
fi
if [[ -n "$SEARCH" ]]; then
  CURL_ARGS+=(--data-urlencode "search=${SEARCH}")
fi
if [[ ${#STATUSES[@]} -gt 0 ]]; then
  for item in "${STATUSES[@]}"; do
    CURL_ARGS+=(--data-urlencode "status=${item}")
  done
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
bash "$AUTH_REQUEST_SCRIPT" GET "/api/work/activities/acceptances" ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

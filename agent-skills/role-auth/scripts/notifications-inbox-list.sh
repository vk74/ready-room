#!/usr/bin/env bash
# version: 0.28.3
# List the calling principal's in-app notifications inbox.
# File: notifications-inbox-list.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/notifications/inbox with optional page, itemsPerPage, and unreadOnly.

set -euo pipefail

die() {
  echo "notifications-inbox-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: notifications-inbox-list.sh [--unread-only] [--page N] [--items-per-page N]

--unread-only sends unreadOnly=true. page is an integer >= 1.
items-per-page is an integer 1..100. Omitted query keys use the server defaults.
EOF
  exit 1
}

resolve_auth() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  AUTH_REQUEST_SCRIPT="${REQUEST_SCRIPT:-}"
  if [[ -z "$AUTH_REQUEST_SCRIPT" ]]; then
    for candidate in "${SCRIPT_DIR}/role-request.sh" "${SCRIPT_DIR}/_lib/role-request.sh" "${SCRIPT_DIR}/../../role-auth/scripts/role-request.sh"; do
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

UNREAD_ONLY="0"
PAGE=""
ITEMS_PER_PAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --unread-only) UNREAD_ONLY="1" ;;
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
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [[ -n "$PAGE" ]]; then
  [[ "$PAGE" =~ ^[1-9][0-9]*$ ]] || die "page must be an integer >= 1"
fi
if [[ -n "$ITEMS_PER_PAGE" ]]; then
  [[ "$ITEMS_PER_PAGE" =~ ^([1-9][0-9]?|100)$ ]] || die "items-per-page must be an integer 1..100"
fi

resolve_auth
CURL_ARGS=(--get)
if [[ "$UNREAD_ONLY" == "1" ]]; then
  CURL_ARGS+=(--data-urlencode "unreadOnly=true")
fi
if [[ -n "$PAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "page=${PAGE}")
fi
if [[ -n "$ITEMS_PER_PAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "itemsPerPage=${ITEMS_PER_PAGE}")
fi
bash "$AUTH_REQUEST_SCRIPT" GET /api/notifications/inbox ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

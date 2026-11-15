#!/usr/bin/env bash
# version: 0.28.3
# Read the requester discussion channel of a service request.
# File: work-request-chat-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/communications/entity/service_request/:id/channels/requester.

set -euo pipefail

die() {
  echo "work-request-chat-get: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-request-chat-get.sh <request_uuid> [--page N] [--items-per-page N]

The requester channel is the conversation between the requester and the support team.
Internal support notes stay on the request work_notes field.
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

[[ $# -ge 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
REQUEST_ID="$(trim "$1")"
shift
is_uuid "$REQUEST_ID" || die "not a UUID: $REQUEST_ID"

PAGE=""
ITEMS_PER_PAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
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
  [[ "$ITEMS_PER_PAGE" =~ ^[1-9][0-9]*$ ]] || die "items-per-page must be an integer >= 1"
fi

resolve_auth
CURL_ARGS=()
if [[ -n "$PAGE" || -n "$ITEMS_PER_PAGE" ]]; then
  CURL_ARGS=(--get)
  if [[ -n "$PAGE" ]]; then
    CURL_ARGS+=(--data-urlencode "page=${PAGE}")
  fi
  if [[ -n "$ITEMS_PER_PAGE" ]]; then
    CURL_ARGS+=(--data-urlencode "itemsPerPage=${ITEMS_PER_PAGE}")
  fi
fi
bash "$AUTH_REQUEST_SCRIPT" GET "/api/communications/entity/service_request/${REQUEST_ID}/channels/requester" ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

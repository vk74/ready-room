#!/usr/bin/env bash
# version: 0.28.3
# Read the requester discussion channel of one service request.
# File: work-request-chat-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/communications/entity/service_request/<request_uuid>/channels/requester.

set -euo pipefail

die() {
  echo "work-request-chat-get: $*" >&2
  exit 1
}

usage() {
  echo "Usage: work-request-chat-get.sh <request_uuid> [--page N] [--items-per-page N]" >&2
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

if [[ $# -ge 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  usage
fi
[[ $# -ge 1 ]] || usage
REQUEST_ID="$(printf '%s' "$1" | xargs)"
shift
require_id request_uuid "$REQUEST_ID"

PAGE=""
ITEMS_PER_PAGE=""
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

bash "$AUTH_REQUEST_SCRIPT" GET "/api/communications/entity/service_request/${REQUEST_ID}/channels/requester" ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

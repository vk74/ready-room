#!/usr/bin/env bash
# version: 0.28.3
# Search work-item forms for the service catalog picker.
# File: admin-services-forms-search.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/admin/app/services/forms/search.

set -euo pipefail

die() {
  echo "admin-services-forms-search: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-services-forms-search.sh [<query>] [--limit N] [--unbound]
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

QUERY=""
LIMIT=""
UNBOUND=""

if [[ $# -gt 0 && "$1" != --* && "$1" != "-h" ]]; then
  QUERY="$(printf '%s' "$1" | xargs)"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$1"
      positive_int limit "$LIMIT" 100
      ;;
    --unbound)
      UNBOUND="true"
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
if [[ -n "$QUERY" ]]; then
  CURL_ARGS+=(--data-urlencode "q=${QUERY}")
fi
if [[ -n "$LIMIT" ]]; then
  CURL_ARGS+=(--data-urlencode "limit=${LIMIT}")
fi
if [[ -n "$UNBOUND" ]]; then
  CURL_ARGS+=(--data-urlencode "unbound=${UNBOUND}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/services/forms/search ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

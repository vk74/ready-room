#!/usr/bin/env bash
# version: 0.28.3
# Search work item forms for the service catalog picker.
# File: admin-services-forms-search.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/admin/app/services/forms/search with q, limit, and unbound.
# - --unbound sends unbound=true and keeps only unbound service_request forms that have a current version.

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

QUERY=""
LIMIT=""
UNBOUND=""
SEEN_QUERY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$1"
      require_positive_int "--limit" "$LIMIT"
      ;;
    --unbound)
      UNBOUND="true"
      ;;
    --help|-h)
      usage
      ;;
    --*)
      die "unknown argument: $1"
      ;;
    *)
      [[ -z "$SEEN_QUERY" ]] || die "unexpected argument: $1"
      QUERY="$(printf '%s' "$1" | xargs)"
      SEEN_QUERY="yes"
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
  CURL_ARGS+=(--data-urlencode "unbound=true")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/services/forms/search ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

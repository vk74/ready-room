#!/usr/bin/env bash
# version: 0.28.3
# Search users for service owner and dispatcher pickers.
# File: core-search-users.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/core/item-selector/search-users.
# - --include-bots sends include_bots=true. --exclude-system sends exclude_system=true.

set -euo pipefail

die() {
  echo "core-search-users: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: core-search-users.sh <query> [--limit N] [--include-bots] [--exclude-system]
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

[[ $# -ge 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
QUERY="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$QUERY" ]] || usage
if [[ ${#QUERY} -lt 2 ]]; then
  die "query must be at least 2 characters"
fi

LIMIT=""
INCLUDE_BOTS=""
EXCLUDE_SYSTEM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$1"
      require_positive_int "--limit" "$LIMIT"
      ;;
    --include-bots)
      INCLUDE_BOTS="true"
      ;;
    --exclude-system)
      EXCLUDE_SYSTEM="true"
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

CURL_ARGS=(--get --data-urlencode "query=${QUERY}")
if [[ -n "$LIMIT" ]]; then
  CURL_ARGS+=(--data-urlencode "limit=${LIMIT}")
fi
if [[ -n "$INCLUDE_BOTS" ]]; then
  CURL_ARGS+=(--data-urlencode "include_bots=true")
fi
if [[ -n "$EXCLUDE_SYSTEM" ]]; then
  CURL_ARGS+=(--data-urlencode "exclude_system=true")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/core/item-selector/search-users ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

#!/usr/bin/env bash
# version: 0.28.3
# Search users for assignment and watcher pickers (GET /api/core/item-selector/search-users).
# File: core-search-users.sh
#
# Changes in v0.28.3:
# - Directory user search. Resolves role-request.sh from REQUEST_SCRIPT, this directory, scripts/_lib, then the monorepo role-auth path.

set -euo pipefail

die() {
  echo "core-search-users: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: core-search-users.sh <query> [--limit N] [--include-bots] [--exclude-system]

query must be at least 2 characters. limit is 1..100 (server default 20).
--include-bots sets include_bots=true. --exclude-system sets exclude_system=true.
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

trim_text() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

[[ $# -ge 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
QUERY="$(trim_text "$1")"
shift
[[ -n "$QUERY" ]] || usage

LIMIT=""
INCLUDE_BOTS="0"
EXCLUDE_SYSTEM="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$(trim "$1")"
      ;;
    --include-bots) INCLUDE_BOTS="1" ;;
    --exclude-system) EXCLUDE_SYSTEM="1" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
chars="$(printf '%s' "$QUERY" | jq -Rr 'length')"
[[ "$chars" -ge 2 ]] || die "query must be at least 2 characters"
if [[ -n "$LIMIT" ]]; then
  [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || die "limit must be an integer 1..100"
  [[ "$LIMIT" -le 100 ]] || die "limit must be an integer 1..100"
fi

resolve_auth
CURL_ARGS=(--get --data-urlencode "query=${QUERY}")
if [[ -n "$LIMIT" ]]; then
  CURL_ARGS+=(--data-urlencode "limit=${LIMIT}")
fi
if [[ "$INCLUDE_BOTS" == "1" ]]; then
  CURL_ARGS+=(--data-urlencode "include_bots=true")
fi
if [[ "$EXCLUDE_SYSTEM" == "1" ]]; then
  CURL_ARGS+=(--data-urlencode "exclude_system=true")
fi
bash "$AUTH_REQUEST_SCRIPT" GET /api/core/item-selector/search-users ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

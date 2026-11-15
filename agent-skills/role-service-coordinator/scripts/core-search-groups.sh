#!/usr/bin/env bash
# version: 0.28.3
# Search groups for assignment (GET /api/core/item-selector/search-groups).
# File: core-search-groups.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/core/item-selector/search-groups.

set -euo pipefail

die() {
  echo "core-search-groups: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: core-search-groups.sh <query> [--limit N] [--exclude-system]

query must be at least 2 characters. limit is 1..100 (server default 20).
--exclude-system sets exclude_system=true so system groups are omitted.
The work PATCH still rejects a system group as assigned_group_id.
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

[[ $# -ge 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
QUERY="$(trim_text "$1")"
shift
[[ -n "$QUERY" ]] || usage

LIMIT=""
EXCLUDE_SYSTEM="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$(trim "$1")"
      ;;
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
if [[ "$EXCLUDE_SYSTEM" == "1" ]]; then
  CURL_ARGS+=(--data-urlencode "exclude_system=true")
fi
bash "$AUTH_REQUEST_SCRIPT" GET /api/core/item-selector/search-groups ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

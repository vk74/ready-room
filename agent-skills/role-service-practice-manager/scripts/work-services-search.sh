#!/usr/bin/env bash
# version: 0.28.3
# Search services for the work picker (GET /api/work/services/search).
# File: work-services-search.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/work/services/search with q, limit, and language.

set -euo pipefail

die() {
  echo "work-services-search: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-services-search.sh <query> [--limit N] [--language english|russian]

limit must be an integer 1..100. The server uses 20 when limit is omitted.
language defaults to english on the server.
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
LANGUAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$(trim "$1")"
      ;;
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$(trim "$1")"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [[ -n "$LIMIT" ]]; then
  [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || die "limit must be an integer 1..100"
  [[ "$LIMIT" -le 100 ]] || die "limit must be an integer 1..100"
fi
if [[ -n "$LANGUAGE" ]]; then
  case "$LANGUAGE" in
    english|russian) ;;
    *) die "language must be english or russian" ;;
  esac
fi

resolve_auth
CURL_ARGS=(--get --data-urlencode "q=${QUERY}")
if [[ -n "$LIMIT" ]]; then
  CURL_ARGS+=(--data-urlencode "limit=${LIMIT}")
fi
if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "language=${LANGUAGE}")
fi
bash "$AUTH_REQUEST_SCRIPT" GET /api/work/services/search ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

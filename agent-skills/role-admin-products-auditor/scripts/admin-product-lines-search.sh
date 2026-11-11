#!/usr/bin/env bash
# version: 1.0.1
# Search admin product lines for read-only lookup flows.
# File: admin-product-lines-search.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET /api/admin/product-lines/search with q, limit, and language.

set -euo pipefail

die() {
  echo "admin-product-lines-search: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-product-lines-search.sh <query> [--limit N] [--language english|russian]
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
QUERY="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$QUERY" ]] || usage

LIMIT=""
LANGUAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$1"
      ;;
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$1"
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

CURL_ARGS=(--get --data-urlencode "q=${QUERY}")
if [[ -n "$LIMIT" ]]; then
  CURL_ARGS+=(--data-urlencode "limit=${LIMIT}")
fi
if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "language=${LANGUAGE}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/product-lines/search ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

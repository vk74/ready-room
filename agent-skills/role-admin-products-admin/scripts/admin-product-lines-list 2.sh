#!/usr/bin/env bash
# version: 1.1.1
# List admin product lines with optional filters.
# File: admin-product-lines-list.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Removed deprecated --published / publishedFilter query wiring.
# - Kept line list flags aligned with status-driven product-lines API.
#
# Changes in v1.0.0:
# - Initial script: GET /api/admin/product-lines/fetch-all with optional filters.

set -euo pipefail

die() {
  echo "admin-product-lines-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-product-lines-list.sh [--language english|russian] [--search "<text>"]
       [--status draft|active|on hold|archived]
EOF
  exit 1
}

LANGUAGE=""
SEARCH=""
STATUS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$1"
      ;;
    --search)
      shift
      [[ $# -gt 0 ]] || die "missing value after --search"
      SEARCH="$1"
      ;;
    --status)
      shift
      [[ $# -gt 0 ]] || die "missing value after --status"
      STATUS="$1"
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
if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "language=${LANGUAGE}")
fi
if [[ -n "$SEARCH" ]]; then
  CURL_ARGS+=(--data-urlencode "searchQuery=${SEARCH}")
fi
if [[ -n "$STATUS" ]]; then
  CURL_ARGS+=(--data-urlencode "statusFilter=${STATUS}")
fi
bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/product-lines/fetch-all ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

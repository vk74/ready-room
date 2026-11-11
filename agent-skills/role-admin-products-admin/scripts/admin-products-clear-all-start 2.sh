#!/usr/bin/env bash
# version: 1.0.1
# Start async clear-all of all admin products (destructive; requires --confirm).
# File: admin-products-clear-all-start.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: POST /api/admin/products/clear-all/start with confirm gate and optional batchSizeHint.

set -euo pipefail

die() {
  echo "admin-products-clear-all-start: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-products-clear-all-start.sh --confirm [--batch-size-hint N]

Starts an irreversible async job that deletes ALL products (snapshot at start).
Requires --confirm. Optional batch-size-hint: integer 100-50000 (server default 5000).
EOF
  exit 1
}

CONFIRM=""
BATCH_SIZE_HINT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)
      CONFIRM="1"
      ;;
    --batch-size-hint)
      shift
      [[ $# -gt 0 ]] || die "missing value after --batch-size-hint"
      BATCH_SIZE_HINT="$1"
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

[[ -n "$CONFIRM" ]] || usage

if [[ -n "$BATCH_SIZE_HINT" ]]; then
  case "$BATCH_SIZE_HINT" in
    *[!0-9]*)
      die "batch-size-hint must be a positive integer"
      ;;
  esac
  if [[ "$BATCH_SIZE_HINT" -lt 100 || "$BATCH_SIZE_HINT" -gt 50000 ]]; then
    die "batch-size-hint must be between 100 and 50000"
  fi
fi

command -v jq >/dev/null 2>&1 || die "required command not found: jq"

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

echo "admin-products-clear-all-start: warning: destructive — permanently deletes ALL products, FS files, and KB links" >&2

if [[ -n "$BATCH_SIZE_HINT" ]]; then
  PAYLOAD="$(jq -cn --argjson hint "$BATCH_SIZE_HINT" '{confirm: true, batchSizeHint: $hint}')"
else
  PAYLOAD='{"confirm":true}'
fi

printf '%s' "$PAYLOAD" | bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/products/clear-all/start \
  -H "Content-Type: application/json" \
  --data-binary @-

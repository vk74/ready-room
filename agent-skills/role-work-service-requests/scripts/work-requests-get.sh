#!/usr/bin/env bash
# version: 0.28.3
# Read one service request, including escalation targets (GET /api/work/requests/:id).
# File: work-requests-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/work/requests/:id with optional language.

set -euo pipefail

die() {
  echo "work-requests-get: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-requests-get.sh <request_uuid> [--language english|russian]
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

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

[[ $# -ge 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
ENTITY_ID="$(trim "$1")"
shift
[[ -n "$ENTITY_ID" ]] || usage
is_uuid "$ENTITY_ID" || die "not a UUID: $ENTITY_ID"

LANGUAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$(trim "$1")"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
if [[ -n "$LANGUAGE" ]]; then
  case "$LANGUAGE" in
    english|russian) ;;
    *) die "language must be english or russian" ;;
  esac
fi

resolve_auth
CURL_ARGS=()

if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS=(--get --data-urlencode "language=${LANGUAGE}")
fi
bash "$AUTH_REQUEST_SCRIPT" GET "/api/work/requests/${ENTITY_ID}" ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

#!/usr/bin/env bash
# version: 0.28.3
# Read one manual task (GET /api/work/activities/manual-tasks/:id).
# File: work-manual-tasks-get.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/work/activities/manual-tasks/:id.

set -euo pipefail

die() {
  echo "work-manual-tasks-get: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-manual-tasks-get.sh <task_uuid>
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

[[ $# -eq 0 ]] || usage

resolve_auth
CURL_ARGS=()
bash "$AUTH_REQUEST_SCRIPT" GET "/api/work/activities/manual-tasks/${ENTITY_ID}"

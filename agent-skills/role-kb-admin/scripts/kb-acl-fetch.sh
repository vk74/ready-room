#!/usr/bin/env bash
# version: 1.1.1
# Fetch KB tree ACL for read or update action.
# File: kb-acl-fetch.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: GET /api/core/visibility/fetch constrained to kb_tree entity type.

set -euo pipefail

die() {
  echo "kb-acl-fetch: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-acl-fetch.sh <tree_id> [read|update]" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage
TREE_ID="$(printf '%s' "$1" | xargs)"
ACTION="${2:-read}"
[[ -n "$TREE_ID" ]] || usage

case "$ACTION" in
  read|update) ;;
  *) die "action must be read or update" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the shared auth wrapper: env override, vendored copy, monorepo path.
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

bash "$AUTH_REQUEST_SCRIPT" GET /api/core/visibility/fetch \
  --get \
  --data-urlencode "entity_id=${TREE_ID}" \
  --data-urlencode "entity_type=kb_tree" \
  --data-urlencode "action=${ACTION}"

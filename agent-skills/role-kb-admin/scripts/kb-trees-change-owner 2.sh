#!/usr/bin/env bash
# version: 1.1.1
# Change KB tree owner.
# File: kb-trees-change-owner.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: POST /api/kb/trees/:id/change-owner.

set -euo pipefail

die() {
  echo "kb-trees-change-owner: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-trees-change-owner.sh <tree_id> <new_owner_user_id>" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
TREE_ID="$(printf '%s' "$1" | xargs)"
NEW_OWNER_ID="$(printf '%s' "$2" | xargs)"
[[ -n "$TREE_ID" && -n "$NEW_OWNER_ID" ]] || usage

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

REQUEST_BODY="$(jq -cn --arg newOwnerId "$NEW_OWNER_ID" '{newOwnerId:$newOwnerId}')"

bash "$AUTH_REQUEST_SCRIPT" POST "/api/kb/trees/${TREE_ID}/change-owner" \
  -H "Content-Type: application/json" \
  --data-binary "$REQUEST_BODY"

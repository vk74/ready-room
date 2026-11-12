#!/usr/bin/env bash
# version: 0.23.12
# Update KB tree ACL for read or update action.
# File: kb-acl-update.sh
#
# Changes in v0.23.12:
# - Payload audience replaces is_public. Allowed values: custom, staff,
#   registered, public. A missing audience is rejected instead of defaulting.
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: POST /api/core/visibility/update constrained to kb_tree entity type.

set -euo pipefail

die() {
  echo "kb-acl-update: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-acl-update.sh <tree_id> <read|update> <payload.json>" >&2
  echo "  payload.json requires audience: custom | staff | registered | public" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
TREE_ID="$(printf '%s' "$1" | xargs)"
ACTION="$(printf '%s' "$2" | xargs)"
PAYLOAD_FILE="$3"
[[ -n "$TREE_ID" ]] || usage
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: ${PAYLOAD_FILE}"

case "$ACTION" in
  read|update) ;;
  *) die "action must be read or update" ;;
esac

command -v jq >/dev/null 2>&1 || die "required command not found: jq"

AUDIENCE="$(jq -r '.audience // empty' "$PAYLOAD_FILE")"
case "$AUDIENCE" in
  custom|staff|registered|public) ;;
  *) die "payload audience must be custom, staff, registered, or public" ;;
esac

REQUEST_BODY="$(jq -c --arg entityId "$TREE_ID" --arg action "$ACTION" --arg audience "$AUDIENCE" '
  {
    entity_id: $entityId,
    entity_type: "kb_tree",
    action: $action,
    audience: $audience,
    allowed_groups: (.allowed_groups // []),
    allowed_users: (.allowed_users // []),
    denied_groups: (.denied_groups // []),
    denied_users: (.denied_users // [])
  }
' "$PAYLOAD_FILE")"

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

bash "$AUTH_REQUEST_SCRIPT" POST /api/core/visibility/update \
  -H "Content-Type: application/json" \
  --data-binary "$REQUEST_BODY"

#!/usr/bin/env bash
# version: 0.28.3
# Mute one subject and drop its unread inbox rows.
# File: notifications-mutes-add.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/notifications/mutes with a JSON object body.

set -euo pipefail

die() {
  echo "notifications-mutes-add: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: notifications-mutes-add.sh <payload.json>

payload.json is an object:
  subjectType    required string, 1..64 characters after trimming
  subjectId      required UUID string
  subjectNumber  optional string or null
  subjectTitle   optional string
EOF
  exit 1
}

resolve_auth() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  AUTH_REQUEST_SCRIPT="${REQUEST_SCRIPT:-}"
  if [[ -z "$AUTH_REQUEST_SCRIPT" ]]; then
    for candidate in "${SCRIPT_DIR}/role-request.sh" "${SCRIPT_DIR}/_lib/role-request.sh" "${SCRIPT_DIR}/../../role-auth/scripts/role-request.sh"; do
      if [[ -f "$candidate" ]]; then
        AUTH_REQUEST_SCRIPT="$candidate"
        break
      fi
    done
  fi
  [[ -n "$AUTH_REQUEST_SCRIPT" && -f "$AUTH_REQUEST_SCRIPT" ]] || die "cannot locate role-request.sh (set REQUEST_SCRIPT or restore scripts/_lib/)"
}

[[ $# -eq 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
PAYLOAD_FILE="$1"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: $PAYLOAD_FILE"

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
jq -e '
  def trimmed:
    if type == "string" then gsub("^\\s+|\\s+$"; "") else . end;
  type == "object"
  and (.subjectType | type == "string")
  and ((.subjectType | trimmed | length) >= 1)
  and ((.subjectType | trimmed | length) <= 64)
  and (.subjectId | type == "string")
  and ((.subjectId | trimmed) | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
  and ((has("subjectNumber") | not) or (.subjectNumber | type == "string" or type == "null"))
  and ((has("subjectTitle") | not) or (.subjectTitle | type == "string"))
' "$PAYLOAD_FILE" >/dev/null \
  || die "payload must be a JSON object with subjectType (1..64 characters) and subjectId (UUID); subjectNumber and subjectTitle are optional"

resolve_auth
bash "$AUTH_REQUEST_SCRIPT" POST /api/notifications/mutes \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

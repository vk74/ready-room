#!/usr/bin/env bash
# version: 0.28.3
# Mark every unread in-app notification for one subject as read.
# File: notifications-inbox-read-by-subject.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/notifications/inbox/read-by-subject with subjectType and subjectId.

set -euo pipefail

die() {
  echo "notifications-inbox-read-by-subject: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: notifications-inbox-read-by-subject.sh <subject_type> <subject_uuid>

subject_type is a non-empty string of 1..64 characters.
subject_uuid is a UUID. The script sends {"subjectType","subjectId"}.
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

trim() {
  printf '%s' "$1" | xargs
}

trim_text() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

[[ $# -eq 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
SUBJECT_TYPE="$(trim_text "$1")"
SUBJECT_UUID="$(trim "$2")"
[[ -n "$SUBJECT_TYPE" ]] || die "subject_type is required"
is_uuid "$SUBJECT_UUID" || die "not a UUID: $SUBJECT_UUID"

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
SUBJECT_LEN="$(printf '%s' "$SUBJECT_TYPE" | jq -Rs 'length')"
[[ "$SUBJECT_LEN" -ge 1 && "$SUBJECT_LEN" -le 64 ]] || die "subject_type must be 1..64 characters"

BODY="$(jq -cn --arg subjectType "$SUBJECT_TYPE" --arg subjectId "$SUBJECT_UUID" '{subjectType: $subjectType, subjectId: $subjectId}')"
[[ -n "$BODY" ]] || die "failed to build request body"

resolve_auth
bash "$AUTH_REQUEST_SCRIPT" POST /api/notifications/inbox/read-by-subject \
  -H "Content-Type: application/json" \
  --data-binary "$BODY"

#!/usr/bin/env bash
# version: 0.28.3
# Remove a subject mute for the calling principal.
# File: notifications-mutes-remove.sh
#
# Changes in v0.28.3:
# - Initial script: DELETE /api/notifications/mutes/:subjectType/:subjectId.

set -euo pipefail

die() {
  echo "notifications-mutes-remove: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: notifications-mutes-remove.sh <subject_type> <subject_uuid>

subject_type is 1..64 URL-safe characters (letters, digits, ".", "_", "~", "-")
and must not contain a slash. subject_uuid is a UUID.
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
[[ "$SUBJECT_TYPE" =~ ^[A-Za-z0-9._~-]+$ ]] || die "subject_type must be URL-safe and must not contain a slash"
[[ ${#SUBJECT_TYPE} -le 64 ]] || die "subject_type must be 1..64 characters"
is_uuid "$SUBJECT_UUID" || die "not a UUID: $SUBJECT_UUID"

resolve_auth
bash "$AUTH_REQUEST_SCRIPT" DELETE "/api/notifications/mutes/${SUBJECT_TYPE}/${SUBJECT_UUID}"

#!/usr/bin/env bash
# version: 0.28.3
# Discard a draft form version.
# File: admin-forms-version-discard.sh
#
# Changes in v0.28.3:
# - Initial script: DELETE /api/admin/app/forms/versions/<version_uuid>.
# - Warns that discarding a draft is destructive.

set -euo pipefail

die() {
  echo "admin-forms-version-discard: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-forms-version-discard.sh <version_uuid>
EOF
  exit 1
}

require_uuid() {
  local label="$1"
  local value="$2"
  case "$value" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      ;;
    *)
      die "${label} must be a UUID"
      ;;
  esac
}

[[ $# -eq 1 ]] || usage
VERSION_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$VERSION_ID" ]] || die "version_uuid must not be empty"
require_uuid "version_uuid" "$VERSION_ID"

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

echo "admin-forms-version-discard: warning: destructive — deletes the draft version. A published version is refused." >&2

bash "$AUTH_REQUEST_SCRIPT" DELETE "/api/admin/app/forms/versions/${VERSION_ID}"

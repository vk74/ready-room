#!/usr/bin/env bash
# version: 0.28.3
# Cancel a service request when the caller is the requester or the beneficiary.
# File: work-requests-cancel.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/work/requests/:id/cancel.

set -euo pipefail

die() {
  echo "work-requests-cancel: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-requests-cancel.sh <request_uuid>

Only the requester (requester_user_id) or the beneficiary (requested_for_user_id)
may cancel. The request must still be open: status must not be resolved, closed,
cancelled, or failed. Read can_cancel on the request first; it is true only in
that case. A caller who is not a party receives WORK-ERR-002. A party cancelling
a terminal status receives VAL-ERR-400.
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

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

[[ $# -eq 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
REQUEST_ID="$(trim "$1")"
[[ -n "$REQUEST_ID" ]] || usage
is_uuid "$REQUEST_ID" || die "not a UUID: $REQUEST_ID"

resolve_auth
bash "$AUTH_REQUEST_SCRIPT" POST "/api/work/requests/${REQUEST_ID}/cancel"

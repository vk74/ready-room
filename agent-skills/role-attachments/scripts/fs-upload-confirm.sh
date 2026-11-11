#!/usr/bin/env bash
# version: 1.1.1
# Confirm previously uploaded file by pending file_id via /api/fs/:id/confirm.
# File: fs-upload-confirm.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: POST confirm endpoint through shared authenticated wrapper.

set -euo pipefail

die() {
  echo "fs-upload-confirm: $*" >&2
  exit 1
}

usage() {
  echo "Usage: fs-upload-confirm.sh <file_id>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
FILE_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$FILE_ID" ]] || usage

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

bash "$AUTH_REQUEST_SCRIPT" POST "/api/fs/${FILE_ID}/confirm"

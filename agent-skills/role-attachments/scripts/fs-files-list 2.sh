#!/usr/bin/env bash
# version: 1.1.1
# List files for one parent entity via /api/fs?entity_type=&entity_id=.
# File: fs-files-list.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: list files for entity_type/entity_id using shared auth wrapper.

set -euo pipefail

die() {
  echo "fs-files-list: $*" >&2
  exit 1
}

usage() {
  echo "Usage: fs-files-list.sh <entity_type> <entity_id>" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
ENTITY_TYPE="$(printf '%s' "$1" | xargs)"
ENTITY_ID="$(printf '%s' "$2" | xargs)"
[[ -n "$ENTITY_TYPE" && -n "$ENTITY_ID" ]] || usage

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

bash "$AUTH_REQUEST_SCRIPT" GET "/api/fs?entity_type=${ENTITY_TYPE}&entity_id=${ENTITY_ID}"

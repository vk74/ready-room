#!/usr/bin/env bash
# version: 1.0.1
# Append one binary chunk to a KB tree import session.
# File: kb-trees-import-chunk.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: PUT /api/kb/trees/import/:sessionId/chunk?offset= with
#   Content-Type application/octet-stream (must be set so evi-request does
#   not auto-add application/json), --data-binary @chunk, --max-time 300.
#   Success KB-SUC-027, data {received, total_so_far}.

set -euo pipefail

die() {
  echo "kb-trees-import-chunk: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-trees-import-chunk.sh <session_id> <offset> <chunk.bin>" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
SESSION_ID="$(printf '%s' "$1" | xargs)"
OFFSET="$(printf '%s' "$2" | xargs)"
CHUNK_FILE="$(printf '%s' "$3" | xargs)"
[[ -n "$SESSION_ID" && -n "$OFFSET" && -n "$CHUNK_FILE" ]] || usage
[[ "$OFFSET" =~ ^[0-9]+$ ]] || die "offset must be a non-negative integer"
[[ -f "$CHUNK_FILE" ]] || die "chunk file not found: ${CHUNK_FILE}"

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

bash "$AUTH_REQUEST_SCRIPT" PUT "/api/kb/trees/import/${SESSION_ID}/chunk?offset=${OFFSET}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@${CHUNK_FILE}" \
  --max-time 300

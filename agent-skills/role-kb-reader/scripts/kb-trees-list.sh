#!/usr/bin/env bash
# version: 1.2.1
# List Knowledge Base trees visible to the caller (shelf or accessible scope).
# File: kb-trees-list.sh
#
# Changes in v1.2.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.2.0:
# - Optional first arg shelf|accessible (default shelf). accessible loads
#   GET /api/kb/trees?scope=accessible (all readable trees, no shelf filter).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: GET /api/kb/trees via shared auth request wrapper.

set -euo pipefail

die() {
  echo "kb-trees-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: kb-trees-list.sh [shelf|accessible]
  shelf (default): trees on the caller personal shelf
  accessible: all ACL-readable trees (no shelf filter)
EOF
  exit 1
}

SCOPE="shelf"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h)
      usage
      ;;
    *)
      SCOPE="$(printf '%s' "$1" | xargs)"
      ;;
  esac
  shift
fi
[[ $# -eq 0 ]] || usage
case "$SCOPE" in
  shelf|accessible) ;;
  *) die "scope must be shelf or accessible" ;;
esac

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

REQUEST_PATH="/api/kb/trees"
if [[ "$SCOPE" == "accessible" ]]; then
  REQUEST_PATH="/api/kb/trees?scope=accessible"
fi

bash "$AUTH_REQUEST_SCRIPT" GET "$REQUEST_PATH"

#!/usr/bin/env bash
# version: 1.1.1
# Link an existing article to a folder or tree root.
# File: kb-articles-link.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: POST /api/kb/articles/:id/link with --parent-node-id or --root.

set -euo pipefail

die() {
  echo "kb-articles-link: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  kb-articles-link.sh <article_id> --parent-node-id "<node_uuid>"
  kb-articles-link.sh <article_id> --root
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
ARTICLE_ID="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$ARTICLE_ID" ]] || usage

PARENT_NODE_ID=""
LINK_TO_ROOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parent-node-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --parent-node-id"
      PARENT_NODE_ID="$1"
      ;;
    --root)
      LINK_TO_ROOT=1
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ $LINK_TO_ROOT -eq 1 && -n "$PARENT_NODE_ID" ]]; then
  die "use either --root or --parent-node-id, not both"
fi
if [[ $LINK_TO_ROOT -eq 0 && -z "$PARENT_NODE_ID" ]]; then
  die "choose --root or --parent-node-id"
fi

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

REQUEST_BODY='{"parentNodeId":null}'
if [[ -n "$PARENT_NODE_ID" ]]; then
  REQUEST_BODY="$(jq -cn --arg parentNodeId "$PARENT_NODE_ID" '{parentNodeId:$parentNodeId}')"
fi

bash "$AUTH_REQUEST_SCRIPT" POST "/api/kb/articles/${ARTICLE_ID}/link" \
  -H "Content-Type: application/json" \
  --data-binary "$REQUEST_BODY"

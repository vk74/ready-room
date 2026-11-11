#!/usr/bin/env bash
# version: 1.2.1
# List published Knowledge Base articles with optional filters.
# File: kb-articles-list-published.sh
#
# Changes in v1.2.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.2.0:
# - Portability: expanding the empty CURL_ARGS array no longer trips `set -u`
#   on bash 3.2 (macOS default) — uses the ${arr[@]+...} idiom.
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: GET /api/kb/articles with optional q and tree_id parameters.

set -euo pipefail

die() {
  echo "kb-articles-list-published: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: kb-articles-list-published.sh [--query "<text>"] [--tree-id "<uuid>"]
EOF
  exit 1
}

QUERY=""
TREE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query)
      shift
      [[ $# -gt 0 ]] || die "missing value after --query"
      QUERY="$1"
      ;;
    --tree-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --tree-id"
      TREE_ID="$1"
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

CURL_ARGS=()
if [[ -n "$QUERY" || -n "$TREE_ID" ]]; then
  CURL_ARGS+=(--get)
fi
if [[ -n "$QUERY" ]]; then
  CURL_ARGS+=(--data-urlencode "q=${QUERY}")
fi
if [[ -n "$TREE_ID" ]]; then
  CURL_ARGS+=(--data-urlencode "tree_id=${TREE_ID}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/kb/articles ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

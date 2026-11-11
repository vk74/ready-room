#!/usr/bin/env bash
# version: 1.0.1
# List Knowledge Base change-history events for one tree, folder subtree, or article.
# File: kb-history-list.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET /api/kb/history with exactly one scope (tree_id,
#   folder_id+tree_id, or article_id) and optional keyset pagination.

set -euo pipefail

die() {
  echo "kb-history-list: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: kb-history-list.sh --tree-id UUID
       kb-history-list.sh --tree-id UUID --folder-id UUID
       kb-history-list.sh --article-id UUID
       [--limit N] [--before-at ISO] [--before-id UUID]
EOF
  exit 1
}

TREE_ID=""
FOLDER_ID=""
ARTICLE_ID=""
LIMIT=""
BEFORE_AT=""
BEFORE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --tree-id"
      TREE_ID="$(printf '%s' "$1" | xargs)"
      ;;
    --folder-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --folder-id"
      FOLDER_ID="$(printf '%s' "$1" | xargs)"
      ;;
    --article-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --article-id"
      ARTICLE_ID="$(printf '%s' "$1" | xargs)"
      ;;
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$(printf '%s' "$1" | xargs)"
      ;;
    --before-at)
      shift
      [[ $# -gt 0 ]] || die "missing value after --before-at"
      BEFORE_AT="$(printf '%s' "$1" | xargs)"
      ;;
    --before-id)
      shift
      [[ $# -gt 0 ]] || die "missing value after --before-id"
      BEFORE_ID="$(printf '%s' "$1" | xargs)"
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

if [[ -n "$ARTICLE_ID" ]]; then
  [[ -z "$TREE_ID" && -z "$FOLDER_ID" ]] || die "article scope cannot be combined with --tree-id or --folder-id"
elif [[ -n "$FOLDER_ID" ]]; then
  [[ -n "$TREE_ID" ]] || die "folder scope requires --tree-id and --folder-id"
elif [[ -n "$TREE_ID" ]]; then
  :
else
  usage
fi

if [[ -n "$LIMIT" ]]; then
  [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || die "limit must be a positive integer"
fi

if [[ -n "$BEFORE_AT" || -n "$BEFORE_ID" ]]; then
  [[ -n "$BEFORE_AT" && -n "$BEFORE_ID" ]] || die "keyset pagination requires both --before-at and --before-id"
fi

command -v jq >/dev/null 2>&1 || die "jq is required"

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

QUERY="$(jq -nr \
  --arg tree_id "$TREE_ID" \
  --arg folder_id "$FOLDER_ID" \
  --arg article_id "$ARTICLE_ID" \
  --arg limit "$LIMIT" \
  --arg before_at "$BEFORE_AT" \
  --arg before_id "$BEFORE_ID" \
  '
  [
    (if $tree_id != "" then "tree_id=\($tree_id|@uri)" else empty end),
    (if $folder_id != "" then "folder_id=\($folder_id|@uri)" else empty end),
    (if $article_id != "" then "article_id=\($article_id|@uri)" else empty end),
    (if $limit != "" then "limit=\($limit|@uri)" else empty end),
    (if $before_at != "" then "before_at=\($before_at|@uri)" else empty end),
    (if $before_id != "" then "before_id=\($before_id|@uri)" else empty end)
  ] | join("&")
  ')"

REQUEST_PATH="/api/kb/history"
if [[ -n "$QUERY" ]]; then
  REQUEST_PATH="${REQUEST_PATH}?${QUERY}"
fi

bash "$AUTH_REQUEST_SCRIPT" GET "$REQUEST_PATH"

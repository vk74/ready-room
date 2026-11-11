#!/usr/bin/env bash
# version: 1.0.1
# Add directional related-article links to a Knowledge Base article.
# File: kb-articles-related-add.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: POST /api/kb/articles/:id/related with target article ids.

set -euo pipefail

die() {
  echo "kb-articles-related-add: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-articles-related-add.sh <article_id> <target_article_id> [<target_article_id>...]" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required"
[[ $# -ge 2 ]] || usage

ARTICLE_ID="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$ARTICLE_ID" ]] || usage

TARGET_IDS=()
while [[ $# -gt 0 ]]; do
  target_id="$(printf '%s' "$1" | xargs)"
  if [[ -n "$target_id" ]]; then
    TARGET_IDS+=("$target_id")
  fi
  shift
done
[[ ${#TARGET_IDS[@]} -gt 0 ]] || die "provide at least one target article id"

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

REQUEST_BODY="$(jq -cn '$ARGS.positional | {article_ids: .}' --args ${TARGET_IDS[@]+"${TARGET_IDS[@]}"} )"

bash "$AUTH_REQUEST_SCRIPT" POST "/api/kb/articles/${ARTICLE_ID}/related" \
  -H "Content-Type: application/json" \
  --data-binary "$REQUEST_BODY"

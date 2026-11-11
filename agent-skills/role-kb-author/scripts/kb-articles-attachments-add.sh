#!/usr/bin/env bash
# version: 1.0.1
# Add files to a KB article's attachments without touching the existing set
# (safe preserve-and-add wrapper around the full-replace PUT semantics).
# File: kb-articles-attachments-add.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET /api/fs?entity_type=kb_article&entity_id=:id to load
#   the currently active file ids, union them with the ids passed on the
#   command line, then PUT /api/kb/articles/:id with the merged
#   attachment_file_ids list.
#
# Usage:
#   kb-articles-attachments-add.sh <article_id> <file_id> [<file_id>...]
#
# The file ids must already be uploaded and confirmed against this article
# (entity_type=kb_article, entity_id=<article_id>) — see the role-attachments
# skill. This script only updates the article's authoritative attachment set.

set -euo pipefail

die() {
  echo "kb-articles-attachments-add: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-articles-attachments-add.sh <article_id> <file_id> [<file_id>...]" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage
ARTICLE_ID="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$ARTICLE_ID" ]] || usage

NEW_IDS=()
for id in "$@"; do
  trimmed="$(printf '%s' "$id" | xargs)"
  [[ -n "$trimmed" ]] || die "empty file_id argument"
  NEW_IDS+=("$trimmed")
done

command -v jq >/dev/null 2>&1 || die "required command not found: jq"

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

# Step 1: load the article's currently active file ids.
LIST_BODY="$(bash "$AUTH_REQUEST_SCRIPT" GET "/api/fs?entity_type=kb_article&entity_id=${ARTICLE_ID}")" \
  || { printf '%s\n' "$LIST_BODY"; die "failed to list current files for article ${ARTICLE_ID}"; }

CURRENT_IDS_JSON="$(printf '%s' "$LIST_BODY" | jq -c '[.data.items[]?.file_id] | map(select(. != null and . != ""))')" \
  || die "unexpected response shape from GET /api/fs"

# Step 2: union current ids with the new ones (order-preserving, deduped).
NEW_IDS_JSON="$(printf '%s\n' "${NEW_IDS[@]}" | jq -R . | jq -cs .)"
MERGED_JSON="$(jq -cn --argjson cur "$CURRENT_IDS_JSON" --argjson add "$NEW_IDS_JSON" '$cur + $add | unique')"

PAYLOAD="$(jq -cn --argjson ids "$MERGED_JSON" '{attachment_file_ids: $ids}')"
echo "kb-articles-attachments-add: keeping $(printf '%s' "$CURRENT_IDS_JSON" | jq 'length') existing file(s), adding ${#NEW_IDS[@]} — final set $(printf '%s' "$MERGED_JSON" | jq 'length')" >&2

# Step 3: PUT the merged authoritative set.
printf '%s' "$PAYLOAD" | bash "$AUTH_REQUEST_SCRIPT" PUT "/api/kb/articles/${ARTICLE_ID}" \
  -H "Content-Type: application/json" \
  --data-binary @-

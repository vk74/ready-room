#!/usr/bin/env bash
# version: 1.0.1
# Reconcile KB related-article backing links to entityLink chips in article content.
# File: kb-articles-related-reconcile.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: extract kb_article entityLink ids from payload, diff against
#   GET /related, POST new links and DELETE removed ones.

set -euo pipefail

die() {
  echo "kb-articles-related-reconcile: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-articles-related-reconcile.sh <article_id> <content_payload.json>" >&2
  echo "  content_payload.json: kb.articles.update payload (or any JSON containing translations.*.content)" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
ARTICLE_ID="$(printf '%s' "$1" | xargs)"
PAYLOAD_FILE="$2"
[[ -n "$ARTICLE_ID" ]] || usage
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: ${PAYLOAD_FILE}"

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

# Collect entityLink.entityId values where entityType is kb_article (all translations).
DESIRED_JSON="$(jq -c '
  [ .. | objects
    | select(.type? == "entityLink" and (.attrs.entityType? // "") == "kb_article")
    | .attrs.entityId // empty
    | select(type == "string" and length > 0)
  ] | unique | sort
' "$PAYLOAD_FILE")"

ARTICLE_RESP="$(bash "$AUTH_REQUEST_SCRIPT" GET "/api/kb/articles/${ARTICLE_ID}")"
ARTICLE_TYPE="$(printf '%s' "$ARTICLE_RESP" | jq -r '.data.article_type_code // empty')"
if [[ "$ARTICLE_TYPE" == "reference_table" ]]; then
  echo "kb-articles-related-reconcile: skipped — reference_table has no rich-text body (no entityLink nodes)" >&2
  exit 0
fi

RELATED_RESP="$(bash "$AUTH_REQUEST_SCRIPT" GET "/api/kb/articles/${ARTICLE_ID}/related")"
CURRENT_JSON="$(printf '%s' "$RELATED_RESP" | jq -c '
  [.data.related_articles[]?.article_id // empty | select(length > 0)] | unique | sort
')"

TO_ADD_JSON="$(jq -cn --argjson desired "$DESIRED_JSON" --argjson current "$CURRENT_JSON" \
  '$desired - $current')"
TO_REMOVE_JSON="$(jq -cn --argjson desired "$DESIRED_JSON" --argjson current "$CURRENT_JSON" \
  '$current - $desired')"

TO_ADD_COUNT="$(printf '%s' "$TO_ADD_JSON" | jq 'length')"
TO_REMOVE_COUNT="$(printf '%s' "$TO_REMOVE_JSON" | jq 'length')"

if [[ "$TO_ADD_COUNT" -eq 0 && "$TO_REMOVE_COUNT" -eq 0 ]]; then
  jq -n --argjson desired "$DESIRED_JSON" \
    '{reconciled: true, added: 0, removed: 0, desired_ids: $desired}'
  exit 0
fi

ADDED=0
REMOVED=0

if [[ "$TO_ADD_COUNT" -gt 0 ]]; then
  REQUEST_BODY="$(jq -cn --argjson ids "$TO_ADD_JSON" '{article_ids: $ids}')"
  ADD_RESP="$(bash "$AUTH_REQUEST_SCRIPT" POST "/api/kb/articles/${ARTICLE_ID}/related" \
    -H "Content-Type: application/json" \
    --data-binary "$REQUEST_BODY")"
  ADDED="$(printf '%s' "$ADD_RESP" | jq -r '.data.added // 0')"
fi

if [[ "$TO_REMOVE_COUNT" -gt 0 ]]; then
  while IFS= read -r target_id; do
    [[ -n "$target_id" ]] || continue
    REMOVE_RESP="$(bash "$AUTH_REQUEST_SCRIPT" DELETE "/api/kb/articles/${ARTICLE_ID}/related/${target_id}")"
    one_removed="$(printf '%s' "$REMOVE_RESP" | jq -r '.data.removed // 0')"
    REMOVED=$((REMOVED + one_removed))
  done < <(printf '%s' "$TO_REMOVE_JSON" | jq -r '.[]')
fi

jq -n \
  --argjson desired "$DESIRED_JSON" \
  --argjson added "$ADDED" \
  --argjson removed "$REMOVED" \
  '{reconciled: true, added: $added, removed: $removed, desired_ids: $desired}'

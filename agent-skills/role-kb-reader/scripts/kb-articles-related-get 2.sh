#!/usr/bin/env bash
# version: 1.0.1
# List related articles for a Knowledge Base article.
# File: kb-articles-related-get.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: GET /api/kb/articles/:id/related.

set -euo pipefail

die() {
  echo "kb-articles-related-get: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-articles-related-get.sh <article_id>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
ARTICLE_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$ARTICLE_ID" ]] || usage

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

bash "$AUTH_REQUEST_SCRIPT" GET "/api/kb/articles/${ARTICLE_ID}/related"

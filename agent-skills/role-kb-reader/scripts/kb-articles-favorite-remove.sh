#!/usr/bin/env bash
# version: 1.0.1
# Remove a Knowledge Base article from the caller personal favorites.
# File: kb-articles-favorite-remove.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: DELETE /api/kb/articles/:id/favorite via shared auth request wrapper.

set -euo pipefail

die() {
  echo "kb-articles-favorite-remove: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-articles-favorite-remove.sh <article_id>" >&2
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

bash "$AUTH_REQUEST_SCRIPT" DELETE "/api/kb/articles/${ARTICLE_ID}/favorite"

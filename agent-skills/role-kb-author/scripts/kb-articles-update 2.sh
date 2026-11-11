#!/usr/bin/env bash
# version: 1.1.1
# Update one KB article content/metadata.
# File: kb-articles-update.sh
#
# Changes in v1.1.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
# - Warn on stderr when the payload omits attachment_file_ids: a present
#   field is an authoritative full replace; an omitted field preserves the
#   currently stored files (server-side contract).
#
# Changes in v1.0.0:
# - Initial script: PUT /api/kb/articles/:id with JSON payload file.

set -euo pipefail

die() {
  echo "kb-articles-update: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-articles-update.sh <article_id> <payload.json>" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
ARTICLE_ID="$(printf '%s' "$1" | xargs)"
PAYLOAD_FILE="$2"
[[ -n "$ARTICLE_ID" ]] || usage
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: ${PAYLOAD_FILE}"

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

# attachment_file_ids semantics: when present it is the authoritative full
# set of attachments (files missing from it are scheduled for deletion);
# when omitted the server preserves currently stored files. Surface a hint
# so callers make the choice consciously.
if command -v jq >/dev/null 2>&1; then
  if ! jq -e 'has("attachment_file_ids")' "$PAYLOAD_FILE" >/dev/null 2>&1; then
    echo "kb-articles-update: note: payload has no attachment_file_ids — existing attachments are preserved; include the full id set to replace them (see references/api-contract.md)" >&2
  fi
fi

bash "$AUTH_REQUEST_SCRIPT" PUT "/api/kb/articles/${ARTICLE_ID}" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

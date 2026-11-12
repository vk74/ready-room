#!/usr/bin/env bash
# version: 1.0.1
# Fetch external URL metadata for externalLink preview enrichment.
# File: core-link-preview.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: POST /api/core/link-preview with a URL argument.

set -euo pipefail

die() {
  echo "core-link-preview: $*" >&2
  exit 1
}

usage() {
  echo "Usage: core-link-preview.sh <url>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
URL="$(printf '%s' "$1" | xargs)"
[[ -n "$URL" ]] || usage

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

REQUEST_BODY="$(jq -cn --arg url "$URL" '{url: $url}')"

bash "$AUTH_REQUEST_SCRIPT" POST "/api/core/link-preview" \
  -H "Content-Type: application/json" \
  --data-binary "$REQUEST_BODY"

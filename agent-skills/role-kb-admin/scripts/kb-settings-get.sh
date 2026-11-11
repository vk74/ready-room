#!/usr/bin/env bash
# version: 0.23.12
# Read Knowledge Base file quotas from GET /api/core/settings.
# File: kb-settings-get.sh
#
# Changes in v0.23.12:
# - Initial script: prints KnowledgeBase.Fs.Quotas. Public KnowledgeBase
#   flags are not in this response.

set -euo pipefail

die() {
  echo "kb-settings-get: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-settings-get.sh" >&2
  exit 1
}

[[ $# -eq 0 ]] || usage

command -v jq >/dev/null 2>&1 || die "required command not found: jq"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

BODY="$(bash "$AUTH_REQUEST_SCRIPT" GET /api/core/settings)" || {
  printf '%s\n' "$BODY"
  die "failed to read settings"
}

printf '%s\n' "$BODY" | jq -c '
  {
    success,
    code,
    data: {
      quotas: (.data.settings["KnowledgeBase.Fs.Quotas"] // null)
    }
  }
'
echo "kb-settings-get: public KnowledgeBase flags (allow.all.registered.to.view.module, allow.all.registered.to.create.trees, allowed.languages) are not in this response" >&2

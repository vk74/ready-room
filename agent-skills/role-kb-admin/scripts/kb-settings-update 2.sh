#!/usr/bin/env bash
# version: 0.23.12
# Update one Knowledge Base module setting or file quota.
# File: kb-settings-update.sh
#
# Changes in v0.23.12:
# - Initial script: POST /api/admin/settings/update for section KnowledgeBase
#   or KnowledgeBase.Fs.Quotas. Rejects null. Confirmation is data.value.

set -euo pipefail

die() {
  echo "kb-settings-update: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-settings-update.sh <sectionPath> <settingName> <jsonValue>" >&2
  echo "  sectionPath: KnowledgeBase | KnowledgeBase.Fs.Quotas" >&2
  echo "  jsonValue: raw JSON (true, false, 250, [\"english\",\"russian\"])" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
SECTION="$(printf '%s' "$1" | xargs)"
NAME="$(printf '%s' "$2" | xargs)"
RAW_VALUE="$3"
[[ -n "$SECTION" && -n "$NAME" && -n "$RAW_VALUE" ]] || usage

case "$SECTION" in
  KnowledgeBase|KnowledgeBase.Fs.Quotas) ;;
  *) die "sectionPath must be KnowledgeBase or KnowledgeBase.Fs.Quotas" ;;
esac

command -v jq >/dev/null 2>&1 || die "required command not found: jq"

if ! VALUE_JSON="$(jq -cn --arg raw "$RAW_VALUE" '$raw | fromjson')"; then
  die "jsonValue must be valid JSON"
fi
if [[ "$VALUE_JSON" == "null" ]]; then
  die "jsonValue must not be null; public KnowledgeBase flags are absent from GET /api/core/settings"
fi

REQUEST_BODY="$(jq -cn --arg section "$SECTION" --arg name "$NAME" --argjson value "$VALUE_JSON" \
  '{sectionPath: $section, settingName: $name, value: $value}')"

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

printf '%s' "$REQUEST_BODY" | bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/settings/update \
  -H "Content-Type: application/json" \
  --data-binary @-

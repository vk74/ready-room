#!/usr/bin/env bash
# version: 1.0.1
# Set AdminProducts.allowed.languages to an explicit language list.
# File: admin-products-allowed-languages-set.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial helper: builds settings update payload and POST /api/admin/settings/update.

set -euo pipefail

die() {
  echo "admin-products-allowed-languages-set: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-products-allowed-languages-set.sh <language> [<language>...]" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage

LANGUAGES=()
for lang in "$@"; do
  trimmed="$(printf '%s' "$lang" | xargs)"
  [[ -n "$trimmed" ]] || die "empty language argument"
  LANGUAGES+=("$trimmed")
done

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

LANGS_JSON="$(printf '%s\n' "${LANGUAGES[@]}" | jq -R . | jq -cs .)"
PAYLOAD="$(jq -cn \
  --argjson langs "$LANGS_JSON" \
  '{sectionPath: "AdminProducts", settingName: "allowed.languages", value: $langs}')"

printf '%s' "$PAYLOAD" | bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/settings/update \
  -H "Content-Type: application/json" \
  --data-binary @-

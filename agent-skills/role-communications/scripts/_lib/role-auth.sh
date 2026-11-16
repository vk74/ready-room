#!/usr/bin/env bash
# version: 1.5.0
# Exchange API_KEY for a short-lived Bearer JWT and cache it.
# File: role-auth.sh
#
# Changes in v1.5.0:
# - Renamed skill/script from evi-auth to role-auth; cache evi-auth.json →
#   role-auth.json; persisted file evi.env → role.env; dropped EVI_ prefix
#   from env vars (BASE_URL, API_KEY, TLS_INSECURE, CA_CERT_FILE, ENV_FILE,
#   ACCESS_TOKEN).
#
# Changes in v1.4.1:
# - Renamed API key format prefix from evik_ to bkey_ in validation and error text.
#
# Changes in v1.4.0:
# - Environment-file fallback: when BASE_URL / API_KEY are absent
#   (agent tool calls often run in fresh shells where exports do not
#   persist), settings are loaded from ${AGENT_HOME:-$HOME/.agent-skills}/role.env
#   (override path with ENV_FILE). Real environment variables always win
#   over file values. Write the file with role-setup.sh.
# - Portability: expanding the empty CURL_TLS_ARGS array no longer trips
#   `set -u` on bash 3.2 (macOS default) — uses the ${arr[@]+...} idiom.
#
# Changes in v1.3.0:
# - Portability: replaced bash-4-only ${1,,} lowercase expansion with tr so
#   the script runs on bash 3.2 (macOS default) and other older hosts.
#
# Changes in v1.2.0:
# - Switched default cache location to ${AGENT_HOME:-$HOME/.agent-skills}/cache.
# - Removed host-specific environment-file hints from validation errors.
#
# Changes in v1.1.0:
# - Added TLS options for self-signed or custom CA deployments.
# - Sends JSON body via stdin to avoid exposing API key in curl argv.
# - Emits explicit hint when /api/auth/bot/token returns 404.
#
# Changes in v1.0.0:
# - Initial bot API-key exchange and auth cache flow.
#
# Exit codes: 0 success, 1 missing/invalid env, 2 auth failed, 3 parse/dependency error

set -euo pipefail

CACHE_DIR="${AGENT_HOME:-$HOME/.agent-skills}/cache"
CACHE_FILE="${CACHE_DIR}/role-auth.json"
ENV_FILE="${ENV_FILE:-${AGENT_HOME:-$HOME/.agent-skills}/role.env}"

# Agent tool calls often run in fresh shells where variables exported in a
# previous call are gone. When the key variables are missing, fall back to
# the persisted env file written by role-setup.sh. Real environment variables
# always take precedence over file values.
load_env_file() {
  [[ -r "$ENV_FILE" ]] || return 0
  if [[ -n "${BASE_URL:-}" && -n "${API_KEY:-}" ]]; then
    return 0
  fi
  local prev_base="${BASE_URL:-}" prev_key="${API_KEY:-}"
  local prev_tls="${TLS_INSECURE:-}" prev_ca="${CA_CERT_FILE:-}"
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
  if [[ -n "$prev_base" ]]; then BASE_URL="$prev_base"; fi
  if [[ -n "$prev_key" ]]; then API_KEY="$prev_key"; fi
  if [[ -n "$prev_tls" ]]; then TLS_INSECURE="$prev_tls"; fi
  if [[ -n "$prev_ca" ]]; then CA_CERT_FILE="$prev_ca"; fi
}
load_env_file

die() {
  echo "role-auth: $*" >&2
  exit "${2:-1}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1" 3
}

is_truthy() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_base_url() {
  local url="${1%/}"
  printf '%s' "$url"
}

validate_api_key_format() {
  local key="$1"
  [[ "$key" == bkey_* ]] || return 1
  local rest="${key#bkey_}"
  local key_id="${rest%%_*}"
  local secret="${rest#*_}"
  [[ -n "$key_id" && -n "$secret" && "$key_id" != "$secret" ]] || return 1
  return 0
}

require_cmd curl
require_cmd jq

[[ -n "${BASE_URL:-}" ]] || die "BASE_URL is not set (export it or run role-setup.sh to persist it in ${ENV_FILE})" 1
[[ -n "${API_KEY:-}" ]] || die "API_KEY is not set (export it or run role-setup.sh to persist it in ${ENV_FILE})" 1

BASE_URL="$(normalize_base_url "$BASE_URL")"
API_KEY="$(printf '%s' "$API_KEY" | tr -d '[:space:]')"
TLS_INSECURE_RAW="${TLS_INSECURE:-0}"
CA_CERT_FILE="${CA_CERT_FILE:-}"

validate_api_key_format "$API_KEY" || die "API_KEY must match bkey_<key_id>_<secret>" 1

CURL_TLS_ARGS=()
if [[ -n "$CA_CERT_FILE" ]]; then
  [[ -r "$CA_CERT_FILE" ]] || die "CA_CERT_FILE is not readable: $CA_CERT_FILE" 1
  CURL_TLS_ARGS+=(--cacert "$CA_CERT_FILE")
elif is_truthy "$TLS_INSECURE_RAW"; then
  CURL_TLS_ARGS+=(-k)
fi

REQUEST_BODY="$(jq -n --arg k "$API_KEY" '{api_key: $k}')"

HTTP_RESPONSE="$(printf '%s' "$REQUEST_BODY" | curl -sS -w $'\n%{http_code}' -X POST \
  "${BASE_URL}/api/auth/bot/token" \
  -H "Content-Type: application/json" \
  ${CURL_TLS_ARGS[@]+"${CURL_TLS_ARGS[@]}"} \
  --data-binary @-)" || die "network error calling /api/auth/bot/token" 2

HTTP_BODY="$(printf '%s' "$HTTP_RESPONSE" | sed '$d')"
HTTP_CODE="$(printf '%s' "$HTTP_RESPONSE" | tail -n 1)"

SUCCESS="$(printf '%s' "$HTTP_BODY" | jq -r '.success // false')"
RESP_CODE="$(printf '%s' "$HTTP_BODY" | jq -r '.code // empty')"

if [[ "$SUCCESS" != "true" || "$RESP_CODE" != "BOT_AUTH-SUC-001" ]]; then
  echo "role-auth: authentication failed (HTTP ${HTTP_CODE}, code=${RESP_CODE:-unknown})" >&2
  if [[ "$HTTP_CODE" == "404" ]]; then
    echo "role-auth: /api/auth/bot/token is missing. Check that evi backend and /api proxy are running." >&2
  fi
  printf '%s\n' "$HTTP_BODY" | jq . >&2 2>/dev/null || printf '%s\n' "$HTTP_BODY" >&2
  exit 2
fi

ACCESS_TOKEN="$(printf '%s' "$HTTP_BODY" | jq -r '.data.accessToken // empty')"
ACCESS_EXPIRES="$(printf '%s' "$HTTP_BODY" | jq -r '.data.accessTokenExpires // empty')"
TOKEN_TYPE="$(printf '%s' "$HTTP_BODY" | jq -r '.data.tokenType // "Bearer"')"

[[ -n "$ACCESS_TOKEN" && -n "$ACCESS_EXPIRES" ]] || die "unexpected response shape from /api/auth/bot/token" 3

mkdir -p "$CACHE_DIR"
OBTAINED_AT="$(date +%s)"

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg accessToken "$ACCESS_TOKEN" \
  --arg tokenType "$TOKEN_TYPE" \
  --argjson accessTokenExpires "$ACCESS_EXPIRES" \
  --argjson obtainedAt "$OBTAINED_AT" \
  '{
    baseUrl: $baseUrl,
    accessToken: $accessToken,
    tokenType: $tokenType,
    accessTokenExpires: $accessTokenExpires,
    obtainedAt: $obtainedAt
  }' >"$CACHE_FILE"

export ACCESS_TOKEN="$ACCESS_TOKEN"

echo "role-auth: success (expires at ${ACCESS_EXPIRES}, cached to ${CACHE_FILE})"
printf '%s\n' "$HTTP_BODY" | jq '{success, code, data: {accessTokenExpires: .data.accessTokenExpires, tokenType: .data.tokenType}}'

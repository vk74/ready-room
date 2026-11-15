#!/usr/bin/env bash
# version: 1.6.0
# Authenticated curl to evi with cached JWT and one re-auth retry on 401.
# File: role-request.sh
#
# Changes in v1.6.0:
# - Renamed skill/script from evi-request to role-request; cache evi-auth.json →
#   role-auth.json; persisted file evi.env → role.env; dropped EVI_ prefix from
#   env vars (BASE_URL, API_KEY, TLS_INSECURE, CA_CERT_FILE, ENV_FILE).
#
# Changes in v1.5.0:
# - Auto-adds `Content-Type: application/json` for POST/PUT/PATCH requests
#   when caller did not provide a Content-Type header explicitly.
#   This prevents silent body parsing issues in direct role-request.sh usage.
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
# - Kept JWT request flow vendor-neutral (no host-specific assumptions).
#
# Changes in v1.1.0:
# - Added TLS options for self-signed or custom CA deployments.
# - Keeps TLS behavior consistent with role-auth.sh.
#
# Changes in v1.0.0:
# - Initial authenticated request wrapper with one retry on auth errors.
#
# Usage: role-request.sh <METHOD> <path> [curl extra args...]
# Example: role-request.sh GET /api/auth/permissions

set -euo pipefail

EXPIRY_BUFFER_SEC=60
CACHE_DIR="${AGENT_HOME:-$HOME/.agent-skills}/cache"
CACHE_FILE="${CACHE_DIR}/role-auth.json"
ENV_FILE="${ENV_FILE:-${AGENT_HOME:-$HOME/.agent-skills}/role.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  echo "role-request: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_truthy() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

token_is_valid() {
  local expires now
  [[ -f "$CACHE_FILE" ]] || return 1
  expires="$(jq -r '.accessTokenExpires // 0' "$CACHE_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [[ "$expires" =~ ^[0-9]+$ ]] || return 1
  (( now + EXPIRY_BUFFER_SEC < expires ))
}

load_token() {
  [[ -f "$CACHE_FILE" ]] || return 1
  jq -r '.accessToken // empty' "$CACHE_FILE"
}

load_base_url() {
  if [[ -f "$CACHE_FILE" ]]; then
    local cached
    cached="$(jq -r '.baseUrl // empty' "$CACHE_FILE")"
    if [[ -n "$cached" ]]; then
      printf '%s' "${cached%/}"
      return 0
    fi
  fi
  if [[ -n "${BASE_URL:-}" ]]; then
    printf '%s' "${BASE_URL%/}"
    return 0
  fi
  return 1
}

ensure_auth() {
  if token_is_valid; then
    return 0
  fi
  echo "role-request: token missing or expired, re-authenticating..." >&2
  bash "${SCRIPT_DIR}/role-auth.sh" >/dev/null
}

response_is_auth_error() {
  local body="$1"
  local success code
  success="$(printf '%s' "$body" | jq -r '.success // empty' 2>/dev/null || true)"
  code="$(printf '%s' "$body" | jq -r '.code // empty' 2>/dev/null || true)"
  [[ "$success" == "false" && ( "$code" == "AUT-ERR-401" || "$code" == "BOT_AUTH-ERR-401" ) ]]
}

require_cmd curl
require_cmd jq

[[ $# -ge 2 ]] || die "usage: role-request.sh <METHOD> <path> [curl args...]"

METHOD="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
PATH_PART="$2"
shift 2
REQUEST_ARGS=("$@")

[[ "$PATH_PART" == /* ]] || die "path must start with / (e.g. /api/auth/permissions)"

TLS_INSECURE_RAW="${TLS_INSECURE:-0}"
CA_CERT_FILE="${CA_CERT_FILE:-}"
CURL_TLS_ARGS=()
if [[ -n "$CA_CERT_FILE" ]]; then
  [[ -r "$CA_CERT_FILE" ]] || die "CA_CERT_FILE is not readable: $CA_CERT_FILE"
  CURL_TLS_ARGS+=(--cacert "$CA_CERT_FILE")
elif is_truthy "$TLS_INSECURE_RAW"; then
  CURL_TLS_ARGS+=(-k)
fi

ensure_auth

BASE_URL="$(load_base_url)" || die "BASE_URL not set and no cache found — run role-setup.sh (persists config) or role-auth.sh first"
TOKEN="$(load_token)" || die "no access token in cache"
URL="${BASE_URL}${PATH_PART}"

is_json_body_method() {
  case "$METHOD" in
    POST|PUT|PATCH) return 0 ;;
    *) return 1 ;;
  esac
}

has_content_type_header() {
  local prev_is_header=0 arg header_value normalized
  for arg in "${REQUEST_ARGS[@]+"${REQUEST_ARGS[@]}"}"; do
    if [[ "$prev_is_header" -eq 1 ]]; then
      normalized="$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')"
      [[ "$normalized" == content-type:* ]] && return 0
      prev_is_header=0
      continue
    fi
    case "$arg" in
      -H|--header)
        prev_is_header=1
        ;;
      -H*)
        header_value="${arg#-H}"
        if [[ -n "$header_value" ]]; then
          normalized="$(printf '%s' "$header_value" | tr '[:upper:]' '[:lower:]')"
          [[ "$normalized" == content-type:* ]] && return 0
        fi
        ;;
      --header=*)
        header_value="${arg#--header=}"
        normalized="$(printf '%s' "$header_value" | tr '[:upper:]' '[:lower:]')"
        [[ "$normalized" == content-type:* ]] && return 0
        ;;
    esac
  done
  return 1
}

if is_json_body_method && ! has_content_type_header; then
  REQUEST_ARGS=(-H "Content-Type: application/json" "${REQUEST_ARGS[@]+"${REQUEST_ARGS[@]}"}")
fi

do_request() {
  curl -sS -w $'\n%{http_code}' -X "$METHOD" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    ${CURL_TLS_ARGS[@]+"${CURL_TLS_ARGS[@]}"} \
    "$URL" \
    "$@"
}

HTTP_RESPONSE="$(do_request "${REQUEST_ARGS[@]+"${REQUEST_ARGS[@]}"}")"
HTTP_BODY="$(printf '%s' "$HTTP_RESPONSE" | sed '$d')"
HTTP_CODE="$(printf '%s' "$HTTP_RESPONSE" | tail -n 1)"

if [[ "$HTTP_CODE" == "401" ]] || response_is_auth_error "$HTTP_BODY"; then
  echo "role-request: got 401, retrying after re-auth..." >&2
  bash "${SCRIPT_DIR}/role-auth.sh" >/dev/null
  TOKEN="$(load_token)" || die "re-auth did not produce a token"
  HTTP_RESPONSE="$(do_request "${REQUEST_ARGS[@]+"${REQUEST_ARGS[@]}"}")"
  HTTP_BODY="$(printf '%s' "$HTTP_RESPONSE" | sed '$d')"
  HTTP_CODE="$(printf '%s' "$HTTP_RESPONSE" | tail -n 1)"
fi

printf '%s\n' "$HTTP_BODY"
echo "role-request: HTTP ${HTTP_CODE}" >&2
[[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]

#!/usr/bin/env bash
# version: 1.1.0
# Persist connection settings to an env file so every later tool call
# (often a fresh shell with no exported variables) can authenticate.
# File: role-setup.sh
#
# Changes in v1.1.0:
# - Renamed skill/script from evi-setup to role-setup; persisted file evi.env →
#   role.env; dropped EVI_ prefix from env vars (BASE_URL, API_KEY, etc.).
#
# Changes in v1.0.1:
# - Renamed API key format prefix from evik_ to bkey_ in validation and usage text.
#
# Changes in v1.0.0:
# - Initial setup script: validates inputs, writes
#   ${AGENT_HOME:-$HOME/.agent-skills}/role.env with 600 permissions, and
#   verifies the credentials by running role-auth.sh (skippable).
#
# Usage:
#   role-setup.sh --base-url https://evi.example.com --api-key bkey_xxx_yyy \
#                [--tls-insecure] [--ca-cert-file /path/ca.pem] [--no-verify]
#
# Values may also come from already-exported BASE_URL / API_KEY /
# TLS_INSECURE / CA_CERT_FILE; flags take precedence over them.
# Target file: ${AGENT_HOME:-$HOME/.agent-skills}/role.env (override with
# ENV_FILE).
#
# Exit codes: 0 success, 1 missing/invalid input, 2 verification failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${AGENT_HOME:-$HOME/.agent-skills}/role.env}"

die() {
  echo "role-setup: $*" >&2
  exit "${2:-1}"
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

BASE_URL="${BASE_URL:-}"
API_KEY="${API_KEY:-}"
TLS_INSECURE="${TLS_INSECURE:-}"
CA_CERT_FILE="${CA_CERT_FILE:-}"
VERIFY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      [[ $# -ge 2 ]] || die "--base-url requires a value"
      BASE_URL="$2"; shift 2 ;;
    --api-key)
      [[ $# -ge 2 ]] || die "--api-key requires a value"
      API_KEY="$2"; shift 2 ;;
    --tls-insecure)
      TLS_INSECURE=1; shift ;;
    --ca-cert-file)
      [[ $# -ge 2 ]] || die "--ca-cert-file requires a value"
      CA_CERT_FILE="$2"; shift 2 ;;
    --no-verify)
      VERIFY=0; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$BASE_URL" ]] || die "base URL is required (--base-url or BASE_URL)"
[[ -n "$API_KEY" ]] || die "API key is required (--api-key or API_KEY)"

BASE_URL="${BASE_URL%/}"
API_KEY="$(printf '%s' "$API_KEY" | tr -d '[:space:]')"

[[ "$BASE_URL" == http://* || "$BASE_URL" == https://* ]] \
  || die "base URL must start with http:// or https://"
validate_api_key_format "$API_KEY" || die "API key must match bkey_<key_id>_<secret>"
if [[ -n "$CA_CERT_FILE" ]]; then
  [[ -r "$CA_CERT_FILE" ]] || die "CA cert file is not readable: $CA_CERT_FILE"
fi

# The env file is sourced by role-auth.sh / role-request.sh; values are written
# single-quoted, so a quote inside a value would break the file syntax.
for v in "$BASE_URL" "$API_KEY" "$TLS_INSECURE" "$CA_CERT_FILE"; do
  case "$v" in
    *"'"*) die "values must not contain single quotes" ;;
  esac
done

ENV_DIR="$(dirname "$ENV_FILE")"
mkdir -p "$ENV_DIR"

TMP_FILE="$(mktemp "${ENV_DIR}/role.env.XXXXXX")"
{
  printf '# agent-skills connection settings (written by role-setup.sh)\n'
  printf '# Sourced automatically by role-auth.sh / role-request.sh when\n'
  printf '# BASE_URL / API_KEY are not present in the environment.\n'
  printf "BASE_URL='%s'\n" "$BASE_URL"
  printf "API_KEY='%s'\n" "$API_KEY"
  if [[ -n "$TLS_INSECURE" ]]; then
    printf "TLS_INSECURE='%s'\n" "$TLS_INSECURE"
  fi
  if [[ -n "$CA_CERT_FILE" ]]; then
    printf "CA_CERT_FILE='%s'\n" "$CA_CERT_FILE"
  fi
} >"$TMP_FILE"
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$ENV_FILE"

echo "role-setup: wrote ${ENV_FILE} (mode 600)"

if [[ "$VERIFY" -eq 1 ]]; then
  AUTH_SCRIPT="${SCRIPT_DIR}/role-auth.sh"
  [[ -f "$AUTH_SCRIPT" ]] || die "cannot verify: ${AUTH_SCRIPT} not found (use --no-verify)" 2
  echo "role-setup: verifying credentials via role-auth.sh..."
  if env -u BASE_URL -u API_KEY ENV_FILE="$ENV_FILE" bash "$AUTH_SCRIPT" >/dev/null; then
    echo "role-setup: verification OK — scripts can now authenticate from ${ENV_FILE}"
  else
    die "verification failed — check base URL / API key (file kept at ${ENV_FILE})" 2
  fi
else
  echo "role-setup: verification skipped (--no-verify)"
fi

#!/usr/bin/env bash
#
# Version: 0.27.4
# Purpose: Sourceable GitHub access-key helpers for install.sh (load/persist/require
#   the GitHub token, authenticated curl, GHCR podman login). Callers already
#   run with set -euo pipefail — this library does not set it. No token is printed.
# File: github-auth.sh
#
# Changes in v0.27.4:
# - Default APP_INSTALL_REPO is vk74/ready-room.
#
# Changes in v0.27.2:
# - Define and export APP_INSTALL_REPO as the single source for the distribution GitHub repository.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - GitHub token persistence reads config/app.secrets.env.
# 
# Changes in v0.25.4:
# - Load and persist the GitHub token from config/app.secrets.env, falling back to
#   config/evi.secrets.env when only the legacy file exists.
#
# Changes in v0.23.6:
# - github_curl now tries every request anonymously first and only retries with
#   Authorization: Bearer if that attempt failed and a token is loaded (was:
#   Bearer whenever a token was loaded, never tried anonymous). An anonymous
#   success always wins, even over a stale/revoked token.
# - podman_login_ghcr's /user lookup uses the new always-authenticated
#   _evi_gh_curl_bearer_only (GET /user is never answered anonymously, so the
#   open-first heuristic can't tell success from failure there).
# - New podman_pull_ghcr: pull anonymously first, log in and retry only on failure.
#
# Changes in v0.23.4:
# - Initial library: load_github_token, persist_github_token, require_github_token,
#   github_curl, and podman_login_ghcr.
# - github_curl puts the Bearer header in a 0600 curl --config file so the token
#   is not visible in `ps` argv.
#
# Guard against double-sourcing. When this file is executed directly (not sourced)
# the first load defines the functions and exits with no output.
if [[ -n "${APP_LIB_GITHUB_AUTH_SH:-}" ]]; then
  return 0
fi
APP_LIB_GITHUB_AUTH_SH=1

APP_INSTALL_REPO="${APP_INSTALL_REPO:-vk74/ready-room}"
export APP_INSTALL_REPO

_app_gh_die() {
  local msg="$*"
  if declare -F die >/dev/null 2>&1; then
    die "${msg}"
  else
    printf 'error: %s\n' "${msg}" >&2
    exit 1
  fi
}

_app_gh_warn() {
  local msg="$*"
  if declare -F warn >/dev/null 2>&1; then
    warn "${msg}"
  else
    printf 'warn: %s\n' "${msg}" >&2
  fi
}

# Read KEY=value from an env file (first match). Value only; strip surrounding quotes.
_app_gh_read_env_value() {
  local file="$1" key="$2"
  local line val
  line=$(grep "^${key}=" "${file}" 2>/dev/null | head -n 1 || true)
  [[ -z "${line}" ]] && return 0
  val="${line#${key}=}"
  if [[ "${val}" == \"*\" ]]; then
    val="${val#\"}"
    val="${val%\"}"
  elif [[ "${val}" == \'*\' ]]; then
    val="${val#\'}"
    val="${val%\'}"
  fi
  printf '%s' "${val}"
}

# Replace KEY=... in file, or append KEY=value if missing. Does not print the value.
_app_gh_upsert_env_line() {
  local file="$1" key="$2" value="$3"
  local tmp found=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/app-gh-XXXXXX")
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "${key}="* ]]; then
      printf '%s=%s\n' "${key}" "${value}"
      found=1
    else
      printf '%s\n' "${line}"
    fi
  done < "${file}" > "${tmp}"
  if [[ "${found}" -eq 0 ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  fi
  chmod 600 "${tmp}"
  mv "${tmp}" "${file}"
}

# Path to config/app.secrets.env when present; empty otherwise.
_app_gh_secrets_file() {
  if [[ -f "${APP_HOME}/config/app.secrets.env" ]]; then
    printf '%s' "${APP_HOME}/config/app.secrets.env"
  fi
}

# Fill APP_GITHUB_TOKEN / APP_GITHUB_USERNAME from env, token file, then secrets.
load_github_token() {
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    local token_file="${APP_HOME}/.github-token"
    if [[ -s "${token_file}" ]]; then
      local line
      line=$(head -n 1 "${token_file}" || true)
      line="${line%$'\r'}"
      if [[ -n "${line}" ]]; then
        APP_GITHUB_TOKEN="${line}"
      fi
    fi
  fi
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    local secrets_file
    secrets_file="$(_app_gh_secrets_file)"
    if [[ -n "${secrets_file}" ]]; then
      APP_GITHUB_TOKEN="$(_app_gh_read_env_value "${secrets_file}" "APP_GITHUB_TOKEN")"
    fi
  fi
  if [[ -z "${APP_GITHUB_USERNAME:-}" ]]; then
    local secrets_file
    secrets_file="$(_app_gh_secrets_file)"
    if [[ -n "${secrets_file}" ]]; then
      APP_GITHUB_USERNAME="$(_app_gh_read_env_value "${secrets_file}" "APP_GITHUB_USERNAME")"
    fi
  fi
  export APP_GITHUB_TOKEN="${APP_GITHUB_TOKEN:-}"
  export APP_GITHUB_USERNAME="${APP_GITHUB_USERNAME:-}"
}

# Write token to ${APP_HOME}/.github-token and upsert secrets when that file exists.
persist_github_token() {
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    return 0
  fi
  local token_file="${APP_HOME}/.github-token"
  (
    umask 077
    printf '%s\n' "${APP_GITHUB_TOKEN:-}" > "${token_file}"
  )
  chmod 600 "${token_file}"

  local secrets_file
  secrets_file="$(_app_gh_secrets_file)"
  if [[ -n "${secrets_file}" ]]; then
    _app_gh_upsert_env_line "${secrets_file}" "APP_GITHUB_TOKEN" "${APP_GITHUB_TOKEN:-}"
    if [[ -n "${APP_GITHUB_USERNAME:-}" ]]; then
      _app_gh_upsert_env_line "${secrets_file}" "APP_GITHUB_USERNAME" "${APP_GITHUB_USERNAME:-}"
    fi
  fi
  return 0
}

# Ensure a token is available (prompt only on a tty when CONFIG_EXISTS=1), then persist.
require_github_token() {
  load_github_token
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    if [[ -t 0 ]] && [[ "${CONFIG_EXISTS:-0}" == "1" ]]; then
      read -rs -p "paste the GitHub access key: " APP_GITHUB_TOKEN
      printf '\n'
      export APP_GITHUB_TOKEN="${APP_GITHUB_TOKEN:-}"
      if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
        _app_gh_die "installation requires a GitHub access key. Set APP_GITHUB_TOKEN."
      fi
    else
      _app_gh_die "installation requires a GitHub access key. Set APP_GITHUB_TOKEN."
    fi
  fi
  persist_github_token
}

# Send curl anonymously first (works when the repo/package is public). Only if that
# attempt looks like a failure AND a token is loaded, retry once with Authorization:
# Bearer via a 0600 curl --config file (never in ps argv, never logged). Never sends
# a token that wasn't needed — this is deliberate: an anonymous success always wins,
# even if a (possibly stale/revoked) token is configured.
github_curl() {
  load_github_token
  local rc out
  out=$(curl "$@")
  rc=$?
  if _app_gh_curl_ok "${rc}" "${out}" "$@"; then
    printf '%s' "${out}"
    return 0
  fi
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    printf '%s' "${out}"
    return "${rc}"
  fi
  out=$(_app_gh_curl_bearer "${APP_GITHUB_TOKEN:-}" "$@")
  rc=$?
  printf '%s' "${out}"
  return "${rc}"
}

# Decide whether a github_curl attempt succeeded, given the args that were passed to
# curl. Three cases, matching every call-site pattern used in this codebase:
#   1. args contain --fail: curl's own exit code is authoritative (curl still prints
#      any -w output before returning non-zero on --fail, so combining --fail with
#      -w '%{http_code}' works too).
#   2. no --fail, but stdout is a bare 3-digit code (caller used -w '%{http_code}'
#      with -o diverting the body elsewhere): success = code starts with 2.
#   3. neither (plain body fetch, no --fail, no -w): best-effort, curl's exit code.
_app_gh_curl_ok() {
  local rc="$1" out="$2"
  shift 2
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "--fail" ]]; then
      [[ "${rc}" -eq 0 ]]
      return
    fi
  done
  if [[ "${out}" =~ ^[0-9][0-9][0-9]$ ]]; then
    [[ "${out}" == 2* ]]
    return
  fi
  [[ "${rc}" -eq 0 ]]
}

# Run curl with a Bearer token, via a 0600 curl --config file (keeps the token out of
# `ps` argv). Takes the token as $1, then the original curl args as the rest.
_app_gh_curl_bearer() {
  local token="$1"
  shift
  local cfg rc
  cfg=$(mktemp "${TMPDIR:-/tmp}/app-gh-curl-XXXXXX")
  chmod 600 "${cfg}"
  printf 'header = "Authorization: Bearer %s"\n' "${token}" > "${cfg}"
  curl -K "${cfg}" "$@"
  rc=$?
  rm -f "${cfg}"
  return "${rc}"
}

# Always-authenticated curl (skips the anonymous attempt entirely). Use only for
# endpoints that are never answered anonymously, e.g. GET /user (which "succeeds"
# with an error body even with no token, so the open-first heuristic can't detect
# failure there). Loads the token first; if none is loaded, behaves like plain curl.
_app_gh_curl_bearer_only() {
  load_github_token
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    curl "$@"
    return
  fi
  _app_gh_curl_bearer "${APP_GITHUB_TOKEN:-}" "$@"
}

# Log in to ghcr.io when a token is present. Skip (0) if empty; warn and return 1 on failure.
podman_login_ghcr() {
  load_github_token
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    return 0
  fi
  local user="${APP_GITHUB_USERNAME:-}"
  if [[ -z "${user}" ]]; then
    local user_json
    user_json=$(_app_gh_curl_bearer_only -sS --max-time 15 \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/user" 2>/dev/null || true)
    user=$(printf '%s' "${user_json}" | grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"login"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
  fi
  if [[ -z "${user}" ]]; then
    user="vk74"
  fi
  if ! printf '%s\n' "${APP_GITHUB_TOKEN:-}" | podman login ghcr.io -u "${user}" --password-stdin; then
    _app_gh_warn "podman login to ghcr.io failed"
    return 1
  fi
  return 0
}

# Pull an image anonymously first; only if that pull fails AND a token is available,
# log in to ghcr.io and retry once. "$@" is the full podman pull argument list
# including the image reference (e.g. --platform linux/amd64 ghcr.io/vk74/fe:1.2.3).
# Returns 0 on success (either attempt). On failure, prints the LAST attempt's
# stderr and returns non-zero.
podman_pull_ghcr() {
  local err_file
  err_file=$(mktemp)
  if podman pull "$@" 2>"${err_file}"; then
    rm -f "${err_file}"
    return 0
  fi
  load_github_token
  if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
    cat "${err_file}" >&2
    rm -f "${err_file}"
    return 1
  fi
  if ! podman_login_ghcr; then
    cat "${err_file}" >&2
    rm -f "${err_file}"
    return 1
  fi
  rm -f "${err_file}"
  podman pull "$@"
}

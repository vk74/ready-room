#!/usr/bin/env bash
#
# Version: 0.27.2
# Purpose: Query the GitHub Releases API and write candidate releases newer than
#          the installed version to CHECK_WORK_DIR/candidates.ndjson.
#          Progress goes to stderr. This script prints nothing on stdout.
#          Usage: check-1-fetch-releases.sh <APP_HOME> <CHECK_WORK_DIR> <true|false>
# File: check-1-fetch-releases.sh
#
# Changes in v0.27.2:
# - Read the distribution repository from APP_INSTALL_REPO (exported by lib/github-auth.sh) instead of local GITHUB_OWNER and GITHUB_REPO variables.
#
# Changes in v0.26.3:
# - Fetch phase of the update check. Filters pre-releases unless include-prerelease
#   is true, and keeps only versions newer than the installed version.
# - Writes tag, prerelease, publishedAt, and trimmed release notes as one JSON
#   object per line. On failure, writes an error line and current-version for the orchestrator.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_LIB="${SCRIPT_DIR}/lib/version.sh"
if [[ ! -f "${VERSION_LIB}" ]]; then
  printf 'error: version library missing (expected %s)\n' "${VERSION_LIB}" >&2
  exit 1
fi
# shellcheck source=lib/version.sh
. "${VERSION_LIB}"

APP_HOME="${1:?usage: check-1-fetch-releases.sh <APP_HOME> <CHECK_WORK_DIR> <include-prerelease>}"
CHECK_WORK_DIR="${2:?usage: check-1-fetch-releases.sh <APP_HOME> <CHECK_WORK_DIR> <include-prerelease>}"
INCLUDE_PRERELEASE="${3:-false}"
export APP_HOME
# shellcheck source=lib/github-auth.sh
. "${SCRIPT_DIR}/lib/github-auth.sh"
load_github_token

PACKAGE_JSON="${APP_HOME}/package.json"
GITHUB_API_RELEASES="https://api.github.com/repos/${APP_INSTALL_REPO}/releases?per_page=50"

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log()  { printf "${CYAN}[update]${NC} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*" >&2; }
err()  { printf "${RED}error:${NC} %s\n" "$*" >&2; }

write_error() {
  printf '%s\n' "$1" > "${CHECK_WORK_DIR}/error"
}

github_token_required_err() {
  err "GitHub access key required. Set APP_GITHUB_TOKEN, or place it in ${APP_HOME}/.github-token or ${APP_HOME}/config/app.secrets.env"
}

get_current_version() {
  if [[ ! -f "$PACKAGE_JSON" ]]; then
    printf 'unknown'
    return 0
  fi
  local ver=""
  if command -v jq >/dev/null 2>&1; then
    ver=$(jq -r '.version // empty' "$PACKAGE_JSON" 2>/dev/null) || ver=""
  else
    ver=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PACKAGE_JSON" 2>/dev/null \
      | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//' | sed 's/"$//' || true)
  fi
  printf '%s' "${ver:-unknown}"
}

# True when this release should be offered: optional pre-release filter, then
# version strictly greater than the installed version.
keep_release() {
  local version="$1" is_prerelease="$2" installed="$3"
  if [[ "$INCLUDE_PRERELEASE" != "true" && "$is_prerelease" == "true" ]]; then
    return 1
  fi
  if [[ "$installed" == "unknown" ]]; then
    return 0
  fi
  local cmp_result=0
  compare_versions "$installed" "$version" || cmp_result=$?
  [[ $cmp_result -eq 2 ]]
}

main() {
  local current_version
  current_version=$(get_current_version)
  printf '%s\n' "$current_version" > "${CHECK_WORK_DIR}/current-version"
  : > "${CHECK_WORK_DIR}/candidates.ndjson"

  log "fetching available releases..."
  if [[ "$current_version" == "unknown" ]]; then
    warn "could not determine current version from package.json"
  fi

  local tmp_file http_code
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/app-releases-XXXXXX")
  http_code=$(github_curl -sS -w "%{http_code}" -o "$tmp_file" \
    -H "Accept: application/vnd.github+json" \
    "$GITHUB_API_RELEASES" 2>/dev/null) || {
    rm -f "$tmp_file"
    if [[ -z "${APP_GITHUB_TOKEN:-}" ]]; then
      github_token_required_err
      write_error "GitHub access key required"
    else
      err "failed to query GitHub API"
      write_error "failed to query GitHub API"
    fi
    exit 1
  }

  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp_file"
    if [[ -z "${APP_GITHUB_TOKEN:-}" && ( "$http_code" == "401" || "$http_code" == "403" || "$http_code" == "404" ) ]]; then
      github_token_required_err
      write_error "GitHub access key required"
      exit 1
    fi
    if [[ "$http_code" == "403" ]]; then
      err "GitHub API rate limit exceeded. Try again later."
    else
      err "GitHub API returned HTTP ${http_code}"
    fi
    write_error "GitHub API HTTP ${http_code}"
    exit 1
  fi

  if command -v jq >/dev/null 2>&1; then
    local releases_ndjson
    releases_ndjson=$(jq -c '.[]' "$tmp_file" 2>/dev/null) || releases_ndjson=""
    rm -f "$tmp_file"
    if [[ -z "$releases_ndjson" ]]; then
      log "no releases found on GitHub"
      exit 0
    fi
    local obj tag is_prerelease pub_date version notes
    while IFS= read -r obj || [[ -n "$obj" ]]; do
      [[ -z "$obj" ]] && continue
      tag=$(jq -r '.tag_name // ""' <<< "$obj")
      [[ -z "$tag" ]] && continue
      is_prerelease=$(jq -r '.prerelease // false' <<< "$obj")
      pub_date=$(jq -r '.published_at // ""' <<< "$obj")
      # Drop the first header line and the generated "### Changes" commit log.
      notes=$(jq -r '(.body // "") | split("### Changes")[0] | split("\n")[1:] | join("\n") | gsub("^\n+|\n+$"; "")' <<< "$obj")
      version="${tag#v}"
      [[ "$is_prerelease" == "true" ]] || is_prerelease="false"
      keep_release "$version" "$is_prerelease" "$current_version" || continue
      jq -nc \
        --arg tag "$tag" \
        --arg version "$version" \
        --argjson prerelease "$is_prerelease" \
        --arg publishedAt "$pub_date" \
        --arg releaseNotes "$notes" \
        '{tag:$tag,version:$version,prerelease:$prerelease,publishedAt:$publishedAt,releaseNotes:$releaseNotes}' \
        >> "${CHECK_WORK_DIR}/candidates.ndjson"
    done <<< "$releases_ndjson"
  else
    warn "jq not found; release notes will not be shown until the next update installs it"
    local tags_raw prerelease_raw published_raw
    tags_raw=$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_file" 2>/dev/null \
      | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
    prerelease_raw=$(grep -o '"prerelease"[[:space:]]*:[[:space:]]*[a-z]*' "$tmp_file" 2>/dev/null \
      | sed 's/.*"prerelease"[[:space:]]*:[[:space:]]*//' || true)
    published_raw=$(grep -o '"published_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_file" 2>/dev/null \
      | sed 's/.*"published_at"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
    rm -f "$tmp_file"
    if [[ -z "$tags_raw" ]]; then
      log "no releases found on GitHub"
      exit 0
    fi
    local -a tags=() prereleases=() published=()
    local line
    while IFS= read -r line; do [[ -n "$line" ]] && tags+=("$line"); done <<< "$tags_raw"
    while IFS= read -r line; do [[ -n "$line" ]] && prereleases+=("$line"); done <<< "$prerelease_raw"
    while IFS= read -r line; do [[ -n "$line" ]] && published+=("$line"); done <<< "$published_raw"
    local count=${#tags[@]} i tag is_prerelease pub_date version
    for ((i=0; i<count; i++)); do
      tag="${tags[i]}"
      is_prerelease="${prereleases[i]:-false}"
      pub_date="${published[i]:-}"
      version="${tag#v}"
      [[ "$is_prerelease" == "true" ]] || is_prerelease="false"
      keep_release "$version" "$is_prerelease" "$current_version" || continue
      printf '{"tag":"%s","version":"%s","prerelease":%s,"publishedAt":"%s","releaseNotes":""}\n' \
        "$tag" "$version" "$is_prerelease" "$pub_date" >> "${CHECK_WORK_DIR}/candidates.ndjson"
    done
  fi
}

main

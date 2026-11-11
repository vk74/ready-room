#!/usr/bin/env bash
#
# Version: 0.27.4
# Purpose: Read candidate releases, fetch each tag's minVersion, and decide
#          compatibility (installed version >= minVersion). Updates
#          config/updates/updates.json and prints the check JSON on stdout.
#          Logs go to stderr.
#          Usage: check-2-evaluate-compatibility.sh <APP_HOME> <CHECK_WORK_DIR> <true|false>
# File: check-2-evaluate-compatibility.sh
#
# Changes in v0.27.4:
# - get_min_version reads .updateCompatibility.minVersion (falling back to .minVersion) when jq is installed.
#
# Changes in v0.27.2:
# - Read the distribution repository from APP_INSTALL_REPO (exported by lib/github-auth.sh) instead of local GITHUB_OWNER and GITHUB_REPO variables.
#
# Changes in v0.26.3:
# - Compatibility phase of the update check. minVersion comes from the GitHub
#   Contents API for that release tag.
# - persist_basic_status keeps downloaded, downloadPath, minVersion, compatible,
#   includeBeta, deployedAt, and lastUpdatedAt.
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

APP_HOME="${1:?usage: check-2-evaluate-compatibility.sh <APP_HOME> <CHECK_WORK_DIR> <include-prerelease>}"
CHECK_WORK_DIR="${2:?usage: check-2-evaluate-compatibility.sh <APP_HOME> <CHECK_WORK_DIR> <include-prerelease>}"
export APP_HOME
# shellcheck source=lib/github-auth.sh
. "${SCRIPT_DIR}/lib/github-auth.sh"
load_github_token

CONFIG_DIR="${APP_HOME}/config"
UPDATES_DIR="${CONFIG_DIR}/updates"
UPDATES_JSON="${UPDATES_DIR}/updates.json"
CANDIDATES="${CHECK_WORK_DIR}/candidates.ndjson"

CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

log()  { printf "${CYAN}[update]${NC} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*" >&2; }
err()  { printf "${RED}error:${NC} %s\n" "$*" >&2; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

read_existing_string() {
  local field="$1"
  if [[ ! -f "$UPDATES_JSON" ]]; then
    printf ''
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" 'if has($f) and (.[$f] | type) == "string" then .[$f] else "" end' "$UPDATES_JSON" 2>/dev/null || printf ''
    return 0
  fi
  grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$UPDATES_JSON" 2>/dev/null \
    | head -1 | sed "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"//" | sed 's/"$//' || true
}

read_existing_bool() {
  local field="$1" default="$2"
  local raw=""
  if [[ -f "$UPDATES_JSON" ]]; then
    if command -v jq >/dev/null 2>&1; then
      raw=$(jq -r --arg f "$field" 'if has($f) and (.[$f] | type) == "boolean" then (if .[$f] then "true" else "false" end) else "" end' "$UPDATES_JSON" 2>/dev/null || true)
    else
      raw=$(grep -o "\"${field}\"[[:space:]]*:[[:space:]]*[a-z]*" "$UPDATES_JSON" 2>/dev/null \
        | head -1 | sed "s/.*\"${field}\"[[:space:]]*:[[:space:]]*//" || true)
    fi
  fi
  if [[ "$raw" == "true" || "$raw" == "false" ]]; then
    printf '%s' "$raw"
  else
    printf '%s' "$default"
  fi
}

# Fetch minVersion from the release tag's package.json (GitHub Contents API).
get_min_version() {
  local tag="$1" content=""
  content=$(github_curl -sS --fail --connect-timeout 10 --max-time 20 \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${APP_INSTALL_REPO}/contents/package.json?ref=${tag}" \
    2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.updateCompatibility.minVersion // .minVersion // empty' <<< "$content" 2>/dev/null || true
    return 0
  fi
  printf '%s' "$content" | grep -o '"minVersion"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed 's/.*"minVersion"[[:space:]]*:[[:space:]]*"//' | sed 's/"$//' || true
}

# Rewrite the status fields. downloaded, downloadPath, minVersion, compatible,
# includeBeta, deployedAt, and lastUpdatedAt stay as they are. releaseNotes is
# cleared when nothing newer is available.
persist_basic_status() {
  local current_version="$1" latest_version="$2" available="$3" last_check="$4" new_release_notes="${5:-}"
  mkdir -p "$UPDATES_DIR"

  local include_beta downloaded download_path min_version compatible deployed_at last_updated_at release_notes
  include_beta=$(read_existing_bool "includeBeta" "false")
  downloaded=$(read_existing_bool "downloaded" "false")
  compatible=$(read_existing_bool "compatible" "true")
  download_path=$(read_existing_string "downloadPath")
  min_version=$(read_existing_string "minVersion")
  deployed_at=$(read_existing_string "deployedAt")
  last_updated_at=$(read_existing_string "lastUpdatedAt")
  release_notes=$(read_existing_string "releaseNotes")

  if [[ "$available" == "false" ]]; then
    release_notes=""
  elif [[ -n "$new_release_notes" ]]; then
    release_notes="$new_release_notes"
  fi

  if command -v jq >/dev/null 2>&1; then
    local tmp_updates jq_prog
    tmp_updates=$(mktemp "${TMPDIR:-/tmp}/app-updates-XXXXXX")
    if [[ -f "$UPDATES_JSON" ]]; then
      jq_prog='.currentVersion = $current_version | .latestVersion = $latest_version | .available = $available | .lastCheck = $last_check | .releaseNotes = $release_notes'
      if jq --arg current_version "$current_version" \
            --arg latest_version "$latest_version" \
            --argjson available "$available" \
            --arg last_check "$last_check" \
            --arg release_notes "$release_notes" \
            "$jq_prog" "$UPDATES_JSON" > "$tmp_updates" 2>/dev/null; then
        mv "$tmp_updates" "$UPDATES_JSON"
        return 0
      fi
      rm -f "$tmp_updates"
      tmp_updates=$(mktemp "${TMPDIR:-/tmp}/app-updates-XXXXXX")
    fi
    if jq -n \
          --arg current_version "$current_version" \
          --arg latest_version "$latest_version" \
          --argjson available "$available" \
          --argjson compatible "$compatible" \
          --arg min_version "$min_version" \
          --argjson downloaded "$downloaded" \
          --arg download_path "$download_path" \
          --arg release_notes "$release_notes" \
          --arg last_check "$last_check" \
          --argjson include_beta "$include_beta" \
          --arg deployed_at "$deployed_at" \
          --arg last_updated_at "$last_updated_at" \
          '{currentVersion:$current_version,latestVersion:$latest_version,available:$available,compatible:$compatible,minVersion:$min_version,downloaded:$downloaded,downloadPath:$download_path,releaseNotes:$release_notes,lastCheck:$last_check,includeBeta:$include_beta,deployedAt:$deployed_at,lastUpdatedAt:$last_updated_at}' \
          > "$tmp_updates" 2>/dev/null; then
      mv "$tmp_updates" "$UPDATES_JSON"
      return 0
    fi
    rm -f "$tmp_updates"
  fi

  {
    printf '{\n'
    printf '  "currentVersion": "%s",\n' "$(json_escape "$current_version")"
    printf '  "latestVersion": "%s",\n' "$(json_escape "$latest_version")"
    printf '  "available": %s,\n' "$available"
    printf '  "compatible": %s,\n' "$compatible"
    printf '  "minVersion": "%s",\n' "$(json_escape "$min_version")"
    printf '  "downloaded": %s,\n' "$downloaded"
    printf '  "downloadPath": "%s",\n' "$(json_escape "$download_path")"
    printf '  "releaseNotes": "%s",\n' "$(json_escape "$release_notes")"
    printf '  "lastCheck": "%s",\n' "$(json_escape "$last_check")"
    printf '  "includeBeta": %s,\n' "$include_beta"
    printf '  "deployedAt": "%s",\n' "$(json_escape "$deployed_at")"
    printf '  "lastUpdatedAt": "%s"\n' "$(json_escape "$last_updated_at")"
    printf '}\n'
  } > "$UPDATES_JSON"
}

main() {
  if [[ ! -f "$CANDIDATES" ]]; then
    err "candidate release list is missing"
    exit 1
  fi

  local current_version
  if [[ -f "${CHECK_WORK_DIR}/current-version" ]]; then
    IFS= read -r current_version < "${CHECK_WORK_DIR}/current-version" || true
  fi
  [[ -z "${current_version:-}" ]] && current_version="unknown"

  local last_check newest_version="" newest_release_notes=""
  last_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local objects_file release_count=0
  objects_file=$(mktemp "${TMPDIR:-/tmp}/app-check-objects-XXXXXX")

  local line tag version is_prerelease pub_date notes min_version compatible obj
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if command -v jq >/dev/null 2>&1; then
      tag=$(jq -r '.tag // ""' <<< "$line")
      version=$(jq -r '.version // ""' <<< "$line")
      is_prerelease=$(jq -r 'if .prerelease == true then "true" else "false" end' <<< "$line")
      pub_date=$(jq -r '.publishedAt // ""' <<< "$line")
      notes=$(jq -r '.releaseNotes // ""' <<< "$line")
    else
      tag=$(printf '%s' "$line" | sed -n 's/.*"tag":"\([^"]*\)".*/\1/p')
      version=$(printf '%s' "$line" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
      is_prerelease=$(printf '%s' "$line" | sed -n 's/.*"prerelease":\([^,}]*\).*/\1/p')
      pub_date=$(printf '%s' "$line" | sed -n 's/.*"publishedAt":"\([^"]*\)".*/\1/p')
      notes=""
    fi
    [[ -z "$version" ]] && continue
    is_prerelease="${is_prerelease// /}"
    [[ "$is_prerelease" == "true" ]] || is_prerelease="false"

    if [[ -z "$newest_version" ]]; then
      newest_version="$version"
      newest_release_notes="$notes"
    fi

    log "checking compatibility for ${version}..."
    min_version=$(get_min_version "$tag") || min_version=""

    compatible="true"
    if [[ -n "$min_version" && "$current_version" != "unknown" ]]; then
      local compat_result=0
      compare_versions "$current_version" "$min_version" || compat_result=$?
      if [[ $compat_result -eq 2 ]]; then
        compatible="false"
      fi
    fi

    if command -v jq >/dev/null 2>&1; then
      obj=$(jq -nc \
        --arg version "$version" \
        --arg tag "$tag" \
        --arg minVersion "$min_version" \
        --argjson prerelease "$is_prerelease" \
        --argjson compatible "$compatible" \
        --arg publishedAt "$pub_date" \
        --arg releaseNotes "$notes" \
        '{version:$version,tag:$tag,minVersion:$minVersion,prerelease:$prerelease,compatible:$compatible,publishedAt:$publishedAt,releaseNotes:$releaseNotes}')
    else
      obj=$(printf '{"version":"%s","tag":"%s","minVersion":"%s","prerelease":%s,"compatible":%s,"publishedAt":"%s","releaseNotes":""}' \
        "$(json_escape "$version")" "$(json_escape "$tag")" "$(json_escape "$min_version")" \
        "$is_prerelease" "$compatible" "$(json_escape "$pub_date")")
    fi
    if [[ ! -s "$objects_file" ]]; then
      printf '%s' "$obj" > "$objects_file"
    else
      printf ',%s' "$obj" >> "$objects_file"
    fi
    release_count=$((release_count + 1))
  done < "$CANDIDATES"

  local available="false"
  [[ $release_count -gt 0 ]] && available="true"
  persist_basic_status "$current_version" "${newest_version:-$current_version}" "$available" "$last_check" "$newest_release_notes"

  local releases_json="[]"
  if [[ -s "$objects_file" ]]; then
    releases_json="[$(cat "$objects_file")]"
  fi
  rm -f "$objects_file"

  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg currentVersion "$current_version" \
      --argjson releases "$releases_json" \
      --arg lastCheck "$last_check" \
      '{currentVersion:$currentVersion,releases:$releases,lastCheck:$lastCheck}'
  else
    printf '{"currentVersion":"%s","releases":%s,"lastCheck":"%s"}\n' \
      "$(json_escape "$current_version")" "$releases_json" "$last_check"
  fi

  log "found ${release_count} available release(s)"
}

main

#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Download one application release and the container images it needs.
#          Phase 1 fetches or reuses the release kit. Phase 2 pulls images.
#          updates.json is marked downloaded only after both phases succeed.
#          Usage: update-download-orchestrator.sh <APP_HOME> [--version <ver>]
# File: update-download-orchestrator.sh
#
# Changes in v0.26.3:
# - Download orchestrator. Runs download-1-release-kit.sh, then download-2-container-images.sh.
# - A targeted --version keeps an existing latestVersion unless it is missing or "unknown".
# - Prints the kit, image, retry, and elapsed summary from the phase stats file.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
# shellcheck source=lib/version.sh
. "${SCRIPT_DIR}/lib/version.sh"
# shellcheck source=lib/github-auth.sh
. "${SCRIPT_DIR}/lib/github-auth.sh"

APP_HOME="${1:?usage: update-download-orchestrator.sh <APP_HOME> [--version <ver>]}"
export APP_HOME
shift
load_github_token

TARGET_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      TARGET_VERSION="${2:-}"
      if [[ -z "$TARGET_VERSION" ]]; then
        err "--version requires a value"
        exit 1
      fi
      shift 2
      ;;
    *) shift ;;
  esac
done

CONFIG_DIR="${APP_HOME}/config"
UPDATES_DIR="${CONFIG_DIR}/updates"
UPDATES_JSON="${UPDATES_DIR}/updates.json"
PACKAGE_JSON="${APP_HOME}/package.json"

read_json_field() {
  local field="$1"
  if [[ ! -f "$UPDATES_JSON" ]]; then
    printf ''
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" '
      if has($f) and (.[$f] | type) != "null" then
        .[$f] | if type == "string" or type == "number" or type == "boolean" then tostring else empty end
      else empty end
    ' "$UPDATES_JSON" 2>/dev/null || true
    return 0
  fi
  grep -o "\"${field}\"[[:space:]]*:[[:space:]]*[^,}]*" "$UPDATES_JSON" 2>/dev/null | \
    sed "s/\"${field}\"[[:space:]]*:[[:space:]]*//" | \
    sed 's/^"//' | sed 's/"$//' | sed 's/[[:space:]]*$//' || true
}

get_current_version() {
  if [[ ! -f "$PACKAGE_JSON" ]]; then
    printf 'unknown'
    return 0
  fi
  local ver=""
  if command -v jq >/dev/null 2>&1; then
    ver=$(jq -r '.version // empty' "$PACKAGE_JSON" 2>/dev/null || true)
  else
    ver=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PACKAGE_JSON" 2>/dev/null \
      | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//' | sed 's/"$//' || true)
  fi
  printf '%s' "${ver:-unknown}"
}

write_json_field() {
  local field="$1" value="$2" is_string="${3:-true}"
  mkdir -p "$UPDATES_DIR"
  if [[ ! -f "$UPDATES_JSON" ]]; then
    local installed
    installed=$(get_current_version)
    printf '%s\n' "{\"currentVersion\":\"${installed}\",\"latestVersion\":\"\",\"available\":false,\"compatible\":true,\"minVersion\":\"\",\"downloaded\":false,\"downloadPath\":\"\",\"releaseNotes\":\"\",\"lastCheck\":\"\",\"includeBeta\":false}" > "$UPDATES_JSON"
  fi
  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/app-updates-XXXXXX")
    if [[ "$is_string" == "true" ]]; then
      if ! jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$UPDATES_JSON" > "$tmp"; then
        rm -f "$tmp"
        err "failed to update ${field} in updates.json"
        return 1
      fi
    else
      if ! jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$UPDATES_JSON" > "$tmp"; then
        rm -f "$tmp"
        err "failed to update ${field} in updates.json"
        return 1
      fi
    fi
    mv "$tmp" "$UPDATES_JSON"
    return 0
  fi
  if [[ "$is_string" == "true" ]]; then
    if grep -q "\"${field}\"" "$UPDATES_JSON" 2>/dev/null; then
      sed -i "s|\"${field}\"[[:space:]]*:[[:space:]]*[^,}]*|\"${field}\": \"${value}\"|" "$UPDATES_JSON"
    else
      sed -i "s|}[[:space:]]*$|,\n  \"${field}\": \"${value}\"\n}|" "$UPDATES_JSON"
    fi
  else
    if grep -q "\"${field}\"" "$UPDATES_JSON" 2>/dev/null; then
      sed -i "s|\"${field}\"[[:space:]]*:[[:space:]]*[^,}]*|\"${field}\": ${value}|" "$UPDATES_JSON"
    else
      sed -i "s|}[[:space:]]*$|,\n  \"${field}\": ${value}\n}|" "$UPDATES_JSON"
    fi
  fi
}

read_stat() {
  local key="$1" line="" val=""
  line=$(grep "^${key}=" "$DL_STATS_FILE" 2>/dev/null | tail -1 || true)
  val="${line#*=}"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
  else
    printf '0'
  fi
}

format_bytes() {
  local bytes="${1:-0}"
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s' "$bytes"
    return 0
  fi
  if (( bytes >= 1048576 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }'
  elif (( bytes >= 1024 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.1f KB", b / 1024 }'
  else
    printf '%d B' "$bytes"
  fi
}

log "preparing to download the application update..."

latest_version=""
if [[ -n "$TARGET_VERSION" ]]; then
  latest_version="$TARGET_VERSION"
  mkdir -p "$UPDATES_DIR"
  if [[ ! -f "$UPDATES_JSON" ]]; then
    write_json_field "available" "true" "false"
  fi
else
  if [[ ! -f "$UPDATES_JSON" ]]; then
    err "updates.json not found at ${UPDATES_JSON}"
    err "run the update check first."
    exit 1
  fi
  available=$(read_json_field "available")
  if [[ "$available" != "true" ]]; then
    info "no update available. Run the update check to refresh."
    exit 0
  fi
  latest_version=$(read_json_field "latestVersion")
fi

if [[ -z "$latest_version" ]]; then
  err "could not determine target version"
  exit 1
fi

log "target version: ${latest_version}"
DOWNLOAD_START_SEC=$SECONDS
DL_STATS_FILE=$(mktemp "${TMPDIR:-/tmp}/app-dl-stats-XXXXXX")
trap 'rm -f "$DL_STATS_FILE"' EXIT

phase "1/2" "downloading release kit"
if ! "${SCRIPT_DIR}/download-1-release-kit.sh" "$APP_HOME" "$latest_version" "$DL_STATS_FILE"; then
  exit 1
fi

phase "2/2" "pulling container images"
if ! "${SCRIPT_DIR}/download-2-container-images.sh" "$APP_HOME" "$latest_version" "$DL_STATS_FILE"; then
  exit 1
fi

download_dir="${UPDATES_DIR}/${latest_version}"
existing_latest=$(read_json_field "latestVersion")
if [[ -z "$TARGET_VERSION" || -z "$existing_latest" || "$existing_latest" == "unknown" ]]; then
  write_json_field "latestVersion" "$latest_version"
fi
write_json_field "available" "true" "false"
write_json_field "downloaded" "true" "false"
write_json_field "downloadPath" "$download_dir"

staged_pkg="${download_dir}/package.json"
if [[ -f "$staged_pkg" ]]; then
  if command -v jq >/dev/null 2>&1; then
    min_ver=$(jq -r '.updateCompatibility.minVersion // empty' "$staged_pkg" 2>/dev/null || true)
  else
    min_ver=$(grep -o '"minVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "$staged_pkg" 2>/dev/null \
      | head -1 | sed 's/.*"minVersion"[[:space:]]*:[[:space:]]*"//' | sed 's/"$//' || true)
  fi
  if [[ -n "$min_ver" ]]; then
    write_json_field "minVersion" "$min_ver"
    cur_ver=$(get_current_version)
    if [[ "$cur_ver" != "unknown" ]]; then
      compat_result=0
      compare_versions "$cur_ver" "$min_ver" || compat_result=$?
      if [[ $compat_result -eq 2 ]]; then
        write_json_field "compatible" "false" "false"
      else
        write_json_field "compatible" "true" "false"
      fi
    fi
  fi
fi

installed=$(get_current_version)
if [[ "$installed" != "unknown" ]]; then
  cur=$(read_json_field "currentVersion")
  if [[ -z "$cur" || "$cur" == "unknown" ]]; then
    write_json_field "currentVersion" "$installed"
  fi
fi

kit_bytes=$(read_stat KIT_BYTES)
total_images=$(read_stat TOTAL_IMAGES)
pulled_count=$(read_stat PULLED_COUNT)
cached_count=$(read_stat CACHED_COUNT)
kit_retries=$(read_stat KIT_RETRIES)
image_retries=$(read_stat IMAGE_RETRIES)
retries_count=$((kit_retries + image_retries))
total_elapsed=$((SECONDS - DOWNLOAD_START_SEC))
(( total_elapsed < 1 )) && total_elapsed=1
printf "\n ${SYM_OK} update v%s ready to install (kit: %s, images: %d total — %d pulled, %d cached, retries: %d, elapsed: %ds)\n" \
  "$latest_version" "$(format_bytes "$kit_bytes")" "$total_images" "$pulled_count" "$cached_count" "$retries_count" "$total_elapsed"

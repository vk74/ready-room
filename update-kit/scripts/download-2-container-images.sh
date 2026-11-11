#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Pull the container images for a staged release. Images already present
#          are counted as cached. A missing image is pulled up to 3 times.
#          On failure, updates.json is marked not downloaded. Writes image stats.
#          Usage: download-2-container-images.sh <APP_HOME> <version> <stats-file>
# File: download-2-container-images.sh
#
# Changes in v0.26.3:
# - Image phase. Resolves images with resolve_expected_images from the staged
#   package.json and deploy/env/app.template.env.
# - Writes TOTAL_IMAGES, PULLED_COUNT, CACHED_COUNT, and IMAGE_RETRIES.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
# shellcheck source=lib/github-auth.sh
. "${SCRIPT_DIR}/lib/github-auth.sh"

APP_HOME="${1:?usage: download-2-container-images.sh <APP_HOME> <version> <stats-file>}"
VERSION="${2:?usage: download-2-container-images.sh <APP_HOME> <version> <stats-file>}"
DL_STATS_FILE="${3:?usage: download-2-container-images.sh <APP_HOME> <version> <stats-file>}"
export APP_HOME
load_github_token

CONFIG_DIR="${APP_HOME}/config"
UPDATES_DIR="${CONFIG_DIR}/updates"
UPDATES_JSON="${UPDATES_DIR}/updates.json"
download_dir="${UPDATES_DIR}/${VERSION}"
# resolve_expected_images reads UPDATE_VERSION_DIR/package.json and NEW_DEPLOY_DIR/env.
UPDATE_VERSION_DIR="$download_dir"
NEW_DEPLOY_DIR="${download_dir}/deploy"
MAX_DOWNLOAD_ATTEMPTS=3

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

retry_backoff_for() {
  if [[ "$1" -le 1 ]]; then
    printf '3'
  else
    printf '6'
  fi
}

mark_download_incomplete() {
  [[ -f "$UPDATES_JSON" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/app-updates-XXXXXX")
    if jq '.downloaded = false | .downloadPath = ""' "$UPDATES_JSON" > "$tmp"; then
      mv "$tmp" "$UPDATES_JSON"
      return 0
    fi
    rm -f "$tmp"
  fi
  sed -i 's|"downloaded"[[:space:]]*:[[:space:]]*[^,}]*|"downloaded": false|' "$UPDATES_JSON" || true
  sed -i 's|"downloadPath"[[:space:]]*:[[:space:]]*"[^"]*"|"downloadPath": ""|' "$UPDATES_JSON" || true
}

if ! resolve_expected_images; then
  mark_download_incomplete
  exit 1
fi

total_images=${#EXPECTED_IMAGES[@]}
pulled_count=0
cached_count=0
image_retries=0
if [[ "$total_images" -eq 0 ]]; then
  err "no container images resolved"
  mark_download_incomplete
  exit 1
fi

idx=0
for img in "${EXPECTED_IMAGES[@]}"; do
  idx=$((idx + 1))
  if podman image exists "$img" >/dev/null 2>&1; then
    img_size=$(podman image inspect "$img" --format '{{.Size}}' 2>/dev/null | head -1 || echo 0)
    cached_count=$((cached_count + 1))
    printf " ${SYM_OK} [%d/%d] %s (cached, %s)\n" "$idx" "$total_images" "$img" "$(format_bytes "$img_size")"
    continue
  fi

  pull_rc=1
  pull_err=""
  attempt=1
  while [[ "$attempt" -le "$MAX_DOWNLOAD_ATTEMPTS" ]]; do
    log "[${idx}/${total_images}] pulling ${img} (attempt ${attempt}/${MAX_DOWNLOAD_ATTEMPTS})..."
    img_t0=$SECONDS
    pull_rc=0
    pull_err=$(podman_pull_ghcr "$img" 2>&1) || pull_rc=$?
    if [[ "$pull_rc" -eq 0 ]]; then
      img_sec=$((SECONDS - img_t0))
      (( img_sec < 1 )) && img_sec=1
      img_size=$(podman image inspect "$img" --format '{{.Size}}' 2>/dev/null | head -1 || echo 0)
      pulled_count=$((pulled_count + 1))
      printf " ${SYM_OK} [%d/%d] pulled %s (%s in %ds)\n" "$idx" "$total_images" "$img" "$(format_bytes "$img_size")" "$img_sec"
      break
    fi
    if [[ "$attempt" -lt "$MAX_DOWNLOAD_ATTEMPTS" ]]; then
      image_retries=$((image_retries + 1))
      backoff=$(retry_backoff_for "$attempt")
      printf " ${SYM_WARN} [%d/%d] pull failed for %s (attempt %d/%d); retrying in %ds...\n" \
        "$idx" "$total_images" "$img" "$attempt" "$MAX_DOWNLOAD_ATTEMPTS" "$backoff"
      sleep "$backoff"
    fi
    attempt=$((attempt + 1))
  done

  if [[ "$pull_rc" -ne 0 ]]; then
    if [[ -n "$pull_err" ]]; then
      printf '%s\n' "$pull_err" >&2
    fi
    printf " ${SYM_FAIL} [%d/%d] failed to pull %s after %d attempts\n" \
      "$idx" "$total_images" "$img" "$MAX_DOWNLOAD_ATTEMPTS"
    mark_download_incomplete
    exit 1
  fi
done

printf 'TOTAL_IMAGES=%s\nPULLED_COUNT=%s\nCACHED_COUNT=%s\nIMAGE_RETRIES=%s\n' \
  "$total_images" "$pulled_count" "$cached_count" "$image_retries" >> "$DL_STATS_FILE"
exit 0

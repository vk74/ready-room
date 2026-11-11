#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Phase 1/5 of an application update: validate paths, minVersion, sudo.pass, and local container images. Takes APP_HOME as $1.
# File: update-1-preflight.sh
#
# Changes in v0.26.3:
# - Pre-flight phase. sudo.pass is validated and left on disk for phase 2.
#   An invalid password is deleted and this script exits 1.
# - Missing release images are pulled here, before any service stop, with up to 3 attempts.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
init_update_context "${1:?usage: update-1-preflight.sh <APP_HOME>}" "$SCRIPT_DIR"

# --- Step 1: Validate inputs ---
validate_inputs() {
  log_tee "validating update paths..."

  if [[ -z "$APP_HOME" ]]; then
    log_tee " ${SYM_FAIL} APP_HOME is empty"
    exit 1
  fi
  if [[ "$APP_HOME" == "/" ]] || [[ "$APP_HOME" == "$HOME" ]]; then
    log_tee " ${SYM_FAIL} safety check failed: APP_HOME must not be / or \$HOME"
    exit 1
  fi
  if [[ ! -d "$NEW_DEPLOY_DIR" ]]; then
    log_tee " ${SYM_FAIL} new deploy kit not found at ${NEW_DEPLOY_DIR}"
    exit 1
  fi
  if [[ ! -f "${NEW_DEPLOY_DIR}/install.sh" ]]; then
    log_tee " ${SYM_FAIL} new deploy kit is missing install.sh"
    exit 1
  fi
  if [[ ! -d "$NEW_UPDATE_DIR" ]]; then
    log_tee " ${SYM_FAIL} new update kit not found at ${NEW_UPDATE_DIR}"
    exit 1
  fi
  if [[ ! -d "${APP_HOME}/config" ]]; then
    log_tee " ${SYM_FAIL} application home directory structure invalid (config/ not found at ${APP_HOME}/config)"
    exit 1
  fi

  log_tee " ${SYM_OK} paths validated"
  log_tee "   application home:       ${APP_HOME}"
  log_tee "   New deploy kit: ${NEW_DEPLOY_DIR}"
  log_tee "   New update kit: ${NEW_UPDATE_DIR}"
  log_tee "   Config dir:     ${CONFIG_DIR}"
}

# --- Step 2: Check current version >= minVersion from new kit (staging package.json) ---
check_compatibility() {
  log_tee "checking version compatibility..."

  local current_version
  current_version=$(read_json_field_from_file "${APP_HOME}/package.json" "version")
  if [[ -z "$current_version" ]] || [[ "$current_version" == "unknown" ]]; then
    log_tee " ${SYM_WARN} could not read current version; proceeding anyway"
    return 0
  fi

  local new_pkg="${UPDATE_VERSION_DIR}/package.json"
  local min_version
  min_version=$(read_json_field_from_file "$new_pkg" "minVersion")
  if [[ -z "$min_version" ]]; then
    min_version=$(grep -o '"minVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "$new_pkg" 2>/dev/null | sed 's/.*"minVersion"[[:space:]]*:[[:space:]]*"//' | sed 's/"$//' | head -1 || echo "")
  fi
  if [[ -z "$min_version" ]]; then
    log_tee " ${SYM_OK} no minVersion in new kit; compatibility check skipped"
    return 0
  fi

  local compat_result=0
  compare_versions "$current_version" "$min_version" || compat_result=$?
  if [[ $compat_result -eq 2 ]]; then
    log_tee " ${SYM_FAIL} incompatible: current version ${current_version} is older than minimum required ${min_version}"
    log_tee "   Please update to at least v${min_version} first."
    exit 1
  fi
  log_tee " ${SYM_OK} compatible (current ${current_version}, min required ${min_version})"
}

# Read sudo.pass written by the Cockpit UI. An older panel can create the file
# a few hundred milliseconds after start-update launches this script, so wait
# up to 2 seconds. Leave the file for update-2-host-and-cockpit.sh. An invalid
# password is deleted here and this phase exits 1.
validate_sudo_password() {
  local pass_file="${UPDATES_DIR}/sudo.pass"
  local attempt=0
  while [[ ! -f "$pass_file" && "$attempt" -lt 4 ]]; do
    sleep 0.5
    attempt=$((attempt + 1))
  done
  if [[ ! -f "$pass_file" ]]; then
    return 0
  fi
  local password=""
  password=$(cat "$pass_file")
  if ! echo "$password" | sudo -S true 2>/dev/null; then
    log_tee " ${SYM_FAIL} sudo password validation failed"
    rm -f "$pass_file"
    exit 1
  fi
  log_tee " ${SYM_OK} sudo credentials verified"
}

# Resolve the new release's images from staging package.json and the staged
# template (same set the download flow already pulled). Pull any that are
# missing before services are stopped. Failure aborts the update.
ensure_images_present() {
  log_tee "verifying container images are present locally..."
  if ! resolve_expected_images; then
    exit 1
  fi
  local img=""
  local -a imgs=()
  if [[ ${#EXPECTED_IMAGES[@]} -gt 0 ]]; then
    imgs=("${EXPECTED_IMAGES[@]}")
  fi

  local -a missing=()
  for img in "${imgs[@]}"; do
    if ! podman image exists "$img" >/dev/null 2>&1; then
      missing+=("$img")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_tee " ${SYM_OK} all ${#imgs[@]} container images verified in local storage"
    return 0
  fi

  local MAX_PULL_ATTEMPTS=3
  local attempt=1 backoff=0 pull_rc=1 pull_err=""
  for img in "${missing[@]}"; do
    pull_rc=1
    pull_err=""
    attempt=1
    while [[ "$attempt" -le "$MAX_PULL_ATTEMPTS" ]]; do
      log_tee "   pulling ${img} (attempt ${attempt}/${MAX_PULL_ATTEMPTS})..."
      pull_rc=0
      pull_err=$(podman_pull_ghcr "$img" 2>&1) || pull_rc=$?
      if [[ "$pull_rc" -eq 0 ]]; then
        log_tee " ${SYM_OK} pulled ${img}"
        break
      fi
      if [[ "$attempt" -lt "$MAX_PULL_ATTEMPTS" ]]; then
        if [[ "$attempt" -le 1 ]]; then
          backoff=3
        else
          backoff=6
        fi
        log_tee " ${SYM_WARN} pull failed for ${img} (attempt ${attempt}/${MAX_PULL_ATTEMPTS}); retrying in ${backoff}s..."
        sleep "$backoff"
      fi
      attempt=$((attempt + 1))
    done
    if [[ "$pull_rc" -ne 0 ]]; then
      if [[ -n "$pull_err" ]]; then
        printf '%s\n' "$pull_err" | tail -20 | while IFS= read -r line; do
          log_tee "   [pull] $line"
        done
      fi
      log_tee " ${SYM_FAIL} required image ${img} could not be pulled; aborting before service stop"
      exit 1
    fi
  done

  log_tee " ${SYM_OK} all ${#imgs[@]} container images verified in local storage"
  return 0
}

# Errexit is off for the run sequence, matching the previous apply-update.sh main.
# Fatal steps exit explicitly so a best-effort command cannot abort the phase.
set +e

validate_inputs
check_compatibility
validate_sudo_password
ensure_images_present
exit 0

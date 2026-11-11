#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Phase 2/5 of an application update: read and delete sudo.pass, sync host prerequisites, and install the Cockpit panel from the staged kit. Takes APP_HOME as $1.
# File: update-2-host-and-cockpit.sh
#
# Changes in v0.26.3:
# - Reads config/updates/sudo.pass, checks it with sudo -S true, and deletes the file immediately.
# - Host prerequisites come from scripts/host/sync-host-prerequisites.sh, with a fallback to the flat scripts/sync-host-prerequisites.sh.
# - The Cockpit panel comes from scripts/host/cockpit-panel-sync.sh, with a fallback to scripts/install-cockpit-panels.sh.
# - SUDO_PASSWORD is unset at the end of the phase.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
init_update_context "${1:?usage: update-2-host-and-cockpit.sh <APP_HOME>}" "$SCRIPT_DIR"

# Read sudo.pass into SUDO_PASSWORD, export it, and delete the file immediately.
# A non-empty password is checked with sudo -S true.
read_and_clear_sudo_password() {
  local pass_file="${UPDATES_DIR}/sudo.pass"
  SUDO_PASSWORD=""
  if [[ -f "$pass_file" ]]; then
    SUDO_PASSWORD=$(cat "$pass_file")
    export SUDO_PASSWORD
    rm -f "$pass_file"
    if [[ -n "${SUDO_PASSWORD}" ]]; then
      if ! echo "${SUDO_PASSWORD}" | sudo -S true 2>/dev/null; then
        log_tee " ${SYM_FAIL} sudo password validation failed"
        unset SUDO_PASSWORD
        exit 1
      fi
      log_tee " ${SYM_OK} sudo credentials verified and removed from disk"
    fi
  fi
}

# Phase 2: host prerequisites and the Cockpit panel, from the staged kit.
# Password sudo when read_and_clear_sudo_password stored a password; otherwise nopasswd.
# A nopasswd sudo failure is a warning. The password is cleared before return.
# scripts/host/ is the current layout. Flat scripts/ is the fallback for a kit
# that has not been rearranged yet. install-cockpit-panels.sh still needs
# --sync-only: its default mode reads sudo.pass, which this phase already deleted.
run_sudo_phase() {
  local sudo_mode="nopasswd"
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    sudo_mode="password"
  fi

  local sync_script="${NEW_DEPLOY_DIR}/scripts/host/sync-host-prerequisites.sh"
  if [[ ! -f "$sync_script" ]]; then
    sync_script="${NEW_DEPLOY_DIR}/scripts/sync-host-prerequisites.sh"
  fi
  if [[ ! -f "$sync_script" ]]; then
    log_tee " ${SYM_WARN} sync-host-prerequisites.sh not found in new kit; skipping prerequisites sync"
  else
    log_tee "checking host prerequisites from new release manifest (sudo mode: ${sudo_mode})..."
    chmod +x "$sync_script"
    local sync_exit=0
    "$sync_script" "$NEW_DEPLOY_DIR" --sudo-mode="${sudo_mode}" 2>&1 | while IFS= read -r line; do
      log_tee "   [prereq] $line"
    done || sync_exit=$?
    if [[ $sync_exit -eq 0 ]]; then
      log_tee " ${SYM_OK} host prerequisites synced"
    elif [[ "$sudo_mode" == "nopasswd" ]]; then
      log_tee " ${SYM_WARN} host prerequisites sync skipped (sudo not available without password)"
    else
      log_tee " ${SYM_WARN} host prerequisites sync failed"
    fi
  fi

  local panel_script="${NEW_DEPLOY_DIR}/scripts/host/cockpit-panel-sync.sh"
  local -a panel_args=("${APP_HOME}" --source-dir "${NEW_DEPLOY_DIR}/cockpit-app-admin" --sudo-mode="${sudo_mode}")
  if [[ ! -f "$panel_script" ]]; then
    panel_script="${NEW_DEPLOY_DIR}/scripts/install-cockpit-panels.sh"
    panel_args=("${APP_HOME}" --source-dir "${NEW_DEPLOY_DIR}/cockpit-app-admin" --sync-only --sudo-mode="${sudo_mode}")
  fi
  if [[ ! -f "$panel_script" ]]; then
    log_tee " ${SYM_WARN} cockpit panel script not found in new kit; skipping panel install"
  else
    log_tee "installing cockpit panel from staging (sudo mode: ${sudo_mode})..."
    chmod +x "$panel_script"
    local panel_exit=0
    "$panel_script" "${panel_args[@]}" 2>&1 | while IFS= read -r line; do
      log_tee "   [cockpit] $line"
    done || panel_exit=$?
    if [[ $panel_exit -eq 0 ]]; then
      log_tee " ${SYM_OK} cockpit panel installed from staging"
    else
      log_tee " ${SYM_WARN} cockpit panel install failed"
    fi
  fi

  unset SUDO_PASSWORD
}

# Errexit is off for the run sequence, matching the previous apply-update.sh main.
# Fatal steps exit explicitly so a best-effort command cannot abort the phase.
set +e

read_and_clear_sudo_password
run_sudo_phase
exit 0

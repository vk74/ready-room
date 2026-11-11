#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Idempotent sync of host prerequisites from prerequisites.conf manifest.
# Sources the manifest, validates variables, installs/upgrades apt packages, configures
# sysctl rootless ports, journald log caps, enables linger, opens UFW ports, and enables
# cockpit and podman sockets. Does not install the Cockpit panel; callers run
# cockpit-panel-sync.sh separately.
# Designed for non-interactive use (nohup/detached). Caller decides fatal vs non-fatal.
# Deploy-kit script; filename: sync-host-prerequisites.sh
#
# Usage: sync-host-prerequisites.sh <deploy-dir> [--sudo-mode=nopasswd|password]
#   <deploy-dir>  Directory containing prerequisites.conf (staging or APP_HOME)
#   --sudo-mode   nopasswd (default): sudo -n only (cached credentials)
#                  password: echo "$SUDO_PASSWORD" | sudo -S (env var must be set)
#
# Changes in v0.26.3:
# - sync_ufw passes --sudo-mode through to ufw-ensure-active.sh.
# - Host prerequisite sync no longer installs the Cockpit panel. Callers run
#   scripts/host/cockpit-panel-sync.sh on their own.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# 
# Changes in v0.23.12:
# - sync_journald delegates to journald-limits-ensure.sh (same --sudo-mode);
#   failure is fatal like sync_sysctl (not warn-and-continue like fail2ban).
#
# Changes in v0.23.10:
# - After sync_ufw, call install-fail2ban.sh with the same --sudo-mode. Helper
#   failure warns and continues (apply-update must not be blocked by a jail write).
#
# Changes in v0.23.8:
# - After required cockpit apt, call install-cockpit-files.sh with the same --sudo-mode.
#   Helper failure does not fail the sync (optional File browser).
#
# Changes in v0.23.1:
# - Noninteractive apt (DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l) so needrestart
#   cannot block updates or restart sshd.
#
# Changes in v0.21.8:
# - Define SCRIPT_DIR so sync_ufw can call ufw-ensure-active.sh under set -u (was unbound; aborted mid-sync).
#
# Changes in v1.0.1:
# - sync_ufw: call ufw-ensure-active.sh instead of skipping when ufw is inactive.
#
# Changes in v1.0.0:
# - Initial implementation: apt packages, cockpit packages, sysctl, linger, UFW, cockpit.socket, podman.socket.
# - Shared by apply-update.sh (non-fatal, nopasswd) and install-cockpit-panels.sh (guaranteed, password).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_DIR="${1:?usage: sync-host-prerequisites.sh <deploy-dir> [--sudo-mode=nopasswd|password]}"
shift

SUDO_MODE="nopasswd"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sudo-mode=*) SUDO_MODE="${1#--sudo-mode=}"; shift ;;
    *) shift ;;
  esac
done

PREREQ_CONF="${DEPLOY_DIR}/prerequisites.conf"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

SYM_OK="${GREEN}[✓]${NC}"
SYM_FAIL="${RED}[✗]${NC}"
SYM_WARN="${YELLOW}[!]${NC}"

log() { printf "${CYAN}[prereq]${NC} %s\n" "$*"; }
info() { printf "${GREEN}info:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*" >&2; }

# --- sudo wrapper: adapts to --sudo-mode ---
do_sudo() {
  case "$SUDO_MODE" in
    password)
      if [[ -z "${SUDO_PASSWORD:-}" ]]; then
        err "SUDO_PASSWORD env var is empty but --sudo-mode=password was requested"
        return 1
      fi
      echo "${SUDO_PASSWORD}" | sudo -S "$@" 2>/dev/null
      ;;
    nopasswd)
      sudo -n "$@"
      ;;
    *)
      err "unknown sudo mode: ${SUDO_MODE}"
      return 1
      ;;
  esac
}

# --- Validate sudo access before doing anything ---
validate_sudo() {
  log "validating sudo access (mode=${SUDO_MODE})..."
  if ! do_sudo true; then
    err "sudo not available (mode=${SUDO_MODE})"
    return 1
  fi
  log " ${SYM_OK} sudo access confirmed"
}

# --- Source and validate manifest ---
load_manifest() {
  if [[ ! -f "${PREREQ_CONF}" ]]; then
    err "prerequisites.conf not found: ${PREREQ_CONF}"
    return 1
  fi

  # shellcheck source=/dev/null
  source "${PREREQ_CONF}"
  APP_PREREQ_APT_PACKAGES="${APP_PREREQ_APT_PACKAGES:-}"
  APP_PREREQ_COCKPIT_PACKAGES="${APP_PREREQ_COCKPIT_PACKAGES:-}"
  APP_PREREQ_COCKPIT_FILES_PACKAGE="${APP_PREREQ_COCKPIT_FILES_PACKAGE:-}"
  APP_PREREQ_COCKPIT_FILES_RELEASE="${APP_PREREQ_COCKPIT_FILES_RELEASE:-}"
  APP_PREREQ_COCKPIT_FILES_DEB_URL="${APP_PREREQ_COCKPIT_FILES_DEB_URL:-}"
  APP_PREREQ_UNPRIVILEGED_PORT_START="${APP_PREREQ_UNPRIVILEGED_PORT_START:-}"
  APP_PREREQ_UFW_PORTS="${APP_PREREQ_UFW_PORTS:-}"

  local ok=0
  if [[ -z "${APP_PREREQ_APT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_APT_PACKAGES is empty"
    ok=1
  fi
  if [[ -z "${APP_PREREQ_COCKPIT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_COCKPIT_PACKAGES is empty"
    ok=1
  fi
  if [[ -z "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" ]] || ! [[ "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" =~ ^[0-9]+$ ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UNPRIVILEGED_PORT_START must be a non-negative integer"
    ok=1
  fi
  if [[ -z "${APP_PREREQ_UFW_PORTS// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UFW_PORTS is empty"
    ok=1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_USE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_USE is empty"
    ok=1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_FILE_SIZE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_FILE_SIZE is empty"
    ok=1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_RETENTION// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_RETENTION is empty"
    ok=1
  fi
  return "${ok}"
}

# --- Sync apt packages ---
sync_apt_packages() {
  log "syncing apt packages: ${APP_PREREQ_APT_PACKAGES:-} ${APP_PREREQ_COCKPIT_PACKAGES:-}..."
  do_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update -qq
  # shellcheck disable=SC2086
  do_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y ${APP_PREREQ_APT_PACKAGES:-}
  # shellcheck disable=SC2086
  do_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y ${APP_PREREQ_COCKPIT_PACKAGES:-}
  if [[ -f "${SCRIPT_DIR}/install-cockpit-files.sh" ]]; then
    bash "${SCRIPT_DIR}/install-cockpit-files.sh" "${DEPLOY_DIR}" --sudo-mode="${SUDO_MODE}" \
      || warn "cockpit file browser (cockpit-files) was not synced; continuing"
  fi
  log " ${SYM_OK} apt packages synced"
}

# --- Sync sysctl rootless ports ---
sync_sysctl() {
  local current_start
  current_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "1024")

  if [[ "${current_start}" =~ ^[0-9]+$ ]] && [[ "${current_start}" -le "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" ]]; then
    log " ${SYM_OK} sysctl rootless ports already ok (start=${current_start})"
    return 0
  fi

  log "configuring rootless ports (unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-})..."
  do_sudo rm -f /etc/sysctl.d/99-evi-rootless.conf 2>/dev/null || true
  echo "net.ipv4.ip_unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" | do_sudo tee /etc/sysctl.d/99-app-rootless.conf >/dev/null
  do_sudo sysctl -p /etc/sysctl.d/99-app-rootless.conf >/dev/null 2>&1 || true
  log " ${SYM_OK} sysctl configured"
}

# --- Sync journald caps (delegates to journald-limits-ensure.sh; hard-fail) ---
sync_journald() {
  if [[ ! -f "${SCRIPT_DIR}/journald-limits-ensure.sh" ]]; then
    err "journald-limits-ensure.sh is missing (${SCRIPT_DIR}/journald-limits-ensure.sh)"
    return 1
  fi
  bash "${SCRIPT_DIR}/journald-limits-ensure.sh" "${DEPLOY_DIR}" --sudo-mode="${SUDO_MODE}"
}

# --- Sync linger ---
sync_linger() {
  if loginctl show-user "$(whoami)" -p Linger 2>/dev/null | grep -q "yes"; then
    log " ${SYM_OK} systemd linger already enabled"
    return 0
  fi
  log "enabling systemd linger for $(whoami)..."
  do_sudo loginctl enable-linger "$(whoami)"
  log " ${SYM_OK} linger enabled"
}

# --- Sync UFW ports (only if UFW is active) ---
sync_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    log " ${SYM_OK} ufw not installed; skipping"
    return 0
  fi
  if ! bash "${SCRIPT_DIR}/ufw-ensure-active.sh" --sudo-mode="${SUDO_MODE}"; then
    log " ${SYM_WARN} ufw could not be enabled; skipping port sync"
    return 0
  fi
  log "syncing UFW ports: ${APP_PREREQ_UFW_PORTS:-}..."
  local port
  for port in ${APP_PREREQ_UFW_PORTS:-}; do
    if ! do_sudo ufw status 2>/dev/null | grep -qE "${port}.*ALLOW"; then
      do_sudo ufw allow "${port}" >/dev/null
      log "   opened ${port}"
    fi
  done
  log " ${SYM_OK} UFW ports synced"
}

# --- Sync cockpit socket ---
sync_cockpit_socket() {
  if do_sudo systemctl is-active cockpit.socket >/dev/null 2>&1; then
    log " ${SYM_OK} cockpit.socket already active"
    return 0
  fi
  log "enabling cockpit.socket..."
  do_sudo systemctl enable --now cockpit.socket
  log " ${SYM_OK} cockpit.socket enabled"
}

# --- Sync podman user socket (no sudo needed) ---
sync_podman_socket() {
  if systemctl --user is-active podman.socket >/dev/null 2>&1; then
    log " ${SYM_OK} podman.socket already active"
    return 0
  fi
  log "enabling podman user socket..."
  systemctl --user enable --now podman.socket
  log " ${SYM_OK} podman.socket enabled"
}

# --- Main ---
main() {
  log "starting host prerequisites sync..."

  load_manifest || exit 1
  validate_sudo || exit 1

  sync_apt_packages
  sync_sysctl
  sync_journald
  sync_linger
  sync_ufw
  if [[ -f "${SCRIPT_DIR}/install-fail2ban.sh" ]]; then
    bash "${SCRIPT_DIR}/install-fail2ban.sh" "${DEPLOY_DIR}" --sudo-mode="${SUDO_MODE}" \
      || warn "sshd jail (fail2ban) was not synced; continuing"
  fi
  sync_cockpit_socket
  sync_podman_socket

  info "host prerequisites sync completed."
}

main

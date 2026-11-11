#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Enable UFW if installed but inactive, ensuring SSH stays allowed before enable.
# Optional --sudo-mode=nopasswd|password|interactive (default interactive) selects how
# privileged ufw commands run, so interactive callers and non-interactive sync share one script.
# Backend script, called from install.sh, ufw-add-rules.sh, sync-host-prerequisites.sh, and check-prerequisites repair.
# Deployment script: ufw-ensure-active.sh
#
# Changes in v0.26.3:
# - Accept optional --sudo-mode=nopasswd|password|interactive, defaulting to interactive.
# - Run ufw commands through do_sudo (sudo -n, sudo -S from SUDO_PASSWORD, or a normal sudo).
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
#
# Changes in v1.0.0:
# - Initial version: allow OpenSSH (or detected sshd Port), then ufw --force enable.
#
set -euo pipefail

CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

log() { printf "${CYAN}[app]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }

SUDO_MODE="interactive"

# Privileged command wrapper. password reads SUDO_PASSWORD; nopasswd refuses a prompt;
# interactive is a normal sudo (prompt allowed).
do_sudo() {
  case "$SUDO_MODE" in
    password)
      if [[ -z "${SUDO_PASSWORD:-}" ]]; then
        return 1
      fi
      echo "${SUDO_PASSWORD}" | sudo -S "$@" 2>/dev/null
      ;;
    nopasswd)
      sudo -n "$@"
      ;;
    interactive)
      sudo "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

detect_ssh_port() {
  local port=22 p
  if [[ -f /etc/ssh/sshd_config ]]; then
    p=$(awk '/^[[:space:]]*Port[[:space:]]+/ { print $2; exit }' /etc/ssh/sshd_config 2>/dev/null || true)
    [[ -n "${p}" ]] && port="${p}"
  fi
  printf '%s' "${port}"
}

ensure_ssh_allowed() {
  local ssh_port="$1"
  if do_sudo ufw status 2>/dev/null | grep -qiE 'openssh|'"${ssh_port}"'/tcp'; then
    return 0
  fi
  if do_sudo ufw allow OpenSSH 2>/dev/null; then
    return 0
  fi
  do_sudo ufw allow "${ssh_port}/tcp" comment 'SSH' 2>/dev/null || do_sudo ufw allow "${ssh_port}/tcp"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sudo-mode=*) SUDO_MODE="${1#--sudo-mode=}"; shift ;;
      *) shift ;;
    esac
  done

  case "${SUDO_MODE}" in
    nopasswd|password|interactive) ;;
    *)
      warn "unknown sudo mode: ${SUDO_MODE}"
      return 1
      ;;
  esac

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not found; cannot enable firewall."
    return 1
  fi

  local status_before ssh_port
  status_before=$(do_sudo ufw status 2>/dev/null | head -1 || true)
  if echo "${status_before}" | grep -q "Status: active"; then
    return 0
  fi

  ssh_port=$(detect_ssh_port)
  log "enabling ufw (allowing SSH on port ${ssh_port} first)..."
  ensure_ssh_allowed "${ssh_port}"
  do_sudo ufw --force enable

  status_before=$(do_sudo ufw status 2>/dev/null | head -1 || true)

  if echo "${status_before}" | grep -q "Status: active"; then
    info_msg="ufw is now active."
    log "${info_msg}"
    return 0
  fi

  warn "ufw enable did not activate the firewall."
  return 2
}

main "$@"

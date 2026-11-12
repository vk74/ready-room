#!/usr/bin/env bash
#
# Version: 0.23.10
# Purpose: Configure or remove the kit-managed fail2ban sshd jail. Does not
#   change sshd_config. Writes only /etc/fail2ban/jail.d/sshd-kit.local.
#   Package install is belt-and-suspenders when fail2ban is missing; callers
#   normally install fail2ban python3-systemd from prerequisites.conf first.
# File: install-fail2ban.sh
#
# Usage: install-fail2ban.sh <deploy-dir>
#          [--sudo-mode=nopasswd|password|interactive]
#          [--remove]
#   Flags may appear before or after <deploy-dir>.
#   nopasswd (default): sudo -n — apply-update / sync.
#   interactive: sudo with a prompt — Deploy, restore, repair, uninstall.
#
# Changes in v0.23.10:
# - Initial helper: detect OpenSSH unit and sshd Port, write kit-managed
#   sshd jail, enable fail2ban, and --remove of sshd-kit.local only.
# - Always set action=%(action_)s so fail2ban 1.1.x (Ubuntu 24.04/26.04)
#   loads a real ban action. Optional banaction=ufw when UFW is active.
#   Upgrade/repair rewrites older sshd-kit.local that had banaction=ufw
#   alone (empty actions; UI ban without firewall drop).
# - After writing the jail: reload, then systemctl restart fail2ban if
#   actions are still empty before hard-fail (reload alone can miss actions).
#

set -euo pipefail

SUDO_MODE="nopasswd"
REMOVE=0
DEPLOY_DIR=""

JAIL_PATH="/etc/fail2ban/jail.d/sshd-kit.local"
KIT_MARKER="kit-managed sshd jail"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() { printf "${CYAN}[sshd-jail]${NC} %s\n" "$*"; }
info() { printf "${GREEN}info:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*" >&2; }

usage() {
  err "usage: install-fail2ban.sh <deploy-dir> [--sudo-mode=nopasswd|password|interactive] [--remove]"
}

# --- sudo wrapper: same pattern as install-cockpit-files.sh ---
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
    interactive)
      sudo "$@"
      ;;
    *)
      err "unknown sudo mode: ${SUDO_MODE}"
      return 1
      ;;
  esac
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --sudo-mode=*) SUDO_MODE="${arg#--sudo-mode=}" ;;
      --remove) REMOVE=1 ;;
      --help|-h)
        usage
        return 1
        ;;
      -*)
        warn "unknown flag: ${arg}"
        ;;
      *)
        if [[ -z "${DEPLOY_DIR}" ]]; then
          DEPLOY_DIR="${arg}"
        fi
        ;;
    esac
  done
  if [[ -z "${DEPLOY_DIR}" ]]; then
    usage
    return 1
  fi
  case "${SUDO_MODE}" in
    nopasswd|password|interactive) ;;
    *)
      err "unknown sudo mode: ${SUDO_MODE}"
      return 1
      ;;
  esac
  return 0
}

detect_ssh_port() {
  local port=22 p
  if [[ -f /etc/ssh/sshd_config ]]; then
    p=$(awk '/^[[:space:]]*Port[[:space:]]+/ { print $2; exit }' /etc/ssh/sshd_config 2>/dev/null || true)
    [[ -n "${p}" ]] && port="${p}"
  fi
  printf '%s' "${port}"
}

# Prefer ssh.service (Ubuntu/Debian) when listed, else sshd.service, else ssh.service.
detect_ssh_unit() {
  local listing=""
  listing="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null || true)"
  if [[ -z "${listing}" ]]; then
    listing="$(do_sudo systemctl list-unit-files --type=service --no-legend 2>/dev/null || true)"
  fi
  if printf '%s\n' "${listing}" | grep -qE '^ssh\.service([[:space:]]|$)'; then
    printf '%s' 'ssh.service'
    return 0
  fi
  if printf '%s\n' "${listing}" | grep -qE '^sshd\.service([[:space:]]|$)'; then
    printf '%s' 'sshd.service'
    return 0
  fi
  printf '%s' 'ssh.service'
}

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  do_sudo ufw status 2>/dev/null | grep -q "Status: active"
}

fail2ban_pkg_installed() {
  dpkg -s fail2ban >/dev/null 2>&1
}

fail2ban_enabled() {
  do_sudo systemctl is-enabled fail2ban >/dev/null 2>&1
}

fail2ban_active() {
  do_sudo systemctl is-active fail2ban >/dev/null 2>&1
}

sshd_status_ok() {
  command -v fail2ban-client >/dev/null 2>&1 || return 1
  do_sudo fail2ban-client status sshd >/dev/null 2>&1
}

kit_jail_exists() {
  do_sudo test -f "${JAIL_PATH}"
}

# True when fail2ban-client reports at least one action for jail sshd.
jail_actions_ok() {
  local raw
  command -v fail2ban-client >/dev/null 2>&1 || return 1
  raw="$(do_sudo fail2ban-client get sshd actions 2>/dev/null || true)"
  raw="$(printf '%s' "${raw}" | tr -d '\r')"
  if [[ -z "${raw}" ]]; then
    return 1
  fi
  if printf '%s' "${raw}" | grep -qiE 'no actions|empty'; then
    return 1
  fi
  return 0
}

# Older kit drop-ins set banaction=ufw without action=%(action_)s (empty actions).
kit_jail_needs_migrate() {
  kit_jail_exists || return 1
  if do_sudo grep -qE '^[[:space:]]*action[[:space:]]*=' "${JAIL_PATH}"; then
    return 1
  fi
  return 0
}


# Operator-owned sshd jail: jail.local or a non-kit jail.d/*.local.
# Distro defaults-debian.conf / jail.conf are not operator-owned.
find_operator_sshd_jail() {
  local f listing
  if do_sudo test -f /etc/fail2ban/jail.local; then
    if do_sudo grep -qE '^[[:space:]]*\[sshd\]' /etc/fail2ban/jail.local; then
      printf '%s' '/etc/fail2ban/jail.local'
      return 0
    fi
  fi
  listing="$(do_sudo bash -c 'shopt -s nullglob; for f in /etc/fail2ban/jail.d/*.local; do printf "%s\n" "${f}"; done' 2>/dev/null || true)"
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    [[ "${f}" == "${JAIL_PATH}" ]] && continue
    if do_sudo grep -qE '^[[:space:]]*\[sshd\]' "${f}"; then
      printf '%s' "${f}"
      return 0
    fi
  done <<< "${listing}"
  return 1
}

fmt_seconds() {
  local s="${1:-}"
  if [[ "${s}" =~ ^[0-9]+$ ]]; then
    if (( s >= 3600 && s % 3600 == 0 )); then
      printf '%sh' "$((s / 3600))"
      return 0
    fi
    if (( s >= 60 && s % 60 == 0 )); then
      printf '%sm' "$((s / 60))"
      return 0
    fi
  fi
  printf '%s' "${s}"
}

generate_desired() {
  local unit="$1" port="$2" banaction_line=""
  # fail2ban 1.1.x: setting banaction alone does not populate jail actions.
  # action=%(action_)s expands DEFAULT action_ using banaction (ufw here, or
  # distro default nftables when UFW is inactive). Do not leave banaction
  # without action - that yielded empty actions after 0.23.10-beta3.
  if ufw_is_active; then
    banaction_line=$'\nbanaction = ufw'
  fi
  cat <<EOF
# ${KIT_MARKER} - edit ignoreip if you need an admin or Tailscale IP, then:
# sudo fail2ban-client reload sshd
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
ignoreip = 127.0.0.1/8 ::1
journalmatch = _SYSTEMD_UNIT=${unit} + _COMM=sshd
port = ${port}
action = %(action_)s${banaction_line}
EOF
}

# Write dest as root without consuming do_sudo stdin (password mode).
install_root_file() {
  local dest="$1"
  local src="$2"
  do_sudo mkdir -p "$(dirname "${dest}")"
  if ! do_sudo cp "${src}" "${dest}"; then
    return 1
  fi
  do_sudo chmod 644 "${dest}" || true
  return 0
}

write_kit_jail() {
  local tmp
  tmp="$(mktemp)" || return 1
  printf '%s' "$1" > "${tmp}"
  if [[ -s "${tmp}" && "$(tail -c 1 "${tmp}" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "${tmp}"
  fi
  if ! install_root_file "${JAIL_PATH}" "${tmp}"; then
    rm -f "${tmp}"
    err "failed to write ${JAIL_PATH}"
    return 1
  fi
  rm -f "${tmp}"
  log "wrote ${JAIL_PATH}"
  return 0
}

kit_content_matches() {
  local desired="$1" tmp_desired tmp_existing
  tmp_desired="$(mktemp)"
  tmp_existing="$(mktemp)"
  printf '%s' "${desired}" > "${tmp_desired}"
  if [[ -s "${tmp_desired}" && "$(tail -c 1 "${tmp_desired}" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "${tmp_desired}"
  fi
  if ! do_sudo cat "${JAIL_PATH}" > "${tmp_existing}"; then
    rm -f "${tmp_desired}" "${tmp_existing}"
    return 1
  fi
  if cmp -s "${tmp_desired}" "${tmp_existing}"; then
    rm -f "${tmp_desired}" "${tmp_existing}"
    return 0
  fi
  rm -f "${tmp_desired}" "${tmp_existing}"
  return 1
}

apt_noninteractive() {
  do_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get "$@"
}

ensure_fail2ban_pkg() {
  if fail2ban_pkg_installed; then
    return 0
  fi
  log "installing fail2ban python3-systemd..."
  apt_noninteractive update
  apt_noninteractive install -y fail2ban python3-systemd
  if ! fail2ban_pkg_installed; then
    err "fail2ban is not installed after apt-get"
    return 1
  fi
  return 0
}

enable_and_verify() {
  do_sudo systemctl enable --now fail2ban
  # Reload alone can leave sshd actions empty on fail2ban 1.1.x (Ubuntu
  # 24.04/26.04) until a full restart. Prefer reload; if actions are still
  # empty, restart then re-check before hard-failing.
  if ! do_sudo fail2ban-client reload; then
    warn "fail2ban-client reload failed; restarting fail2ban"
    do_sudo systemctl restart fail2ban
  fi
  local ok=0
  if sshd_status_ok; then
    ok=1
  else
    sleep 1
    if sshd_status_ok; then
      ok=1
    fi
  fi
  if [[ "${ok}" -ne 1 ]]; then
    err "fail2ban sshd jail did not become active"
    return 1
  fi
  if ! jail_actions_ok; then
    warn "sshd jail actions empty after reload; restarting fail2ban"
    do_sudo systemctl restart fail2ban
    sleep 1
    if ! sshd_status_ok; then
      err "fail2ban sshd jail did not become active after restart"
      return 1
    fi
  fi
  if ! jail_actions_ok; then
    err "fail2ban sshd jail has empty actions (ban will not drop traffic)"
    return 1
  fi
  return 0
}

print_sshd_section() {
  local src="$1"
  do_sudo awk '
    /^[[:space:]]*\[sshd\]/ { p=1; print; next }
    /^[[:space:]]*\[/ { if (p) exit }
    p { print }
  ' "${src}" 2>/dev/null || true
}

print_summary() {
  local note="${1:-}"
  local jail_on="off" bantime="—" maxretry="—" findtime="—"
  local raw
  if sshd_status_ok; then
    jail_on="on"
    raw="$(do_sudo fail2ban-client get sshd bantime 2>/dev/null || true)"
    bantime="$(fmt_seconds "${raw}")"
    maxretry="$(do_sudo fail2ban-client get sshd maxretry 2>/dev/null || true)"
    raw="$(do_sudo fail2ban-client get sshd findtime 2>/dev/null || true)"
    findtime="$(fmt_seconds "${raw}")"
  fi
  info "sshd jail: ${jail_on}"
  info "bantime: ${bantime}  maxretry: ${maxretry}  findtime: ${findtime}"
  info "detected unit: ${SSH_UNIT}"
  if [[ -n "${note}" ]]; then
    info "${note}"
  fi
}

print_operator_jail() {
  local src="${1:-}"
  log "sshd jail is already active (operator jail); kit drop-in not written"
  if [[ -n "${src}" ]]; then
    log "jail source: ${src}"
    print_sshd_section "${src}"
  else
    do_sudo fail2ban-client status sshd || true
  fi
  print_summary "operator jail"
}

run_remove() {
  if kit_jail_exists; then
    do_sudo rm -f "${JAIL_PATH}"
    log "removed ${JAIL_PATH}"
  else
    log "${JAIL_PATH} not present (ok)"
  fi
  if fail2ban_active; then
    if ! do_sudo fail2ban-client reload; then
      warn "fail2ban-client reload after remove failed"
    fi
  fi
  return 0
}

run_install() {
  local desired operator_src=""
  local pkg_ok=0 kit_ok=0 jail_ok=0

  SSH_UNIT="$(detect_ssh_unit)"
  SSH_PORT="$(detect_ssh_port)"
  desired="$(generate_desired "${SSH_UNIT}" "${SSH_PORT}")"

  if fail2ban_pkg_installed; then
    pkg_ok=1
  fi
  if kit_jail_exists; then
    kit_ok=1
  fi
  if [[ "${pkg_ok}" -eq 1 ]] && sshd_status_ok; then
    jail_ok=1
  fi

  # Case 3: working sshd jail and no kit drop-in — leave an operator-owned jail.
  if [[ "${pkg_ok}" -eq 1 && "${jail_ok}" -eq 1 && "${kit_ok}" -eq 0 ]]; then
    operator_src="$(find_operator_sshd_jail || true)"
    if [[ -n "${operator_src}" ]]; then
      print_operator_jail "${operator_src}"
      return 0
    fi
    # Distro default only (e.g. defaults-debian.conf): write the kit overlay.
  fi

  # Force rewrite of pre-fix kit drop-ins (banaction without action=).
  if [[ "${kit_ok}" -eq 1 ]] && kit_jail_needs_migrate; then
    log "migrating ${JAIL_PATH} (add action=%(action_)s)"
    ensure_fail2ban_pkg
    write_kit_jail "${desired}"
    enable_and_verify
    print_summary "kit jail migrated"
    return 0
  fi

  # Case 1: kit drop-in matches and the jail is healthy - skip.
  if [[ "${kit_ok}" -eq 1 ]] && kit_content_matches "${desired}"; then
    if fail2ban_enabled && sshd_status_ok && jail_actions_ok; then
      print_summary "already configured (kit jail)"
      return 0
    fi
    # Content OK but actions empty or service down: rewrite + re-enable.
    ensure_fail2ban_pkg
    write_kit_jail "${desired}"
    enable_and_verify
    print_summary "kit jail repaired"
    return 0
  fi

  # Case 2 (content differs) or case 4 / fresh (jail off or no kit file).
  # Content-diff covers upgrade from broken beta3 sshd-kit.local.
  ensure_fail2ban_pkg
  write_kit_jail "${desired}"
  enable_and_verify
  print_summary "kit jail"
  return 0
}

main() {
  if ! parse_args "$@"; then
    return 1
  fi
  if [[ "${REMOVE}" -eq 1 ]]; then
    run_remove
    return 0
  fi
  run_install
}

SSH_UNIT="ssh.service"
SSH_PORT="22"

main "$@"

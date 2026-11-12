#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Diagnose, report, and repair application prerequisites on an existing installation.
# Deployment script: check-prerequisites.sh
# Logic: Four phases — diagnose (check each prerequisite status and version),
#   report (color-coded status table), repair (fix only broken items), verify (re-check after repair).
#   Called from install.sh option 1 when CONFIG_EXISTS=1. Receives deployment dir as $1.
#   Sources prerequisites.conf from the deployment kit (same manifest as deploy_full); no silent fallback.
#   No upgrade logic — only checks if prerequisites are installed and functional.
#
# Changes in v0.26.3:
# - repair_cockpit_app_admin delegates the panel install to
#   scripts/host/cockpit-panel-sync.sh --sync-only --sudo-mode=interactive.
# - Repair helpers are scripts/host/journald-limits-ensure.sh,
#   scripts/host/install-cockpit-files.sh, scripts/host/install-fail2ban.sh,
#   and scripts/host/ufw-ensure-active.sh.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Prerequisite checks read config/app.env.
# - check_cockpit_app_admin verifies panel version and file parity against cockpit-app-admin/ in the kit; repair_cockpit_app_admin copies all JS/CSS assets and renders both dispatch scripts.
# 
# Changes in v0.25.4:
# - pgAdmin env check reads config/app.env, falling back to legacy config/evi.env.
#
# Changes in v0.23.12:
# - check_journald_limits / repair_journald_limits: validate PREREQ_JOURNAL_* and
#   call journald-limits-ensure.sh (--check / --sudo-mode=interactive).
# - repair_ufw_manifest resolves ufw-ensure-active.sh under DEPLOYMENT_DIR/scripts
#   (SCRIPT_DIR is not defined here; under set -u the repair aborted the run).
#
# Changes in v0.23.10:
# - check_sshd_jail / repair_sshd_jail: kit drop-in + fail2ban-client status sshd
#   when the fail2ban package is present. Repair runs install-fail2ban.sh.
# - check_sshd_jail also requires non-empty actions and action= in sshd-kit.local
#   so broken beta3 drop-ins (banaction=ufw only) are repaired on upgrade.
#   Missing package is the apt row only (no second fail).
# - check_sshd_jail: "operator jail" only when jail.local or a non-kit
#   jail.d/*.local has [sshd]. Distro defaults-debian.conf / jail.conf are
#   not operator-owned, so Check & repair still writes the kit overlay.
#
# Changes in v0.23.8:
# - check_cockpit_files: missing File browser is a warn (not fail); repair via
#   install-cockpit-files.sh --sudo-mode=interactive, not apt:cockpit-files
#   (Debian 12 has no candidate).
#
# Changes in v0.23.1:
# - Noninteractive apt (DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l) so needrestart
#   cannot block repair or restart sshd.
#
# Changes in v1.3.1:
# - check_ufw_manifest: inactive ufw is a fail with repair_ufw_manifest (calls ufw-ensure-active.sh).
#
# Changes in v1.3.0:
# - Updated all container name references to short forms without evi- prefix.
#
# Changes in v1.2.0:
# - Removed check_cockpit_evi_pgadmin() and repair_cockpit_evi_pgadmin(): the standalone
#   pgAdmin Cockpit panel no longer exists; pgAdmin is now in the evi-admin DB Tools section.
# - Removed check_cockpit_evi_pgadmin call from diagnose_all().
#
# Changes in v1.1.0:
# - Require prerequisites.conf in deployment dir; exit non-zero if missing or invalid EVI_PREREQ_*.
# - Diagnose/repair apt packages, cockpit stack, sysctl unprivileged ports, and UFW from manifest variables.
# - run_one_repair dispatches apt:<pkg>, repair_cockpit_stack, repair_ufw_manifest, and named repair_* helpers.
#
# Changes in v1.0.0:
# - Initial script: diagnose/report/repair for podman, curl, openssl, cockpit, UFW, linger, cockpit panels.
#

set -euo pipefail

# --- Paths ---
DEPLOYMENT_DIR="${1:?usage: check-prerequisites.sh <deployment-dir>}"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
TARGET_ENV="${CONFIG_DIR}/app.env"
PREREQ_CONF="${DEPLOYMENT_DIR}/prerequisites.conf"

# --- Colors and symbols (ANSI-C quoting) ---
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'
BOLD=$'\033[1m'

SYM_OK="${GREEN}[✓]${NC}"
SYM_FAIL="${RED}[✗]${NC}"
SYM_WARN="${YELLOW}[!]${NC}"

if [[ ! -f "${PREREQ_CONF}" ]]; then
  printf "${RED}error:${NC} prerequisites.conf missing: %s\n" "${PREREQ_CONF}" >&2
  exit 1
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

# --- Helpers ---
log() { printf "${CYAN}[app]${NC} %s\n" "$*"; }
info() { printf "${GREEN}info:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*"; }

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local reply
  read -r -p "${prompt} [${default}]: " reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

validate_prereq_manifest() {
  local ok=0
  if [[ -z "${APP_PREREQ_APT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_APT_PACKAGES is empty (${PREREQ_CONF})"
    ok=1
  fi
  if [[ -z "${APP_PREREQ_COCKPIT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_COCKPIT_PACKAGES is empty (${PREREQ_CONF})"
    ok=1
  fi
  if [[ -z "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" ]] || ! [[ "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" =~ ^[0-9]+$ ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UNPRIVILEGED_PORT_START must be a non-negative integer (${PREREQ_CONF})"
    ok=1
  fi
  if [[ -z "${APP_PREREQ_UFW_PORTS// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UFW_PORTS is empty (${PREREQ_CONF})"
    ok=1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_USE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_USE is empty (${PREREQ_CONF})"
    ok=1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_FILE_SIZE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_FILE_SIZE is empty (${PREREQ_CONF})"
    ok=1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_RETENTION// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_RETENTION is empty (${PREREQ_CONF})"
    ok=1
  fi
  return "${ok}"
}

validate_prereq_manifest || exit 1

# --- State arrays (parallel arrays for component name, status, version, repair action) ---
# Status values: ok, fail, warn
COMP_NAMES=()
COMP_STATUS=()
COMP_VERSION=()
COMP_REPAIR_FN=()

# Reset state arrays before each diagnose pass
reset_state() {
  COMP_NAMES=()
  COMP_STATUS=()
  COMP_VERSION=()
  COMP_REPAIR_FN=()
}

# Add a component result
add_result() {
  local name="$1" status="$2" version="${3:-}" repair_fn="${4:-}"
  COMP_NAMES+=("${name}")
  COMP_STATUS+=("${status}")
  COMP_VERSION+=("${version}")
  COMP_REPAIR_FN+=("${repair_fn}")
}

# Count issues (fail + warn)
count_issues() {
  local count=0
  for s in "${COMP_STATUS[@]}"; do
    [[ "${s}" == "fail" || "${s}" == "warn" ]] && count=$((count + 1))
  done
  echo "${count}"
}

# --- Phase 1: Diagnose ---

check_apt_package() {
  local pkg="$1"
  dpkg -s "${pkg}" >/dev/null 2>&1
}

get_apt_version() {
  local pkg="$1"
  dpkg -s "${pkg}" 2>/dev/null | grep "^Version:" | head -1 | awk '{print $2}'
}

check_apt_pkg_row() {
  local pkg="$1"
  if check_apt_package "${pkg}"; then
    add_result "${pkg}" "ok" "$(get_apt_version "${pkg}")"
  else
    add_result "${pkg}" "fail" "" "apt:${pkg}"
  fi
}

check_cockpit_with_socket() {
  local ver=""
  if check_apt_package cockpit; then
    ver=$(get_apt_version cockpit)
    if sudo systemctl is-active cockpit.socket >/dev/null 2>&1; then
      add_result "cockpit" "ok" "${ver}"
    else
      add_result "cockpit" "warn" "${ver} (socket inactive)" "repair_cockpit_socket"
    fi
  else
    add_result "cockpit" "fail" "" "repair_cockpit_stack"
  fi
}

check_rootless_ports() {
  local port_start
  port_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "1024")
  if [[ "${port_start}" =~ ^[0-9]+$ ]] && [[ "${port_start}" -le "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" ]]; then
    add_result "rootless ports" "ok" "start=${port_start}"
  else
    add_result "rootless ports" "fail" "start=${port_start}" "repair_rootless_ports"
  fi
}

check_linger() {
  if loginctl show-user "$(whoami)" -p Linger 2>/dev/null | grep -q "yes"; then
    add_result "systemd linger" "ok"
  else
    add_result "systemd linger" "fail" "" "repair_linger"
  fi
}

check_journald_limits() {
  local helper="${DEPLOYMENT_DIR}/scripts/host/journald-limits-ensure.sh"
  local reason=""
  if [[ ! -f "${helper}" ]]; then
    add_result "journald limits" "fail" "helper missing" "repair_journald_limits"
    return 0
  fi
  if reason="$(bash "${helper}" "${DEPLOYMENT_DIR}" --check 2>/dev/null)"; then
    add_result "journald limits" "ok"
  else
    add_result "journald limits" "fail" "${reason:-mismatch}" "repair_journald_limits"
  fi
}

repair_journald_limits() {
  local helper="${DEPLOYMENT_DIR}/scripts/host/journald-limits-ensure.sh"
  log "configuring journald limits..."
  if [[ ! -f "${helper}" ]]; then
    err "journald-limits-ensure.sh not found; cannot repair journald limits"
    return 1
  fi
  bash "${helper}" "${DEPLOYMENT_DIR}" --sudo-mode=interactive
}

# UFW: verify each port spec from the manifest when UFW is active
check_ufw_manifest() {
  local ufw_label="ufw rules"
  if ! command -v ufw >/dev/null 2>&1; then
    add_result "${ufw_label}" "ok" "ufw not installed"
    return
  fi
  if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    add_result "${ufw_label}" "fail" "ufw inactive" "repair_ufw_manifest"
    return
  fi
  local missing="" spec
  for spec in ${APP_PREREQ_UFW_PORTS:-}; do
    if ! sudo ufw status 2>/dev/null | grep -qE "${spec}.*ALLOW"; then
      [[ -n "${missing}" ]] && missing="${missing}, "
      missing="${missing}${spec}"
    fi
  done
  if [[ -z "${missing}" ]]; then
    add_result "${ufw_label}" "ok"
  else
    add_result "${ufw_label}" "fail" "missing: ${missing}" "repair_ufw_manifest"
  fi
}

check_podman_socket() {
  if systemctl --user is-active podman.socket >/dev/null 2>&1; then
    add_result "podman user socket" "ok"
  else
    add_result "podman user socket" "fail" "" "repair_podman_socket"
  fi
}

check_cockpit_app_admin() {
  local dst_dir="/usr/local/share/cockpit/app-admin"
  local src_dir="${DEPLOYMENT_DIR}/cockpit-app-admin"

  if [[ ! -f "${dst_dir}/manifest.json" ]]; then
    add_result "cockpit app-admin" "fail" "" "repair_cockpit_app_admin"
    return 0
  fi

  local installed_ver="" kit_ver="" line
  local ver_re="ADMIN_TOOLS_VERSION[[:space:]]*=[[:space:]]*'(v[^']+)'"
  if [[ -f "${dst_dir}/admin.js" ]]; then
    while IFS= read -r line; do
      if [[ "${line}" =~ $ver_re ]]; then
        installed_ver="${BASH_REMATCH[1]}"
        break
      fi
    done < "${dst_dir}/admin.js" || true
  fi
  if [[ -f "${src_dir}/admin.js" ]]; then
    while IFS= read -r line; do
      if [[ "${line}" =~ $ver_re ]]; then
        kit_ver="${BASH_REMATCH[1]}"
        break
      fi
    done < "${src_dir}/admin.js" || true
  fi

  local mismatch=0 name tpl dispatch_name tmp_rendered
  for name in manifest.json index.html admin.js update.js helper.update.status.js admin.css; do
    if [[ ! -f "${dst_dir}/${name}" || ! -f "${src_dir}/${name}" ]] || ! cmp -s "${dst_dir}/${name}" "${src_dir}/${name}"; then
      mismatch=1
      break
    fi
  done

  if [[ "${mismatch}" -eq 0 ]]; then
    for tpl in "${src_dir}/admin-dispatch.sh.tpl" "${src_dir}/update-dispatch.sh.tpl"; do
      dispatch_name="$(basename "${tpl}" .tpl)"
      if [[ ! -f "${tpl}" || ! -f "${dst_dir}/${dispatch_name}" ]]; then
        mismatch=1
        break
      fi
      tmp_rendered="$(mktemp)"
      sed "s|{{DEPLOYMENT_DIR}}|${DEPLOYMENT_DIR}|g" "${tpl}" > "${tmp_rendered}"
      if ! cmp -s "${dst_dir}/${dispatch_name}" "${tmp_rendered}"; then
        mismatch=1
      fi
      rm -f "${tmp_rendered}"
      if [[ "${mismatch}" -eq 1 ]]; then
        break
      fi
    done
  fi

  if [[ "${mismatch}" -eq 1 ]]; then
    add_result "cockpit app-admin" "warn" "${installed_ver:-outdated} -> ${kit_ver:-kit}" "repair_cockpit_app_admin"
  else
    add_result "cockpit app-admin" "ok" "${installed_ver}"
  fi
}

check_cockpit_files() {
  local ver=""
  if dpkg -s cockpit-files >/dev/null 2>&1; then
    ver="$(get_apt_version cockpit-files)"
    add_result "cockpit-files" "ok" "${ver}"
    return
  fi
  if [[ -f /usr/share/cockpit/files/manifest.json || -f /usr/local/share/cockpit/files/manifest.json ]]; then
    add_result "cockpit-files" "ok" "present"
    return
  fi
  add_result "cockpit-files" "warn" "not installed" "repair_cockpit_files"
}

repair_cockpit_files() {
  local helper="${DEPLOYMENT_DIR}/scripts/host/install-cockpit-files.sh"
  log "installing cockpit file browser (optional)..."
  if [[ ! -f "${helper}" ]]; then
    warn "install-cockpit-files.sh not found; cannot repair cockpit-files"
    return 0
  fi
  sudo -v 2>/dev/null || true
  bash "${helper}" "${DEPLOYMENT_DIR}" --sudo-mode=interactive \
    || warn "cockpit file browser (cockpit-files) was not installed"
}

# Operator-owned sshd jail: jail.local or a non-kit jail.d/*.local.
# Distro defaults-debian.conf / jail.conf are not operator-owned.
has_operator_sshd_jail() {
  local f listing kit_jail="/etc/fail2ban/jail.d/sshd-kit.local"
  if sudo test -f /etc/fail2ban/jail.local; then
    if sudo grep -qE '^[[:space:]]*\[sshd\]' /etc/fail2ban/jail.local; then
      return 0
    fi
  fi
  listing="$(sudo bash -c 'shopt -s nullglob; for f in /etc/fail2ban/jail.d/*.local; do printf "%s\n" "${f}"; done' 2>/dev/null || true)"
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    [[ "${f}" == "${kit_jail}" ]] && continue
    if sudo grep -qE '^[[:space:]]*\[sshd\]' "${f}"; then
      return 0
    fi
  done <<< "${listing}"
  return 1
}

check_sshd_jail() {
  if ! check_apt_package fail2ban; then
    return 0
  fi
  local kit_ok=0 jail_ok=0 actions_ok=0 action_line_ok=0
  local actions_raw=""
  if sudo test -f /etc/fail2ban/jail.d/sshd-kit.local; then
    kit_ok=1
    if sudo grep -qE '^[[:space:]]*action[[:space:]]*=' /etc/fail2ban/jail.d/sshd-kit.local; then
      action_line_ok=1
    fi
  fi
  if sudo fail2ban-client status sshd >/dev/null 2>&1; then
    jail_ok=1
    actions_raw="$(sudo fail2ban-client get sshd actions 2>/dev/null || true)"
    actions_raw="$(printf '%s' "${actions_raw}" | tr -d '\r')"
    if [[ -n "${actions_raw}" ]] && ! printf '%s' "${actions_raw}" | grep -qiE 'no actions|empty'; then
      actions_ok=1
    fi
  fi
  # Kit drop-in present but missing action= or empty actions: needs migrate/repair.
  if [[ "${kit_ok}" -eq 1 && ( "${action_line_ok}" -eq 0 || "${actions_ok}" -eq 0 ) ]]; then
    add_result "sshd jail" "fail" "empty actions or missing action=" "repair_sshd_jail"
    return 0
  fi
  if [[ "${kit_ok}" -eq 1 && "${jail_ok}" -eq 1 && "${actions_ok}" -eq 1 ]]; then
    add_result "sshd jail" "ok" "kit"
    return 0
  fi
  if [[ "${kit_ok}" -eq 0 && "${jail_ok}" -eq 1 && "${actions_ok}" -eq 1 ]] && has_operator_sshd_jail; then
    add_result "sshd jail" "ok" "operator jail"
    return 0
  fi
  add_result "sshd jail" "fail" "" "repair_sshd_jail"
}

repair_sshd_jail() {
  local helper="${DEPLOYMENT_DIR}/scripts/host/install-fail2ban.sh"
  log "configuring sshd jail (fail2ban)..."
  if [[ ! -f "${helper}" ]]; then
    err "install-fail2ban.sh not found; cannot repair sshd jail"
    return 1
  fi
  bash "${helper}" "${DEPLOYMENT_DIR}" --sudo-mode=interactive
}

check_pgadmin_env() {
  if [[ ! -f "${TARGET_ENV}" ]]; then
    add_result "pgadmin in env" "warn" "app.env missing"
    return
  fi
  local enabled
  enabled=$(grep "^APP_PGADMIN_ENABLED=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]' || true)
  if [[ -z "${enabled}" ]]; then
    enabled=$(grep "^APP_PGADMIN_ENABLED=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]' || true)
  fi
  if [[ "${enabled}" == "true" ]]; then
    add_result "pgadmin in env" "ok"
  else
    add_result "pgadmin in env" "ok" "disabled"
  fi
}

diagnose_all() {
  reset_state
  local pkg
  for pkg in ${APP_PREREQ_APT_PACKAGES:-}; do
    check_apt_pkg_row "${pkg}"
  done
  for pkg in ${APP_PREREQ_COCKPIT_PACKAGES:-}; do
    if [[ "${pkg}" == "cockpit" ]]; then
      check_cockpit_with_socket
    else
      check_apt_pkg_row "${pkg}"
    fi
  done
  check_cockpit_files
  check_rootless_ports
  check_linger
  check_journald_limits
  check_ufw_manifest
  check_sshd_jail
  check_podman_socket
  check_cockpit_app_admin
  check_pgadmin_env
}

# --- Phase 2: Report ---

print_report() {
  echo ""
  log "=== prerequisites status ==="
  echo ""
  printf "  %-26s %-8s %s\n" "component" "status" "version"
  printf "  %-26s %-8s %s\n" "-------------------------" "------" "----------"
  local i
  for i in "${!COMP_NAMES[@]}"; do
    local name="${COMP_NAMES[$i]}"
    local status="${COMP_STATUS[$i]}"
    local version="${COMP_VERSION[$i]}"
    local status_label
    case "${status}" in
      ok)   status_label="${GREEN}ok${NC}" ;;
      fail) status_label="${RED}FAIL${NC}" ;;
      warn) status_label="${YELLOW}WARN${NC}" ;;
      *)    status_label="${status}" ;;
    esac
    printf "  %-26s ${status_label}%-$((8 - ${#status}))s %s\n" "${name}" "" "${version}"
  done
  echo ""
  local issues
  issues=$(count_issues)
  if [[ "${issues}" -eq 0 ]]; then
    printf "  ${GREEN}all prerequisites ok${NC}\n"
  elif [[ "${issues}" -eq 1 ]]; then
    printf "  ${YELLOW}${issues} issue found${NC}\n"
  else
    printf "  ${YELLOW}${issues} issues found${NC}\n"
  fi
  echo ""
}

# --- Phase 3: Repair ---

run_one_repair() {
  local rf="$1"
  case "${rf}" in
    apt:*)
      local p="${rf#apt:}"
      log "installing ${p}..."
      sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y "${p}"
      ;;
    repair_cockpit_stack)
      log "installing cockpit packages: ${APP_PREREQ_COCKPIT_PACKAGES:-}..."
      sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y ${APP_PREREQ_COCKPIT_PACKAGES:-}
      sudo systemctl enable --now cockpit.socket
      ;;
    repair_cockpit_socket)
      log "enabling cockpit socket..."
      sudo systemctl enable --now cockpit.socket
      ;;
    repair_rootless_ports)
      log "configuring rootless ports (unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-})..."
      sudo rm -f /etc/sysctl.d/99-evi-rootless.conf 2>/dev/null || true
      echo "net.ipv4.ip_unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" | sudo tee /etc/sysctl.d/99-app-rootless.conf
      sudo sysctl -p /etc/sysctl.d/99-app-rootless.conf || true
      ;;
    repair_ufw_manifest)
      log "enabling ufw and opening ports from manifest: ${APP_PREREQ_UFW_PORTS:-}..."
      bash "${DEPLOYMENT_DIR}/scripts/host/ufw-ensure-active.sh" || true
      local port
      for port in ${APP_PREREQ_UFW_PORTS:-}; do
        sudo ufw allow "${port}"
      done
      ;;
    *)
      if declare -F "${rf}" >/dev/null 2>&1; then
        "${rf}"
      else
        err "unknown repair: ${rf}"
      fi
      ;;
  esac
}

repair_linger() {
  log "enabling systemd linger for $(whoami)..."
  sudo loginctl enable-linger "$(whoami)"
}

repair_podman_socket() {
  log "enabling podman user socket..."
  systemctl --user enable --now podman.socket
}

repair_cockpit_app_admin() {
  local src_dir="${DEPLOYMENT_DIR}/cockpit-app-admin"
  if [[ -d "${src_dir}" ]] && [[ -f "${src_dir}/manifest.json" ]]; then
    log "updating app-admin panel in cockpit..."
    bash "${DEPLOYMENT_DIR}/scripts/host/cockpit-panel-sync.sh" "${DEPLOYMENT_DIR}" --sync-only --sudo-mode=interactive
    rm -f "${CONFIG_DIR}/updates/deploy-kit-ready" 2>/dev/null || true
    info "app-admin panel updated."
  else
    err "cockpit-app-admin package not found in deploy kit. cannot repair."
  fi
}

run_repairs() {
  local repaired=0
  local i
  for i in "${!COMP_NAMES[@]}"; do
    local status="${COMP_STATUS[$i]}"
    local repair_fn="${COMP_REPAIR_FN[$i]}"
    if [[ "${status}" == "fail" || "${status}" == "warn" ]] && [[ -n "${repair_fn}" ]]; then
      run_one_repair "${repair_fn}"
      repaired=$((repaired + 1))
    fi
  done
  echo ""
  if [[ "${repaired}" -gt 0 ]]; then
    info "repair completed. verifying..."
  fi
  return 0
}

# --- Main flow ---

main() {
  echo ""
  log "checking prerequisites..."

  diagnose_all
  print_report

  local issues
  issues=$(count_issues)

  if [[ "${issues}" -eq 0 ]]; then
    info "all prerequisites are installed and functional."
    echo ""
    read -r -p "press enter to continue..."
    return 0
  fi

  echo "  r) repair broken prerequisites (requires sudo)"
  echo "  0) back to main menu"
  echo ""
  local choice
  read -r -p "select [r/0]: " choice
  case "${choice}" in
    r|R)
      echo ""
      if ! confirm "proceed with repair?"; then
        return 0
      fi
      echo ""
      run_repairs

      echo ""
      diagnose_all
      print_report

      local remaining
      remaining=$(count_issues)
      if [[ "${remaining}" -eq 0 ]]; then
        info "all prerequisites are now ok."
      else
        warn "${remaining} issue(s) remain. some may need manual attention."
      fi
      echo ""
      read -r -p "press enter to continue..."
      ;;
    *)
      return 0
      ;;
  esac
}

main

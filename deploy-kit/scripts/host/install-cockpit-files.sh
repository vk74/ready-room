#!/usr/bin/env bash
#
# Version: 0.26.2
# Purpose: Best-effort install or remove of the official Cockpit File browser
#   (Debian/Ubuntu package cockpit-files). Never aborts Deploy or uninstall.
#   Picks apt, a dedicated backports/universe drop-in, or a pinned Architecture: all
#   .deb (dpkg -i). Does not unpack the GitHub source tarball as a module.
#   Writes ${DEPLOY_DIR}/config/cockpit-files.origin so uninstall can reverse
#   the same method. File: install-cockpit-files.sh
#
# Usage: install-cockpit-files.sh <deploy-dir>
#          [--sudo-mode=nopasswd|password|interactive]
#          [--remove] [--rewrite-origin]
#   Flags may appear before or after <deploy-dir>.
#   nopasswd (default): sudo -n — apply-update / sync.
#   interactive: sudo with a prompt — Deploy, restore, repair, uninstall.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Origin file records APP_COCKPIT_FILES_VERSION.
# 
# Changes in v0.23.8:
# - Initial helper: OS-aware apt / backports / pinned .deb install, origin file,
#   and symmetric --remove (apt, apt_backports, deb, tarball leftover, none).
# - --sudo-mode=interactive (plain sudo) for Deploy / restore / repair / uninstall;
#   nopasswd stays the default for apply-update sync.
# - install_via_apt uses apt-get -t BACKPORTS_SUITE when set so cockpit-files can
#   pull cockpit-bridge from backports (Pin-Priority 100).
#

set -euo pipefail

SUDO_MODE="nopasswd"
REMOVE=0
REWRITE_ORIGIN=0
DEPLOY_DIR=""

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() { printf "${CYAN}[cockpit-files]${NC} %s\n" "$*"; }
info() { printf "${GREEN}info:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*" >&2; }

usage() {
  err "usage: install-cockpit-files.sh <deploy-dir> [--sudo-mode=nopasswd|password|interactive] [--remove] [--rewrite-origin]"
}

# --- sudo wrapper: same pattern as sync-host-prerequisites.sh ---
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
      --rewrite-origin) REWRITE_ORIGIN=1 ;;
      --help|-h)
        usage
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
  return 0
}

# Pins from prerequisites.conf; missing files-vars keep manifest defaults.
PKG="cockpit-files"
RELEASE="44"
DEB_URL="http://ftp.debian.org/debian/pool/main/c/cockpit-files/cockpit-files_44-1_all.deb"

load_pins() {
  local conf="${DEPLOY_DIR}/prerequisites.conf"
  if [[ -f "${conf}" ]]; then
    # shellcheck disable=SC1090
    source "${conf}" || true
    PKG="${APP_PREREQ_COCKPIT_FILES_PACKAGE:-${PKG}}"
    RELEASE="${APP_PREREQ_COCKPIT_FILES_RELEASE:-${RELEASE}}"
    DEB_URL="${APP_PREREQ_COCKPIT_FILES_DEB_URL:-${DEB_URL}}"
  fi
}

ORIGIN_FILE=""
METHOD=""
STRATEGY="fallback"
BACKPORTS_SUITE=""
OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_UBUNTU_CODENAME=""

load_os_release() {
  OS_ID=""
  OS_ID_LIKE=""
  OS_VERSION_ID=""
  OS_VERSION_CODENAME=""
  OS_UBUNTU_CODENAME=""
  if [[ ! -r /etc/os-release ]]; then
    return 0
  fi
  # shellcheck disable=SC1091
  OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  OS_ID_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
  OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  OS_VERSION_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  OS_UBUNTU_CODENAME="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-}")"
}

is_ubuntu_like() {
  case "${OS_ID}" in
    ubuntu|linuxmint|pop|neon) return 0 ;;
  esac
  case " ${OS_ID_LIKE} " in
    *" ubuntu "*) return 0 ;;
  esac
  return 1
}

ubuntu_codename() {
  if [[ -n "${OS_UBUNTU_CODENAME}" ]]; then
    printf '%s' "${OS_UBUNTU_CODENAME}"
    return 0
  fi
  printf '%s' "${OS_VERSION_CODENAME}"
}

version_major() {
  local v="${1:-}"
  printf '%s' "${v%%.*}"
}

# Mint/Pop/Neon: classify by UBUNTU_CODENAME (noble → Ubuntu 24), not Mint 22.
detect_strategy() {
  STRATEGY="fallback"
  BACKPORTS_SUITE=""
  load_os_release

  local major
  major="$(version_major "${OS_VERSION_ID}")"
  local dcode="${OS_VERSION_CODENAME}"
  local ucode
  ucode="$(ubuntu_codename)"

  if [[ "${OS_ID}" == "debian" ]]; then
    if [[ "${dcode}" == "forky" || "${dcode}" == "sid" ]]; then
      STRATEGY="apt_direct"
      return 0
    fi
    if [[ -n "${major}" && "${major}" =~ ^[0-9]+$ && "${major}" -ge 14 ]]; then
      STRATEGY="apt_direct"
      return 0
    fi
    if [[ "${dcode}" == "trixie" || "${major}" == "13" ]]; then
      STRATEGY="debian_backports"
      BACKPORTS_SUITE="trixie-backports"
      return 0
    fi
    STRATEGY="fallback"
    return 0
  fi

  if is_ubuntu_like; then
    if [[ "${ucode}" == "jammy" || "${ucode}" == "noble" ]]; then
      STRATEGY="ubuntu_lts_backports"
      BACKPORTS_SUITE="${ucode}-backports"
      return 0
    fi
    if [[ -n "${major}" && "${major}" =~ ^[0-9]+$ && "${major}" -ge 26 ]]; then
      STRATEGY="apt_direct"
      return 0
    fi
    if [[ -n "${ucode}" ]]; then
      STRATEGY="apt_direct"
      return 0
    fi
  fi

  STRATEGY="fallback"
}

module_present() {
  if dpkg -s "${PKG}" >/dev/null 2>&1; then
    return 0
  fi
  [[ -f /usr/share/cockpit/files/manifest.json || -f /usr/local/share/cockpit/files/manifest.json ]]
}

has_apt_candidate() {
  local cand
  cand="$(apt-cache policy "${PKG}" 2>/dev/null | awk '/Candidate:/ { print $2; exit }' || true)"
  [[ -n "${cand}" && "${cand}" != "(none)" ]]
}

sources_have() {
  local needle="$1"
  grep -Rqs --include='*.list' --include='*.sources' -- "${needle}" \
    /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || return 1
  return 0
}

# Write a file as root without consuming do_sudo stdin (password mode).
install_root_file() {
  local dest="$1"
  local content="$2"
  local tmp
  tmp="$(mktemp)" || return 1
  printf '%s\n' "${content}" > "${tmp}"
  if ! do_sudo cp "${tmp}" "${dest}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  do_sudo chmod 644 "${dest}" || true
  return 0
}

DROPIN="/etc/apt/sources.list.d/app-cockpit-files.list"

remove_dropin() {
  do_sudo rm -f /etc/apt/sources.list.d/app-cockpit-files.list \
    /etc/apt/sources.list.d/evi-cockpit-files.list 2>/dev/null || true
}


apt_noninteractive() {
  do_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get "$@"
}

install_via_apt() {
  # Backports Pin-Priority is 100; without -t apt keeps the installed cockpit-bridge.
  if [[ -n "${BACKPORTS_SUITE}" ]]; then
    log "installing ${PKG} via apt (-t ${BACKPORTS_SUITE})..."
    apt_noninteractive install -y -t "${BACKPORTS_SUITE}" "${PKG}"
  else
    log "installing ${PKG} via apt..."
    apt_noninteractive install -y "${PKG}"
  fi
}

remove_apt() {
  log "removing ${PKG} via apt..."
  apt_noninteractive remove -y --no-autoremove -o APT::Get::Upgrade=false "${PKG}" || true
}

install_via_deb() {
  local tmp deb
  tmp="$(mktemp -d)" || return 1
  deb="${tmp}/cockpit-files.deb"
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is not available; cannot download pinned ${PKG} .deb"
    rm -rf "${tmp}"
    return 1
  fi
  log "downloading pinned ${PKG} .deb..."
  if ! curl -fsSL -o "${deb}" "${DEB_URL}"; then
    warn "failed to download ${DEB_URL}"
    rm -rf "${tmp}"
    return 1
  fi
  if ! do_sudo dpkg -i "${deb}"; then
    warn "dpkg -i of pinned ${PKG} failed"
    rm -rf "${tmp}"
    return 1
  fi
  rm -rf "${tmp}"
  return 0
}

remove_deb() {
  log "removing ${PKG} via dpkg..."
  do_sudo dpkg -r "${PKG}" || true
}

remove_tarball() {
  log "removing leftover /usr/local/share/cockpit/files..."
  do_sudo rm -rf /usr/local/share/cockpit/files || true
}

remove_none() {
  :
}

bridge_ge_318() {
  local ver
  ver="$(dpkg-query -W -f='${Version}' cockpit-bridge 2>/dev/null || true)"
  if [[ -z "${ver}" ]]; then
    return 1
  fi
  dpkg --compare-versions "${ver}" ge 318
}

write_origin() {
  local dest_dir
  dest_dir="$(dirname "${ORIGIN_FILE}")"
  if ! mkdir -p "${dest_dir}"; then
    warn "could not create ${dest_dir}; origin not written"
    return 0
  fi
  if ! printf 'APP_COCKPIT_FILES_METHOD=%s\nAPP_COCKPIT_FILES_VERSION=%s\n' \
    "${METHOD}" "${RELEASE}" > "${ORIGIN_FILE}"; then
    warn "could not write ${ORIGIN_FILE}"
    return 0
  fi
  chmod 644 "${ORIGIN_FILE}" || true
  log "wrote origin ${ORIGIN_FILE} (METHOD=${METHOD} VERSION=${RELEASE})"
}

enable_ubuntu_universe() {
  local ucode
  ucode="$(ubuntu_codename)"
  if [[ -z "${ucode}" ]]; then
    return 1
  fi
  if [[ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
    warn "ubuntu-archive-keyring.gpg missing; not adding universe drop-in"
    return 1
  fi
  local line
  line="deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu ${ucode} universe"
  log "adding universe drop-in ${DROPIN}"
  install_root_file "${DROPIN}" "${line}"
}

enable_ubuntu_backports() {
  local ucode
  ucode="$(ubuntu_codename)"
  if [[ -z "${ucode}" ]]; then
    return 1
  fi
  if [[ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
    warn "ubuntu-archive-keyring.gpg missing; not adding backports drop-in"
    return 1
  fi
  local line
  line="deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu ${ucode}-backports main universe"
  log "adding Ubuntu backports drop-in ${DROPIN}"
  install_root_file "${DROPIN}" "${line}"
}

enable_debian_backports() {
  if [[ ! -f /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
    warn "debian-archive-keyring.gpg missing; not adding backports drop-in"
    return 1
  fi
  local line
  line="deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian trixie-backports main"
  log "adding Debian backports drop-in ${DROPIN}"
  install_root_file "${DROPIN}" "${line}"
}

# Step 6: enable a dedicated drop-in only when there is still no candidate.
# Never mutates the main ubuntu.sources. Never enables bookworm-backports.
try_enable_sources_and_install() {
  local created=0

  case "${STRATEGY}" in
    apt_direct)
      if is_ubuntu_like; then
        if ! sources_have "universe"; then
          if enable_ubuntu_universe; then
            apt_noninteractive update || true
          fi
        fi
        if has_apt_candidate && install_via_apt; then
          METHOD="apt"
          return 0
        fi
      fi
      ;;
    ubuntu_lts_backports)
      if sources_have "${BACKPORTS_SUITE}"; then
        created=0
        apt_noninteractive update || true
      else
        if enable_ubuntu_backports; then
          created=1
          apt_noninteractive update || true
        fi
      fi
      if has_apt_candidate && install_via_apt; then
        if [[ "${created}" -eq 1 ]]; then
          METHOD="apt_backports"
        else
          METHOD="apt"
        fi
        return 0
      fi
      ;;
    debian_backports)
      if sources_have "${BACKPORTS_SUITE}"; then
        created=0
        apt_noninteractive update || true
      else
        if enable_debian_backports; then
          created=1
          apt_noninteractive update || true
        fi
      fi
      if has_apt_candidate && install_via_apt; then
        if [[ "${created}" -eq 1 ]]; then
          METHOD="apt_backports"
        else
          METHOD="apt"
        fi
        return 0
      fi
      ;;
    fallback)
      ;;
  esac
  return 0
}

try_deb_or_none() {
  if bridge_ge_318; then
    if install_via_deb; then
      METHOD="deb"
      return 0
    fi
    METHOD="none"
    warn "Cockpit File browser was not installed (pinned .deb failed)."
    return 0
  fi
  METHOD="none"
  warn "Cockpit File browser needs cockpit-bridge >= 318; skipping."
}

run_install() {
  do_sudo rm -f /etc/apt/sources.list.d/evi-cockpit-files.list 2>/dev/null || true
  load_pins
  ORIGIN_FILE="${DEPLOY_DIR}/config/cockpit-files.origin"

  if module_present && [[ -f "${ORIGIN_FILE}" ]] && [[ "${REWRITE_ORIGIN}" -eq 0 ]]; then
    info "cockpit-files already present; keeping existing origin"
    return 0
  fi

  detect_strategy
  log "strategy=${STRATEGY} (id=${OS_ID:-unknown} ubuntu_codename=$(ubuntu_codename))"
  METHOD=""

  if has_apt_candidate; then
    if install_via_apt; then
      METHOD="apt"
    else
      warn "apt-get install ${PKG} failed; trying fallbacks"
    fi
  fi

  if [[ -z "${METHOD}" ]]; then
    try_enable_sources_and_install
  fi

  if [[ -z "${METHOD}" ]]; then
    try_deb_or_none
  fi

  if [[ -z "${METHOD}" ]]; then
    METHOD="none"
    warn "Cockpit File browser was not installed."
  fi

  write_origin
}

run_remove() {
  remove_dropin
  load_pins
  ORIGIN_FILE="${DEPLOY_DIR}/config/cockpit-files.origin"

  if [[ -f "${ORIGIN_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ORIGIN_FILE}" || true
    local method="${APP_COCKPIT_FILES_METHOD:-}"
    case "${method}" in
      apt|apt_backports)
        remove_apt
        ;;
      deb)
        remove_deb
        ;;
      tarball)
        remove_tarball
        ;;
      none)
        remove_none
        ;;
      *)
        warn "unknown APP_COCKPIT_FILES_METHOD=${method}; skipping origin-based remove"
        ;;
    esac
    return 0
  fi

  # Origin missing: upgrade-from-old-evi safety — remove package and tarball leftover.
  if dpkg -s "${PKG}" >/dev/null 2>&1 || [[ -e /usr/local/share/cockpit/files ]]; then
    remove_apt
    remove_deb
    remove_tarball
  fi
}

main() {
  if ! parse_args "$@"; then
    return 0
  fi

  if [[ "${REMOVE}" -eq 1 ]]; then
    run_remove || warn "cockpit-files remove encountered an error; continuing"
    return 0
  fi

  run_install || warn "cockpit-files install encountered an error; continuing"
  return 0
}

main "$@" || warn "cockpit-files helper exiting after an unexpected error"
exit 0

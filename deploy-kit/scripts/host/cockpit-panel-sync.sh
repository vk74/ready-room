#!/usr/bin/env bash
# Version: 0.26.3
# Purpose: Idempotently install the Cockpit app-admin panel into
#   /usr/local/share/cockpit/app-admin. Copies manifest, HTML, JS, and CSS
#   from the package, renders each *.sh.tpl with {{DEPLOYMENT_DIR}} set to
#   APP_HOME, and removes legacy panel directories evi-admin, evi-pgadmin,
#   and evi-update. Does not read or write sudo.pass, deploy-kit-ready,
#   cockpit-install-result.json, or sync-host-prerequisites.sh.
# Usage: cockpit-panel-sync.sh <APP_HOME> [--source-dir <dir>]
#   [--sudo-mode=nopasswd|password|interactive] [--sync-only]
#   --sync-only is accepted and ignored. Default sudo mode is nopasswd.
#   password mode reads SUDO_PASSWORD from the environment.
#   When --source-dir is omitted, the package is ${APP_HOME}/cockpit-app-admin.
# File: cockpit-panel-sync.sh
#
# Changes in v0.26.3:
# - Initial script: one panel copy, dispatch-template render, and legacy cleanup.

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

SYM_OK="${GREEN}[✓]${NC}"
SYM_FAIL="${RED}[✗]${NC}"
SYM_WARN="${YELLOW}[!]${NC}"

log_tee() { printf "${CYAN}[app]${NC} %s\n" "$*"; }

usage() {
  printf 'usage: cockpit-panel-sync.sh <APP_HOME> [--source-dir <dir>] [--sudo-mode=nopasswd|password|interactive] [--sync-only]\n' >&2
}

# password: SUDO_PASSWORD env var. nopasswd: sudo -n. interactive: sudo.
do_sudo() {
  case "${SUDO_MODE}" in
    password)
      echo "${SUDO_PASSWORD}" | sudo -S "$@" 2>/dev/null
      ;;
    nopasswd)
      sudo -n "$@"
      ;;
    interactive)
      sudo "$@"
      ;;
    *)
      log_tee " ${SYM_FAIL} invalid sudo mode: ${SUDO_MODE:-}"
      return 1
      ;;
  esac
}

# Returns 0 when the panel is installed or cockpit itself is absent.
# Returns 1 when APP_HOME is unsafe or the app-admin package is missing.
sync_panels() {
  if [[ -z "${APP_HOME}" || "${APP_HOME}" == "/" || "${APP_HOME}" == "${HOME}" ]]; then
    log_tee " ${SYM_FAIL} safety check failed: APP_HOME must not be empty, / or \$HOME"
    return 1
  fi

  if ! command -v cockpit-bridge >/dev/null 2>&1; then
    log_tee " ${SYM_WARN} cockpit not installed, skipping panel install"
    return 0
  fi

  local src_dir="${SOURCE_DIR}"
  if [[ ! -d "${src_dir}" || ! -f "${src_dir}/manifest.json" ]]; then
    log_tee " ${SYM_FAIL} cockpit-app-admin package not found"
    return 1
  fi

  if [[ "${SUDO_MODE}" == "password" && -z "${SUDO_PASSWORD:-}" ]]; then
    log_tee " ${SYM_FAIL} SUDO_PASSWORD is required for --sudo-mode=password"
    return 1
  fi

  local dst_dir="/usr/local/share/cockpit/app-admin"
  local ext f tpl dispatch_name tmp_rendered legacy_panel

  do_sudo mkdir -p "${dst_dir}" || return 1
  do_sudo cp -f "${src_dir}/manifest.json" "${src_dir}/index.html" "${dst_dir}/" || return 1

  for ext in js css; do
    for f in "${src_dir}/"*."${ext}"; do
      if [[ -f "${f}" ]]; then
        do_sudo cp -f "${f}" "${dst_dir}/" || return 1
      fi
    done
  done

  for tpl in "${src_dir}/"*.sh.tpl; do
    if [[ -f "${tpl}" ]]; then
      dispatch_name=$(basename "${tpl}" .tpl)
      tmp_rendered=$(mktemp) || return 1
      # Live deployment path, even when the package itself comes from --source-dir.
      sed "s|{{DEPLOYMENT_DIR}}|${APP_HOME}|g" "${tpl}" > "${tmp_rendered}" || {
        rm -f "${tmp_rendered}"
        return 1
      }
      do_sudo cp -f "${tmp_rendered}" "${dst_dir}/${dispatch_name}" || {
        rm -f "${tmp_rendered}"
        return 1
      }
      rm -f "${tmp_rendered}"
      do_sudo chmod 755 "${dst_dir}/${dispatch_name}" || return 1
      log_tee "   rendered dispatch: ${dispatch_name}"
    fi
  done

  for legacy_panel in evi-admin evi-pgadmin evi-update; do
    if [[ -d "/usr/local/share/cockpit/${legacy_panel}" ]]; then
      do_sudo rm -rf "/usr/local/share/cockpit/${legacy_panel}" || return 1
      log_tee " ${SYM_OK} removed legacy ${legacy_panel} panel"
    fi
  done

  log_tee " ${SYM_OK} cockpit-app-admin installed to ${dst_dir}"
  return 0
}

SUDO_MODE="nopasswd"
SOURCE_DIR=""
APP_HOME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sync-only)
      shift
      ;;
    --sudo-mode=*)
      SUDO_MODE="${1#--sudo-mode=}"
      shift
      ;;
    --source-dir)
      if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then
        usage
        exit 1
      fi
      SOURCE_DIR="$2"
      shift 2
      ;;
    --source-dir=*)
      SOURCE_DIR="${1#--source-dir=}"
      if [[ -z "${SOURCE_DIR}" ]]; then
        usage
        exit 1
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 1
      ;;
    *)
      if [[ -n "${APP_HOME}" ]]; then
        usage
        exit 1
      fi
      APP_HOME="$1"
      shift
      ;;
  esac
done

if [[ -z "${APP_HOME}" ]]; then
  usage
  exit 1
fi

case "${SUDO_MODE}" in
  nopasswd|password|interactive) ;;
  *)
    log_tee " ${SYM_FAIL} invalid sudo mode: ${SUDO_MODE}"
    usage
    exit 1
    ;;
esac

if [[ -z "${SOURCE_DIR}" ]]; then
  SOURCE_DIR="${APP_HOME}/cockpit-app-admin"
fi

sync_panels || exit $?
exit 0

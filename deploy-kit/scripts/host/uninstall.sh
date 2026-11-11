#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Full uninstall of application: containers, volumes, secrets, images, state, config, quadlets, cockpit panels, UFW rules, sysctl, apt packages.
# File: uninstall.sh
# Backend script, called from install.sh (option 5) or evi-reconfigure.sh. Can be run standalone.
# Logic: Single confirmation (type 'yes'), stop services, remove podman resources, remove dirs (config/ with sudo for pgadmin data), quadlets, systemd reload,
#        then sudo block: cockpit panels, UFW rules by number for ports 80/443/9090/5445, sysctl, apt remove. Prints instruction to run rm -rf ~/evi.
#
# Changes in v0.26.3:
# - DEPLOYMENT_DIR is the kit root, two levels above this script (scripts/host/).
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Uninstall reads secret names from config/app.env.
# 
# Changes in v0.25.4:
# - Secret and bind-path cleanup reads config/app.env, falling back to legacy config/evi.env.
#
# Changes in v0.23.10:
# - Call install-fail2ban.sh --sudo-mode=interactive --remove before deleting
#   config/. apt-get remove also drops fail2ban (not python3-systemd).
#
# Changes in v0.23.9:
# - File renamed from uninstall-evi.sh to uninstall.sh.
#
# Changes in v0.23.8:
# - Call install-cockpit-files.sh --sudo-mode=interactive --remove before deleting
#   config/ so cockpit-files.origin is still readable. Also apt-get remove
#   cockpit-files as belt-and-suspenders.
#
# Changes in v1.9.3:
# - Do not apt-get remove curl/openssl/ca-certificates. Those are system packages; removing
#   them on Ubuntu pulls ubuntu-desktop, firefox, snapd, xorg. Do not run apt-get autoremove.
#   Only remove evi-owned packages: cockpit cockpit-podman podman (and cockpit-ws if present).
#
# Changes in v1.9.2:
# - Added cleanup of external bind directories for DB/FS volumes based on config/evi.env:
#   EVI_DATA_PATH/db and EVI_FS_DATA_PATH/fs (with EVI_FS_DATA_PATH fallback to EVI_DATA_PATH).
# - Bind-path cleanup is path-safe and skips default-volume installs (empty paths).
#
# Changes in v1.9.1:
#
# Changes in v1.9.0:
# - Renamed volume assets_data -> fs_data in volume removal list.
#   Renamed EVI_FS_SECRET_NAME -> EVI_FS_SECRET_NAME; local var assets_name -> fs_name.
#
# Changes in v1.8.0:
# - Podman secret removal is config-driven: source config/evi.env (if present) and remove
#   secrets named by EVI_JWT_SECRET_NAME / EVI_FS_SECRET_NAME / EVI_VALKEY_SECRET_NAME
#   (with hardcoded names as fallback). Previously the names were hardcoded, so a custom
#   *_SECRET_NAME would leak its secret on uninstall.
#
# Changes in v1.7.0:
# - Added valkey_password to secrets removal list.
#   Updated quadlet cleanup glob: also removes network quadlet file (both evi.network and network).
#
# Changes in v1.6.0:
# - Removed evi- prefix: disk-monitor unit names (was evi-disk-monitor.*).
#   Updated secret names: jwt_private_key (was evi_jwt_private_key), fs_credentials (was evi_fs_credentials).
#   Updated volume filter from grep "^evi" to explicit list of known volume names (db_data, assets_data, caddy_data, caddy_config).
#
# Changes in v1.5.0:
# - Updated all container name references to short forms without evi- prefix.
#
# Changes in v1.4.0:
# - Stop and remove evi-disk-monitor systemd user timer and service.
#
# Changes in v1.3.0:
# - evi-update Cockpit panel paths kept in removal loop as legacy cleanup (standalone panel was
#   removed in this release; paths may still exist on servers upgraded from older versions).
#
# Changes in v1.2.0:
# - evi-pgadmin Cockpit panel paths kept in removal loop as legacy cleanup (standalone panel was
#   removed in this release; paths may still exist on servers upgraded from older versions).
#
# Changes in v1.1.0:
# - Volume filter changed from grep "^evi-" to grep "^evi" so underscore-named volumes (evi_fs_data, evi_db_data) are also removed.
# - Image filter extended with "seaweedfs" so the evi-fs SeaweedFS image (chrislusf/seaweedfs) is removed on uninstall.
#
# Changes in v1.0.7:
# - Added evi-fs to stop and container removal list; added evi_fs_credentials to secrets removal.
#
# Changes in v1.0.6:
# - Added evi-update cockpit panel paths to removal loop (/usr/local/share/cockpit/evi-update, /usr/share/cockpit/evi-update).
#
# Changes in v1.0.5:
# - Switched to CONFIG_DIR layout: remove ~/evi/config (contains state, tls, env files, backup, updates)
#   instead of separate ~/.local/share/evi and ~/.config/evi.
# - CONFIG_DIR computed from script location (DEPLOYMENT_DIR/config).
#
# Changes in v1.0.4:
# - Final hint shows two commands (cd ~ and rm -rf ~/evi) so user can paste both when shell stays in evi dir.
#
# Changes in v1.0.3:
# - On success: no "press enter to exit"; exit with code 2 so install.sh can cd to HOME and exit (user lands in ~ to paste rm -rf ~/evi). On cancel still exit 0.
#
# Changes in v1.0.2:
# - Colors/symbols: use ANSI-C quoting ($'...') so green checkmarks and colors render in terminal instead of literal \033.
# - apt-get remove: add -o APT::Get::Upgrade=false so uninstall does not upgrade other packages.
# - After apt-get remove, run apt-get autoremove -y to remove unused dependencies without requiring user to do it.
#
# Changes in v1.0.1:
# - Single confirmation only (removed second "type 'yes' again" prompt).
#
# Changes in v1.0.0:
# - Initial version: extracted from install.sh; state dir removed with sudo to fix pgadmin data permission denied; UFW rules removed by numbered delete; cockpit removal without suppressing errors.
#

set -euo pipefail

# Paths (same defaults as install.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
APP_QUADLET_DIR_DEFAULT="${HOME}/.config/containers/systemd"

# Colors and symbols (ANSI-C quoting so escapes render in terminal)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'
BOLD=$'\033[1m'
SYM_OK="${GREEN}[✓]${NC}"
SYM_WARN="${YELLOW}[!]${NC}"
SYM_PENDING="${GRAY}[○]${NC}"

log() { printf "${CYAN}[app]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*"; }

# Remove UFW rules that mention evi ports (80, 443, 9090, 5445). Deletes by rule number in reverse order.
remove_ufw_app_rules() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    return 0
  fi
  local nums
  nums=$(sudo ufw status numbered 2>/dev/null | grep -E '(80|443|9090|5445)/' | sed -n 's/.*\[ *\([0-9]*\)\].*/\1/p' | sort -rn | tr '\n' ' ')
  if [[ -z "${nums}" ]]; then
    return 0
  fi
  for n in ${nums}; do
    sudo ufw --force delete "${n}" 2>/dev/null || true
  done
}

remove_bind_volume_dir() {
  local base_path="$1"
  local leaf="$2"
  local label="$3"
  [[ -z "${base_path}" ]] && return 0

  case "${leaf}" in
    db|fs) ;;
    *) return 0 ;;
  esac

  local target="${base_path%/}/${leaf}"
  if [[ "${target}" == "/db" ]] || [[ "${target}" == "/fs" ]]; then
    warn "skipping unsafe bind directory removal for ${label}: ${target}"
    return 0
  fi

  if [[ -d "${target}" ]] || [[ -e "${target}" ]]; then
    if sudo rm -rf -- "${target}" 2>/dev/null; then
      printf "  %s removed bind directory %s (%s)\n" "${SYM_OK}" "${target}" "${label}"
    else
      warn "could not remove bind directory ${target} (${label})"
    fi
  else
    printf "  %s bind directory %s (%s) not found\n" "${SYM_PENDING}" "${target}" "${label}"
  fi
}

main() {
  echo ""
  log "=== uninstall application ==="
  echo ""
  printf "${RED}${BOLD}WARNING: this will permanently remove application and all its data. This cannot be undone.${NC}\n"
  echo ""
  echo "the following will be removed:"
  echo "  - all application containers and data volumes"
  echo "  - external bind directories for DB/FS volumes (if configured)"
  echo "  - application state and config under your home directory"
  echo "  - cockpit panels and application packages (podman, cockpit). curl/openssl stay."
  echo ""
  read -r -p "type 'yes' (full word) to confirm uninstall: " confirm1
  if [[ "${confirm1}" != "yes" ]]; then
    log "uninstall cancelled."
    read -r -p "press enter to continue..."
    exit 0
  fi

  echo ""
  log "stopping application services..."
  systemctl --user stop reverse-proxy fe be worker fs state db pgadmin 2>/dev/null || true
  printf "  %s services stopped\n" "${SYM_OK}"

  log "removing disk monitor timer..."
  systemctl --user disable --now disk-monitor.timer 2>/dev/null || true
  systemctl --user stop disk-monitor.service 2>/dev/null || true
  rm -f "${HOME}/.config/systemd/user/disk-monitor.timer" "${HOME}/.config/systemd/user/disk-monitor.service" 2>/dev/null || true
  printf "  %s disk monitor removed\n" "${SYM_OK}"

  log "removing containers..."
  for c in db state fs be fe reverse-proxy worker pgadmin; do
    if podman rm -f "${c}" 2>/dev/null; then
      printf "  %s removed container %s\n" "${SYM_OK}" "${c}"
    else
      printf "  %s container %s (not found or already removed)\n" "${SYM_PENDING}" "${c}"
    fi
  done

  log "removing podman volumes..."
  local vol
  for vol in db_data fs_data caddy_data caddy_config; do
    if podman volume rm "${vol}" 2>/dev/null; then
      printf "  %s removed volume %s\n" "${SYM_OK}" "${vol}"
    else
      printf "  %s could not remove volume %s\n" "${SYM_WARN}" "${vol}"
    fi
  done

  log "reading current env settings for secrets and bind paths..."
  # Read secret names from config/app.env so custom *_SECRET_NAME values are honoured.
  # Missing file keeps the default secret names.
  local jwt_name="jwt_private_key" fs_name="fs_credentials" valkey_name="valkey_password"
  local db_data_path="" fs_data_path=""
  local env_file=""
  if [[ -f "${CONFIG_DIR}/app.env" ]]; then env_file="${CONFIG_DIR}/app.env"; fi
  if [[ -n "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}" 2>/dev/null || true
    jwt_name="${APP_JWT_SECRET_NAME:-${jwt_name}}"
    fs_name="${APP_FS_SECRET_NAME:-${fs_name}}"
    valkey_name="${APP_VALKEY_SECRET_NAME:-${valkey_name}}"
    db_data_path="${APP_DATA_PATH:-}"
    fs_data_path="${APP_FS_DATA_PATH:-${db_data_path}}"
  fi

  log "removing podman secrets..."
  local s
  for s in "${jwt_name}" "${fs_name}" "${valkey_name}"; do
    if podman secret rm "${s}" 2>/dev/null; then
      printf "  %s removed secret %s\n" "${SYM_OK}" "${s}"
    else
      printf "  %s secret %s (not found or already removed)\n" "${SYM_PENDING}" "${s}"
    fi
  done

  log "removing external bind directories for DB/FS (if configured)..."
  remove_bind_volume_dir "${db_data_path}" "db" "db volume"
  remove_bind_volume_dir "${fs_data_path}" "fs" "fs volume"

  log "removing application container images..."
  local img
  for img in $(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "evi|pgadmin|caddy|seaweedfs" || true); do
    if podman rmi -f "${img}" 2>/dev/null; then
      printf "  %s removed image %s\n" "${SYM_OK}" "${img}"
    fi
  done

  local quadlet_dir="${APP_QUADLET_DIR_DEFAULT}"
  log "removing quadlet files..."
  if [[ -d "${quadlet_dir}" ]]; then
    rm -f "${quadlet_dir}"/evi-*.container "${quadlet_dir}"/evi-*.volume "${quadlet_dir}"/evi-*.network "${quadlet_dir}"/evi.network "${quadlet_dir}"/network 2>/dev/null || true
    printf "  %s quadlet files removed\n" "${SYM_OK}"
  fi

  if [[ -f "${SCRIPT_DIR}/install-fail2ban.sh" ]]; then
    log "removing kit sshd jail..."
    bash "${SCRIPT_DIR}/install-fail2ban.sh" "${DEPLOYMENT_DIR}" \
      --sudo-mode=interactive --remove \
      || warn "sshd jail helper remove failed; continuing"
  fi

  # Origin-aware cockpit-files removal must run while config/cockpit-files.origin still exists.
  if [[ -f "${SCRIPT_DIR}/install-cockpit-files.sh" ]]; then
    log "removing cockpit file browser..."
    if sudo -v 2>/dev/null; then
      bash "${SCRIPT_DIR}/install-cockpit-files.sh" "${DEPLOYMENT_DIR}" \
        --sudo-mode=interactive --remove \
        || warn "cockpit-files helper remove failed; apt-get remove will retry later"
    else
      warn "sudo not available; cockpit-files will be removed later if possible"
    fi
  fi

  log "removing config directory (using sudo for pgadmin data owned by container user)..."
  if [[ -d "${CONFIG_DIR}" ]]; then
    if sudo rm -rf "${CONFIG_DIR}" 2>/dev/null; then
      printf "  %s removed %s\n" "${SYM_OK}" "${CONFIG_DIR}"
    else
      warn "could not remove some files in ${CONFIG_DIR} (permission denied). try: sudo rm -rf ${CONFIG_DIR}"
    fi
  fi

  log "reloading systemd..."
  systemctl --user daemon-reload 2>/dev/null || true
  printf "  %s daemon reloaded\n" "${SYM_OK}"

  echo ""
  log "removing system packages and cockpit panels (requires sudo)..."
  if ! sudo -v 2>/dev/null; then
    warn "sudo failed; skipping cockpit removal, ufw, sysctl and package removal."
  else
    log "removing cockpit panels..."
    # evi-pgadmin and evi-update paths are legacy (standalone panels removed; functionality is
    # now embedded inside evi-admin as DB Tools and Updates sections respectively).
    for cockpit_path in /usr/local/share/cockpit/app-admin /usr/share/cockpit/app-admin /usr/local/share/cockpit/evi-pgadmin /usr/local/share/cockpit/evi-admin /usr/local/share/cockpit/evi-update /usr/share/cockpit/evi-pgadmin /usr/share/cockpit/evi-admin /usr/share/cockpit/evi-update; do
      if [[ -d "${cockpit_path}" ]] || [[ -e "${cockpit_path}" ]]; then
        if sudo rm -rf "${cockpit_path}"; then
          printf "  %s removed %s\n" "${SYM_OK}" "${cockpit_path}"
        else
          warn "failed to remove ${cockpit_path}"
        fi
      fi
    done

    if command -v ufw >/dev/null 2>&1; then
      log "removing ufw rules for application ports (80, 443, 9090, 5445)..."
      remove_ufw_app_rules
      printf "  %s ufw rules removed\n" "${SYM_OK}"
    fi

    log "removing sysctl config..."
    sudo rm -f /etc/sysctl.d/99-app-rootless.conf /etc/sysctl.d/99-evi-rootless.conf 2>/dev/null || true
    sudo sysctl --system >/dev/null 2>&1 || true
    printf "  %s sysctl config removed\n" "${SYM_OK}"

    log "removing application packages (podman, cockpit)..."
    # Never remove curl/openssl/ca-certificates: Ubuntu treats them as desktop/system deps.
    # Never autoremove: it follows the same reverse-deps and can delete ubuntu-desktop.
    sudo apt-get remove -y --no-autoremove -o APT::Get::Upgrade=false \
      cockpit cockpit-podman cockpit-ws cockpit-files podman fail2ban 2>/dev/null || true
    printf "  %s application packages removed (curl/openssl left installed)\n" "${SYM_OK}"
  fi

  echo ""
  printf "${GREEN}=== uninstall complete ===${NC}\n"
  echo ""
  printf "${YELLOW}to finish cleanup, go to home and remove the application directory:${NC}\n"
  echo ""
  printf "  ${CYAN}cd ~${NC}\n"
  printf "  ${CYAN}rm -rf ~/app${NC}\n"
  echo ""
  exit 2
}

main "$@"

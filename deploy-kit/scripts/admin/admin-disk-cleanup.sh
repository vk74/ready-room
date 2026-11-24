#!/usr/bin/env bash
#
# Version: 0.28.9
# Purpose: Free disk space by pruning unused images, clearing staged updates, or deleting one backup archive.
# File: admin-disk-cleanup.sh
# Logic: prune-images runs podman image prune. clear-updates removes staged kit
#        directories under config/updates when no update is running, and resets
#        the downloaded flag in updates.json. delete-backup removes one validated
#        archive name from config/backup and its paired app-v / app-data-v sibling.
#
# Usage: admin-disk-cleanup.sh <prune-images|clear-updates|delete-backup> [filename]
#
# Changes in v0.28.9:
# - Initial cleanup actions for the admin disk panel.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
BACKUP_DIR="${CONFIG_DIR}/backup"
UPDATES_DIR="${CONFIG_DIR}/updates"
UPDATES_JSON="${UPDATES_DIR}/updates.json"
PID_FILE="${UPDATES_DIR}/update.pid"

_runtime_dir="/run/user/$(id -u)"
if [[ -d "${_runtime_dir}" ]]; then
  export XDG_RUNTIME_DIR="${_runtime_dir}"
fi

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

log()  { printf "${CYAN}[disk-cleanup]${NC} %s\n" "$*"; }
ok()   { printf '  %s[✓]%s %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '  %s[!]%s %s\n' "${YELLOW}" "${NC}" "$*"; }
err()  { printf '%sERROR:%s %s\n' "${RED}" "${NC}" "$*" >&2; }
die()  { err "$*"; exit 1; }

action="${1:-}"
if [[ -z "${action}" ]]; then
  die "usage: admin-disk-cleanup.sh <prune-images|clear-updates|delete-backup> [filename]"
fi

prune_images() {
  if ! command -v podman >/dev/null 2>&1; then
    die "podman is required to prune images"
  fi
  log "Pruning unused container images..."
  podman image prune -a -f
  ok "Pruned unused container images."
}

clear_updates() {
  local old_pid="" child="" child_real="" parent="" updates_real="" tmp=""
  if [[ -f "${PID_FILE}" ]]; then
    old_pid=$(cat "${PID_FILE}" 2>/dev/null || true)
    if [[ "${old_pid}" =~ ^[0-9]+$ ]] && [[ "${old_pid}" -gt 0 ]] && kill -0 "${old_pid}" 2>/dev/null; then
      die "an update is already running"
    fi
  fi
  log "Clearing staged update files..."
  if [[ -d "${UPDATES_DIR}" ]]; then
    updates_real="$(realpath "${UPDATES_DIR}")"
    for child in "${UPDATES_DIR}"/*; do
      [[ -d "${child}" ]] || continue
      child_real="$(realpath "${child}")" || continue
      parent="$(dirname "${child_real}")"
      parent="$(realpath "${parent}")" || continue
      if [[ "${parent}" != "${updates_real}" || "${child_real}" == "${updates_real}" ]]; then
        continue
      fi
      log "removing ${child_real}"
      rm -rf "${child_real}"
    done
    rm -f "${UPDATES_DIR}/precheck-report.json" "${UPDATES_DIR}/ack-warnings.flag"
  fi
  if [[ -f "${UPDATES_JSON}" ]]; then
    if [[ -x /usr/bin/jq ]]; then
      tmp="$(mktemp "${UPDATES_DIR}/updates.json.XXXXXX")"
      if ! /usr/bin/jq '.downloaded = false | .downloadPath = "" | .minVersion = "" | .compatible = true' \
          "${UPDATES_JSON}" > "${tmp}"; then
        rm -f "${tmp}"
        die "could not update updates.json"
      fi
      mv "${tmp}" "${UPDATES_JSON}"
    else
      warn "jq is not available at /usr/bin/jq; updates.json downloaded flag was left unchanged"
    fi
  fi
  ok "Cleared staged update files."
}

delete_backup() {
  local filename="${1:-}" path="" rest="" sibling="" removed=""
  local name_re='^(app-v|app-data-v|evi-v|evi-data-v)[0-9A-Za-z._-]+\.(tar\.gz|tar\.zst)(\.enc)?$'
  if [[ -z "${filename}" ]]; then
    die "backup filename is required"
  fi
  if [[ "${filename}" == *"/"* || "${filename}" == *".."* ]]; then
    die "invalid backup filename"
  fi
  if [[ ! "${filename}" =~ ${name_re} ]]; then
    die "invalid backup filename"
  fi
  path="${BACKUP_DIR}/${filename}"
  if [[ ! -f "${path}" ]]; then
    die "backup archive not found: ${filename}"
  fi
  rm -f "${path}"
  removed="${filename}"
  # Current archives are paired (app-v + app-data-v). Historical names are deleted alone.
  if [[ "${filename}" == app-data-v* ]]; then
    rest="${filename#app-data-v}"
    sibling="app-v${rest}"
  elif [[ "${filename}" == app-v* ]]; then
    rest="${filename#app-v}"
    sibling="app-data-v${rest}"
  fi
  if [[ -n "${sibling}" && -f "${BACKUP_DIR}/${sibling}" ]]; then
    log "also removing paired archive ${sibling}"
    rm -f "${BACKUP_DIR}/${sibling}"
    removed="${filename} and ${sibling}"
  fi
  ok "Deleted backup archive ${removed}."
}

case "${action}" in
  prune-images)
    prune_images
    ;;
  clear-updates)
    clear_updates
    ;;
  delete-backup)
    delete_backup "${2:-}"
    ;;
  *)
    die "unknown action: ${action}. Expected prune-images, clear-updates, or delete-backup."
    ;;
esac

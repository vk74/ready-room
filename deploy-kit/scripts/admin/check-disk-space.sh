#!/usr/bin/env bash
#
# Version: 0.28.9
# Purpose: Check disk space for application data volumes and system disk; log warnings to journald
#          and write a marker file when critical threshold is reached.
# Deployment file: check-disk-space.sh
# Logic: Reads APP_DATA_PATH and APP_FS_DATA_PATH from config/app.env.
#        APP_FS_DATA_PATH=system means the file-storage volume is on the system disk.
#        An empty APP_FS_DATA_PATH follows APP_DATA_PATH.
#        Checks usage percentage via df. Thresholds: 85% = warning, 95% = critical.
#        Critical state writes a marker file for Cockpit panel to detect.
#        Always checks the system disk at /. Checks the database path and, when it
#        is a different directory, the file-storage path.
#
# Exit codes:
#   0 - All checks passed or warnings logged
#   1 - Configuration error (missing DEPLOYMENT_DIR)
#
# Changes in v0.28.9:
# - Checks the file-storage disk when APP_FS_DATA_PATH is a separate directory.
# - APP_FS_DATA_PATH=system is the system disk, not an external bind path.
# - The system disk check is always "/".
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Disk check reads APP_DATA_PATH from config/app.env.
# 
# Changes in v0.25.4:
# - Reads EVI_DATA_PATH from config/app.env, falling back to legacy config/evi.env.
#
# Changes in v1.0.2:
# - Renamed logger tag from evi-disk-monitor to disk-monitor.
#
# Changes in v1.0.1:
# - Updated all container name references to short forms without evi- prefix.
#
# Changes in v1.0.0:
# - Initial version: df-based disk checks, journald logging, marker file for Cockpit.
#

set -euo pipefail

DEPLOYMENT_DIR="${1:?usage: check-disk-space.sh <deployment-dir>}"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
TARGET_ENV="${CONFIG_DIR}/app.env"
STATE_DIR="${CONFIG_DIR}/state"
MARKER_FILE="${STATE_DIR}/.disk-space-critical"
MARKER_DATA_FILE="${STATE_DIR}/.disk-space-data-critical"
MARKER_FS_FILE="${STATE_DIR}/.disk-space-fs-critical"

WARN_THRESHOLD=85
CRIT_THRESHOLD=95

get_env_value() {
  local key="$1"
  local val
  val=$(grep "^${key}=" "${TARGET_ENV}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
  printf '%s' "${val}"
}

get_use_percent() {
  local path="$1"
  local check_path="${path}"
  while [[ ! -d "${check_path}" ]] && [[ "${check_path}" != "/" ]]; do
    check_path="$(dirname "${check_path}")"
  done
  df --output=pcent "${check_path}" 2>/dev/null | tail -1 | tr -d '[:space:]%' || echo "0"
}

get_disk_info() {
  local path="$1"
  local check_path="${path}"
  while [[ ! -d "${check_path}" ]] && [[ "${check_path}" != "/" ]]; do
    check_path="$(dirname "${check_path}")"
  done
  df -h --output=size,used,avail,pcent "${check_path}" 2>/dev/null | tail -1 || echo "? ? ? ?"
}

check_disk() {
  local label="$1" path="$2" marker="$3"
  local pct
  pct=$(get_use_percent "${path}")
  if [[ ! "${pct}" =~ ^[0-9]+$ ]]; then
    pct=0
  fi

  if [[ ${pct} -ge ${CRIT_THRESHOLD} ]]; then
    local info
    info=$(get_disk_info "${path}")
    logger -t disk-monitor -p user.crit \
      "CRITICAL: ${label} disk usage at ${pct}% (path: ${path}, ${info}). Free up space immediately."
    echo "CRITICAL" > "${marker}"
    echo "${pct}" >> "${marker}"
    echo "${path}" >> "${marker}"
    echo "$(date -Iseconds)" >> "${marker}"
  elif [[ ${pct} -ge ${WARN_THRESHOLD} ]]; then
    local info
    info=$(get_disk_info "${path}")
    logger -t disk-monitor -p user.warning \
      "WARNING: ${label} disk usage at ${pct}% (path: ${path}, ${info}). Consider freeing up space."
    rm -f "${marker}" 2>/dev/null || true
  else
    rm -f "${marker}" 2>/dev/null || true
  fi
}

main() {
  if [[ ! -f "${TARGET_ENV}" ]]; then
    exit 0
  fi

  mkdir -p "${STATE_DIR}"

  local data_path="" fs_path="" effective_fs_path=""
  data_path=$(get_env_value "APP_DATA_PATH")
  fs_path=$(get_env_value "APP_FS_DATA_PATH")
  if [[ "${fs_path}" == "system" ]]; then
    effective_fs_path=""
  else
    effective_fs_path="${fs_path:-${data_path}}"
  fi

  check_disk "system" "/" "${MARKER_FILE}"

  if [[ -n "${data_path}" && -d "${data_path}" ]]; then
    check_disk "app-data" "${data_path}" "${MARKER_DATA_FILE}"
  else
    rm -f "${MARKER_DATA_FILE}" 2>/dev/null || true
  fi

  if [[ -n "${effective_fs_path}" && -d "${effective_fs_path}" && "${effective_fs_path}" != "${data_path}" ]]; then
    check_disk "app-fs" "${effective_fs_path}" "${MARKER_FS_FILE}"
  else
    rm -f "${MARKER_FS_FILE}" 2>/dev/null || true
  fi
}

main "$@"

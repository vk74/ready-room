#!/usr/bin/env bash
#
# Version: 0.28.9
# Purpose: Apply database, state, and file-storage placement plus the file-storage capacity limit.
# File: admin-storage-apply.sh
# Logic: Reads APP_NEW_DATA_PATH, APP_NEW_FS_DATA_PATH, and APP_NEW_FS_VOLUME_MAX_GB.
#        An empty data path means the system disk. An empty file-storage path follows
#        the data path. APP_FS_DATA_PATH=system forces the default named volume even
#        when database data is on an external disk. When only the capacity limit
#        changes, the script updates config/app.env and restarts via install.sh.
#        When a volume moves, it checks free space, stops services, copies data with
#        podman unshare, rewrites the env file, restarts, and deletes the old external
#        directory only after every container is active.
#
# Changes in v0.28.9:
# - Initial volume relocation and file-storage capacity apply for the admin disk panel.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
TARGET_ENV="${CONFIG_DIR}/app.env"
TARGET_SECRETS="${CONFIG_DIR}/app.secrets.env"
INSTALL_SH="${DEPLOYMENT_DIR}/install.sh"
HEADROOM_BYTES=104857600

_runtime_dir="/run/user/$(id -u)"
if [[ -d "${_runtime_dir}" ]]; then
  export XDG_RUNTIME_DIR="${_runtime_dir}"
fi

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

log()  { printf "${CYAN}[disk-storage]${NC} %s\n" "$*"; }
ok()   { printf '  %s[✓]%s %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '  %s[!]%s %s\n' "${YELLOW}" "${NC}" "$*"; }
err()  { printf '%sERROR:%s %s\n' "${RED}" "${NC}" "$*" >&2; }
die()  { err "$*"; exit 1; }

get_kv() {
  local key="$1" val=""
  val=$(grep "^${key}=" "${TARGET_ENV}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
  val="${val%$'\r'}"
  printf '%s' "${val}"
}

sed_escape_repl() {
  printf '%s' "$1" | sed 's/[\/&|]/\\&/g'
}

set_env_line() {
  local file="$1" key="$2" value="$3" esc=""
  esc=$(sed_escape_repl "${value}")
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

norm_path() {
  local p="$1"
  while [[ -n "${p}" && "${p}" != "/" && "${p}" == */ ]]; do
    p="${p%/}"
  done
  printf '%s' "${p}"
}

get_dir_bytes() {
  local path="$1" bytes="" kb=""
  if [[ -z "${path}" || ! -e "${path}" ]]; then
    printf '0'
    return 0
  fi
  bytes=$(du -sb "${path}" 2>/dev/null | head -1 | cut -f1 || true)
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]] && command -v podman >/dev/null 2>&1; then
    bytes=$(podman unshare du -sb "${path}" 2>/dev/null | head -1 | cut -f1 || true)
  fi
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]]; then
    kb=$(du -sk "${path}" 2>/dev/null | head -1 | awk '{print $1}' || true)
    if [[ "${kb}" =~ ^[0-9]+$ ]]; then
      bytes=$((kb * 1024))
    else
      bytes=0
    fi
  fi
  printf '%s' "${bytes}"
}

get_mount_target() {
  local path="$1"
  local check_path="${path}"
  local target=""
  if [[ -z "${path}" ]]; then
    printf '/'
    return 0
  fi
  while [[ ! -d "${check_path}" && "${check_path}" != "/" ]]; do
    check_path="$(dirname "${check_path}")"
  done
  target=$(df --output=target "${check_path}" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
  if [[ -z "${target}" ]]; then
    target=$(df -P "${check_path}" 2>/dev/null | tail -1 | awk '{print $NF}' || true)
  fi
  if [[ -z "${target}" ]]; then
    target="/"
  fi
  printf '%s' "${target}"
}

avail_bytes() {
  local mount="$1" avail="" kb=""
  avail=$(df -B1 --output=avail "${mount}" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
  if [[ ! "${avail}" =~ ^[0-9]+$ ]]; then
    kb=$(df -Pk "${mount}" 2>/dev/null | tail -1 | awk '{print $4}' || true)
    if [[ "${kb}" =~ ^[0-9]+$ ]]; then
      avail=$((kb * 1024))
    else
      avail=0
    fi
  fi
  printf '%s' "${avail}"
}

# Effective host base for fs: "system" and empty-with-no-data-path mean no bind directory.
effective_base() {
  local data_path="$1" fs_path="$2"
  if [[ "${fs_path}" == "system" ]]; then
    printf ''
  elif [[ -n "${fs_path}" ]]; then
    printf '%s' "${fs_path}"
  else
    printf '%s' "${data_path}"
  fi
}

bind_dir() {
  local base="$1" leaf="$2"
  base="$(norm_path "${base}")"
  if [[ -n "${base}" ]]; then
    printf '%s' "${base}/${leaf}"
  fi
}

validate_external_path() {
  local path="$1"
  local kind="$2"
  local check="${path}"
  if [[ "${path}" != /* ]]; then
    die "${kind} path must start with /"
  fi
  if [[ "${path}" == *".."* ]]; then
    die "${kind} path must not contain .."
  fi
  if [[ "${path}" == *[[:space:]]* ]]; then
    die "${kind} path must not contain whitespace"
  fi
  while [[ ! -d "${check}" && "${check}" != "/" ]]; do
    check="$(dirname "${check}")"
  done
  if [[ ! -d "${check}" ]]; then
    die "${kind} path is not on an existing mount"
  fi
  if [[ ! -w "${check}" ]]; then
    die "${kind} path is not writable (${check})"
  fi
}

live_mountpoint() {
  local vol_name="$1" mp=""
  mp=$(podman volume inspect "${vol_name}" --format '{{.Mountpoint}}' 2>/dev/null || true)
  printf '%s' "${mp}"
}

live_volume_bytes() {
  local vol_name="$1" fallback="$2" mp=""
  mp="$(live_mountpoint "${vol_name}")"
  if [[ -n "${mp}" && -d "${mp}" ]]; then
    get_dir_bytes "${mp}"
    return 0
  fi
  if [[ -n "${fallback}" && -d "${fallback}" ]]; then
    get_dir_bytes "${fallback}"
    return 0
  fi
  printf '0'
}

target_mount_for() {
  local bind="$1" storage="${HOME}/.local/share/containers/storage"
  if [[ -n "${bind}" ]]; then
    get_mount_target "${bind}"
    return 0
  fi
  if [[ -d "${storage}" ]]; then
    get_mount_target "${storage}"
  else
    get_mount_target "${HOME}"
  fi
}

need_mounts=()
need_bytes=()
note_move() {
  local mount="$1" bytes="$2" i
  if [[ ${#need_mounts[@]} -gt 0 ]]; then
    for (( i=0; i<${#need_mounts[@]}; i++ )); do
      if [[ "${need_mounts[$i]}" == "${mount}" ]]; then
        need_bytes[$i]=$((need_bytes[$i] + bytes))
        return 0
      fi
    done
  fi
  need_mounts+=("${mount}")
  need_bytes+=("${bytes}")
}

retired_dirs=()
to_system_vols=()
to_system_olds=()

remember_retired() {
  local dir="$1" existing=""
  dir="$(norm_path "${dir}")"
  [[ -n "${dir}" ]] || return 0
  if [[ ${#retired_dirs[@]} -gt 0 ]]; then
    for existing in "${retired_dirs[@]}"; do
      if [[ "${existing}" == "${dir}" ]]; then
        return 0
      fi
    done
  fi
  retired_dirs+=("${dir}")
}

relocate_volume() {
  local vol_name="$1" unit_name="$2" old_bind_dir="$3" new_bind_dir="$4" old_mp=""
  old_mp="$(live_mountpoint "${vol_name}")"
  log "relocating ${vol_name} (${old_bind_dir:-system disk} -> ${new_bind_dir:-system disk})"
  if [[ -n "${new_bind_dir}" ]]; then
    if [[ -n "${old_mp}" && "${old_mp}" == "${new_bind_dir}" ]]; then
      log "${vol_name} is already stored at ${new_bind_dir}"
      return 0
    fi
    mkdir -p "${new_bind_dir}"
    if [[ -n "${old_mp}" && -d "${old_mp}" && "${old_mp}" != "${new_bind_dir}" ]]; then
      log "copying ${vol_name} to ${new_bind_dir}"
      if ! podman unshare cp -a "${old_mp}/." "${new_bind_dir}/"; then
        die "failed to copy ${vol_name} from ${old_mp} to ${new_bind_dir}. Services are stopped and the original volume was kept."
      fi
    fi
    systemctl --user stop "${unit_name}-volume.service" 2>/dev/null || true
    podman rm -f "${unit_name}" 2>/dev/null || true
    podman volume rm -f "${vol_name}" 2>/dev/null || true
    if [[ -n "${old_bind_dir}" && "${old_bind_dir}" != "${new_bind_dir}" ]]; then
      remember_retired "${old_bind_dir}"
    fi
    return 0
  fi

  systemctl --user stop "${unit_name}-volume.service" 2>/dev/null || true
  podman rm -f "${unit_name}" 2>/dev/null || true
  podman volume rm -f "${vol_name}" 2>/dev/null || true
  if [[ -n "${old_bind_dir}" ]]; then
    to_system_vols+=("${vol_name}")
    to_system_olds+=("${old_bind_dir}")
    remember_retired "${old_bind_dir}"
  fi
}

seed_named_volume() {
  local vol_name="$1" old_bind_dir="$2" new_mp=""
  if [[ -z "${old_bind_dir}" || ! -d "${old_bind_dir}" ]]; then
    return 0
  fi
  if ! podman volume inspect "${vol_name}" >/dev/null 2>&1; then
    log "creating named volume ${vol_name}"
    podman volume create "${vol_name}" >/dev/null
  fi
  new_mp="$(live_mountpoint "${vol_name}")"
  if [[ -z "${new_mp}" || ! -d "${new_mp}" ]]; then
    die "named volume ${vol_name} has no mountpoint. Previous data is still at ${old_bind_dir}."
  fi
  if [[ "${old_bind_dir}" == "${new_mp}" ]]; then
    return 0
  fi
  log "copying ${old_bind_dir} into ${vol_name}"
  if ! podman unshare cp -a "${old_bind_dir}/." "${new_mp}/"; then
    die "failed to copy ${old_bind_dir} into ${vol_name} at ${new_mp}. Previous data is still at ${old_bind_dir}. Services are stopped."
  fi
}

remove_retired_dir() {
  local dir="$1"
  dir="$(norm_path "${dir}")"
  case "${dir}" in
    */db|*/fs|*/state) ;;
    *)
      die "refusing to remove unexpected path ${dir}"
      ;;
  esac
  if [[ "${dir}" == *..* || "${dir}" == "/" ]]; then
    die "refusing to remove ${dir}"
  fi
  if [[ ! -d "${dir}" ]]; then
    return 0
  fi
  log "removing retired directory ${dir}"
  if ! podman unshare rm -rf "${dir}"; then
    die "could not remove retired directory ${dir}"
  fi
  ok "removed ${dir}"
}

if [[ ! -f "${TARGET_ENV}" ]]; then
  die "Missing ${TARGET_ENV}"
fi
if [[ ! -f "${INSTALL_SH}" ]]; then
  die "Missing ${INSTALL_SH}"
fi

current_data="$(norm_path "$(get_kv APP_DATA_PATH)")"
current_fs="$(get_kv APP_FS_DATA_PATH)"
if [[ "${current_fs}" != "system" ]]; then
  current_fs="$(norm_path "${current_fs}")"
fi
current_gb="$(get_kv APP_FS_VOLUME_MAX_GB)"
if [[ ! "${current_gb}" =~ ^[0-9]+$ ]]; then
  current_gb=100
fi

if [[ -z "${APP_NEW_DATA_PATH+x}" ]]; then
  new_data="${current_data}"
else
  new_data="$(norm_path "${APP_NEW_DATA_PATH}")"
fi
if [[ -z "${APP_NEW_FS_DATA_PATH+x}" ]]; then
  new_fs="${current_fs}"
else
  new_fs="${APP_NEW_FS_DATA_PATH}"
  if [[ "${new_fs}" != "system" ]]; then
    new_fs="$(norm_path "${new_fs}")"
  fi
fi
if [[ -z "${APP_NEW_FS_VOLUME_MAX_GB+x}" ]]; then
  new_gb="${current_gb}"
else
  new_gb="${APP_NEW_FS_VOLUME_MAX_GB}"
fi

if [[ ! "${new_gb}" =~ ^[0-9]+$ ]] || [[ "$((10#${new_gb}))" -lt 1 ]]; then
  die "File storage capacity limit must be a positive whole number of gigabytes."
fi
new_gb="$((10#${new_gb}))"

if [[ -n "${new_data}" ]]; then
  validate_external_path "${new_data}" "Database data"
  mkdir -p "${new_data}/db" "${new_data}/state"
fi
if [[ -n "${new_fs}" && "${new_fs}" != "system" ]]; then
  validate_external_path "${new_fs}" "File storage data"
  mkdir -p "${new_fs}/fs"
fi

old_db_bind="$(bind_dir "${current_data}" db)"
new_db_bind="$(bind_dir "${new_data}" db)"
old_state_bind="$(bind_dir "${current_data}" state)"
new_state_bind="$(bind_dir "${new_data}" state)"
old_fs_base="$(effective_base "${current_data}" "${current_fs}")"
new_fs_base="$(effective_base "${new_data}" "${new_fs}")"
old_fs_bind="$(bind_dir "${old_fs_base}" fs)"
new_fs_bind="$(bind_dir "${new_fs_base}" fs)"

db_changed=0
state_changed=0
fs_changed=0
if [[ "${old_db_bind}" != "${new_db_bind}" ]]; then
  db_changed=1
fi
if [[ "${old_state_bind}" != "${new_state_bind}" ]]; then
  state_changed=1
fi
if [[ "${old_fs_bind}" != "${new_fs_bind}" ]]; then
  fs_changed=1
fi

if [[ "${db_changed}" -eq 0 && "${state_changed}" -eq 0 && "${fs_changed}" -eq 0 ]]; then
  log "volume placement is unchanged; updating the file storage capacity limit to ${new_gb} GB"
  set_env_line "${TARGET_ENV}" "APP_FS_VOLUME_MAX_GB" "${new_gb}"
  ok "updated APP_FS_VOLUME_MAX_GB"
  exec bash "${INSTALL_SH}" __cockpit_apply_restart
fi

if [[ ! -f "${TARGET_SECRETS}" ]]; then
  die "Missing ${TARGET_SECRETS}"
fi
if ! command -v podman >/dev/null 2>&1; then
  die "podman is required to relocate volumes"
fi
if ! command -v systemctl >/dev/null 2>&1; then
  die "systemctl is required to relocate volumes"
fi

plan_one() {
  local vol_name="$1" old_bind="$2" new_bind="$3" copy_bytes="" target="" mp=""
  mp="$(live_mountpoint "${vol_name}")"
  if [[ -n "${new_bind}" && -n "${mp}" && "${mp}" == "${new_bind}" ]]; then
    return 0
  fi
  copy_bytes="$(live_volume_bytes "${vol_name}" "${old_bind}")"
  if [[ "${copy_bytes}" -le 0 ]]; then
    return 0
  fi
  target="$(target_mount_for "${new_bind}")"
  note_move "${target}" "${copy_bytes}"
}

if [[ "${db_changed}" -eq 1 ]]; then
  plan_one db_data "${old_db_bind}" "${new_db_bind}"
fi
if [[ "${state_changed}" -eq 1 ]]; then
  plan_one state_data "${old_state_bind}" "${new_state_bind}"
fi
if [[ "${fs_changed}" -eq 1 ]]; then
  plan_one fs_data "${old_fs_bind}" "${new_fs_bind}"
fi

if [[ ${#need_mounts[@]} -gt 0 ]]; then
  need_i=0
  for (( need_i=0; need_i<${#need_mounts[@]}; need_i++ )); do
    mount="${need_mounts[$need_i]}"
    moving="${need_bytes[$need_i]}"
    required=$((moving + HEADROOM_BYTES))
    avail="$(avail_bytes "${mount}")"
    log "space check ${mount}: moving ${moving} bytes, available ${avail} bytes, required ${required} bytes"
    if [[ "${avail}" -lt "${required}" ]]; then
      die "Not enough free space on ${mount}. Need ${required} bytes (moving data plus 100 MB headroom), available ${avail} bytes. Containers were not stopped."
    fi
  done
fi

log "stopping application services"
systemctl --user stop reverse-proxy fe be worker fs state db pgadmin 2>/dev/null || true

if [[ "${db_changed}" -eq 1 ]]; then
  relocate_volume db_data db "${old_db_bind}" "${new_db_bind}"
fi
if [[ "${state_changed}" -eq 1 ]]; then
  relocate_volume state_data state "${old_state_bind}" "${new_state_bind}"
fi
if [[ "${fs_changed}" -eq 1 ]]; then
  relocate_volume fs_data fs "${old_fs_bind}" "${new_fs_bind}"
fi

log "updating storage settings in ${TARGET_ENV}"
set_env_line "${TARGET_ENV}" "APP_DATA_PATH" "${new_data}"
set_env_line "${TARGET_ENV}" "APP_FS_DATA_PATH" "${new_fs}"
set_env_line "${TARGET_ENV}" "APP_FS_VOLUME_MAX_GB" "${new_gb}"

if [[ ${#to_system_vols[@]} -gt 0 ]]; then
  seed_i=0
  for (( seed_i=0; seed_i<${#to_system_vols[@]}; seed_i++ )); do
    seed_named_volume "${to_system_vols[$seed_i]}" "${to_system_olds[$seed_i]}"
  done
fi

log "rendering units and restarting containers"
set +e
bash "${INSTALL_SH}" __cockpit_apply_restart
apply_status=$?
set -e
if [[ "${apply_status}" -ne 0 ]]; then
  err "configuration apply did not leave all containers active (exit ${apply_status})."
  if [[ ${#retired_dirs[@]} -gt 0 ]]; then
    err "previous data directories were kept:"
    kept=""
    for kept in "${retired_dirs[@]}"; do
      err "  ${kept}"
    done
  fi
  exit "${apply_status}"
fi

if [[ ${#retired_dirs[@]} -gt 0 ]]; then
  kept=""
  for kept in "${retired_dirs[@]}"; do
    remove_retired_dir "${kept}"
  done
fi
ok "storage placement applied"

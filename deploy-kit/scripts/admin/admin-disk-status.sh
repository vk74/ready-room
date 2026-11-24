#!/usr/bin/env bash
#
# Version: 0.28.9
# Purpose: Print a JSON snapshot of mounted disks, volume placement, and cleanup candidates.
# File: admin-disk-status.sh
# Logic: Reads APP_DATA_PATH, APP_FS_DATA_PATH, APP_FS_VOLUME_MAX_GB, and APP_*_IMAGE
#        from config/app.env. Measures db_data, fs_data, state_data, container storage
#        (excluding named volumes), backups, and staged updates. Lists real block-device
#        mounts and attributes each component to the mount that holds it.
#        APP_FS_DATA_PATH=system means the file-storage volume uses the default named
#        volume on the system disk. An empty APP_FS_DATA_PATH follows APP_DATA_PATH.
#
# Changes in v0.28.9:
# - Initial disk status snapshot for the admin panel.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="${1:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
TARGET_ENV="${CONFIG_DIR}/app.env"
STATE_DIR="${CONFIG_DIR}/state"
BACKUP_DIR="${CONFIG_DIR}/backup"
UPDATES_DIR="${CONFIG_DIR}/updates"

_runtime_dir="/run/user/$(id -u)"
if [[ -d "${_runtime_dir}" ]]; then
  export XDG_RUNTIME_DIR="${_runtime_dir}"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to format disk status" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
DISKS_JSONL="${WORK_DIR}/disks.jsonl"
BACKUPS_JSONL="${WORK_DIR}/backups.jsonl"
: > "${DISKS_JSONL}"
: > "${BACKUPS_JSONL}"

found_mounts=()
found_devices=()
found_fstypes=()
emitted_mounts=()
emitted_totals=()

get_env_value() {
  local key="$1" val=""
  if [[ ! -f "${TARGET_ENV}" ]]; then
    printf ''
    return 0
  fi
  val=$(grep "^${key}=" "${TARGET_ENV}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
  val="${val%$'\r'}"
  printf '%s' "${val}"
}

as_int() {
  local v="${1:-}"
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${v}"
  else
    printf '0'
  fi
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

read_device() {
  local path="$1" dev=""
  dev=$(df --output=source "${path}" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
  if [[ -z "${dev}" ]]; then
    dev=$(df -P "${path}" 2>/dev/null | tail -1 | awk '{print $1}' || true)
  fi
  if [[ -z "${dev}" ]]; then
    dev="unknown"
  fi
  printf '%s' "${dev}"
}

# Sets DF_SIZE, DF_USED, DF_AVAIL, DF_PCT for the mount that holds path.
read_df() {
  local path="$1"
  local check_path="${path}"
  local line="" size="" used="" avail="" pct=""
  DF_SIZE=0
  DF_USED=0
  DF_AVAIL=0
  DF_PCT=0
  if [[ -z "${path}" ]]; then
    check_path="/"
  fi
  while [[ ! -d "${check_path}" && "${check_path}" != "/" ]]; do
    check_path="$(dirname "${check_path}")"
  done
  line=$(df -B1 --output=size,used,avail,pcent "${check_path}" 2>/dev/null | tail -1 || true)
  if [[ -n "${line}" ]]; then
    size=$(printf '%s' "${line}" | awk '{print $1}')
    used=$(printf '%s' "${line}" | awk '{print $2}')
    avail=$(printf '%s' "${line}" | awk '{print $3}')
    pct=$(printf '%s' "${line}" | awk '{print $4}' | tr -d '%')
  else
    line=$(df -Pk "${check_path}" 2>/dev/null | tail -1 || true)
    size=$(printf '%s' "${line}" | awk '{print $2}')
    used=$(printf '%s' "${line}" | awk '{print $3}')
    avail=$(printf '%s' "${line}" | awk '{print $4}')
    pct=$(printf '%s' "${line}" | awk '{print $5}' | tr -d '%')
    if [[ "${size}" =~ ^[0-9]+$ ]]; then size=$((size * 1024)); fi
    if [[ "${used}" =~ ^[0-9]+$ ]]; then used=$((used * 1024)); fi
    if [[ "${avail}" =~ ^[0-9]+$ ]]; then avail=$((avail * 1024)); fi
  fi
  DF_SIZE="$(as_int "${size}")"
  DF_USED="$(as_int "${used}")"
  DF_AVAIL="$(as_int "${avail}")"
  DF_PCT="$(as_int "${pct}")"
}

have_found() {
  local mount="$1" i
  if [[ ${#found_mounts[@]} -eq 0 ]]; then
    return 1
  fi
  for (( i=0; i<${#found_mounts[@]}; i++ )); do
    if [[ "${found_mounts[$i]}" == "${mount}" ]]; then
      return 0
    fi
  done
  return 1
}

add_found() {
  local mount="$1" dev="$2" fst="$3"
  if have_found "${mount}"; then
    return 0
  fi
  found_mounts+=("${mount}")
  found_devices+=("${dev}")
  found_fstypes+=("${fst}")
}

resolve_volume_path() {
  local vol_name="$1" fallback="$2" mp=""
  if command -v podman >/dev/null 2>&1; then
    mp=$(podman volume inspect "${vol_name}" --format '{{.Mountpoint}}' 2>/dev/null || true)
  fi
  if [[ -n "${mp}" ]]; then
    printf '%s' "${mp}"
  else
    printf '%s' "${fallback}"
  fi
}

iso_utc_mtime() {
  local f="$1" out="" epoch=""
  out=$(date -u -r "${f}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  if [[ ! "${out}" =~ ^[0-9]{4}- ]]; then
    epoch=$(stat -c %Y "${f}" 2>/dev/null || stat -f %m "${f}" 2>/dev/null || true)
    if [[ "${epoch}" =~ ^[0-9]+$ ]]; then
      out=$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    fi
  fi
  if [[ -z "${out}" ]]; then
    out="1970-01-01T00:00:00Z"
  fi
  printf '%s' "${out}"
}

file_bytes() {
  local f="$1" n=""
  n=$(wc -c < "${f}" 2>/dev/null | tr -d '[:space:]' || true)
  printf '%s' "$(as_int "${n}")"
}

id_is_used() {
  local id="$1" one="" rest="${IMAGE_USED_IDS#|}"
  while [[ "${rest}" == *"|"* ]]; do
    one="${rest%%|*}"
    rest="${rest#*|}"
    if [[ -z "${one}" ]]; then
      continue
    fi
    if [[ "${id}" == "${one}" || "${id}" == "${one}"* || "${one}" == "${id}"* ]]; then
      return 0
    fi
  done
  return 1
}

collect_unused_images() {
  unused_images_count=0
  unused_images_bytes=0
  IMAGE_USED_IDS="|"
  IMAGE_CONFIGURED="|${APP_PROXY_IMAGE:-}|${APP_FE_IMAGE:-}|${APP_BE_IMAGE:-}|${APP_DB_IMAGE:-}|${APP_STATE_IMAGE:-}|${APP_WORKER_IMAGE:-}|${APP_FS_IMAGE:-}|${APP_PGADMIN_IMAGE:-}|"
  if ! command -v podman >/dev/null 2>&1; then
    return 0
  fi
  local used_raw="" line="" id="" rest="" repo="" size="" seen_ids="|"
  while IFS= read -r used_raw; do
    [[ -z "${used_raw}" ]] && continue
    used_raw="${used_raw#sha256:}"
    IMAGE_USED_IDS="${IMAGE_USED_IDS}${used_raw}|"
  done < <(podman ps -a --format '{{.ImageID}}' 2>/dev/null || true)

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    id="${line%%|*}"
    rest="${line#*|}"
    repo="${rest%%|*}"
    id="${id#sha256:}"
    [[ -z "${id}" ]] && continue
    case "${seen_ids}" in
      *"|${id}|"*) continue ;;
    esac
    seen_ids="${seen_ids}${id}|"
    case "${IMAGE_CONFIGURED}" in
      *"|${repo}|"*) continue ;;
    esac
    if id_is_used "${id}"; then
      continue
    fi
    size=$(podman image inspect "${id}" --format '{{.Size}}' 2>/dev/null || true)
    size="$(as_int "${size}")"
    unused_images_count=$((unused_images_count + 1))
    unused_images_bytes=$((unused_images_bytes + size))
  done < <(podman images --format '{{.ID}}|{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
}

emit_disk() {
  local mount="$1" device="$2" fstype="$3"
  local total="$4" used="$5" avail="$6" pct="$7"
  local b_db="$8" b_fs="$9" b_state="${10}" b_images="${11}" b_backups="${12}" b_updates="${13}"
  local level="ok" other=0 writable_json="false" is_system_json="false" role_list="" roles_json="[]"
  if [[ "${pct}" -ge 95 ]]; then
    level="critical"
  elif [[ "${pct}" -ge 85 ]]; then
    level="warning"
  fi
  other=$((used - b_db - b_fs - b_state - b_images - b_backups - b_updates))
  if [[ "${other}" -lt 0 ]]; then
    other=0
  fi
  if [[ -w "${mount}" || -w "${mount}/data" ]]; then
    writable_json="true"
  fi
  if [[ "${mount}" == "/" || "${mount}" == "${home_mount}" ]]; then
    is_system_json="true"
    role_list="system"
  fi
  if [[ "${mount}" == "${db_mount}" ]]; then
    role_list="${role_list}"$'\n'"db"
  fi
  if [[ "${mount}" == "${fs_mount}" ]]; then
    role_list="${role_list}"$'\n'"fs"
  fi
  if [[ "${mount}" == "${state_mount}" ]]; then
    role_list="${role_list}"$'\n'"state"
  fi
  if [[ "${mount}" == "${backups_mount}" ]]; then
    role_list="${role_list}"$'\n'"backups"
  fi
  if [[ -n "${role_list}" ]]; then
    roles_json=$(printf '%s\n' "${role_list}" | jq -R . | jq -s 'map(select(length > 0))')
  fi
  jq -n \
    --arg mount_point "${mount}" \
    --arg device "${device}" \
    --arg fstype "${fstype}" \
    --argjson is_system "${is_system_json}" \
    --argjson writable "${writable_json}" \
    --argjson total_bytes "${total}" \
    --argjson used_bytes "${used}" \
    --argjson avail_bytes "${avail}" \
    --argjson use_percent "${pct}" \
    --arg level "${level}" \
    --argjson roles "${roles_json}" \
    --argjson db "${b_db}" \
    --argjson fs "${b_fs}" \
    --argjson state "${b_state}" \
    --argjson images "${b_images}" \
    --argjson backups "${b_backups}" \
    --argjson updates "${b_updates}" \
    --argjson other "${other}" \
    --argjson free "${avail}" \
    'def pct(b): if $total_bytes > 0 then ((b * 10000 / $total_bytes) | round) / 100 else 0 end;
     {
       mount_point: $mount_point,
       device: $device,
       fstype: $fstype,
       is_system: $is_system,
       writable: $writable,
       total_bytes: $total_bytes,
       used_bytes: $used_bytes,
       avail_bytes: $avail_bytes,
       use_percent: $use_percent,
       level: $level,
       roles: $roles,
       breakdown: {db: $db, fs: $fs, state: $state, images: $images, backups: $backups, updates: $updates},
       segments: [
         {key: "db", bytes: $db, percent_of_disk: pct($db)},
         {key: "fs", bytes: $fs, percent_of_disk: pct($fs)},
         {key: "state", bytes: $state, percent_of_disk: pct($state)},
         {key: "images", bytes: $images, percent_of_disk: pct($images)},
         {key: "backups", bytes: $backups, percent_of_disk: pct($backups)},
         {key: "updates", bytes: $updates, percent_of_disk: pct($updates)},
         {key: "other", bytes: $other, percent_of_disk: pct($other)},
         {key: "free", bytes: $free, percent_of_disk: pct($free)}
       ]
     }' >> "${DISKS_JSONL}"
  emitted_mounts+=("${mount}")
  emitted_totals+=("${total}")
}

discover_mounts() {
  local line="" mount_target="" source_dev="" fstype=""
  local skip_fs="tmpfs|devtmpfs|squashfs|overlay|fuse\\.snapfuse|proc|sysfs|cgroup2?|efivarfs|securityfs|debugfs|tracefs|configfs|fusectl|pstore|bpf|hugetlbfs|mqueue|devpts|autofs|binfmt_misc|ramfs|nsfs"
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    mount_target=$(printf '%s' "${line}" | awk '{print $1}')
    source_dev=$(printf '%s' "${line}" | awk '{print $2}')
    fstype=$(printf '%s' "${line}" | awk '{print $3}')
    [[ "${source_dev}" == /dev/* ]] || continue
    [[ "${source_dev}" == *\[* ]] && continue
    [[ "${mount_target}" == /snap/* || "${mount_target}" == /var/snap/* ]] && continue
    [[ "${mount_target}" == /boot || "${mount_target}" == /boot/* ]] && continue
    [[ "${mount_target}" == /sys/* ]] && continue
    [[ "${mount_target}" == /proc/* ]] && continue
    [[ "${mount_target}" == /run/* ]] && continue
    [[ "${mount_target}" == /dev/* ]] && continue
    if printf '%s' "${fstype}" | grep -qE "^(${skip_fs})$"; then
      continue
    fi
    add_found "${mount_target}" "${source_dev}" "${fstype}"
  done < <(findmnt -rno TARGET,SOURCE,FSTYPE --real 2>/dev/null || true)

  add_found "/" "$(read_device /)" "unknown"
  add_found "${db_mount}" "$(read_device "${db_mount}")" "unknown"
  add_found "${fs_mount}" "$(read_device "${fs_mount}")" "unknown"
  add_found "${state_mount}" "$(read_device "${state_mount}")" "unknown"
  add_found "${backups_mount}" "$(read_device "${backups_mount}")" "unknown"
}

slice_bytes() {
  local mount="$1" owner="$2" value="$3"
  if [[ "${mount}" == "${owner}" ]]; then
    printf '%s' "${value}"
  else
    printf '0'
  fi
}

data_path="$(get_env_value APP_DATA_PATH)"
fs_setting="$(get_env_value APP_FS_DATA_PATH)"
fs_max_raw="$(get_env_value APP_FS_VOLUME_MAX_GB)"
APP_PROXY_IMAGE="$(get_env_value APP_PROXY_IMAGE)"
APP_FE_IMAGE="$(get_env_value APP_FE_IMAGE)"
APP_BE_IMAGE="$(get_env_value APP_BE_IMAGE)"
APP_DB_IMAGE="$(get_env_value APP_DB_IMAGE)"
APP_STATE_IMAGE="$(get_env_value APP_STATE_IMAGE)"
APP_WORKER_IMAGE="$(get_env_value APP_WORKER_IMAGE)"
APP_FS_IMAGE="$(get_env_value APP_FS_IMAGE)"
APP_PGADMIN_IMAGE="$(get_env_value APP_PGADMIN_IMAGE)"

if [[ "${fs_setting}" == "system" ]]; then
  effective_fs_path=""
else
  effective_fs_path="${fs_setting:-${data_path}}"
fi

fs_max_gb="$(as_int "${fs_max_raw:-100}")"
if [[ "${fs_max_gb}" -lt 1 ]]; then
  fs_max_gb=100
fi

vol_root="${HOME}/.local/share/containers/storage/volumes"
if [[ -n "${data_path}" ]]; then
  db_fallback="${data_path}/db"
  state_fallback="${data_path}/state"
else
  db_fallback="${vol_root}/db_data/_data"
  state_fallback="${vol_root}/state_data/_data"
fi
if [[ -n "${effective_fs_path}" ]]; then
  fs_fallback="${effective_fs_path}/fs"
else
  fs_fallback="${vol_root}/fs_data/_data"
fi

db_path="$(resolve_volume_path db_data "${db_fallback}")"
fs_path="$(resolve_volume_path fs_data "${fs_fallback}")"
state_path="$(resolve_volume_path state_data "${state_fallback}")"
db_bytes="$(get_dir_bytes "${db_path}")"
fs_bytes="$(get_dir_bytes "${fs_path}")"
state_bytes="$(get_dir_bytes "${state_path}")"
db_mount="$(get_mount_target "${db_path}")"
fs_mount="$(get_mount_target "${fs_path}")"
state_mount="$(get_mount_target "${state_path}")"

storage_root="${HOME}/.local/share/containers/storage"
storage_total="$(get_dir_bytes "${storage_root}")"
volumes_total="$(get_dir_bytes "${storage_root}/volumes")"
images_bytes=$((storage_total - volumes_total))
if [[ "${images_bytes}" -lt 0 ]]; then
  images_bytes=0
fi
images_mount="$(get_mount_target "${storage_root}")"

backups_bytes="$(get_dir_bytes "${BACKUP_DIR}")"
backups_mount="$(get_mount_target "${BACKUP_DIR}")"
scanned_backup_bytes=0
if [[ -d "${BACKUP_DIR}" ]]; then
  backup_file=""
  for backup_file in "${BACKUP_DIR}"/*.tar.gz "${BACKUP_DIR}"/*.tar.zst "${BACKUP_DIR}"/*.enc; do
    [[ -f "${backup_file}" ]] || continue
    backup_name="$(basename "${backup_file}")"
    backup_size="$(file_bytes "${backup_file}")"
    backup_mtime="$(iso_utc_mtime "${backup_file}")"
    scanned_backup_bytes=$((scanned_backup_bytes + backup_size))
    jq -n --arg name "${backup_name}" --argjson size_bytes "${backup_size}" --arg mtime "${backup_mtime}" \
      '{name: $name, size_bytes: $size_bytes, mtime: $mtime}' >> "${BACKUPS_JSONL}"
  done
fi
if [[ "${backups_bytes}" -eq 0 && "${scanned_backup_bytes}" -gt 0 ]]; then
  backups_bytes="${scanned_backup_bytes}"
fi

updates_bytes=0
staged_version=""
if [[ -d "${UPDATES_DIR}" ]]; then
  updates_real="$(realpath "${UPDATES_DIR}" 2>/dev/null || printf '%s' "${UPDATES_DIR}")"
  update_child=""
  for update_child in "${UPDATES_DIR}"/*; do
    [[ -d "${update_child}" ]] || continue
    child_real="$(realpath "${update_child}" 2>/dev/null || printf '%s' "${update_child}")"
    parent="$(dirname "${child_real}")"
    parent="$(realpath "${parent}" 2>/dev/null || printf '%s' "${parent}")"
    [[ "${parent}" == "${updates_real}" ]] || continue
    [[ "${child_real}" == "${updates_real}" ]] && continue
    part="$(get_dir_bytes "${child_real}")"
    updates_bytes=$((updates_bytes + part))
  done
fi
updates_mount="$(get_mount_target "${UPDATES_DIR}")"
updates_json="${UPDATES_DIR}/updates.json"
if [[ -f "${updates_json}" ]]; then
  downloaded="$(jq -r 'if .downloaded == true then "true" else "false" end' "${updates_json}" 2>/dev/null || printf 'false')"
  if [[ "${downloaded}" == "true" ]]; then
    download_path="$(jq -r 'if (.downloadPath | type) == "string" then .downloadPath else "" end' "${updates_json}" 2>/dev/null || true)"
    if [[ -n "${download_path}" && -f "${download_path}/package.json" ]]; then
      staged_version="$(jq -r 'if (.version | type) == "string" then .version else "" end' "${download_path}/package.json" 2>/dev/null || true)"
    fi
  fi
fi

collect_unused_images

home_mount="$(get_mount_target "${HOME}")"
discover_mounts

disk_i=0
for (( disk_i=0; disk_i<${#found_mounts[@]}; disk_i++ )); do
  mount="${found_mounts[$disk_i]}"
  read_df "${mount}"
  b_db="$(slice_bytes "${mount}" "${db_mount}" "${db_bytes}")"
  b_fs="$(slice_bytes "${mount}" "${fs_mount}" "${fs_bytes}")"
  b_state="$(slice_bytes "${mount}" "${state_mount}" "${state_bytes}")"
  b_images="$(slice_bytes "${mount}" "${images_mount}" "${images_bytes}")"
  b_backups="$(slice_bytes "${mount}" "${backups_mount}" "${backups_bytes}")"
  b_updates="$(slice_bytes "${mount}" "${updates_mount}" "${updates_bytes}")"
  emit_disk "${mount}" "${found_devices[$disk_i]}" "${found_fstypes[$disk_i]}" \
    "${DF_SIZE}" "${DF_USED}" "${DF_AVAIL}" "${DF_PCT}" \
    "${b_db}" "${b_fs}" "${b_state}" "${b_images}" "${b_backups}" "${b_updates}"
done

fs_disk_total=0
if [[ ${#emitted_mounts[@]} -gt 0 ]]; then
  for (( disk_i=0; disk_i<${#emitted_mounts[@]}; disk_i++ )); do
    if [[ "${emitted_mounts[$disk_i]}" == "${fs_mount}" ]]; then
      fs_disk_total="${emitted_totals[$disk_i]}"
    fi
  done
fi
fs_ceiling_bytes=$((fs_max_gb * 1073741824))
fs_ceiling_exceeds_disk=false
if [[ "${fs_disk_total}" -gt 0 && "${fs_ceiling_bytes}" -gt "${fs_disk_total}" ]]; then
  fs_ceiling_exceeds_disk=true
fi

read_df "/"
system_json=$(jq -n \
  --argjson total_bytes "${DF_SIZE}" \
  --argjson used_bytes "${DF_USED}" \
  --argjson avail_bytes "${DF_AVAIL}" \
  --argjson use_percent "${DF_PCT}" \
  '{label: "system", path: "/", total_bytes: $total_bytes, used_bytes: $used_bytes, avail_bytes: $avail_bytes, use_percent: $use_percent}')
system_pct="${DF_PCT}"

data_json='null'
data_pct=0
data_checked=false
if [[ -n "${data_path}" ]]; then
  read_df "${data_path}"
  data_pct="${DF_PCT}"
  if [[ -d "${data_path}" ]]; then
    data_checked=true
  fi
  data_json=$(jq -n \
    --arg path "${data_path}" \
    --argjson total_bytes "${DF_SIZE}" \
    --argjson used_bytes "${DF_USED}" \
    --argjson avail_bytes "${DF_AVAIL}" \
    --argjson use_percent "${DF_PCT}" \
    '{label: "data", path: $path, total_bytes: $total_bytes, used_bytes: $used_bytes, avail_bytes: $avail_bytes, use_percent: $use_percent}')
fi

fs_pct=0
fs_checked=false
if [[ -n "${effective_fs_path}" && -d "${effective_fs_path}" && "${effective_fs_path}" != "${data_path}" ]]; then
  read_df "${effective_fs_path}"
  fs_pct="${DF_PCT}"
  fs_checked=true
fi

system_critical=false
data_critical=false
fs_critical=false
if [[ -f "${STATE_DIR}/.disk-space-critical" || "${system_pct}" -ge 95 ]]; then
  system_critical=true
fi
if [[ -f "${STATE_DIR}/.disk-space-data-critical" ]] || { [[ "${data_checked}" == "true" ]] && [[ "${data_pct}" -ge 95 ]]; }; then
  data_critical=true
fi
if [[ -f "${STATE_DIR}/.disk-space-fs-critical" ]] || { [[ "${fs_checked}" == "true" ]] && [[ "${fs_pct}" -ge 95 ]]; }; then
  fs_critical=true
fi

jq -s '.' "${DISKS_JSONL}" > "${WORK_DIR}/disks.json"
jq -s 'sort_by(.name)' "${BACKUPS_JSONL}" > "${WORK_DIR}/backups.json"

jq -n \
  --slurpfile disks "${WORK_DIR}/disks.json" \
  --slurpfile backups "${WORK_DIR}/backups.json" \
  --arg app_data_path "${data_path}" \
  --arg app_fs_data_path "${fs_setting}" \
  --arg effective_db_mount "${db_mount}" \
  --arg effective_fs_mount "${fs_mount}" \
  --arg effective_state_mount "${state_mount}" \
  --argjson db_volume_bytes "${db_bytes}" \
  --argjson fs_volume_bytes "${fs_bytes}" \
  --argjson state_volume_bytes "${state_bytes}" \
  --argjson fs_volume_max_gb "${fs_max_gb}" \
  --argjson fs_ceiling_exceeds_disk "${fs_ceiling_exceeds_disk}" \
  --argjson unused_images_count "${unused_images_count}" \
  --argjson unused_images_bytes "${unused_images_bytes}" \
  --argjson staged_updates_bytes "${updates_bytes}" \
  --arg staged_version "${staged_version}" \
  --argjson backups_bytes "${backups_bytes}" \
  --argjson system "${system_json}" \
  --argjson data "${data_json}" \
  --argjson system_critical "${system_critical}" \
  --argjson data_critical "${data_critical}" \
  --argjson fs_critical "${fs_critical}" \
  '{
     disks: $disks[0],
     storage_config: {
       app_data_path: $app_data_path,
       app_fs_data_path: $app_fs_data_path,
       effective_db_mount: $effective_db_mount,
       effective_fs_mount: $effective_fs_mount,
       effective_state_mount: $effective_state_mount,
       db_volume_bytes: $db_volume_bytes,
       fs_volume_bytes: $fs_volume_bytes,
       state_volume_bytes: $state_volume_bytes,
       fs_volume_max_gb: $fs_volume_max_gb,
       fs_ceiling_exceeds_disk: $fs_ceiling_exceeds_disk
     },
     cleanup: {
       unused_images_count: $unused_images_count,
       unused_images_bytes: $unused_images_bytes,
       staged_updates_bytes: $staged_updates_bytes,
       staged_version: (if $staged_version == "" then null else $staged_version end),
       backups_bytes: $backups_bytes,
       backups: $backups[0]
     },
     system: $system,
     system_critical: $system_critical,
     data_critical: $data_critical,
     fs_critical: $fs_critical
   } + (if $data == null then {} else {data: $data} end)'

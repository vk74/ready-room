#!/usr/bin/env bash
#
# Version: 0.28.9
# Purpose: Shared template rendering functions for application deploy and update processes.
# Deployment file: render-templates.sh
# Logic: Sourced by install.sh and apply-update.sh. Provides functions to render quadlet templates,
#        Caddyfile, compute MemoryMax blocks, apply the state memory percentage, and render valkey.conf.
#        All APP_* env vars must be loaded before calling.
#
# Required variables before source (contract):
#   TPL_DIR         — path to quadlet-templates/ directory
#   PROXY_DIR       — path to reverse-proxy/ directory (Caddyfile templates)
#   DEPLOY_KIT_DIR  — path to deploy kit root (for pgadmin template)
#   APP_QUADLET_DIR — path to ~/.config/containers/systemd/
#   APP_STATE_DIR   — path to config/state/ directory
#   TLS_DIR         — path to config/tls/ directory
#
# Changes in v0.28.9:
# - APP_FS_DATA_PATH=system renders the file-storage volume as the default named volume, even when APP_DATA_PATH is an external disk.
# - State memory is a percentage of host RAM (default 10%). Valkey maxmemory is half of that container limit, minimum 50mb. Legacy sizes 256m, 512m, 1g, 2g, 4g, and 8g are treated as 10%.
# - Container limit blocks emit systemd MemoryMax= and ignore CPU limit arguments.
# - Quadlet rendering substitutes APP_LIMIT_MEM_STATE and defaults an empty value to 10%.
#
# Changes in v0.28.6:
# - Host RAM GiB adds 0.75 GiB before flooring so a 4 GB VM that reports about 3.3–3.9 GiB counts as 4.
# - The low-RAM warning text is "ram < 4gb" when measured RAM is at least 2 GiB and below 4 GiB.
#
# Changes in v0.27.2:
# - Add APP_INSTALL_REPO to deploy_render_template_file() keys (worker quadlet).
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Template substitution uses APP_* values only.
# 
# Changes in v0.23.9:
# - Render state.volume and compute EVI_DATA_VOLUME_OPTIONS_STATE (EVI_DATA_PATH/state)
#   so evi-state persists AOF on the named volume state_data.
# - Five-step host-RAM ladder for evi-state (test/compact/medium/large/xlarge) persisted
#   as APP_LIMIT_MEM_STATE; a leftover pre-rename state-mem key is adopted then dropped.
#   valkey.conf maxmemory is derived on each render ({{APP_VALKEY_MAXMEMORY}}).
#   Host RAM < 2 GiB hard-stops (deploy_check_host_mem); 2–4 GiB warns (test).
#   compact (512m) maxmemory is 200mb.
#   Disk headroom is warned when EVI_DATA_PATH is set (2× maxmemory); the profile is unchanged.
#
# Changes in v0.23.4:
# - Added EVI_GITHUB_TOKEN to deploy_render_template_file() keys (worker quadlet).
#
# Changes in v1.5.3:
# - Render EVI_NETWORK_SUBNET / EVI_NETWORK_GATEWAY (pinned internal network CIDR) and
#   EVI_TRUSTED_PROXY_CIDRS (backend real client-IP extraction) into templates.
#
# Changes in v1.5.2:
# - Added EVI_FS_VOLUME_MAX_GB / EVI_FS_VOLUME_MAX to template rendering (fs.container -volume.max).
#
# Changes in v1.5.1:
# - Added EVI_FS_DATA_PATH support for FS volume bind-mount placement.
# - FS volume options now use EVI_FS_DATA_PATH when set, with fallback to EVI_DATA_PATH.
#
# Changes in v1.5.0:
# - Renamed EVI_FS_* to EVI_FS_* throughout; renamed EVI_LIMIT_*_FS to EVI_LIMIT_*_FS;
#   renamed fs.container/fs.volume to fs.container/fs.volume in render list;
#   renamed EVI_DATA_VOLUME_OPTIONS_FS to EVI_DATA_VOLUME_OPTIONS_FS;
#   updated data path from EVI_DATA_PATH/assets to EVI_DATA_PATH/fs.
#
# Changes in v1.4.0:
# - Fixed network quadlet filename: network -> network.network in deploy_render_quadlets().
#   Podman Quadlet requires the .network extension to recognise the file as a network unit
#   and generate network.service. Without the extension the file was silently ignored,
#   causing all containers to fail with "Unit network.service not found".
#
# Changes in v1.3.0:
# - Renamed network quadlet file: evi.network -> network (deploy_render_quadlets).
#
# Changes in v1.2.0:
# - Updated deploy_render_quadlets() to use short-named quadlet template files
#   (db.container, be.container, fe.container, state.container, worker.container,
#    fs.container, reverse-proxy.container, pgadmin.container, db.volume, fs.volume).
#
# Changes in v1.1.0:
# - Added EVI_DATA_PATH to deploy_render_template_file() keys array for volume template rendering.
# - Added EVI_DATA_VOLUME_OPTIONS computed block for conditional bind-mount in volume quadlets.
# - deploy_render_quadlets(): computes EVI_DATA_VOLUME_OPTIONS from EVI_DATA_PATH before rendering.
#
# Changes in v1.0.0:
# - Extracted from install.sh: deploy_compute_limits_block, deploy_prepare_proxy_tls_mounts,
#   deploy_render_template_file, deploy_render_caddyfile, deploy_render_quadlets.
#

# Callers may set either the current name or the legacy name.
APP_QUADLET_DIR="${APP_QUADLET_DIR:-}"
APP_STATE_DIR="${APP_STATE_DIR:-}"

# --- Validate required path variables (call before deploy_render_quadlets / deploy_render_caddyfile) ---
render_validate_paths() {
  local missing=0
  for var in TPL_DIR PROXY_DIR DEPLOY_KIT_DIR APP_QUADLET_DIR APP_STATE_DIR TLS_DIR; do
    if [[ -z "${!var:-}" ]]; then
      echo "render-templates.sh: required variable ${var} is not set" >&2
      missing=1
    fi
  done
  return $missing
}

# Host RAM in GiB. Linux VMs provisioned with N GB often report MemTotal below
# that size because of kernel and hypervisor reservations (a 4 GB VM can report
# about 3.3–3.9 GiB, for example 3480248 kB). Add 0.75 GiB (786432 kB) before
# dividing so those hosts resolve to the provisioned size: 4 GB VMs at or above
# 3.25 GiB become 4, 8 GB VMs become 8, while 2 GB stays 2, 3 GB stays 3, and
# 1 GB stays 1. APP_HOST_MEM_GIB, when set and non-empty, is returned unchanged.
deploy_host_mem_gib() {
  if [[ -n "${APP_HOST_MEM_GIB:-}" ]]; then
    printf '%s\n' "${APP_HOST_MEM_GIB}"
    return 0
  fi
  local mem_kb
  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
  printf '%s\n' "$(((mem_kb + 786432) / 1024 / 1024))"
}

# < 2: print fail to stderr, return 1 (no exit). 2 ≤ x < 4: WARN "ram < 4gb", return 0. Else return 0.
deploy_check_host_mem() {
  local host_gib
  host_gib="$(deploy_host_mem_gib)"
  if [[ "${host_gib}" -lt 2 ]]; then
    printf 'host ram < 2gb (minimum 2gb). deployment stopped.\n' >&2
    return 1
  fi
  if [[ "${host_gib}" -lt 4 ]]; then
    printf 'WARN: ram < 4gb: suitable for testing, not recommended for production\n' >&2
  fi
  return 0
}

# Host RAM in KiB. APP_HOST_MEM_GIB, when set, is converted exactly (no 0.75 GiB
# tolerance — that adjustment belongs to deploy_host_mem_gib). Missing or
# unreadable MemTotal falls back to 4 GiB (4194304 KiB).
deploy_host_mem_kb() {
  if [[ -n "${APP_HOST_MEM_GIB:-}" ]]; then
    printf '%s\n' "$((APP_HOST_MEM_GIB * 1024 * 1024))"
    return 0
  fi
  local mem_kb
  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  if [[ -z "${mem_kb}" || ! "${mem_kb}" =~ ^[0-9]+$ ]]; then
    mem_kb=4194304
  fi
  printf '%s\n' "${mem_kb}"
}

# Valkey maxmemory is 50% of the container memory limit, minimum 50mb.
# Empty and legacy ladder sizes (256m|512m|1g|2g|4g|8g) are treated as 10%.
# A percentage argument uses host RAM. Any other string warns and returns 50mb.
deploy_state_maxmemory_for_limit() {
  local limit="${1:-10%}"
  local pct mem_kb limit_mb maxmem_mb
  case "${limit}" in
    ""|256m|512m|1g|2g|4g|8g) limit="10%" ;;
  esac
  if [[ "${limit}" =~ ^([0-9]+)%$ ]]; then
    pct="${BASH_REMATCH[1]}"
    mem_kb="$(deploy_host_mem_kb)"
    limit_mb=$((mem_kb * pct / 100 / 1024))
    maxmem_mb=$((limit_mb / 2))
    [[ "${maxmem_mb}" -lt 50 ]] && maxmem_mb=50
    printf '%s\n' "${maxmem_mb}mb"
    return 0
  fi
  printf 'WARN: unknown APP_LIMIT_MEM_STATE=%s; using maxmemory 50mb\n' "${limit}" >&2
  printf '%s\n' "50mb"
}

# Empty or a legacy ladder size becomes 10% (return 0). Any other value is left
# unchanged (return 1).
deploy_apply_state_memory_profile() {
  case "${APP_LIMIT_MEM_STATE:-}" in
    ""|256m|512m|1g|2g|4g|8g)
      export APP_LIMIT_MEM_STATE="10%"
      return 0
      ;;
  esac
  return 1
}

# Idempotent APP_LIMIT_MEM_STATE= write.
# Portable tmp+sed (not GNU sed -i). Always persist, including when APP was already set.
deploy_persist_limit_mem_state() {
  local env_file="$1"
  local val="${APP_LIMIT_MEM_STATE:-}"
  if [[ ! -f "${env_file}" ]]; then
    printf 'APP_LIMIT_MEM_STATE=%s\n' "${val}" > "${env_file}"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if grep -q '^APP_LIMIT_MEM_STATE=' "${env_file}"; then
    sed -e "s|^APP_LIMIT_MEM_STATE=.*|APP_LIMIT_MEM_STATE=${val}|" \
        "${env_file}" > "${tmp}"
  else
    cat "${env_file}" > "${tmp}"
    printf 'APP_LIMIT_MEM_STATE=%s\n' "${val}" >> "${tmp}"
  fi
  cat "${tmp}" > "${env_file}"
  rm -f "${tmp}"
}

# Warn (stderr) if APP_DATA_PATH/state free bytes < 2 × derived maxmemory.
# Does not change the profile. Skips the default named volume (APP_DATA_PATH empty).
deploy_warn_state_disk_if_needed() {
  [[ -n "${APP_DATA_PATH:-}" ]] || return 0
  local state_dir="${APP_DATA_PATH:-}/state"
  mkdir -p "${state_dir}" 2>/dev/null || true
  local maxmem num unit maxmem_bytes need_bytes free_bytes
  maxmem="$(deploy_state_maxmemory_for_limit "${APP_LIMIT_MEM_STATE:-}")"
  if [[ "${maxmem}" =~ ^([0-9]+)([a-zA-Z]+)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "${unit}" in
      kb|k|KB|K) maxmem_bytes=$((num * 1024)) ;;
      mb|m|MB|M) maxmem_bytes=$((num * 1024 * 1024)) ;;
      gb|g|GB|G) maxmem_bytes=$((num * 1024 * 1024 * 1024)) ;;
      *) return 0 ;;
    esac
  else
    return 0
  fi
  need_bytes=$((maxmem_bytes * 2))
  free_bytes="$(df -P -B1 "${state_dir}" 2>/dev/null | awk 'NR==2 { print $4 }')"
  [[ -n "${free_bytes}" && "${free_bytes}" =~ ^[0-9]+$ ]] || return 0
  if [[ "${free_bytes}" -lt "${need_bytes}" ]]; then
    printf 'WARN: free space on %s (%s bytes) is below 2× Valkey maxmemory %s (%s bytes)\n' \
      "${state_dir}" "${free_bytes}" "${maxmem}" "${need_bytes}" >&2
  fi
}

# mkdir dest dir, substitute {{APP_VALKEY_MAXMEMORY}} from current APP_LIMIT_MEM_STATE, write dst.
deploy_render_valkey_conf() {
  local src="$1" dst="$2"
  local dest_dir maxmem content
  if [[ ! -f "${src}" ]]; then
    printf 'render-templates.sh: valkey.conf template not found: %s\n' "${src}" >&2
    return 1
  fi
  dest_dir="$(dirname "${dst}")"
  mkdir -p "${dest_dir}"
  maxmem="$(deploy_state_maxmemory_for_limit "${APP_LIMIT_MEM_STATE:-}")"
  content="$(cat "${src}")"
  content="${content//\{\{APP_VALKEY_MAXMEMORY\}\}/${maxmem}}"
  printf '%s\n' "${content}" > "${dst}"
}

# MemoryMax= for [Service]. Accepts one argument (memory) or the legacy
# two-argument form (cpu, memory); the CPU argument is ignored.
# Empty → no output. N% → MemoryMax=N%. Byte sizes (512m, 1g, 2G, 512mb) →
# MemoryMax= with the unit letter uppercased (K, M, G, T). Other strings → no output.
deploy_compute_limits_block() {
  local mem unit_upper num unit
  if [[ $# -ge 2 ]]; then
    mem="$2"
  else
    mem="${1:-}"
  fi
  if [[ -z "${mem}" ]]; then
    return 0
  fi
  if [[ "${mem}" =~ ^([0-9]+)%$ ]]; then
    printf 'MemoryMax=%s\n' "${mem}"
    return 0
  fi
  if [[ "${mem}" =~ ^([0-9]+)([kKmMgGtT])[bB]?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    unit_upper="$(printf '%s' "${unit}" | tr '[:lower:]' '[:upper:]')"
    printf 'MemoryMax=%s%s\n' "${num}" "${unit_upper}"
  fi
}

deploy_prepare_proxy_tls_mounts() {
  if [[ "${APP_TLS_MODE:-}" == "manual" ]]; then
    export APP_TLS_CERT_IN_CONTAINER="/etc/app-tls/cert.pem"
    export APP_TLS_KEY_IN_CONTAINER="/etc/app-tls/key.pem"
    export APP_PROXY_TLS_MOUNTS=$'Volume='"${TLS_DIR}"$'/cert.pem:'"${APP_TLS_CERT_IN_CONTAINER:-}"$':ro,Z\nVolume='"${TLS_DIR}"$'/key.pem:'"${APP_TLS_KEY_IN_CONTAINER:-}"$':ro,Z\n'
  else
    export APP_PROXY_TLS_MOUNTS=""
  fi
}

deploy_render_template_file() {
  local in_file="$1" out_file="$2" content k v
  content="$(cat "${in_file}")"
  local keys=(
    APP_DOMAIN APP_ACME_EMAIL APP_TLS_MODE
    APP_HTTP_PORT APP_HTTPS_PORT
    APP_PROXY_IMAGE APP_FE_IMAGE APP_BE_IMAGE APP_DB_IMAGE APP_STATE_IMAGE APP_WORKER_IMAGE APP_FS_IMAGE
    APP_NETWORK APP_NETWORK_SUBNET APP_NETWORK_GATEWAY APP_TRUSTED_PROXY_CIDRS APP_BE_PORT APP_FE_PORT APP_DB_PORT APP_VALKEY_PORT APP_VALKEY_SECRET_NAME
    APP_FS_S3_PORT APP_FS_BUCKET APP_FS_SECRET_NAME APP_FS_ACCESS_KEY APP_FS_SECRET_KEY
    APP_CORS_ORIGINS
    APP_POSTGRES_DB APP_POSTGRES_USER APP_POSTGRES_PASSWORD APP_DB_PASSWORD APP_ADMIN_DB_USERNAME APP_ADMIN_DB_PASSWORD APP_SEED_DEMO_DATA
    APP_GITHUB_TOKEN APP_INSTALL_REPO
    APP_STATE_DIR APP_JWT_SECRET_NAME APP_VALKEY_PASSWORD
    APP_PGADMIN_IMAGE APP_PGADMIN_HOST APP_PGADMIN_PORT APP_PGADMIN_EMAIL
    APP_DATA_PATH APP_FS_DATA_PATH APP_FS_VOLUME_MAX_GB APP_FS_VOLUME_MAX
    APP_LIMIT_MEM_STATE
  )
  for k in "${keys[@]}"; do
    v="${!k-}"
    content="${content//\{\{${k}\}\}/${v}}"
  done
  content="${content//\{\{APP_DATA_VOLUME_OPTIONS_DB\}\}/${APP_DATA_VOLUME_OPTIONS_DB-}}"
  content="${content//\{\{APP_DATA_VOLUME_OPTIONS_FS\}\}/${APP_DATA_VOLUME_OPTIONS_FS-}}"
  content="${content//\{\{APP_DATA_VOLUME_OPTIONS_STATE\}\}/${APP_DATA_VOLUME_OPTIONS_STATE-}}"
  content="${content//\{\{APP_PODMANARGS_LIMITS_PROXY\}\}/${APP_PODMANARGS_LIMITS_PROXY-}}"
  content="${content//\{\{APP_PODMANARGS_LIMITS_FE\}\}/${APP_PODMANARGS_LIMITS_FE-}}"
  content="${content//\{\{APP_PODMANARGS_LIMITS_BE\}\}/${APP_PODMANARGS_LIMITS_BE-}}"
  content="${content//\{\{APP_PODMANARGS_LIMITS_DB\}\}/${APP_PODMANARGS_LIMITS_DB-}}"
  content="${content//\{\{APP_PODMANARGS_LIMITS_STATE\}\}/${APP_PODMANARGS_LIMITS_STATE-}}"
  content="${content//\{\{APP_PODMANARGS_LIMITS_WORKER\}\}/${APP_PODMANARGS_LIMITS_WORKER-}}"
  content="${content//\{\{APP_PODMANARGS_LIMITS_FS\}\}/${APP_PODMANARGS_LIMITS_FS-}}"
  content="${content//\{\{APP_PROXY_TLS_MOUNTS\}\}/${APP_PROXY_TLS_MOUNTS-}}"
  content="${content//\{\{APP_TLS_SITE_BLOCK\}\}/${APP_TLS_SITE_BLOCK-}}"
  content="${content//\{\{APP_CADDY_EMAIL_BLOCK\}\}/${APP_CADDY_EMAIL_BLOCK-}}"
  content="${content//\{\{APP_CADDY_GLOBAL_OPTIONS\}\}/${APP_CADDY_GLOBAL_OPTIONS-}}"
  content="${content//\{\{APP_HTTP_REDIRECT_BLOCK\}\}/${APP_HTTP_REDIRECT_BLOCK-}}"
  printf "%s\n" "${content}" > "${out_file}"
}

deploy_render_caddyfile() {
  local base_tpl="${PROXY_DIR}/Caddyfile.template" site_tpl=""
  if [[ "${APP_TLS_MODE:-}" == "manual" ]]; then
    export APP_CADDY_GLOBAL_OPTIONS="auto_https off"
    export APP_HTTP_REDIRECT_BLOCK=":${APP_HTTP_PORT:-} {
	redir https://${APP_DOMAIN:-}{uri} permanent
}"
    export APP_TLS_CERT_IN_CONTAINER="/etc/app-tls/cert.pem"
    export APP_TLS_KEY_IN_CONTAINER="/etc/app-tls/key.pem"
    site_tpl="${PROXY_DIR}/Caddyfile.site.manual.template"
    export APP_TLS_SITE_BLOCK="$(cat "${site_tpl}")"
    export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_TLS_CERT_IN_CONTAINER\}\}/${APP_TLS_CERT_IN_CONTAINER:-}}"
    export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_TLS_KEY_IN_CONTAINER\}\}/${APP_TLS_KEY_IN_CONTAINER:-}}"
  else
    export APP_CADDY_GLOBAL_OPTIONS="email ${APP_ACME_EMAIL:-admin@example.com}"
    export APP_HTTP_REDIRECT_BLOCK="http://${APP_DOMAIN:-}:${APP_HTTP_PORT:-} {
	redir https://${APP_DOMAIN:-}{uri} permanent
}"
    site_tpl="${PROXY_DIR}/Caddyfile.site.letsencrypt.template"
    export APP_TLS_SITE_BLOCK="$(cat "${site_tpl}")"
  fi
  export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_DOMAIN\}\}/${APP_DOMAIN:-}}"
  export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_HTTP_PORT\}\}/${APP_HTTP_PORT:-}}"
  export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_HTTPS_PORT\}\}/${APP_HTTPS_PORT:-}}"
  export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_BE_PORT\}\}/${APP_BE_PORT:-}}"
  export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_FE_PORT\}\}/${APP_FE_PORT:-}}"
  export APP_TLS_SITE_BLOCK="${APP_TLS_SITE_BLOCK//\{\{APP_FS_S3_PORT\}\}/${APP_FS_S3_PORT:-}}"
  deploy_render_template_file "${base_tpl}" "${APP_STATE_DIR:-}/reverse-proxy/Caddyfile"
  log "OK: rendered Caddyfile to ${APP_STATE_DIR:-}/reverse-proxy/Caddyfile"
}

deploy_render_quadlets() {
  export APP_LIMIT_MEM_STATE="${APP_LIMIT_MEM_STATE:-10%}"
  export APP_PODMANARGS_LIMITS_PROXY
  export APP_PODMANARGS_LIMITS_FE
  export APP_PODMANARGS_LIMITS_BE
  export APP_PODMANARGS_LIMITS_DB
  export APP_PODMANARGS_LIMITS_STATE
  export APP_PODMANARGS_LIMITS_WORKER
  export APP_PODMANARGS_LIMITS_FS
  APP_PODMANARGS_LIMITS_PROXY="$(deploy_compute_limits_block "${APP_LIMIT_MEM_PROXY-}")"
  APP_PODMANARGS_LIMITS_FE="$(deploy_compute_limits_block "${APP_LIMIT_MEM_FE-}")"
  APP_PODMANARGS_LIMITS_BE="$(deploy_compute_limits_block "${APP_LIMIT_MEM_BE-}")"
  APP_PODMANARGS_LIMITS_DB="$(deploy_compute_limits_block "${APP_LIMIT_MEM_DB-}")"
  APP_PODMANARGS_LIMITS_STATE="$(deploy_compute_limits_block "${APP_LIMIT_MEM_STATE-}")"
  APP_PODMANARGS_LIMITS_WORKER="$(deploy_compute_limits_block "${APP_LIMIT_MEM_WORKER-}")"
  APP_PODMANARGS_LIMITS_FS="$(deploy_compute_limits_block "${APP_LIMIT_MEM_FS-}")"
  export APP_FS_VOLUME_MAX_GB="${APP_FS_VOLUME_MAX_GB:-100}"
  export APP_FS_VOLUME_MAX="${APP_FS_VOLUME_MAX_GB:-}"
  # Compute bind-mount options for DB/FS/state volumes when custom data paths are set
  export APP_DATA_VOLUME_OPTIONS_DB=""
  export APP_DATA_VOLUME_OPTIONS_FS=""
  export APP_DATA_VOLUME_OPTIONS_STATE=""
  local fs_data_path="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
  # "system" places fs_data on the default named volume while db/state stay on APP_DATA_PATH.
  [[ "${fs_data_path}" == "system" ]] && fs_data_path=""
  if [[ -n "${APP_DATA_PATH:-}" ]]; then
    APP_DATA_VOLUME_OPTIONS_DB=$'Driver=local\nOptions=type=none,device='"${APP_DATA_PATH:-}/db"$',o=bind'
    APP_DATA_VOLUME_OPTIONS_STATE=$'Driver=local\nOptions=type=none,device='"${APP_DATA_PATH:-}/state"$',o=bind'
  fi
  if [[ -n "${fs_data_path}" ]]; then
    APP_DATA_VOLUME_OPTIONS_FS=$'Driver=local\nOptions=type=none,device='"${fs_data_path}/fs"$',o=bind'
  fi
  deploy_prepare_proxy_tls_mounts
  deploy_render_template_file "${TPL_DIR}/network.network" "${APP_QUADLET_DIR:-}/network.network"
  deploy_render_template_file "${TPL_DIR}/db.volume" "${APP_QUADLET_DIR:-}/db.volume"
  deploy_render_template_file "${TPL_DIR}/fs.volume" "${APP_QUADLET_DIR:-}/fs.volume"
  deploy_render_template_file "${TPL_DIR}/state.volume" "${APP_QUADLET_DIR:-}/state.volume"
  deploy_render_template_file "${TPL_DIR}/state.container" "${APP_QUADLET_DIR:-}/state.container"
  deploy_render_template_file "${TPL_DIR}/fs.container" "${APP_QUADLET_DIR:-}/fs.container"
  deploy_render_template_file "${TPL_DIR}/db.container" "${APP_QUADLET_DIR:-}/db.container"
  deploy_render_template_file "${TPL_DIR}/be.container" "${APP_QUADLET_DIR:-}/be.container"
  deploy_render_template_file "${TPL_DIR}/worker.container" "${APP_QUADLET_DIR:-}/worker.container"
  deploy_render_template_file "${TPL_DIR}/fe.container" "${APP_QUADLET_DIR:-}/fe.container"
  deploy_render_template_file "${TPL_DIR}/reverse-proxy.container" "${APP_QUADLET_DIR:-}/reverse-proxy.container"
  if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
    deploy_render_template_file "${TPL_DIR}/pgadmin.container" "${APP_QUADLET_DIR:-}/pgadmin.container"
    local pgadmin_tpl="${DEPLOY_KIT_DIR}/pgadmin/servers.json.template" pgadmin_out="${APP_STATE_DIR:-}/pgadmin/servers.json"
    if [[ -f "${pgadmin_tpl}" ]]; then
      local servers_content
      servers_content="$(cat "${pgadmin_tpl}")"
      servers_content="${servers_content//\{\{APP_ADMIN_DB_USERNAME\}\}/${APP_ADMIN_DB_USERNAME:-evidba}}"
      printf "%s\n" "${servers_content}" > "${pgadmin_out}"
      log "OK: rendered pgAdmin servers.json"
    fi
  else
    [[ -f "${APP_QUADLET_DIR:-}/pgadmin.container" ]] && rm "${APP_QUADLET_DIR:-}/pgadmin.container"
  fi
  log "OK: rendered Quadlet files into ${APP_QUADLET_DIR:-}"
}

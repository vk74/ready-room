#!/usr/bin/env bash
#
# Version: 0.27.2
# Purpose: Shared template rendering functions for application deploy and update processes.
# Deployment file: render-templates.sh
# Logic: Sourced by install.sh and apply-update.sh. Provides functions to render quadlet templates,
#        Caddyfile, compute resource limit blocks, apply the evi-state RAM profile, and render valkey.conf.
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

# Host RAM in GiB (integer MemTotal_kB / 1024 / 1024). Half-open bounds.
# APP_HOST_MEM_GIB: test hook — if set and non-empty, return that value instead.
deploy_host_mem_gib() {
  if [[ -n "${APP_HOST_MEM_GIB:-}" ]]; then
    printf '%s\n' "${APP_HOST_MEM_GIB}"
    return 0
  fi
  local mem_kb
  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
  printf '%s\n' "$((mem_kb / 1024 / 1024))"
}

# < 2: print fail to stderr, return 1 (no exit). 2 ≤ x < 4: WARN, return 0. Else return 0.
deploy_check_host_mem() {
  local host_gib
  host_gib="$(deploy_host_mem_gib)"
  if [[ "${host_gib}" -lt 2 ]]; then
    printf 'host ram < 2gb (minimum 2gb). deployment stopped.\n' >&2
    return 1
  fi
  if [[ "${host_gib}" -lt 4 ]]; then
    printf 'WARN: ram 2-4gb: suitable for testing, not recommended for production\n' >&2
  fi
  return 0
}

# Prints test|compact|medium|large|xlarge from host_gib (stdout only).
# May be called with host_gib 0/1 in tests; the hard-stop is deploy_check_host_mem, not pick.
deploy_pick_state_profile() {
  local host_gib
  host_gib="$(deploy_host_mem_gib)"
  if [[ "${host_gib}" -lt 4 ]]; then
    printf '%s\n' "test"
  elif [[ "${host_gib}" -lt 8 ]]; then
    printf '%s\n' "compact"
  elif [[ "${host_gib}" -lt 16 ]]; then
    printf '%s\n' "medium"
  elif [[ "${host_gib}" -lt 32 ]]; then
    printf '%s\n' "large"
  else
    printf '%s\n' "xlarge"
  fi
}

# Reverse-map a persisted container limit to a profile name.
# 256m→test, 512m→compact, 1g→medium, 2g→large, 4g→xlarge; else deploy_pick_state_profile.
deploy_state_profile_name_for_limit() {
  case "${1:-}" in
    256m) printf '%s\n' "test" ;;
    512m) printf '%s\n' "compact" ;;
    1g)   printf '%s\n' "medium" ;;
    2g)   printf '%s\n' "large" ;;
    4g)   printf '%s\n' "xlarge" ;;
    *)    deploy_pick_state_profile ;;
  esac
}

# test→256m, compact→512m, medium→1g, large→2g, xlarge→4g, unknown→256m.
deploy_state_container_limit_for_profile() {
  case "${1:-}" in
    test)    printf '%s\n' "256m" ;;
    compact) printf '%s\n' "512m" ;;
    medium)  printf '%s\n' "1g" ;;
    large)   printf '%s\n' "2g" ;;
    xlarge)  printf '%s\n' "4g" ;;
    *)       printf '%s\n' "256m" ;;
  esac
}

# Derive Valkey maxmemory from the current container limit (not stored in evi.env).
# empty / 256m → 50mb (no warn). Unknown non-empty → 50mb + WARN mentioning APP_LIMIT_MEM_STATE.
deploy_state_maxmemory_for_limit() {
  local limit="${1:-}"
  case "${limit}" in
    "")    printf '%s\n' "50mb" ;;
    256m)  printf '%s\n' "50mb" ;;
    512m)  printf '%s\n' "200mb" ;;
    1g)    printf '%s\n' "400mb" ;;
    2g)    printf '%s\n' "800mb" ;;
    4g)    printf '%s\n' "1600mb" ;;
    8g)    printf '%s\n' "4g" ;;
    *)
      printf 'WARN: unknown APP_LIMIT_MEM_STATE=%s; using maxmemory 50mb\n' "${limit}" >&2
      printf '%s\n' "50mb"
      ;;
  esac
}

# If APP_LIMIT_MEM_STATE is already set: do not overwrite, return 1.
# If it is empty: pick a profile, export APP_LIMIT_MEM_STATE, return 0.
deploy_apply_state_memory_profile() {
  if [[ -n "${APP_LIMIT_MEM_STATE:-}" ]]; then
    return 1
  fi
  local profile limit
  profile="$(deploy_pick_state_profile)"
  limit="$(deploy_state_container_limit_for_profile "${profile}")"
  export APP_LIMIT_MEM_STATE="${limit}"
  return 0
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

deploy_compute_limits_block() {
  local cpu="$1" mem="$2" out=""
  [[ -n "${cpu}" ]] && out+=$'PodmanArgs=--cpus='"${cpu}"$'\n'
  [[ -n "${mem}" ]] && out+=$'PodmanArgs=--memory='"${mem}"$'\n'
  printf "%s" "${out}"
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
  export APP_PODMANARGS_LIMITS_PROXY
  export APP_PODMANARGS_LIMITS_FE
  export APP_PODMANARGS_LIMITS_BE
  export APP_PODMANARGS_LIMITS_DB
  export APP_PODMANARGS_LIMITS_STATE
  export APP_PODMANARGS_LIMITS_WORKER
  export APP_PODMANARGS_LIMITS_FS
  APP_PODMANARGS_LIMITS_PROXY="$(deploy_compute_limits_block "${APP_LIMIT_CPU_PROXY-}" "${APP_LIMIT_MEM_PROXY-}")"
  APP_PODMANARGS_LIMITS_FE="$(deploy_compute_limits_block "${APP_LIMIT_CPU_FE-}" "${APP_LIMIT_MEM_FE-}")"
  APP_PODMANARGS_LIMITS_BE="$(deploy_compute_limits_block "${APP_LIMIT_CPU_BE-}" "${APP_LIMIT_MEM_BE-}")"
  APP_PODMANARGS_LIMITS_DB="$(deploy_compute_limits_block "${APP_LIMIT_CPU_DB-}" "${APP_LIMIT_MEM_DB-}")"
  APP_PODMANARGS_LIMITS_STATE="$(deploy_compute_limits_block "${APP_LIMIT_CPU_STATE-}" "${APP_LIMIT_MEM_STATE-}")"
  APP_PODMANARGS_LIMITS_WORKER="$(deploy_compute_limits_block "${APP_LIMIT_CPU_WORKER-}" "${APP_LIMIT_MEM_WORKER-}")"
  APP_PODMANARGS_LIMITS_FS="$(deploy_compute_limits_block "${APP_LIMIT_CPU_FS-}" "${APP_LIMIT_MEM_FS-}")"
  export APP_FS_VOLUME_MAX_GB="${APP_FS_VOLUME_MAX_GB:-100}"
  export APP_FS_VOLUME_MAX="${APP_FS_VOLUME_MAX_GB:-}"
  # Compute bind-mount options for DB/FS/state volumes when custom data paths are set
  export APP_DATA_VOLUME_OPTIONS_DB=""
  export APP_DATA_VOLUME_OPTIONS_FS=""
  export APP_DATA_VOLUME_OPTIONS_STATE=""
  local fs_data_path="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
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

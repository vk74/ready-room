#!/usr/bin/env bash
#
# Version: 0.27.2
# Purpose: Phase 4/5 of an application update: replace kits, merge env and secrets, update image tags, render templates, reload systemd, and refresh the disk monitor. Takes APP_HOME as $1. Does not pull images.
# File: update-4-files-and-config.sh
#
# Changes in v0.27.2:
# - Sync APP_INSTALL_REPO in config/app.env from app.template.env during update_all_image_tags().
#
# Changes in v0.26.3:
# - Kit and configuration phase. update_all_image_tags appends each replaced image ref to replaced-infra-images.list for phase 5.
# - pull_images is retained and is not called. Phase 1 already verified or pulled every required image.
# - Scripts under the installed scripts directory are made executable recursively. Rendering sources scripts/lib/render-templates.sh, then scripts/render-templates.sh.
# - The disk monitor script is scripts/admin/check-disk-space.sh.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
init_update_context "${1:?usage: update-4-files-and-config.sh <APP_HOME>}" "$SCRIPT_DIR"

# --- Replace deploy kit (runs AFTER a successful migration + schema-health) ---
replace_deploy_kit() {
  log_tee "replacing deploy kit..."

  local item
  for item in "${APP_HOME}"/* "${APP_HOME}"/.[!.]* "${APP_HOME}"/..?*; do
    [[ ! -e "$item" ]] && continue
    local basename
    basename=$(basename "$item")
    if [[ "$basename" == "config" ]] || [[ "$basename" == "update" ]]; then
      continue
    fi
    rm -rf "$item"
  done

  cp -a "${NEW_DEPLOY_DIR}/"* "${APP_HOME}/" 2>/dev/null || true
  for item in "${NEW_DEPLOY_DIR}"/.[!.]* "${NEW_DEPLOY_DIR}"/..?*; do
    [[ -e "$item" ]] && cp -a "$item" "${APP_HOME}/" 2>/dev/null || true
  done

  if [[ -f "${UPDATE_VERSION_DIR}/package.json" ]]; then
    cp -a "${UPDATE_VERSION_DIR}/package.json" "${APP_HOME}/package.json"
    log_tee " ${SYM_OK} package.json updated"
  fi

  chmod +x "${APP_HOME}/install.sh" 2>/dev/null || true
  if [[ -d "${APP_HOME}/scripts" ]]; then
    find "${APP_HOME}/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  fi
  log_tee " ${SYM_OK} new deploy kit copied to ${APP_HOME}"
}

# --- Replace update kit ---
replace_update_kit() {
  log_tee "replacing update kit..."

  if [[ -d "${APP_HOME}/update" ]]; then
    rm -rf "${APP_HOME}/update"
  fi
  if [[ -d "$NEW_UPDATE_DIR" ]]; then
    cp -a "$NEW_UPDATE_DIR" "${APP_HOME}/update"
    if [[ -d "${APP_HOME}/update/scripts" ]]; then
      chmod +x "${APP_HOME}/update/scripts/"*.sh 2>/dev/null || true
    fi
    log_tee " ${SYM_OK} new update kit copied to ${APP_HOME}/update"
  else
    log_tee " ${SYM_WARN} no update kit in staging; skipping"
  fi
}

# --- Merge env (add missing vars from template, preserve existing) ---
merge_env() {
  local template="${APP_HOME}/env/app.template.env"
  local target="${CONFIG_DIR}/app.env"

  if [[ ! -f "$template" ]]; then
    log_tee " ${SYM_WARN} app.template.env not found at ${template}; skipping env merge"
    return
  fi
  if [[ ! -f "$target" ]]; then
    log_tee " ${SYM_WARN} app.env not found at ${target}; skipping env merge"
    return
  fi

  log_tee "merging environment variables..."
  local added=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    local key="${line%%=*}"
    [[ -z "$key" ]] && continue

    if ! grep -q "^${key}=" "$target" 2>/dev/null; then
      echo "$line" >> "$target"
      log_tee "   added: ${key}"
      added=$((added + 1))
    fi
  done < "$template"

  if [[ $added -eq 0 ]]; then
    log_tee " ${SYM_OK} env merge: no new variables"
  else
    log_tee " ${SYM_OK} env merge: ${added} variable(s) added"
  fi
}

# --- Merge secrets (add missing keys from template, never overwrite existing — including empty) ---
merge_secrets() {
  local template=""
  if [[ -f "${APP_HOME}/env/app.secrets.template.env" ]]; then
    template="${APP_HOME}/env/app.secrets.template.env"
  elif [[ -f "${APP_HOME}/app.secrets.template.env" ]]; then
    template="${APP_HOME}/app.secrets.template.env"
  fi
  local target="${CONFIG_DIR}/app.secrets.env"

  if [[ -z "$template" ]]; then
    log_tee " ${SYM_WARN} app.secrets.template.env not found; skipping secrets merge"
    return
  fi
  if [[ ! -f "$target" ]]; then
    log_tee " ${SYM_WARN} app.secrets.env not found at ${target}; skipping secrets merge"
    return
  fi

  log_tee "merging secrets (missing keys only)..."
  local added=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    local key="${line%%=*}"
    [[ -z "$key" ]] && continue
    [[ "$key" == "$line" ]] && continue

    if ! grep -q "^${key}=" "$target" 2>/dev/null; then
      echo "$line" >> "$target"
      log_tee "   added: ${key}"
      added=$((added + 1))
    fi
  done < "$template"

  if [[ $added -eq 0 ]]; then
    log_tee " ${SYM_OK} secrets merge: no new keys"
  else
    log_tee " ${SYM_OK} secrets merge: ${added} key(s) added"
  fi
}

# --- Read version from EVI_HOME/package.json ---
read_package_json_version() {
  local field="$1"
  local pkg="${APP_HOME}/package.json"
  if [[ ! -f "$pkg" ]]; then
    echo ""
    return
  fi
  grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$pkg" 2>/dev/null | \
    sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1 || echo ""
}

# --- Update ALL image tags in config/app.env from package.json ---
update_all_image_tags() {
  local env_file="${CONFIG_DIR}/app.env"
  if [[ ! -f "$env_file" ]]; then
    log_tee " ${SYM_WARN} app.env not found, skipping image tag update"
    return
  fi
  local pkg="${APP_HOME}/package.json"
  if [[ ! -f "$pkg" ]]; then
    log_tee " ${SYM_WARN} package.json not found, skipping image tag update"
    return
  fi

  log_tee "updating container image tags in app.env..."
  : > "$REPLACED_INFRA_FILE"

  # Internal images: tag from package.json. Repository comes from app.template.env
  # when that line is set, so a non-canonical registry is reset and queued for prune.
  local ver
  ver=$(read_package_json_version "version")
  if [[ -n "$ver" ]]; then
    local env_key base_ref current_line current_val current_repo tpl_line tpl_val
    local template="${APP_HOME}/env/app.template.env"
    for env_key in APP_FE_IMAGE APP_BE_IMAGE APP_DB_IMAGE APP_WORKER_IMAGE; do
      current_line=$(grep "^${env_key}=" "$env_file" 2>/dev/null | head -1) || true
      [[ -z "$current_line" ]] && continue
      current_val="${current_line#*=}"
      current_val=$(echo "$current_val" | tr -d '"' | tr -d "'")
      tpl_val=""
      if [[ -f "$template" ]]; then
        tpl_line=$(grep "^${env_key}=" "$template" 2>/dev/null | head -1) || true
        tpl_val="${tpl_line#*=}"
        tpl_val=$(echo "$tpl_val" | tr -d '"' | tr -d "'")
      fi
      if [[ -n "$tpl_val" ]]; then
        base_ref="${tpl_val%:*}"
      else
        base_ref="${current_val%:*}"
      fi
      current_repo="${current_val%:*}"
      if [[ -n "$current_val" && "$current_repo" != "$base_ref" ]]; then
        log_tee " ${SYM_WARN} ${env_key} repository ${current_repo} differs from canonical ${base_ref}; resetting to ${base_ref}:${ver}"
        REPLACED_INFRA_IMAGES+=("$current_val")
        printf '%s\n' "$current_val" >> "$REPLACED_INFRA_FILE"
      fi
      sed -i "s|^${env_key}=.*|${env_key}=${base_ref}:${ver}|" "$env_file"
      log_tee "   ${env_key}=${base_ref}:${ver}"
    done
  fi

  # External images: replace with full ref from package.json.infrastructure
  local infra_map=(
    "reverse-proxy:APP_PROXY_IMAGE"
    "state:APP_STATE_IMAGE"
    "fs:APP_FS_IMAGE"
    "pgadmin:APP_PGADMIN_IMAGE"
  )
  local entry infra_key env_key new_ref
  for entry in "${infra_map[@]}"; do
    infra_key="${entry%%:*}"
    env_key="${entry##*:}"
    new_ref=$(read_json_field_from_file "$pkg" "$infra_key")
    [[ -z "$new_ref" ]] && continue
    if grep -q "^${env_key}=" "$env_file" 2>/dev/null; then
      local old_line old_ref
      old_line=$(grep "^${env_key}=" "$env_file" 2>/dev/null | head -1) || true
      old_ref="${old_line#*=}"
      old_ref=$(echo "$old_ref" | tr -d '"' | tr -d "'")
      if [[ -n "$old_ref" && "$old_ref" != "$new_ref" ]]; then
        REPLACED_INFRA_IMAGES+=("$old_ref")
        printf '%s\n' "$old_ref" >> "$REPLACED_INFRA_FILE"
      fi
      sed -i "s|^${env_key}=.*|${env_key}=${new_ref}|" "$env_file"
      log_tee "   ${env_key}=${new_ref}"
    fi
  done

  # Distribution repository: keep config/app.env aligned with app.template.env.
  local tpl_install_repo=""
  local install_tpl="${APP_HOME}/env/app.template.env"
  if [[ -f "$install_tpl" ]]; then
    local tpl_install_line
    tpl_install_line=$(grep "^APP_INSTALL_REPO=" "$install_tpl" 2>/dev/null | head -1) || true
    tpl_install_repo="${tpl_install_line#*=}"
    tpl_install_repo=$(echo "$tpl_install_repo" | tr -d '"' | tr -d "'")
  fi
  if [[ -n "$tpl_install_repo" ]] && grep -q "^APP_INSTALL_REPO=" "$env_file" 2>/dev/null; then
    sed -i "s|^APP_INSTALL_REPO=.*|APP_INSTALL_REPO=${tpl_install_repo}|" "$env_file"
    log_tee "   APP_INSTALL_REPO=${tpl_install_repo}"
  fi

  log_tee " ${SYM_OK} image tags updated"
}

# --- Load env+secrets, source render-templates.sh, render quadlets and configs ---
load_env_and_render() {
  log_tee "loading environment and rendering templates..."

  local env_file="${CONFIG_DIR}/app.env"
  local secrets_file="${CONFIG_DIR}/app.secrets.env"

  if [[ ! -f "$env_file" ]]; then
    log_tee " ${SYM_FAIL} app.env not found at ${env_file}"
    return 1
  fi

  # Source env + secrets (secrets needed for quadlet templates with {{APP_POSTGRES_PASSWORD}} etc.)
  set +u
  # shellcheck disable=SC1090
  source "$env_file"
  if [[ -f "$secrets_file" ]]; then
    # shellcheck disable=SC1090
    source "$secrets_file"
  fi
  set -u
  # File/env token wins when the secrets key is empty so the worker quadlet gets a real value.
  load_github_token

  # Defaults for image/bucket/port/etc. come from the kit template so they
  # cannot drift from deploy-kit/env/app.template.env. Only unset keys are filled.
  local template="${APP_HOME}/env/app.template.env"
  if [[ -f "$template" ]]; then
    apply_template_defaults_for_unset "$template"
  else
    log_tee " ${SYM_WARN} app.template.env not found at ${template}; template defaults skipped"
  fi

  # Host-path values cannot live in the template (they depend on this machine).
  export APP_STATE_DIR="${APP_STATE_DIR:-${CONFIG_DIR}/state}"
  export APP_QUADLET_DIR="${APP_QUADLET_DIR:-${HOME}/.config/containers/systemd}"
  # Secret-name defaults live in app.secrets.template.env, not app.template.env.
  export APP_JWT_SECRET_NAME="${APP_JWT_SECRET_NAME:-jwt_private_key}"
  export APP_ADMIN_DB_USERNAME="${APP_ADMIN_DB_USERNAME:-evidba}"
  # Empty APP_FS_DATA_PATH in the template means "fall back to APP_DATA_PATH".
  export APP_FS_DATA_PATH="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
  # Derived alias — the template stores APP_FS_VOLUME_MAX_GB, not this name.
  export APP_FS_VOLUME_MAX="${APP_FS_VOLUME_MAX_GB:-}"

  # Ensure data directories exist when external DB/FS paths are set
  local fs_data_path="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
  if [[ -n "${APP_DATA_PATH:-}" ]]; then
    mkdir -p "${APP_DATA_PATH:-}/db" 2>/dev/null || true
    mkdir -p "${APP_DATA_PATH:-}/state" 2>/dev/null || true
  fi
  if [[ -n "${fs_data_path}" ]]; then
    mkdir -p "${fs_data_path}/fs" 2>/dev/null || true
  fi
  if [[ -n "${APP_DATA_PATH:-}" ]] || [[ -n "${fs_data_path}" ]]; then
    log_tee " ${SYM_OK} ensured data directories (db: ${APP_DATA_PATH:-default}, fs: ${fs_data_path:-default})"
  fi

  # Set path variables for render-templates.sh contract
  TPL_DIR="${APP_HOME}/quadlet-templates"
  PROXY_DIR="${APP_HOME}/reverse-proxy"
  DEPLOY_KIT_DIR="${APP_HOME}"
  TLS_DIR="${CONFIG_DIR}/tls"

  # Source shared render functions. lib/ is the current layout; the flat
  # script remains for a kit that has not been rearranged yet.
  local render_script="${APP_HOME}/scripts/lib/render-templates.sh"
  if [[ ! -f "$render_script" ]]; then
    render_script="${APP_HOME}/scripts/render-templates.sh"
  fi
  if [[ ! -f "$render_script" ]]; then
    log_tee " ${SYM_FAIL} render-templates.sh not found under ${APP_HOME}/scripts"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$render_script"
  render_validate_paths || {
    log_tee " ${SYM_FAIL} render path validation failed"
    return 1
  }

  if [[ -n "${APP_DATA_PATH:-}" ]]; then
    mkdir -p "${APP_DATA_PATH:-}/state" 2>/dev/null || true
  fi
  deploy_check_host_mem || {
    log_tee " ${SYM_FAIL} host ram < 2gb (minimum 2gb). deployment stopped."
    return 1
  }
  deploy_apply_state_memory_profile || true
  deploy_persist_limit_mem_state "${CONFIG_DIR}/app.env"
  deploy_warn_state_disk_if_needed
  deploy_render_valkey_conf "${APP_HOME}/state/valkey.conf" "${APP_STATE_DIR:-}/valkey/valkey.conf"
  local st_limit="${APP_LIMIT_MEM_STATE:-}"
  local st_maxmem st_profile
  st_maxmem="$(deploy_state_maxmemory_for_limit "${st_limit}")"
  st_profile="$(deploy_state_profile_name_for_limit "${st_limit}")"
  log_tee " ${SYM_OK} state memory profile ${st_profile} → APP_LIMIT_MEM_STATE=${st_limit} maxmemory ${st_maxmem}"

  # Clean existing quadlet files
  log_tee "   removing old quadlet files..."
  rm -f "${APP_QUADLET_DIR:-}"/evi-*.container "${APP_QUADLET_DIR:-}"/evi-*.volume "${APP_QUADLET_DIR:-}"/evi.network "${APP_QUADLET_DIR:-}"/network "${APP_QUADLET_DIR:-}"/network.network 2>/dev/null || true

  # Render all quadlets from templates
  deploy_render_quadlets
  log_tee " ${SYM_OK} quadlets rendered"

  # Render Caddyfile
  deploy_render_caddyfile
  log_tee " ${SYM_OK} Caddyfile rendered"
}

# --- daemon-reload ---
daemon_reload() {
  log_tee "reloading systemd user daemon..."
  systemctl --user daemon-reload 2>/dev/null || true
  log_tee " ${SYM_OK} daemon-reload completed"
}

# --- Pull container images ---
# Not called from main. ensure_images_present (phase 1) already verified or
# pulled every required image before services stop, so phase 4 does not pull.
pull_images() {
  log_tee "pulling container images..."
  local env_file="${CONFIG_DIR}/app.env"
  if [[ ! -f "$env_file" ]]; then
    log_tee " ${SYM_WARN} app.env not found, skipping image pull"
    return
  fi
  set +u
  # shellcheck disable=SC1090
  source "$env_file"
  set -u

  local images=()
  local var img
  for var in "${APP_PULL_IMAGE_VARS[@]}"; do
    eval "img=\${${var}:-}"
    [[ -n "$img" ]] && images+=("$img")
  done

  if [[ ${#images[@]} -eq 0 ]]; then
    log_tee " ${SYM_WARN} no container images defined in app.env"
    return
  fi
  local img
  for img in "${images[@]}"; do
    log_tee "   pulling ${img}..."
    if podman_pull_ghcr "$img" 2>&1 | tail -1; then
      log_tee " ${SYM_OK} pulled ${img}"
    else
      log_tee " ${SYM_WARN} failed to pull ${img} (will use existing if available)"
    fi
  done

  # pgAdmin (conditional)
  if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]] && [[ -n "${APP_PGADMIN_IMAGE:-}" ]]; then
    log_tee "   pulling ${APP_PGADMIN_IMAGE:-}..."
    if podman_pull_ghcr "${APP_PGADMIN_IMAGE:-}" 2>&1 | tail -1; then
      log_tee " ${SYM_OK} pulled ${APP_PGADMIN_IMAGE:-}"
    else
      log_tee " ${SYM_WARN} failed to pull ${APP_PGADMIN_IMAGE:-}"
    fi
  fi
}

# Install or refresh the disk-monitor user units from the kit templates.
refresh_disk_monitor() {
  local _dm_tpl_dir="${APP_HOME}/systemd-templates"
  local _dm_user_dir="${HOME}/.config/systemd/user"
  if [[ -d "${_dm_tpl_dir}" ]]; then
    mkdir -p "${_dm_user_dir}"
    local _dm_unit _dm_content
    for _dm_unit in disk-monitor.service disk-monitor.timer; do
      if [[ -f "${_dm_tpl_dir}/${_dm_unit}" ]]; then
        _dm_content="$(cat "${_dm_tpl_dir}/${_dm_unit}")"
        _dm_content="${_dm_content//\{\{DEPLOYMENT_DIR\}\}/${APP_HOME}}"
        printf "%s\n" "${_dm_content}" > "${_dm_user_dir}/${_dm_unit}"
      fi
    done
    chmod +x "${APP_HOME}/scripts/admin/check-disk-space.sh" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now disk-monitor.timer 2>/dev/null || true
    log_tee " ${SYM_OK} disk monitor timer installed"
  fi
}

# Errexit is off for the run sequence, matching the previous apply-update.sh main.
# Fatal steps exit explicitly so a best-effort command cannot abort the phase.
set +e

replace_deploy_kit
replace_update_kit
merge_env
merge_secrets
update_all_image_tags
load_env_and_render || exit 1
daemon_reload
refresh_disk_monitor
exit 0

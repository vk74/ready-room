#!/usr/bin/env bash
#
# Version: 0.27.1
# Purpose: Phase 5/5 of an application update: restart db, start services, verify health, prune replaced images, and finalize the update. Takes APP_HOME as $1.
# File: update-5-start-and-verify.sh
#
# Changes in v0.27.1:
# - Log an explicit confirmation line when removing the pre-migration database snapshot after verify_health.
#
# Changes in v0.26.3:
# - Start and health phase. prune_unused_images reads replaced image refs from replaced-infra-images.list when that file is present.
# - On success, removes the pre-migration snapshot and writes update-result.json status success.
# - finalize_updates_json sets lastUpdatedAt so the panel shows the update time immediately.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
init_update_context "${1:?usage: update-5-start-and-verify.sh <APP_HOME>}" "$SCRIPT_DIR"

# --- Restart DB service ---
restart_db() {
  log_tee "restarting database service..."
  local restart_output
  restart_output=$(systemctl --user restart db.service 2>&1) || {
    log_tee " ${SYM_FAIL} failed to restart db"
    [[ -n "$restart_output" ]] && log_tee "   systemctl: ${restart_output}"
    return 1
  }
  local timeout=30
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local state
    state=$(systemctl --user is-active db.service 2>/dev/null || echo "inactive")
    if [[ "$state" == "active" ]]; then
      log_tee " ${SYM_OK} db is active"
      sleep 3
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log_tee " ${SYM_FAIL} db did not become active within ${timeout}s"
  return 1
}

# --- Verify all services active (timeout 60s) ---
verify_health() {
  log_tee "verifying services..."
  sleep 10

  local units=("${APP_HEALTH_UNITS[@]}")

  # Add pgAdmin if enabled
  local env_file="${CONFIG_DIR}/app.env"
  if [[ -f "$env_file" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$env_file"
    set -u
    if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
      units+=(pgadmin)
    fi
  fi

  local timeout=60
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local all_ok=1
    for unit in "${units[@]}"; do
      local state
      state=$(systemctl --user is-active "${unit}.service" 2>/dev/null || echo "inactive")
      if [[ "$state" != "active" ]]; then
        all_ok=0
        break
      fi
    done
    if [[ $all_ok -eq 1 ]]; then
      log_tee " ${SYM_OK} all application services active"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  # Report which services failed
  for unit in "${units[@]}"; do
    local state
    state=$(systemctl --user is-active "${unit}.service" 2>/dev/null || echo "inactive")
    if [[ "$state" != "active" ]]; then
      log_tee " ${SYM_FAIL} ${unit} is ${state}"
    fi
  done
  log_tee " ${SYM_FAIL} some services are not active after ${timeout}s"
  return 1
}

# Refs recorded by update_all_image_tags in phase 4 (one image per line).
# A missing file leaves REPLACED_INFRA_IMAGES as it already is, so a caller
# can load the list and then delete the file before prune_unused_images runs.
load_replaced_infra_images() {
  [[ -f "${REPLACED_INFRA_FILE:-}" ]] || return 0
  REPLACED_INFRA_IMAGES=()
  local replaced_line=""
  while IFS= read -r replaced_line || [[ -n "${replaced_line:-}" ]]; do
    [[ -z "$replaced_line" ]] && continue
    REPLACED_INFRA_IMAGES+=("$replaced_line")
  done < "$REPLACED_INFRA_FILE"
}

# Remove unused old image tags after verify_health succeeds.
# Candidates are other tags of the 4 application repositories (plus legacy
# evi-* names in the same registry namespace) and infrastructure refs recorded
# in REPLACED_INFRA_IMAGES. Configured refs and any image a container still
# references are kept. podman rmi is never forced; this function always returns 0.
prune_unused_images() {
  log_tee "cleaning up unused old container images..."
  load_replaced_infra_images

  # Subshell so sourcing config/app.env does not leak into the caller.
  local env_file="${CONFIG_DIR}/app.env"
  local template="${APP_HOME}/env/app.template.env"
  local image_dump=""
  image_dump=$(
    set +u
    if [[ -f "$env_file" ]]; then
      # shellcheck disable=SC1090
      source "$env_file"
    fi
    if [[ -f "$template" ]]; then
      apply_template_defaults_for_unset "$template"
    fi
    printf '%s\n' \
      "${APP_FE_IMAGE-}" \
      "${APP_BE_IMAGE-}" \
      "${APP_DB_IMAGE-}" \
      "${APP_WORKER_IMAGE-}" \
      "${APP_PROXY_IMAGE-}" \
      "${APP_STATE_IMAGE-}" \
      "${APP_FS_IMAGE-}" \
      "${APP_PGADMIN_IMAGE-}"
  ) || true

  local image_vals=()
  local image_line
  while IFS= read -r image_line || [[ -n "${image_line:-}" ]]; do
    image_vals+=("$image_line")
  done <<< "$image_dump"

  local fe_image="${image_vals[0]:-}"
  local be_image="${image_vals[1]:-}"
  local db_image="${image_vals[2]:-}"
  local worker_image="${image_vals[3]:-}"
  local proxy_image="${image_vals[4]:-}"
  local state_image="${image_vals[5]:-}"
  local fs_image="${image_vals[6]:-}"
  local pgadmin_image="${image_vals[7]:-}"

  # All 8 configured refs, including pgAdmin when APP_PGADMIN_ENABLED is false,
  # so a disabled pgAdmin image is not deleted.
  local active_refs=()
  local configured
  for configured in "$fe_image" "$be_image" "$db_image" "$worker_image" \
                    "$proxy_image" "$state_image" "$fs_image" "$pgadmin_image"; do
    [[ -n "$configured" ]] && active_refs+=("$configured")
  done

  local app_repos=()
  local app_ref repo repo_prefix repo_leaf
  for app_ref in "$fe_image" "$be_image" "$db_image" "$worker_image"; do
    [[ -z "$app_ref" ]] && continue
    repo="${app_ref%:*}"
    [[ -z "$repo" ]] && continue
    app_repos+=("$repo")
    if [[ "$repo" == */* ]]; then
      repo_prefix="${repo%/*}"
      repo_leaf="${repo##*/}"
      if [[ "$repo_leaf" != evi-* ]]; then
        app_repos+=("${repo_prefix}/evi-${repo_leaf}")
      fi
    fi
  done

  local in_use_refs=()
  local in_use_ids=()
  local pod_line
  while IFS= read -r pod_line || [[ -n "${pod_line:-}" ]]; do
    [[ -z "$pod_line" ]] && continue
    in_use_refs+=("$pod_line")
  done < <(podman ps -a --format '{{.Image}}' 2>/dev/null || true)
  while IFS= read -r pod_line || [[ -n "${pod_line:-}" ]]; do
    [[ -z "$pod_line" ]] && continue
    in_use_ids+=("$pod_line")
  done < <(podman ps -a --format '{{.ImageID}}' 2>/dev/null || true)

  local candidates=()
  local seen_refs=()
  local img_line img_ref img_id repo_part item
  local is_candidate=0 skip=0 id_a="" id_b=""
  while IFS= read -r img_line || [[ -n "${img_line:-}" ]]; do
    [[ -z "$img_line" ]] && continue
    [[ "$img_line" != *" "* ]] && continue
    img_ref="${img_line%% *}"
    img_id="${img_line#* }"
    [[ -z "$img_ref" ]] && continue
    [[ "$img_ref" == *"<none>"* ]] && continue

    repo_part="${img_ref%:*}"
    is_candidate=0
    if [[ ${#app_repos[@]} -gt 0 ]]; then
      for item in "${app_repos[@]}"; do
        if [[ "$repo_part" == "$item" ]]; then
          is_candidate=1
          break
        fi
      done
    fi
    if [[ "$is_candidate" -eq 0 && ${#REPLACED_INFRA_IMAGES[@]} -gt 0 ]]; then
      for item in "${REPLACED_INFRA_IMAGES[@]}"; do
        if [[ "$img_ref" == "$item" ]]; then
          is_candidate=1
          break
        fi
      done
    fi
    [[ "$is_candidate" -eq 0 ]] && continue

    skip=0
    if [[ ${#active_refs[@]} -gt 0 ]]; then
      for item in "${active_refs[@]}"; do
        if [[ "$img_ref" == "$item" ]]; then
          skip=1
          break
        fi
      done
    fi
    if [[ "$skip" -eq 0 && ${#in_use_refs[@]} -gt 0 ]]; then
      for item in "${in_use_refs[@]}"; do
        if [[ "$img_ref" == "$item" ]]; then
          skip=1
          break
        fi
      done
    fi
    if [[ "$skip" -eq 0 && -n "$img_id" && ${#in_use_ids[@]} -gt 0 ]]; then
      id_a="${img_id#sha256:}"
      if [[ -n "$id_a" ]]; then
        for item in "${in_use_ids[@]}"; do
          id_b="${item#sha256:}"
          [[ -z "$id_b" ]] && continue
          if [[ "$id_a" == "$id_b" || "$id_a" == "$id_b"* || "$id_b" == "$id_a"* ]]; then
            skip=1
            break
          fi
        done
      fi
    fi
    [[ "$skip" -eq 1 ]] && continue

    skip=0
    if [[ ${#seen_refs[@]} -gt 0 ]]; then
      for item in "${seen_refs[@]}"; do
        if [[ "$item" == "$img_ref" ]]; then
          skip=1
          break
        fi
      done
    fi
    [[ "$skip" -eq 1 ]] && continue

    seen_refs+=("$img_ref")
    candidates+=("$img_ref")
  done < <(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null || true)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_tee " ${SYM_OK} no unused old images to remove"
    return 0
  fi

  local removed_count=0
  local candidate_ref
  for candidate_ref in "${candidates[@]}"; do
    # No --force: Podman refuses when any container still references the image.
    if podman rmi "$candidate_ref" >/dev/null 2>&1; then
      log_tee " ${SYM_OK} removed old image ${candidate_ref}"
      removed_count=$((removed_count + 1))
    else
      log_tee " ${SYM_WARN} skipped image ${candidate_ref} (in use or could not remove)"
    fi
  done

  log_tee " ${SYM_OK} image cleanup finished (${removed_count} removed)"
  return 0
}

# --- Update updates.json after success ---
finalize_updates_json() {
  if [[ ! -f "$UPDATES_JSON" ]]; then
    return 0
  fi
  local new_version="$VERSION_DIR_NAME"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp "${UPDATES_DIR}/updates.json.XXXXXX" 2>/dev/null || true)
    if [[ -n "$tmp" ]] && jq --arg v "$new_version" --arg ts "$ts" \
        '.currentVersion = $v | .available = false | .downloaded = false | .downloadPath = "" | .lastUpdatedAt = $ts' \
        "$UPDATES_JSON" > "$tmp"; then
      mv "$tmp" "$UPDATES_JSON"
      return 0
    fi
    [[ -n "$tmp" ]] && rm -f "$tmp"
    log_tee " ${SYM_WARN} jq could not update updates.json; falling back to sed"
  fi
  sed -i "s|\"currentVersion\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"currentVersion\": \"${new_version}\"|" "$UPDATES_JSON"
  sed -i "s|\"available\"[[:space:]]*:[[:space:]]*[^,}]*|\"available\": false|" "$UPDATES_JSON"
  sed -i "s|\"downloaded\"[[:space:]]*:[[:space:]]*[^,}]*|\"downloaded\": false|" "$UPDATES_JSON"
  sed -i "s|\"downloadPath\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"downloadPath\": \"\"|" "$UPDATES_JSON"
  if grep -q '"lastUpdatedAt"' "$UPDATES_JSON" 2>/dev/null; then
    sed -i "s|\"lastUpdatedAt\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"lastUpdatedAt\": \"${ts}\"|" "$UPDATES_JSON"
  else
    sed -i "s|}[[:space:]]*$|,\n  \"lastUpdatedAt\": \"${ts}\"\n}|" "$UPDATES_JSON"
  fi
}

# --- Remove staging directory ---
cleanup_staging() {
  if [[ -d "$UPDATE_VERSION_DIR" ]]; then
    rm -rf "$UPDATE_VERSION_DIR"
    log_tee " ${SYM_OK} removed update staging ${UPDATE_VERSION_DIR}"
  fi
}

# Errexit is off for the run sequence, matching the previous apply-update.sh main.
# Fatal steps exit explicitly so a best-effort command cannot abort the phase.
set +e

restart_db || exit 1
start_services
verify_health || exit 1

# Load replaced image refs before deleting the list, then drop the snapshot.
# The dump is discarded only after a fully healthy new stack.
load_replaced_infra_images
if [[ -n "${SNAPSHOT_PATH:-}" && -f "$SNAPSHOT_PATH" ]]; then
  rm -f "$SNAPSHOT_PATH" "$SNAPSHOT_PKG_PATH"
  log_tee " ${SYM_OK} removed pre-migration database snapshot"
else
  rm -f "$SNAPSHOT_PATH" "$SNAPSHOT_PKG_PATH"
fi
rm -f "$REPLACED_INFRA_FILE"
SNAPSHOT_PATH=""
SNAPSHOT_PKG_PATH=""

prune_unused_images
finalize_updates_json
cleanup_update_lock_and_write_result "success" "0"
cleanup_staging
exit 0

#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Shared paths, logging, and helpers for the update orchestrator and the
#          five phase scripts. Sourceable library: no set -euo pipefail at top level.
#          init_update_context sets APP_HOME, sources lib/version.sh (the only
#          compare_versions definition) and lib/github-auth.sh, and derives staging paths.
# File: update-common.sh
#
# Changes in v0.26.3:
# - Initial library for the split update pipeline: logging, canonical unit lists,
#   path setup, image resolution, service start, and update-result.json writing.
# - Replaced infrastructure image refs are a file (replaced-infra-images.list) so
#   phase 5, a separate process, can prune them.
#

# Guard against double-sourcing. When executed directly, exit without redefining.
if [[ "${APP_LIB_UPDATE_COMMON_SH:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
APP_LIB_UPDATE_COMMON_SH=1

# Ensure rootless podman and systemctl --user work (Cockpit may not inherit XDG_RUNTIME_DIR)
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

# compare_versions is defined only in lib/version.sh. This library sources that file.

init_update_context() {
  local app_home="${1:-}"
  local caller_script_dir="${2:-}"
  local version_lib=""

  if [[ -z "$app_home" ]]; then
    printf 'error: APP_HOME is required\n' >&2
    exit 1
  fi
  APP_HOME="$app_home"
  export APP_HOME

  # An explicit caller directory wins. UPDATE_SCRIPTS_DIR is the fallback when
  # the caller does not pass one. Phase scripts pass their own directory so the
  # staged kit wins over an on-disk UPDATE_SCRIPTS_DIR.
  if [[ -n "$caller_script_dir" ]]; then
    UPDATE_SCRIPTS_DIR="$caller_script_dir"
  elif [[ -z "${UPDATE_SCRIPTS_DIR:-}" ]]; then
    printf 'error: caller script directory or UPDATE_SCRIPTS_DIR is required\n' >&2
    exit 1
  fi

  version_lib="${UPDATE_SCRIPTS_DIR}/lib/version.sh"
  if [[ ! -f "$version_lib" ]]; then
    printf 'error: version library missing (expected %s)\n' "$version_lib" >&2
    exit 1
  fi
  # shellcheck source=lib/version.sh
  . "$version_lib"
  # shellcheck source=lib/github-auth.sh
  . "${UPDATE_SCRIPTS_DIR}/lib/github-auth.sh"
  load_github_token

  NEW_UPDATE_DIR="$(cd "${UPDATE_SCRIPTS_DIR}/.." && pwd)"
  UPDATE_VERSION_DIR="$(cd "${NEW_UPDATE_DIR}/.." && pwd)"
  NEW_DEPLOY_DIR="${UPDATE_VERSION_DIR}/deploy"

  CONFIG_DIR="${APP_HOME}/config"
  UPDATES_DIR="${CONFIG_DIR}/updates"
  UPDATES_JSON="${UPDATES_DIR}/updates.json"
  VERSION_DIR_NAME="$(basename "$UPDATE_VERSION_DIR")"

  SNAPSHOT_PATH="${UPDATE_VERSION_DIR}/pre-update.dump"
  SNAPSHOT_PKG_PATH="${UPDATE_VERSION_DIR}/pre-update.package.json"
  REPLACED_INFRA_FILE="${UPDATE_VERSION_DIR}/replaced-infra-images.list"
}

# Pre-migration snapshot (set by pre_migration_snapshot). Kept on every
# failure path; deleted only after verify_health succeeds.
SNAPSHOT_PATH=""
SNAPSHOT_PKG_PATH=""
RESULT_WRITTEN=0

# Migrations that committed during this run (parsed from run-migrations.sh output,
# never from the audit table — restore overwrites that). APPLIED_MIG_STATE is
# "known" or "unknown"; unknown must not be treated as zero.
APPLIED_MIG_STATE="unknown"
APPLIED_MIG_LIST=""

# Canonical unit lists. Start order is NOT the reverse of stop:
#   stop:   all app/infra units in one call (db stays up for migrations/snapshot)
#   start:  state+fs first (valkey/fs must be up before the backend), then
#           app+proxy, then pgadmin when enabled
#   health: db plus every unit we start (pgadmin appended when enabled)
# pull_images uses image env vars (not unit names) — listed here so the set cannot drift.
APP_STOP_UNITS=(be fe worker state fs reverse-proxy pgadmin)
APP_START_PHASE1_UNITS=(state fs)
APP_START_PHASE2_UNITS=(be fe reverse-proxy worker)
APP_HEALTH_UNITS=(db be fe worker state fs reverse-proxy)
APP_PULL_IMAGE_VARS=(APP_PROXY_IMAGE APP_FE_IMAGE APP_BE_IMAGE APP_DB_IMAGE APP_STATE_IMAGE APP_WORKER_IMAGE APP_FS_IMAGE)

# Infrastructure image refs (repo:tag) that were replaced during update_all_image_tags().
# Phase 4 also writes them to REPLACED_INFRA_FILE; phase 5 loads that file.
REPLACED_INFRA_IMAGES=()
EXPECTED_IMAGES=()

# --- Colors ---
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
AMBER=$'\033[38;5;214m'

SYM_OK="${GREEN}[✓]${NC}"
SYM_FAIL="${RED}[✗]${NC}"
SYM_WARN="${YELLOW}[!]${NC}"


log() { printf "${CYAN}[update]${NC} %s\n" "$*"; }

info() { printf "${GREEN}info:${NC} %s\n" "$*"; }

warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }

err() { printf "${RED}error:${NC} %s\n" "$*" >&2; }

phase() {
  local num="$1" title="$2"
  printf '\n%s>> phase %s%s  %s%s%s\n' "${AMBER}${BOLD}" "${num}" "${NC}" "${CYAN}${BOLD}" "${title}" "${NC}"
  printf '%s────────────────────────────────────────────────────────%s\n' "${DIM}${CYAN}" "${NC}"
}

# --- Log to stdout only (dispatch redirects to update-output.log) ---
log_tee() {
  printf "${CYAN}[update]${NC} %s\n" "$*"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

# Database name from config/app.env.
get_postgres_db_name() {
  local db_name="maindb"
  local env_file="${CONFIG_DIR}/app.env"
  if [[ -f "$env_file" ]]; then
    local env_db
    env_db=$(grep '^APP_POSTGRES_DB=' "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    [[ -n "$env_db" ]] && db_name="$env_db"
  fi
  printf '%s' "$db_name"
}

# Count words in APPLIED_MIG_LIST (filenames have no spaces).
applied_mig_count() {
  local n=0 x
  for x in $APPLIED_MIG_LIST; do
    n=$((n + 1))
  done
  printf '%s' "$n"
}

json_applied_migrations_value() {
  if [[ "$APPLIED_MIG_STATE" != "known" ]]; then
    printf 'null'
    return
  fi
  local first=1 name
  printf '['
  for name in $APPLIED_MIG_LIST; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$(json_escape "$name")"
  done
  printf ']'
}

json_rollback_exact_value() {
  if [[ "$APPLIED_MIG_STATE" != "known" ]]; then
    printf 'null'
    return
  fi
  if [[ "$(applied_mig_count)" -eq 0 ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# --- Read a string field from a JSON file ---
# jq looks at the top level, then .infrastructure, then .updateCompatibility.
# grep is the fallback when jq is not installed.
read_json_field_from_file() {
  local file="$1"
  local field="$2"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" '(.[$f] // .infrastructure[$f] // .updateCompatibility[$f] // "") | tostring' "$file" 2>/dev/null || echo ""
    return
  fi
  grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | \
    sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1 || echo ""
}

# Read KEY from an env file. strip_tag=true drops the trailing :tag.
read_env_image_ref() {
  local file="$1"
  local key="$2"
  local strip_tag="${3:-false}"
  local line="" val=""
  [[ -f "$file" ]] || return 0
  line=$(grep "^${key}=" "$file" 2>/dev/null | head -1 || true)
  [[ -z "$line" ]] && return 0
  val="${line#*=}"
  val=$(printf '%s' "$val" | tr -d '"' | tr -d "'")
  if [[ "$strip_tag" == "true" ]]; then
    val="${val%:*}"
  fi
  printf '%s' "$val"
}

pgadmin_enabled() {
  local env_file="${CONFIG_DIR}/app.env"
  local line="" val=""
  [[ -f "$env_file" ]] || return 1
  line=$(grep "^APP_PGADMIN_ENABLED=" "$env_file" 2>/dev/null | head -1 || true)
  val="${line#*=}"
  val=$(printf '%s' "$val" | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')
  [[ "$val" == "true" ]]
}

# Resolve the new release's images from staging package.json and the staged
# template (same set download-update.sh already pulled). On failure the caller
# aborts before services are stopped.
resolve_expected_images() {
  EXPECTED_IMAGES=()
  local pkg="${UPDATE_VERSION_DIR}/package.json"
  local template="${NEW_DEPLOY_DIR}/env/app.template.env"
  local env_file="${CONFIG_DIR}/app.env"
  local ver="" base_ref="" ref="" env_key="" infra_key="" pair="" img=""
  local -a imgs=()

  ver=$(read_json_field_from_file "$pkg" "version")
  if [[ -z "$ver" ]]; then
    log_tee " ${SYM_FAIL} could not read version from ${pkg}; aborting before service stop"
    return 1
  fi

  for env_key in APP_FE_IMAGE APP_BE_IMAGE APP_DB_IMAGE APP_WORKER_IMAGE; do
    base_ref=$(read_env_image_ref "$template" "$env_key" "true")
    if [[ -z "$base_ref" ]]; then
      base_ref=$(read_env_image_ref "$env_file" "$env_key" "true")
    fi
    if [[ -z "$base_ref" ]]; then
      log_tee " ${SYM_FAIL} could not resolve repository for ${env_key}; aborting before service stop"
      return 1
    fi
    imgs+=("${base_ref}:${ver}")
  done

  local infra_pairs=(
    "reverse-proxy:APP_PROXY_IMAGE"
    "state:APP_STATE_IMAGE"
    "fs:APP_FS_IMAGE"
  )
  for pair in "${infra_pairs[@]}"; do
    infra_key="${pair%%:*}"
    env_key="${pair##*:}"
    ref=$(read_json_field_from_file "$pkg" "$infra_key")
    if [[ -z "$ref" ]]; then
      ref=$(read_env_image_ref "$template" "$env_key" "false")
    fi
    if [[ -z "$ref" ]]; then
      log_tee " ${SYM_FAIL} could not resolve infrastructure image ${infra_key}; aborting before service stop"
      return 1
    fi
    imgs+=("$ref")
  done

  if pgadmin_enabled; then
    ref=$(read_json_field_from_file "$pkg" "pgadmin")
    if [[ -z "$ref" ]]; then
      log_tee " ${SYM_FAIL} could not resolve infrastructure image pgadmin; aborting before service stop"
      return 1
    fi
    imgs+=("$ref")
  fi
  EXPECTED_IMAGES=("${imgs[@]}")
  return 0
}

# Apply KEY=VALUE defaults from app.template.env for variables that are unset.
# Already-set keys (including empty) are never overwritten — same contract as merge_env.
apply_template_defaults_for_unset() {
  local template="$1"
  local line key val isset
  [[ -f "$template" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ -z "$key" ]] && continue
    isset=""
    eval "isset=\${${key}+x}"
    if [[ -z "$isset" ]]; then
      export "${key}=${val}"
    fi
  done < "$template"
}

# --- Start services (phased: infra first, then app) ---
start_services() {
  log_tee "starting application services..."
  # Phase 1: infrastructure services (valkey/fs must be up before the backend)
  systemctl --user start "${APP_START_PHASE1_UNITS[@]}" 2>/dev/null || true
  sleep 3
  # Phase 2: application + proxy
  systemctl --user start "${APP_START_PHASE2_UNITS[@]}" 2>/dev/null || true
  # Phase 3: pgAdmin (conditional)
  local env_file="${CONFIG_DIR}/app.env"
  if [[ -f "$env_file" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$env_file"
    set -u
    if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
      systemctl --user start pgadmin 2>/dev/null || true
    fi
  fi
  log_tee " ${SYM_OK} services started"
}

# --- Remove lock and write result; update.pid is kept for UI ---
# Shape (required keys, parsed by evi-update-dispatch.sh.tpl):
#   {"status":"...","version":"...","timestamp":"...","exitCode":N}
# Optional extra keys on failure/rollback: snapshotPath, error.
# On rolled_back / rollback_failed also: appliedMigrations (array or null),
# rollbackExact (true / false / null). Dispatch greps exitCode only;
# JS treats exitCode===0 as success. Do not change that field's shape.
cleanup_update_lock_and_write_result() {
  local status="$1"
  local exit_code="${2:-0}"
  local error_msg="${3:-}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  rm -f "${UPDATES_DIR}/update.lock"
  local result_file="${UPDATES_DIR}/update-result.json"
  if command -v jq >/dev/null 2>&1; then
    local snapshot="" include_rollback=0
    if [[ -n "${SNAPSHOT_PATH:-}" && -f "$SNAPSHOT_PATH" ]]; then
      snapshot="$SNAPSHOT_PATH"
    fi
    if [[ "$status" == "rolled_back" || "$status" == "rollback_failed" ]]; then
      include_rollback=1
    fi
    local applied_json="null"
    local rollback_json="null"
    if [[ "$include_rollback" -eq 1 ]]; then
      applied_json="$(json_applied_migrations_value)"
      rollback_json="$(json_rollback_exact_value)"
    fi
    local tmp
    tmp=$(mktemp "${UPDATES_DIR}/update-result.XXXXXX" 2>/dev/null || true)
    if [[ -n "$tmp" ]] && jq -n \
        --arg status "$status" \
        --arg version "$VERSION_DIR_NAME" \
        --arg timestamp "$timestamp" \
        --argjson exitCode "$exit_code" \
        --arg error "$error_msg" \
        --arg snapshot "$snapshot" \
        --argjson appliedMigrations "$applied_json" \
        --argjson rollbackExact "$rollback_json" \
        --argjson includeRollback "$include_rollback" \
        '{status:$status, version:$version, timestamp:$timestamp, exitCode:$exitCode}
         + (if $snapshot != "" then {snapshotPath:$snapshot} else {} end)
         + (if $error != "" then {error:$error} else {} end)
         + (if $includeRollback == 1 then {appliedMigrations:$appliedMigrations, rollbackExact:$rollbackExact} else {} end)' \
        > "$tmp"; then
      mv "$tmp" "$result_file"
      RESULT_WRITTEN=1
      return 0
    fi
    [[ -n "$tmp" ]] && rm -f "$tmp"
  fi
  local extra=""
  if [[ -n "${SNAPSHOT_PATH:-}" && -f "$SNAPSHOT_PATH" ]]; then
    extra="${extra},\"snapshotPath\":\"$(json_escape "$SNAPSHOT_PATH")\""
  fi
  if [[ -n "$error_msg" ]]; then
    extra="${extra},\"error\":\"$(json_escape "$error_msg")\""
  fi
  if [[ "$status" == "rolled_back" || "$status" == "rollback_failed" ]]; then
    extra="${extra},\"appliedMigrations\":$(json_applied_migrations_value)"
    extra="${extra},\"rollbackExact\":$(json_rollback_exact_value)"
  fi
  echo "{\"status\":\"${status}\",\"version\":\"${VERSION_DIR_NAME}\",\"timestamp\":\"${timestamp}\",\"exitCode\":${exit_code}${extra}}" > "$result_file"
  RESULT_WRITTEN=1
}


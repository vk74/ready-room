#!/usr/bin/env bash
#
# Version: 0.28.7
# Purpose: Read-only pre-update inspection of an installed instance. Checks the
#   database schema version, migration audit, catalog baseline, app settings,
#   env and secrets, a template-render dry-run, and manual edits of rendered
#   files. Writes a JSON report and exits 1 on blockers, 2 on warnings, or 0
#   when the instance is clean or warnings are explicitly allowed. Schema drift
#   against the reference master schema is a blocker and is printed to stdout.
# File: verify-instance.sh
#
# Changes in v0.28.7:
# - Missing reference baseline manifest (baseline_manifest_missing) is a BLOCKER.
# - When database schema drift or schema_version_mismatch is detected, prints an
#   explicit notice that upgrades are only supported for unmodified databases
#   matching the reference master schema.
#
# Changes in v0.28.5:
# - Initial precheck: database, catalog baseline, config dry-run, rendered-file drift.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$(id -u)" ]]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

# shellcheck source=lib/version.sh
. "${SCRIPT_DIR}/lib/version.sh"
# shellcheck source=lib/schema-baseline.sh
. "${SCRIPT_DIR}/lib/schema-baseline.sh"

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'
SYM_FAIL="${RED}[✗]${NC}"
SYM_WARN="${YELLOW}[!]${NC}"

# render-templates.sh calls log; keep it defined before that file is sourced.
log() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: verify-instance.sh <APP_HOME> [options]

Options:
  --staged-dir DIR       Path to staged update directory (config/updates/<version>)
  --report-file PATH     Output JSON report path (default: <APP_HOME>/config/updates/precheck-report.json)
  --db-container NAME    Database container name (default: db)
  --db-name NAME         Database name override (default: APP_POSTGRES_DB from config/app.env, or maindb)
  --allow-warnings       Exit 0 when there are warnings but zero blockers
  --help                 Show this help and exit
EOF
}

add_finding() {
  local severity="$1"
  local code="$2"
  local object="$3"
  local message="$4"
  message="${message//$'\n'/ }"
  message="${message//$'\r'/}"
  printf '%s\t%s\t%s\t%s\n' "$severity" "$code" "$object" "$message" >> "${TMP_WORK}/findings.tsv"
  if [[ "$severity" == "BLOCKER" ]]; then
    printf " %s [BLOCKER] (%s) %s: %s\n" "${SYM_FAIL}" "$code" "$object" "$message"
  elif [[ "$severity" == "WARNING" ]]; then
    printf " %s [WARNING] (%s) %s: %s\n" "${SYM_WARN}" "$code" "$object" "$message"
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/}"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

read_json_string() {
  local file="$1"
  local field="$2"
  local val=""
  if [[ ! -f "$file" ]]; then
    printf ''
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    val="$(jq -r --arg f "$field" '.[$f] // empty | if type == "string" then . else empty end' "$file" 2>/dev/null || true)"
  fi
  if [[ -z "$val" ]]; then
    val="$(grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || true)"
  fi
  printf '%s' "$val"
}

read_package_version() {
  local pkg="$1"
  local ver=""
  if [[ ! -f "$pkg" ]]; then
    printf 'unknown'
    return 0
  fi
  ver="$(read_json_string "$pkg" "version")"
  if [[ -z "$ver" ]]; then
    printf 'unknown'
    return 0
  fi
  printf '%s' "$ver"
}

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

# Already-set keys, including empty ones, are never overwritten. Same contract
# as merge_env / apply_template_defaults_for_unset in the update scripts.
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

append_missing_keys() {
  local template="$1"
  local target="$2"
  local line key
  [[ -f "$template" && -f "$target" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    [[ -z "$key" ]] && continue
    if ! grep -q "^${key}=" "$target" 2>/dev/null; then
      printf '%s\n' "$line" >> "$target"
    fi
  done < "$template"
}

psql_query() {
  local sql="$1"
  podman exec "${DB_CONTAINER}" psql -U postgres -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 -tA -F $'\t' -c "${sql}"
}

locate_manifest() {
  local ver="$1"
  if [[ -z "$ver" ]]; then
    printf ''
    return 0
  fi
  if [[ -f "${STAGED_UPDATE_DIR}/baselines/${ver}.manifest" ]]; then
    printf '%s' "${STAGED_UPDATE_DIR}/baselines/${ver}.manifest"
    return 0
  fi
  if [[ -f "${APP_HOME}/update/baselines/${ver}.manifest" ]]; then
    printf '%s' "${APP_HOME}/update/baselines/${ver}.manifest"
    return 0
  fi
  printf ''
}

resolve_staged_paths() {
  local candidate="" download_path="" updates_json=""
  if [[ -n "${STAGED_DIR_ARG}" ]]; then
    STAGED_DIR="${STAGED_DIR_ARG}"
  else
    candidate="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    if [[ -f "${candidate}/deploy/install.sh" && -f "${candidate}/package.json" ]]; then
      STAGED_DIR="$candidate"
    else
      STAGED_DIR=""
      updates_json="${APP_HOME}/config/updates/updates.json"
      if [[ -f "$updates_json" ]]; then
        download_path="$(read_json_string "$updates_json" "downloadPath")"
        if [[ -n "$download_path" && -d "$download_path" ]]; then
          STAGED_DIR="$download_path"
        fi
      fi
      if [[ -z "$STAGED_DIR" ]]; then
        STAGED_DIR="${APP_HOME}"
      fi
    fi
  fi

  # A downloaded kit is <version>/{deploy,update,package.json}. An installed
  # home is compared with itself: deploy kit at the root, update kit under update/.
  if [[ -f "${STAGED_DIR}/deploy/install.sh" && -f "${STAGED_DIR}/package.json" ]]; then
    STAGED_DEPLOY_DIR="${STAGED_DIR}/deploy"
    STAGED_UPDATE_DIR="${STAGED_DIR}/update"
  else
    STAGED_DEPLOY_DIR="${STAGED_DIR}"
    STAGED_UPDATE_DIR="${STAGED_DIR}/update"
  fi
}

resolve_db_name() {
  local env_file line env_db
  if [[ "$DB_NAME_SET" -eq 1 ]]; then
    return 0
  fi
  DB_NAME="maindb"
  env_file="${CONFIG_DIR}/app.env"
  if [[ -f "$env_file" ]]; then
    line="$(grep '^APP_POSTGRES_DB=' "$env_file" 2>/dev/null | head -1 || true)"
    env_db="${line#APP_POSTGRES_DB=}"
    env_db="${env_db%\"}"
    env_db="${env_db#\"}"
    env_db="${env_db%\'}"
    env_db="${env_db#\'}"
    if [[ -n "$env_db" ]]; then
      DB_NAME="$env_db"
    fi
  fi
}

check_db_and_migrations() {
  local installed_base running schema_raw exists_raw failed_rows checksum_rows
  local mig_id mig_base mig_status mig_checksum mig_file sum ver mfile

  printf 'checking database and migrations...\n'
  installed_base="${INSTALLED_VERSION%%-*}"
  DB_SCHEMA_VERSION=""
  DB_REACHABLE=0

  running="$(podman container inspect "${DB_CONTAINER}" --format '{{.State.Running}}' 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
    return 0
  fi
  if ! schema_raw="$(podman exec "${DB_CONTAINER}" psql -U postgres -d "${DB_NAME}" -v ON_ERROR_STOP=1 -tAc "SELECT schema_version FROM app.instance WHERE id = 1" 2>/dev/null)"; then
    add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
    return 0
  fi
  DB_SCHEMA_VERSION="$(printf '%s' "$schema_raw" | tr -d '[:space:]')"
  DB_REACHABLE=1

  if [[ -n "$installed_base" && "$installed_base" != "unknown" && "$DB_SCHEMA_VERSION" != "$installed_base" ]]; then
    add_finding "BLOCKER" "schema_version_mismatch" "app.instance.schema_version" "Database schema_version (${DB_SCHEMA_VERSION}) does not match installed version (${installed_base})"
    SCHEMA_DRIFT_FOUND=1
  fi

  if ! exists_raw="$(psql_query "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'app' AND table_name = 'schema_migrations')")"; then
    add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
    DB_REACHABLE=0
    return 0
  fi
  exists_raw="$(printf '%s' "$exists_raw" | tr -d '[:space:]')"
  if [[ "$exists_raw" != "t" ]]; then
    return 0
  fi

  if ! failed_rows="$(psql_query "SELECT version, COALESCE(migration_file, version) FROM app.schema_migrations WHERE status = 'failed' ORDER BY version")"; then
    add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
    DB_REACHABLE=0
    return 0
  fi
  while IFS=$'\t' read -r ver mfile; do
    [[ -z "$ver" ]] && continue
    add_finding "BLOCKER" "failed_migration_present" "app.schema_migrations:${ver}" "Migration ${mfile} (${ver}) is in failed status"
  done <<< "$failed_rows"

  if ! checksum_rows="$(psql_query "SELECT version, COALESCE(checksum, ''), COALESCE(status, '') FROM app.schema_migrations WHERE status IN ('success', 'skipped') AND checksum IS NOT NULL AND checksum <> '' ORDER BY version")"; then
    add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
    DB_REACHABLE=0
    return 0
  fi
  while IFS=$'\t' read -r mig_id mig_checksum mig_status; do
    [[ -z "$mig_id" ]] && continue
    mig_base="${mig_id#m_}"
    mig_file=""
    for mig_file in "${STAGED_UPDATE_DIR}/migrations/m_${mig_base}_"*.sql "${STAGED_UPDATE_DIR}/migrations/m_${mig_base}.sql"; do
      [[ -f "$mig_file" ]] || continue
      sum="$(file_sha256 "$mig_file")"
      if [[ "$sum" != "$mig_checksum" ]]; then
        add_finding "WARNING" "migration_checksum_drift" "app.schema_migrations:${mig_id}" "Recorded checksum for ${mig_base} differs from the staged migration file"
      fi
      break
    done
  done <<< "$checksum_rows"
}

check_db_catalog_baseline() {
  local ref_manifest target_manifest target_base rows skey sval schema
  printf 'checking catalog baseline...\n'
  # One pass. break skips the remaining catalog queries and still prints the
  # standard-schema notice below when drift was already recorded.
  while :; do
  [[ "$DB_REACHABLE" -eq 1 ]] || break

  target_base="${TARGET_VERSION%%-*}"
  ref_manifest="$(locate_manifest "$DB_SCHEMA_VERSION")"
  target_manifest="$(locate_manifest "$target_base")"

  if [[ -z "$ref_manifest" ]]; then
    add_finding "BLOCKER" "baseline_manifest_missing" "baselines/${DB_SCHEMA_VERSION}.manifest" "Reference baseline manifest for version ${DB_SCHEMA_VERSION} is not present in the kit; cannot verify standard database schema"
    SCHEMA_DRIFT_FOUND=1
  else
    if ! dump_catalog_baseline "${DB_CONTAINER}" "${DB_NAME}" > "${TMP_WORK}/live.manifest"; then
      add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
      break
    fi
    if [[ -n "$target_manifest" ]]; then
      if ! compare_catalog_baselines "$ref_manifest" "${TMP_WORK}/live.manifest" "$target_manifest" > "${TMP_WORK}/catalog-findings.tsv"; then
        add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
        break
      fi
    else
      if ! compare_catalog_baselines "$ref_manifest" "${TMP_WORK}/live.manifest" > "${TMP_WORK}/catalog-findings.tsv"; then
        add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
        break
      fi
    fi
    if [[ -f "${TMP_WORK}/catalog-findings.tsv" ]]; then
      while IFS=$'\t' read -r sev code obj msg; do
        if [[ -n "${sev:-}" ]]; then
          SCHEMA_DRIFT_FOUND=1
          add_finding "$sev" "$code" "$obj" "$msg"
        fi
      done < "${TMP_WORK}/catalog-findings.tsv"
    fi
  fi

  # value is JSONB. Scalar checks use value #>> '{}' so booleans, numbers, and
  # strings compare as text. A JSON null matches an enum that contains null.
  # The SQL file is written with a heredoc redirect: bash 3.2 mis-parses this
  # regex when the same heredoc sits inside $(...).
  cat > "${TMP_WORK}/settings-check.sql" <<'SQL'
SELECT section_path || '|' || setting_name || '|' || environment::text,
       CASE
         WHEN jsonb_typeof(value) = 'null' THEN 'null'
         ELSE COALESCE(value #>> '{}', value::text)
       END,
       validation_schema::text
FROM app.app_settings
WHERE validation_schema IS NOT NULL
  AND value IS NOT NULL
  AND (
    (validation_schema->>'type' = 'boolean' AND lower(value #>> '{}') NOT IN ('true', 'false'))
    OR (validation_schema->>'type' IN ('integer', 'number') AND (value #>> '{}') !~ '^-?[0-9]+(\.[0-9]+)?$')
    OR (
      jsonb_typeof(validation_schema->'enum') = 'array'
      AND NOT (
        EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(validation_schema->'enum') AS e(val)
          WHERE e.val = (app.app_settings.value #>> '{}')
        )
        OR (
          jsonb_typeof(app.app_settings.value) = 'null'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(validation_schema->'enum') AS e(elem)
            WHERE jsonb_typeof(e.elem) = 'null'
          )
        )
      )
    )
  )
ORDER BY 1
SQL
  if ! rows="$(psql_query "$(cat "${TMP_WORK}/settings-check.sql")")"; then
    add_finding "BLOCKER" "db_unreachable" "${DB_CONTAINER}" "Database container ${DB_CONTAINER} is not running or cannot be queried"
    break
  fi
  while IFS=$'\t' read -r skey sval schema; do
    [[ -z "$skey" ]] && continue
    add_finding "BLOCKER" "setting_value_invalid" "app.app_settings:${skey}" "Current value '${sval}' violates validation_schema"
  done <<< "$rows"
  break
  done

  if [[ "$SCHEMA_DRIFT_FOUND" -eq 1 ]]; then
    printf " %s Database schema differs from the reference master schema for version %s.\n" "${SYM_FAIL}" "${DB_SCHEMA_VERSION:-unknown}"
    printf "   Upgrades are only supported for unmodified databases that match the standard master schema.\n"
    printf "   Restore the database schema to the standard state before running the update.\n"
  fi
}

# Send template writes that use the live state directory into the dry-run tree.
# Quadlet writes use APP_QUADLET_DIR, which the caller points at the dry-run
# directory. APP_STATE_DIR stays the live path so {{APP_STATE_DIR}} matches the
# installed files; only the Caddyfile and pgAdmin servers.json destinations move.
redirect_rendered_path() {
  local path="$1"
  if [[ -n "${REDIRECT_STATE_FROM:-}" && "$path" == "${REDIRECT_STATE_FROM}/"* ]]; then
    printf '%s\n' "${REDIRECT_STATE_TO}${path#${REDIRECT_STATE_FROM}}"
    return 0
  fi
  printf '%s\n' "$path"
}

install_output_redirects() {
  local fn
  eval "$(declare -f deploy_render_template_file | sed '1s/^deploy_render_template_file /_render_template_file_orig /')"
  deploy_render_template_file() {
    local in_file="$1"
    local out_file="$2"
    local dest
    dest="$(redirect_rendered_path "$out_file")"
    mkdir -p "$(dirname "$dest")"
    _render_template_file_orig "$in_file" "$dest"
  }

  fn="$(declare -f deploy_render_quadlets)"
  if [[ "$fn" != *'> "${pgadmin_out}"'* ]]; then
    printf 'render-templates.sh: pgAdmin output path was not found; refusing to render\n' >&2
    return 1
  fi
  fn="$(printf '%s\n' "$fn" | sed 's#> "${pgadmin_out}"#> "$(redirect_rendered_path "${pgadmin_out}")"#')"
  fn="$(printf '%s\n' "$fn" | sed '1s/^deploy_render_quadlets /_render_quadlets_orig /')"
  eval "$fn"
  deploy_render_quadlets() {
    _render_quadlets_orig
  }
}

# Source env files and render into out_quadlets / out_state.
# check_secrets=1 records empty secrets, JWT, and manual TLS findings.
# check_mem=1 records insufficient_host_ram when host memory can be read.
run_template_render() {
  local env_file="$1"
  local secrets_file="$2"
  local kit_dir="$3"
  local out_quadlets="$4"
  local out_state="$5"
  local check_secrets="$6"
  local check_mem="$7"
  local render_script template

  render_script="${kit_dir}/scripts/lib/render-templates.sh"
  if [[ ! -f "$render_script" ]]; then
    render_script="${kit_dir}/scripts/render-templates.sh"
  fi
  if [[ ! -f "$render_script" ]]; then
    return 1
  fi
  template="${kit_dir}/env/app.template.env"
  mkdir -p "$out_quadlets" "${out_state}/reverse-proxy" "${out_state}/valkey" "${out_state}/pgadmin"

  (
    set +u
    # shellcheck disable=SC1090
    source "$env_file"
    if [[ -f "$secrets_file" ]]; then
      # shellcheck disable=SC1090
      source "$secrets_file"
    fi
    set -u
    if [[ -f "$template" ]]; then
      apply_template_defaults_for_unset "$template"
    fi

    if [[ "$check_secrets" -eq 1 ]]; then
      sec_key=""
      sec_val=""
      for sec_key in APP_POSTGRES_PASSWORD APP_DB_PASSWORD APP_ADMIN_DB_PASSWORD APP_VALKEY_PASSWORD APP_FS_ACCESS_KEY APP_FS_SECRET_KEY; do
        sec_val="${!sec_key:-}"
        if [[ -z "$sec_val" ]]; then
          add_finding "BLOCKER" "missing_secret_or_tls" "config/app.secrets.env:${sec_key}" "Required secret ${sec_key} is empty"
        fi
      done
      if [[ "${APP_JWT_GENERATE_KEY:-}" == "false" && -z "${APP_JWT_PRIVATE_KEY_PEM_PATH:-}" && -z "${APP_JWT_PRIVATE_KEY_PEM_INLINE:-}" ]]; then
        add_finding "BLOCKER" "missing_secret_or_tls" "config/app.secrets.env:APP_JWT_PRIVATE_KEY" "APP_JWT_GENERATE_KEY is false but no JWT private key path or inline key is set"
      fi
      if [[ "${APP_TLS_MODE:-}" == "manual" ]]; then
        tls_cert="${APP_TLS_CERT_PATH:-${CONFIG_DIR}/tls/cert.pem}"
        tls_key="${APP_TLS_KEY_PATH:-${CONFIG_DIR}/tls/key.pem}"
        if [[ ! -s "$tls_cert" || ! -s "$tls_key" ]]; then
          add_finding "BLOCKER" "missing_secret_or_tls" "config/tls" "Manual TLS mode is enabled but certificate or key file is missing"
        fi
      fi
    fi

    export APP_JWT_SECRET_NAME="${APP_JWT_SECRET_NAME:-jwt_private_key}"
    export APP_ADMIN_DB_USERNAME="${APP_ADMIN_DB_USERNAME:-evidba}"
    export APP_FS_DATA_PATH="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
    export APP_FS_VOLUME_MAX="${APP_FS_VOLUME_MAX_GB:-}"
    export APP_STATE_DIR="${APP_STATE_DIR:-${CONFIG_DIR}/state}"
    export REDIRECT_STATE_FROM="$APP_STATE_DIR"
    export REDIRECT_STATE_TO="$out_state"
    export APP_QUADLET_DIR="$out_quadlets"
    export TPL_DIR="${kit_dir}/quadlet-templates"
    export PROXY_DIR="${kit_dir}/reverse-proxy"
    export DEPLOY_KIT_DIR="$kit_dir"
    export TLS_DIR="${CONFIG_DIR}/tls"

    # shellcheck disable=SC1090
    source "$render_script"
    install_output_redirects

    if [[ "$check_mem" -eq 1 ]]; then
      if [[ -f /proc/meminfo || -n "${APP_HOST_MEM_GIB:-}" ]]; then
        if ! deploy_check_host_mem; then
          add_finding "BLOCKER" "insufficient_host_ram" "host.memory" "Host RAM is below the 2 GiB minimum required"
        fi
      fi
    fi

    render_validate_paths
    deploy_apply_state_memory_profile || true
    deploy_render_valkey_conf "${kit_dir}/state/valkey.conf" "${out_state}/valkey/valkey.conf"
    deploy_render_quadlets
    deploy_render_caddyfile
  )
}

scan_unreplaced_tokens() {
  local root="$1"
  local f rel token
  [[ -d "$root" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rel="${f#"${root}/"}"
    while IFS= read -r token; do
      [[ -n "$token" ]] || continue
      add_finding "BLOCKER" "template_render_failed" "render:${rel}" "Unreplaced template placeholder ${token} in ${rel}"
    done < <(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -oE '\{\{[A-Za-z0-9_]+\}\}' | sort -u || true)
  done < <(find "${root}/quadlets" "${root}/state" -type f 2>/dev/null | sort)
}

check_config_and_render_dryrun() {
  local key known_file template secrets_template dry_root render_rc
  printf 'checking configuration and template render...\n'

  if [[ ! -f "${CONFIG_DIR}/app.env" ]]; then
    add_finding "BLOCKER" "env_syntax_error" "config/app.env" "config/app.env is missing"
    return 0
  fi
  if [[ ! -f "${CONFIG_DIR}/app.secrets.env" ]]; then
    add_finding "BLOCKER" "env_syntax_error" "config/app.secrets.env" "config/app.secrets.env is missing"
    return 0
  fi
  if ! bash -n "${CONFIG_DIR}/app.env" || ! ( set -e; source "${CONFIG_DIR}/app.env" ) >/dev/null 2>&1; then
    add_finding "BLOCKER" "env_syntax_error" "config/app.env" "config/app.env has invalid shell syntax or cannot be sourced"
    return 0
  fi
  if ! bash -n "${CONFIG_DIR}/app.secrets.env" || ! ( set -e; source "${CONFIG_DIR}/app.secrets.env" ) >/dev/null 2>&1; then
    add_finding "BLOCKER" "env_syntax_error" "config/app.secrets.env" "config/app.secrets.env has invalid shell syntax or cannot be sourced"
    return 0
  fi

  known_file="${TMP_WORK}/known-env-keys"
  : > "$known_file"
  for template in "${APP_HOME}/env/app.template.env" "${STAGED_DEPLOY_DIR}/env/app.template.env"; do
    [[ -f "$template" ]] || continue
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$template" | cut -d= -f1 >> "$known_file" || true
  done
  printf 'APP_PGADMIN_IMAGE\n' >> "$known_file"
  sort -u "$known_file" -o "$known_file"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! grep -Fxq "$key" "$known_file"; then
      add_finding "WARNING" "unknown_env_key" "config/app.env:${key}" "Custom key ${key} in config/app.env is not defined in app.template.env"
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${CONFIG_DIR}/app.env" | cut -d= -f1 | sort -u)

  dry_root="${TMP_WORK}/dryrun"
  mkdir -p "$dry_root"
  cp "${CONFIG_DIR}/app.env" "${dry_root}/app.env"
  cp "${CONFIG_DIR}/app.secrets.env" "${dry_root}/app.secrets.env"
  append_missing_keys "${STAGED_DEPLOY_DIR}/env/app.template.env" "${dry_root}/app.env"
  secrets_template=""
  if [[ -f "${STAGED_DEPLOY_DIR}/env/app.secrets.template.env" ]]; then
    secrets_template="${STAGED_DEPLOY_DIR}/env/app.secrets.template.env"
  elif [[ -f "${STAGED_DEPLOY_DIR}/app.secrets.template.env" ]]; then
    secrets_template="${STAGED_DEPLOY_DIR}/app.secrets.template.env"
  fi
  if [[ -n "$secrets_template" ]]; then
    append_missing_keys "$secrets_template" "${dry_root}/app.secrets.env"
  fi

  render_rc=0
  run_template_render "${dry_root}/app.env" "${dry_root}/app.secrets.env" "$STAGED_DEPLOY_DIR" \
    "${dry_root}/quadlets" "${dry_root}/state" 1 1 || render_rc=$?
  if [[ "$render_rc" -ne 0 ]]; then
    add_finding "BLOCKER" "template_render_failed" "render-templates.sh" "Template rendering dry-run failed"
    return 0
  fi
  scan_unreplaced_tokens "$dry_root"
}

check_rendered_files_drift() {
  local render_script current_root render_rc f base live_file rendered_caddy live_caddy
  printf 'checking rendered file drift...\n'

  render_script="${APP_HOME}/scripts/lib/render-templates.sh"
  if [[ ! -f "$render_script" ]]; then
    render_script="${APP_HOME}/scripts/render-templates.sh"
  fi
  if [[ ! -f "$render_script" || ! -d "${APP_HOME}/quadlet-templates" || ! -d "${APP_HOME}/reverse-proxy" ]]; then
    return 0
  fi

  current_root="${TMP_WORK}/current-render"
  render_rc=0
  run_template_render "${CONFIG_DIR}/app.env" "${CONFIG_DIR}/app.secrets.env" "$APP_HOME" \
    "${current_root}/quadlets" "${current_root}/state" 0 0 || render_rc=$?
  if [[ "$render_rc" -ne 0 ]]; then
    add_finding "BLOCKER" "template_render_failed" "render-templates.sh" "Template rendering dry-run failed"
    return 0
  fi

  shopt -s nullglob
  for f in "${current_root}/quadlets/"*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    live_file="${LIVE_QUADLET_DIR}/${base}"
    if [[ -f "$live_file" ]] && ! cmp -s "$f" "$live_file"; then
      add_finding "WARNING" "manual_rendered_file_edit" "quadlets/${base}" "Live quadlet ${base} has manual modifications and will be overwritten by the update"
    fi
  done
  shopt -u nullglob

  rendered_caddy="${current_root}/state/reverse-proxy/Caddyfile"
  live_caddy="${CONFIG_DIR}/state/reverse-proxy/Caddyfile"
  if [[ -f "$live_caddy" && -f "$rendered_caddy" ]] && ! cmp -s "$rendered_caddy" "$live_caddy"; then
    add_finding "WARNING" "manual_rendered_file_edit" "state/reverse-proxy/Caddyfile" "Live Caddyfile has manual modifications and will be overwritten by the update"
  fi
}

write_report() {
  local blockers warnings status timestamp items tmp_report line severity code object message first
  blockers="$(awk -F '\t' 'BEGIN { n = 0 } $1 == "BLOCKER" { n++ } END { print n + 0 }' "${TMP_WORK}/findings.tsv")"
  warnings="$(awk -F '\t' 'BEGIN { n = 0 } $1 == "WARNING" { n++ } END { print n + 0 }' "${TMP_WORK}/findings.tsv")"
  if [[ "$blockers" -gt 0 ]]; then
    status="blockers"
  elif [[ "$warnings" -gt 0 ]]; then
    status="warnings"
  else
    status="clean"
  fi
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$(dirname "$REPORT_FILE")"
  tmp_report="${TMP_WORK}/precheck-report.json"

  if command -v jq >/dev/null 2>&1; then
    items="$(jq -R -s '
      split("\n")
      | map(select(length > 0))
      | map(split("\t"))
      | map({
          severity: .[0],
          code: .[1],
          object: .[2],
          message: (.[3:] | join("\t"))
        })
    ' "${TMP_WORK}/findings.tsv")"
    jq -n \
      --arg status "$status" \
      --arg currentVersion "$INSTALLED_VERSION" \
      --arg targetVersion "$TARGET_VERSION" \
      --arg timestamp "$timestamp" \
      --argjson blockersCount "$blockers" \
      --argjson warningsCount "$warnings" \
      --argjson items "$items" \
      '{status:$status, currentVersion:$currentVersion, targetVersion:$targetVersion, timestamp:$timestamp, blockersCount:$blockersCount, warningsCount:$warningsCount, items:$items}' \
      > "$tmp_report"
  else
    {
      printf '{\n'
      printf '  "status": "%s",\n' "$(json_escape "$status")"
      printf '  "currentVersion": "%s",\n' "$(json_escape "$INSTALLED_VERSION")"
      printf '  "targetVersion": "%s",\n' "$(json_escape "$TARGET_VERSION")"
      printf '  "timestamp": "%s",\n' "$(json_escape "$timestamp")"
      printf '  "blockersCount": %s,\n' "$blockers"
      printf '  "warningsCount": %s,\n' "$warnings"
      printf '  "items": ['
      first=1
      while IFS=$'\t' read -r severity code object message; do
        [[ -z "$severity" ]] && continue
        if [[ "$first" -eq 1 ]]; then
          first=0
        else
          printf ','
        fi
        printf '{"severity":"%s","code":"%s","object":"%s","message":"%s"}' \
          "$(json_escape "$severity")" "$(json_escape "$code")" "$(json_escape "$object")" "$(json_escape "$message")"
      done < "${TMP_WORK}/findings.tsv"
      printf ']\n}\n'
    } > "$tmp_report"
  fi
  mv "$tmp_report" "$REPORT_FILE"
  printf 'precheck status=%s current=%s target=%s blockers=%s warnings=%s report=%s\n' \
    "$status" "$INSTALLED_VERSION" "$TARGET_VERSION" "$blockers" "$warnings" "$REPORT_FILE"

  if [[ "$blockers" -gt 0 ]]; then
    return 1
  fi
  if [[ "$warnings" -gt 0 && "$ALLOW_WARNINGS" -eq 0 ]]; then
    return 2
  fi
  return 0
}

APP_HOME=""
STAGED_DIR_ARG=""
REPORT_FILE=""
DB_CONTAINER="db"
DB_NAME=""
DB_NAME_SET=0
ALLOW_WARNINGS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --allow-warnings)
      ALLOW_WARNINGS=1
      shift
      ;;
    --staged-dir)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        printf 'error: --staged-dir requires a directory\n' >&2
        usage >&2
        exit 2
      fi
      STAGED_DIR_ARG="$2"
      shift 2
      ;;
    --report-file)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        printf 'error: --report-file requires a path\n' >&2
        usage >&2
        exit 2
      fi
      REPORT_FILE="$2"
      shift 2
      ;;
    --db-container)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        printf 'error: --db-container requires a name\n' >&2
        usage >&2
        exit 2
      fi
      DB_CONTAINER="$2"
      shift 2
      ;;
    --db-name)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        printf 'error: --db-name requires a name\n' >&2
        usage >&2
        exit 2
      fi
      DB_NAME="$2"
      DB_NAME_SET=1
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$APP_HOME" ]]; then
        printf 'error: unexpected argument: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      APP_HOME="$1"
      shift
      ;;
  esac
done

if [[ -z "$APP_HOME" ]]; then
  usage >&2
  exit 2
fi
if [[ ! -d "$APP_HOME" ]]; then
  printf 'error: APP_HOME is not a directory: %s\n' "$APP_HOME" >&2
  exit 2
fi
if [[ -n "$STAGED_DIR_ARG" && ! -d "$STAGED_DIR_ARG" ]]; then
  printf 'error: staged directory not found: %s\n' "$STAGED_DIR_ARG" >&2
  exit 2
fi

CONFIG_DIR="${APP_HOME}/config"
LIVE_QUADLET_DIR="${APP_QUADLET_DIR:-${HOME}/.config/containers/systemd}"
if [[ -z "$REPORT_FILE" ]]; then
  REPORT_FILE="${APP_HOME}/config/updates/precheck-report.json"
fi

resolve_staged_paths
resolve_db_name
INSTALLED_VERSION="$(read_package_version "${APP_HOME}/package.json")"
TARGET_VERSION="$(read_package_version "${STAGED_DIR}/package.json")"
DB_REACHABLE=0
SCHEMA_DRIFT_FOUND=0
DB_SCHEMA_VERSION=""

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/app-verify-instance.XXXXXX")"
trap 'rc=$?; rm -rf "${TMP_WORK}"; exit "$rc"' EXIT INT TERM
: > "${TMP_WORK}/findings.tsv"

check_db_and_migrations
check_db_catalog_baseline
check_config_and_render_dryrun
check_rendered_files_drift
write_report

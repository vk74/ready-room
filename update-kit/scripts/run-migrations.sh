#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Execute pending database migrations against the db container.
# Reads app.instance.schema_version and app.schema_migrations (checksum audit).
# Update script: run-migrations.sh
# Logic:
# - Receives DEPLOYMENT_DIR as $1 (~/evi on the server). Optional flags override
#   the migrations directory, db container name, and database name. Optional
#   --applied-list-file records each migration that commits, one basename per line.
# - Sources config/app.env for APP_POSTGRES_DB (unless --db-name is given).
# - Applies ${MIGRATIONS_DIR}/_prelude/*.sql unconditionally (idempotent helpers;
#   not recorded in the audit table and they do not change schema_version)
# - For each top-level m_<X.Y.Z>_*.sql (semantic version sort): decide apply vs
#   skip via schema_migrations checksum when an audit row exists; without an
#   audit row, skip when the DB schema_version already covers the migration
#   target (compatibility fallback for installs created from an older golden
#   master) and record the skip. Seeded audit rows from
#   db/init/16_migration_audit_seed.sql make this precise on 0.23.2+ installs.
# - Records every apply attempt in app.schema_migrations (success/failed/skipped).
# - Exits 0 if all migrations applied or none pending; non-zero on failure
#
# Changes in v0.26.3:
# - Optional --applied-list-file PATH. The file is truncated at the start of the
#   run, and each migration whose psql apply succeeds is appended by basename.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Database name is read from config/app.env.
# 
# Changes in v0.25.4:
# - Database name is read from config/app.env first, then legacy config/evi.env.
#
# Changes in v0.24.5:
# - sql_escape_literal doubles single quotes without a backslash, so a description
#   that contains a quote (m_0.24.5 mentions 'paused') can be recorded through psql.
#
# Changes in v0.23.2:
# - Source shared compare_versions from lib/version.sh (pre-release aware).
# - Optional flags: --migrations-dir, --db-container, --db-name, --help.
#   Unknown flags exit 2. Default behaviour with no flags is unchanged.
# - Apply _prelude/*.sql unconditionally before any m_*.sql (no audit rows,
#   no schema_version change). Missing _prelude is fine (older kits).
# - extract_migration_version: portable grep -E (replaces GNU-only PCRE grep)
#   so macOS/BSD rehearsal hosts extract the last schema_version assignment.
# - now_ms: portable millisecond clock (GNU date +%s%N when available, else
#   seconds * 1000) so execution_time_ms does not abort on BSD date.
# - Comment on the no-audit-row skip: seed rows make the decision precise for
#   0.23.2+ golden-master installs; version comparison stays as the fallback
#   for older installs. Safe because prelude helpers always exist and a
#   release-time rehearsal diffs the upgraded schema against the golden master.
#
# Changes in v1.6.0:
# - Release-versioned migration naming: files are m_<X.Y.Z>_<description>.sql where X.Y.Z is
#   the base version of the release that first ships the migration (no -beta/-rc suffixes).
#   Migration id in app.schema_migrations is m_<X.Y.Z> (e.g. m_0.21.8).
# - Execution order: semantic version sort of the X.Y.Z prefix (replaces integer sort).
# - Removed legacy integer naming support and LEGACY_MIGRATION_AUDIT_CUTOFF: legacy m_2..m_16
#   files were removed from the kit (minVersion raised to 0.21.7).
# - No-audit-row skip: when a migration has no schema_migrations row and the current DB
#   schema_version is already >= the migration target (fresh install from golden master),
#   the migration is skipped and a 'skipped' audit row is recorded. Prevents re-running
#   already-baked-in migrations on installations created from a newer golden master.
# - Fail (not skip) when the version in the file name and schema_version inside the SQL differ.
# - Placeholder renamed to m_0.0.0_future_migrations.sql.
#
# Changes in v1.5.0:
# - Checksum-based apply/skip via app.schema_migrations; re-apply when file content changed.
# - Record success/failed/skipped rows with schema_version_before/after, errors, execution time.
# - Legacy schema_version-only skip for migrations m_2..m_16 without audit rows.
#
# Changes in v1.4.1:
# - Run psql with ON_ERROR_STOP=1 so SQL errors fail the migration instead of
#   being masked as successful updates.
#
# Changes in v1.4.0:
# - Numeric sort by m_<N>_ prefix instead of lexical filename sort.
# - Placeholder skip updated to m_1_future_migrations.sql.
# - sed -E for portable numeric prefix extraction (BSD + GNU sed).
#
# Changes in v1.3.0:
# - Updated container name from evi-db to db in all podman exec calls.
#
# Changes in v1.2.0:
# - Removed debug instrumentation (root cause was superuser:'try' in Cockpit JS, fixed in evi-update.js v1.2.0)
#
# Changes in v1.1.0:
# - Debug: log db_name, evi-db container status, schema/table existence before reading schema_version.
#
# Changes in v1.0.0:
# - Initial implementation: schema_version comparison, lexical ordering, psql execution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_LIB="${SCRIPT_DIR}/lib/version.sh"
if [[ ! -f "${VERSION_LIB}" ]]; then
  echo "error: version library missing (expected ${VERSION_LIB})" >&2
  exit 1
fi
# shellcheck source=lib/version.sh
. "${VERSION_LIB}"

# Placeholder file (documentation only, never executed).
MIGRATION_PLACEHOLDER="m_0.0.0_future_migrations.sql"

# --- Colors ---
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

SYM_OK="${GREEN}[✓]${NC}"
SYM_FAIL="${RED}[✗]${NC}"
SYM_WARN="${YELLOW}[!]${NC}"

log() { printf "${CYAN}[update]${NC} %s\n" "$*"; }
info() { printf "${GREEN}info:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: run-migrations.sh <deployment-dir> [options]

Execute pending database migrations against the db container.

Options:
  --migrations-dir DIR   Override the migrations directory
                         (default: <deployment-dir>/update/migrations)
  --db-container NAME    Override the podman container name (default: db)
  --db-name NAME         Override the database name
                         (default: APP_POSTGRES_DB from config/app.env, or maindb)
  --applied-list-file PATH
                         Truncate PATH at start, then append the basename of
                         each migration that commits successfully
  --help                 Show this help and exit
EOF
}

# --- CLI ---
DEPLOYMENT_DIR=""
MIGRATIONS_DIR=""
DB_CONTAINER="db"
DB_NAME_OVERRIDE=""
APPLIED_LIST_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --migrations-dir)
      if [[ $# -lt 2 || -z "${2}" || "${2}" == --* ]]; then
        err "--migrations-dir requires a directory argument"
        exit 2
      fi
      MIGRATIONS_DIR="$2"
      shift 2
      ;;
    --db-container)
      if [[ $# -lt 2 || -z "${2}" || "${2}" == --* ]]; then
        err "--db-container requires a name argument"
        exit 2
      fi
      DB_CONTAINER="$2"
      shift 2
      ;;
    --db-name)
      if [[ $# -lt 2 || -z "${2}" || "${2}" == --* ]]; then
        err "--db-name requires a name argument"
        exit 2
      fi
      DB_NAME_OVERRIDE="$2"
      shift 2
      ;;
    --applied-list-file)
      if [[ $# -lt 2 || -z "${2}" || "${2}" == --* ]]; then
        err "--applied-list-file requires a path argument"
        exit 2
      fi
      APPLIED_LIST_FILE="$2"
      shift 2
      ;;
    --*)
      err "unknown flag: $1"
      exit 2
      ;;
    *)
      if [[ -n "$DEPLOYMENT_DIR" ]]; then
        err "unexpected argument: $1"
        exit 2
      fi
      DEPLOYMENT_DIR="$1"
      shift
      ;;
  esac
done

if [[ -z "$DEPLOYMENT_DIR" ]]; then
  err "usage: run-migrations.sh <deployment-dir>"
  exit 1
fi

CONFIG_DIR="${DEPLOYMENT_DIR}/config"
if [[ -z "$MIGRATIONS_DIR" ]]; then
  MIGRATIONS_DIR="${DEPLOYMENT_DIR}/update/migrations"
fi

migration_version_prefix() {
  local basename="$1"
  sed -En 's/^m_([0-9]+\.[0-9]+\.[0-9]+)_.*/\1/p' <<<"$basename"
}

migration_id_from_file() {
  local basename="$1"
  sed -En 's/^(m_[0-9]+\.[0-9]+\.[0-9]+)_.*/\1/p' <<<"$basename"
}

# Zero-padded sort key for semantic version ordering (e.g. 0.21.8 -> 000000000021000008)
migration_sort_key() {
  local version="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$version"
  printf '%06d%06d%06d' "${major:-0}" "${minor:-0}" "${patch:-0}"
}

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

# Portable millisecond timestamp. GNU date supports %N; BSD date does not
# (it emits a literal N, which would abort arithmetic under set -e).
now_ms() {
  local raw
  raw=$(date +%s%N 2>/dev/null || true)
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo $((raw / 1000000))
    return 0
  fi
  echo $(($(date +%s) * 1000))
}

extract_migration_description() {
  local file="$1"
  grep -m1 '^-- Description:' "$file" 2>/dev/null \
    | sed 's/^-- Description:[[:space:]]*//' \
    | sed 's/[[:space:]]*$//' || echo "Database migration"
}

# Last schema_version = 'X.Y.Z' assignment in the file (portable; no PCRE grep).
extract_migration_version() {
  local file="$1"
  grep -E "schema_version[[:space:]]*=[[:space:]]*'[^']+'" "$file" 2>/dev/null \
    | tail -1 | sed "s/.*schema_version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/" || echo ""
}

psql_exec() {
  local db_name="$1"
  shift
  podman exec "${DB_CONTAINER}" psql -v ON_ERROR_STOP=1 -U postgres -d "$db_name" -tAc "$*"
}

psql_exec_file() {
  local db_name="$1"
  local file="$2"
  cat "$file" | podman exec -i "${DB_CONTAINER}" psql -v ON_ERROR_STOP=1 -U postgres -d "$db_name"
}

sql_escape_literal() {
  local value="$1"
  # Bash 3.2 keeps the backslashes in ${value//\'/\'\'}. psql then
  # treats \' as a meta-command and aborts the script.
  local quote="'"
  local doubled="''"
  value="${value//$quote/$doubled}"
  printf "%s" "$value"
}

get_current_schema_version() {
  local db_name="$1"
  local version
  version=$(psql_exec "$db_name" "SELECT schema_version FROM app.instance WHERE id = 1" 2>/dev/null) || {
    err "failed to read schema_version from app.instance"
    return 1
  }
  version=$(echo "$version" | tr -d '[:space:]')
  if [[ -z "$version" ]]; then
    err "schema_version is empty in app.instance"
    return 1
  fi
  echo "$version"
}

audit_tracking_ready() {
  local db_name="$1"
  local ready
  ready=$(psql_exec "$db_name" "
    SELECT CASE WHEN EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'app'
        AND table_name = 'schema_migrations'
        AND column_name = 'migration_file'
    ) THEN 1 ELSE 0 END
  " 2>/dev/null || echo "0")
  [[ "$(echo "$ready" | tr -d '[:space:]')" == "1" ]]
}

get_migration_audit_row() {
  local db_name="$1"
  local migration_id="$2"
  if ! audit_tracking_ready "$db_name"; then
    echo ""
    return 0
  fi
  psql_exec "$db_name" \
    "SELECT COALESCE(checksum,''), COALESCE(status,'') FROM app.schema_migrations WHERE version = '$(sql_escape_literal "$migration_id")'" \
    2>/dev/null || echo ""
}

record_migration_audit() {
  local db_name="$1"
  if ! audit_tracking_ready "$db_name"; then
    return 0
  fi
  local migration_id="$2"
  local migration_file="$3"
  local description="$4"
  local checksum="$5"
  local schema_before="$6"
  local schema_after="$7"
  local status="$8"
  local error_message="${9:-}"
  local error_detail="${10:-}"
  local execution_ms="${11:-}"

  local esc_id esc_file esc_desc esc_checksum esc_before esc_after esc_status esc_err esc_detail
  esc_id=$(sql_escape_literal "$migration_id")
  esc_file=$(sql_escape_literal "$migration_file")
  esc_desc=$(sql_escape_literal "$description")
  esc_checksum=$(sql_escape_literal "$checksum")
  esc_before=$(sql_escape_literal "$schema_before")
  esc_after=$(sql_escape_literal "$schema_after")
  esc_status=$(sql_escape_literal "$status")
  esc_err=$(sql_escape_literal "$error_message")
  esc_detail=$(sql_escape_literal "$error_detail")

  local exec_sql="NULL"
  if [[ -n "$execution_ms" ]]; then
    exec_sql="$execution_ms"
  fi

  psql_exec "$db_name" "
    INSERT INTO app.schema_migrations (
        version, migration_file, description, checksum,
        schema_version_before, schema_version_after, status,
        error_message, error_detail, execution_time_ms, applied_at
    ) VALUES (
        '${esc_id}', '${esc_file}', '${esc_desc}', '${esc_checksum}',
        NULLIF('${esc_before}', ''), NULLIF('${esc_after}', ''), '${esc_status}',
        NULLIF('${esc_err}', ''), NULLIF('${esc_detail}', ''), ${exec_sql}, NOW()
    )
    ON CONFLICT (version) DO UPDATE SET
        migration_file = EXCLUDED.migration_file,
        description = EXCLUDED.description,
        checksum = EXCLUDED.checksum,
        schema_version_before = COALESCE(EXCLUDED.schema_version_before, app.schema_migrations.schema_version_before),
        schema_version_after = EXCLUDED.schema_version_after,
        status = EXCLUDED.status,
        error_message = EXCLUDED.error_message,
        error_detail = EXCLUDED.error_detail,
        execution_time_ms = EXCLUDED.execution_time_ms,
        applied_at = NOW()
  " >/dev/null
}

# Apply idempotent prelude helpers before any m_*.sql. Not recorded in the
# audit table and they must not change schema_version. Failure is fatal.
apply_prelude() {
  local db_name="$1"
  local prelude_dir="${MIGRATIONS_DIR}/_prelude"
  if [[ ! -d "$prelude_dir" ]]; then
    info "no _prelude directory at ${prelude_dir}; continuing (older kit)"
    return 0
  fi

  local f prelude_basename prelude_output prelude_exit
  local found=0
  for f in "${prelude_dir}"/*.sql; do
    [[ ! -f "$f" ]] && continue
    found=1
    prelude_basename=$(basename "$f")
    log "applying prelude: ${prelude_basename}..."
    set +e
    prelude_output=$(psql_exec_file "$db_name" "$f" 2>&1)
    prelude_exit=$?
    set -e
    if [[ $prelude_exit -ne 0 ]]; then
      printf " ${SYM_FAIL} prelude %s FAILED\n" "$prelude_basename"
      err "prelude ${prelude_basename} failed; stopping before any migration."
      echo "$prelude_output" >&2
      exit 1
    fi
    printf " ${SYM_OK} prelude %s applied\n" "$prelude_basename"
  done

  if [[ $found -eq 0 ]]; then
    info "no prelude SQL files in ${prelude_dir}; continuing"
  fi
}

should_apply_migration() {
  local db_name="$1"
  local file="$2"
  local basename="$3"
  local migration_id="$4"
  local target_version="$5"
  local current_version="$6"
  local checksum="$7"

  local audit_row existing_checksum existing_status
  audit_row=$(get_migration_audit_row "$db_name" "$migration_id" || true)
  existing_checksum=""
  existing_status=""
  if [[ -n "$audit_row" && "$audit_row" == *"|"* ]]; then
    existing_checksum="${audit_row%%|*}"
    existing_status="${audit_row#*|}"
  fi

  if [[ -n "$existing_status" ]]; then
    if [[ "$existing_status" == "success" && "$existing_checksum" == "$checksum" ]]; then
      return 2
    fi
    if [[ "$existing_status" == "success" && "$existing_checksum" != "$checksum" ]]; then
      warn "migration ${basename}: file changed since last successful apply (checksum ${existing_checksum} -> ${checksum}); re-applying"
      return 0
    fi
    if [[ "$existing_status" == "failed" ]]; then
      warn "migration ${basename}: previous attempt failed; retrying"
      return 0
    fi
    if [[ "$existing_status" == "skipped" && "$existing_checksum" == "$checksum" ]]; then
      return 2
    fi
    return 0
  fi

  # No audit row: skip when the DB schema already covers the migration target.
  # Seeded audit rows (db/init/16_migration_audit_seed.sql) make this precise
  # for installs created at 0.23.2 or later. The version comparison remains
  # the compatibility fallback for installs created from earlier golden
  # masters (e.g. 0.22.1), which have no seed rows at all. Removing this
  # fallback would try to APPLY older migrations such as m_0.21.8 against a
  # 0.22.1 database — that file contains data migration plus a preflight that
  # RAISE EXCEPTION's on duplicate placement rows.
  # The fallback is safe because: (a) _prelude helpers are always applied, so
  # a skipped migration can never leave a helper missing, and (b) a
  # release-time rehearsal diffs the upgraded schema against the golden master.
  local cmp_result=0
  compare_versions "$target_version" "$current_version" || cmp_result=$?
  if [[ $cmp_result -ne 1 ]]; then
    return 2
  fi
  return 0
}

# --- Main ---
main() {
  # Truncate before any migration (including prelude) so a failed run cannot
  # leave names from a previous attempt in the list.
  if [[ -n "${APPLIED_LIST_FILE}" ]]; then
    if ! : > "$APPLIED_LIST_FILE"; then
      err "could not initialize applied migration list ${APPLIED_LIST_FILE}"
      exit 1
    fi
  fi

  log "checking for pending database migrations..."

  if [[ ! -d "$MIGRATIONS_DIR" ]]; then
    info "no migrations directory at ${MIGRATIONS_DIR}; nothing to do"
    exit 0
  fi

  local db_name="maindb"
  if [[ -n "$DB_NAME_OVERRIDE" ]]; then
    db_name="$DB_NAME_OVERRIDE"
  elif [[ -f "${CONFIG_DIR}/app.env" ]]; then
    local env_db
    env_db=$(grep '^APP_POSTGRES_DB=' "${CONFIG_DIR}/app.env" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    [[ -n "$env_db" ]] && db_name="$env_db"
  fi

  apply_prelude "$db_name"

  local current_version
  current_version=$(get_current_schema_version "$db_name") || exit 1
  log "current schema version: ${current_version}"

  # Top-level m_*.sql only — the glob does not descend into _prelude/.
  local -a migration_files=()
  local f
  for f in "${MIGRATIONS_DIR}"/m_*.sql; do
    [[ ! -f "$f" ]] && continue
    local basename
    basename=$(basename "$f")
    if [[ "$basename" == "$MIGRATION_PLACEHOLDER" || "$basename" == "m_1_future_migrations.sql" ]]; then
      continue
    fi
    migration_files+=("$f")
  done

  if [[ ${#migration_files[@]} -eq 0 ]]; then
    printf " ${SYM_OK} no pending migrations found; schema is up to date (%s)\n" "$current_version"
    exit 0
  fi

  IFS=$'\n' migration_files=($(
    for f in "${migration_files[@]}"; do
      v=$(migration_version_prefix "$(basename "$f")")
      printf '%s\t%s\n' "$(migration_sort_key "${v:-0.0.0}")" "$f"
    done | sort | cut -f2-
  )); unset IFS

  local applied=0
  local skipped=0

  for f in "${migration_files[@]}"; do
    local basename migration_id file_version target_version description checksum
    basename=$(basename "$f")
    migration_id=$(migration_id_from_file "$basename")
    file_version=$(migration_version_prefix "$basename")
    target_version=$(extract_migration_version "$f")
    description=$(extract_migration_description "$f")
    checksum=$(file_sha256 "$f")

    if [[ -z "$migration_id" || -z "$file_version" ]]; then
      err "migration ${basename}: file name does not match m_<X.Y.Z>_<description>.sql"
      exit 1
    fi

    if [[ -z "$target_version" ]]; then
      err "migration ${basename}: no schema_version found in file (required)"
      exit 1
    fi

    if [[ "$file_version" != "$target_version" ]]; then
      err "migration ${basename}: version in file name (${file_version}) does not match schema_version inside the file (${target_version})"
      exit 1
    fi

    local apply_decision=0
    should_apply_migration "$db_name" "$f" "$basename" "$migration_id" \
      "$target_version" "$current_version" "$checksum" || apply_decision=$?

    if [[ $apply_decision -eq 2 ]]; then
      record_migration_audit "$db_name" "$migration_id" "$basename" "$description" "$checksum" \
        "$current_version" "$current_version" "skipped" "" "" ""
      skipped=$((skipped + 1))
      continue
    fi

    log "applying migration: ${basename} (${current_version} -> ${target_version})..."
    local schema_before="$current_version"
    local start_ms end_ms elapsed_ms mig_output mig_exit
    start_ms=$(now_ms)

    set +e
    mig_output=$(psql_exec_file "$db_name" "$f" 2>&1)
    mig_exit=$?
    set -e

    end_ms=$(now_ms)
    elapsed_ms=$((end_ms - start_ms))

    if [[ $mig_exit -eq 0 ]]; then
      printf " ${SYM_OK} migration %s applied successfully\n" "$basename"
      # Record the basename before the audit insert. The migration transaction
      # has already committed; a later audit failure must not drop it from the list.
      if [[ -n "${APPLIED_LIST_FILE}" ]]; then
        if ! printf '%s\n' "$basename" >> "$APPLIED_LIST_FILE"; then
          err "could not record applied migration ${basename} in ${APPLIED_LIST_FILE}"
          exit 1
        fi
      fi
      current_version="$target_version"
      record_migration_audit "$db_name" "$migration_id" "$basename" "$description" "$checksum" \
        "$schema_before" "$target_version" "success" "" "" "$elapsed_ms"
      applied=$((applied + 1))
    else
      printf " ${SYM_FAIL} migration %s FAILED\n" "$basename"
      local err_msg err_detail
      err_msg=$(echo "$mig_output" | tail -5 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-2000)
      err_detail=$(echo "$mig_output" | tail -20)
      record_migration_audit "$db_name" "$migration_id" "$basename" "$description" "$checksum" \
        "$schema_before" "$schema_before" "failed" "$err_msg" "$err_detail" "$elapsed_ms" || true
      err "migration ${basename} failed; stopping. Database may be in an intermediate state."
      echo "$mig_output" >&2
      exit 1
    fi
  done

  echo ""
  if [[ $applied -gt 0 ]]; then
    printf " ${SYM_OK} %d migration(s) applied; schema version is now %s\n" "$applied" "$current_version"
  else
    printf " ${SYM_OK} all migrations already applied; schema is up to date (%s)\n" "$current_version"
  fi
  if [[ $skipped -gt 0 ]]; then
    info "${skipped} migration(s) skipped (already applied or no version)"
  fi
}

main

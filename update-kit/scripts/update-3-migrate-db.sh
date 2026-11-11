#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Phase 3/5 of an application update: stop services except db, snapshot, run migrations, check schema invariants, and roll the database back on failure. Takes APP_HOME as $1.
# File: update-3-migrate-db.sh
#
# Changes in v0.26.3:
# - Database migration phase. A snapshot failure starts services and exits 1 without writing update-result.json.
# - handle_schema_failure writes rolled_back or rollback_failed to update-result.json, then this script exits 1.
# - Schema invariant SQL runs inside validate_schema_health. There is no separate schema-health script.
# - Backup hints name deploy-kit/scripts/backup/backup-create.sh.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
init_update_context "${1:?usage: update-3-migrate-db.sh <APP_HOME>}" "$SCRIPT_DIR"

# True when a runner documents --migrations-dir (grep the file; do not invoke
# --help — older runners treat $1 as DEPLOYMENT_DIR and would error).
runner_supports_migrations_dir() {
  local script="$1"
  grep -q -- '--migrations-dir' "$script" 2>/dev/null
}

# Same probe as runner_supports_migrations_dir, for the applied-list flag.
runner_supports_applied_list_file() {
  grep -q -- '--applied-list-file' "$1" 2>/dev/null
}

# Parse run-migrations.sh stdout for migrations that actually committed.
# Success line (current runner): " migration <basename> applied successfully"
# Summary: " N migration(s) applied; ..." or " all migrations already applied; ..."
# "applying migration:" is printed BEFORE apply — a failing file has that line too.
#
# Degrades to APPLIED_MIG_STATE=unknown (never silently zero) when the output
# does not match those markers, or when a summary count disagrees with parsed names.
parse_applied_migrations_from_output() {
  local output="$1"
  APPLIED_MIG_STATE="unknown"
  APPLIED_MIG_LIST=""

  local stripped
  stripped=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g')

  local success_names="" success_count=0 applying_count=0 failed_count=0
  local has_already=0 summary_n="" name line

  applying_count=$(printf '%s\n' "$stripped" | grep -c 'applying migration:' || true)
  failed_count=$(printf '%s\n' "$stripped" | grep -c ' FAILED' || true)
  if printf '%s\n' "$stripped" | grep -q 'all migrations already applied'; then
    has_already=1
  fi

  summary_n=$(printf '%s\n' "$stripped" | sed -n 's/.* \([0-9][0-9]*\) migration(s) applied.*/\1/p' | head -1)

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *" applied successfully"*)
        name=$(printf '%s\n' "$line" | sed -n 's/.*[Mm]igration \([^[:space:]]*\) applied successfully.*/\1/p')
        if [[ -n "$name" ]]; then
          success_names="${success_names} ${name}"
          success_count=$((success_count + 1))
        fi
        ;;
    esac
  done <<< "$stripped"
  success_names="${success_names# }"

  if [[ $has_already -eq 1 ]]; then
    APPLIED_MIG_STATE="known"
    APPLIED_MIG_LIST=""
    return
  fi
  if [[ -n "$summary_n" && "$summary_n" -eq 0 ]]; then
    APPLIED_MIG_STATE="known"
    APPLIED_MIG_LIST=""
    return
  fi

  if [[ $success_count -gt 0 ]]; then
    if [[ -n "$summary_n" && "$summary_n" -ne "$success_count" ]]; then
      log_tee " ${SYM_WARN} migration-output parse mismatch (summary=${summary_n}, names=${success_count}); treating applied set as unknown"
      APPLIED_MIG_STATE="unknown"
      APPLIED_MIG_LIST=""
      return
    fi
    APPLIED_MIG_STATE="known"
    APPLIED_MIG_LIST="$success_names"
    return
  fi

  # Summary claims applies but no success lines parsed → wording changed.
  if [[ -n "$summary_n" && "$summary_n" -gt 0 ]]; then
    APPLIED_MIG_STATE="unknown"
    APPLIED_MIG_LIST=""
    return
  fi

  # First (and only) apply attempt failed before any success line: exact zero.
  # Several "applying" lines with no parsed successes could hide committed files
  # if the success wording changed — that is unknown, not zero.
  if [[ $applying_count -eq 1 && $failed_count -gt 0 ]]; then
    APPLIED_MIG_STATE="known"
    APPLIED_MIG_LIST=""
    return
  fi

  APPLIED_MIG_STATE="unknown"
  APPLIED_MIG_LIST=""
}

# db stays up across stop_services. If it is down anyway, start it before the snapshot.
ensure_db_running() {
  if podman container inspect db --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    return 0
  fi
  log_tee "database container is not running; starting it before the snapshot..."
  systemctl --user start db.service 2>/dev/null || true
  local elapsed=0
  while [[ "$elapsed" -lt 30 ]]; do
    if podman container inspect db --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
      sleep 3
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log_tee " ${SYM_FAIL} db is not running"
  return 1
}

# --- Step 3: Stop app services (db stays running for snapshot + migrations) ---
stop_services() {
  log_tee "stopping application services (db stays running for migrations)..."
  systemctl --user stop "${APP_STOP_UNITS[@]}" 2>/dev/null || true
  log_tee " ${SYM_OK} services stopped"
}

# --- Pre-migration snapshot (FATAL if it cannot be produced) ---
pre_migration_snapshot() {
  log_tee "creating pre-migration snapshot..."

  SNAPSHOT_PATH="${UPDATE_VERSION_DIR}/pre-update.dump"
  SNAPSHOT_PKG_PATH="${UPDATE_VERSION_DIR}/pre-update.package.json"

  if ! podman container inspect db --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    log_tee " ${SYM_FAIL} db container is not running; cannot create pre-migration snapshot"
    log_tee " ${SYM_FAIL} refuse update: take a full backup (deploy-kit/scripts/backup/backup-create.sh) and retry"
    return 1
  fi

  local db_name
  db_name="$(get_postgres_db_name)"

  # Exact invocation style as deploy-kit/scripts/backup/backup-create.sh dump_database().
  if ! podman exec db pg_dump -U postgres -d "${db_name}" \
       -Fc --clean --if-exists --no-owner \
       -f "/tmp/maindb.dump"; then
    log_tee " ${SYM_FAIL} pg_dump failed; cannot create pre-migration snapshot"
    log_tee " ${SYM_FAIL} refuse update: take a full backup (deploy-kit/scripts/backup/backup-create.sh) and retry"
    return 1
  fi

  if ! podman cp "db:/tmp/maindb.dump" "${SNAPSHOT_PATH}"; then
    log_tee " ${SYM_FAIL} failed to copy dump out of db container"
    log_tee " ${SYM_FAIL} refuse update: take a full backup (deploy-kit/scripts/backup/backup-create.sh) and retry"
    podman exec db rm -f "/tmp/maindb.dump" 2>/dev/null || true
    return 1
  fi
  podman exec db rm -f "/tmp/maindb.dump" 2>/dev/null || true

  if [[ ! -s "$SNAPSHOT_PATH" ]]; then
    log_tee " ${SYM_FAIL} snapshot file is missing or empty at ${SNAPSHOT_PATH}"
    log_tee " ${SYM_FAIL} refuse update: take a full backup (deploy-kit/scripts/backup/backup-create.sh) and retry"
    return 1
  fi

  if [[ -f "${APP_HOME}/package.json" ]]; then
    cp -a "${APP_HOME}/package.json" "${SNAPSHOT_PKG_PATH}" || {
      log_tee " ${SYM_FAIL} failed to save current package.json"
      log_tee " ${SYM_FAIL} refuse update: take a full backup (deploy-kit/scripts/backup/backup-create.sh) and retry"
      return 1
    }
  fi

  local size
  size=$(stat -c%s "${SNAPSHOT_PATH}" 2>/dev/null || stat -f%z "${SNAPSHOT_PATH}" 2>/dev/null || echo "unknown")
  log_tee " ${SYM_OK} pre-migration snapshot written to ${SNAPSHOT_PATH} (${size} bytes)"
  log_tee "   (fast pre-flight snapshot: database + package.json only; not a full backup)"
  return 0
}

# Restore the pre-migration dump. Small on purpose: migrations run BEFORE
# kit/env/image replacement, so the on-disk kit, app.env, and container images
# are still the old ones. Restoring the dump and starting the previously
# stopped units is enough — nothing else needs undoing.
#
# Automatic rollback is scoped to the migration/schema-health window ONLY.
# After replace_deploy_kit the schema is the intended new schema; rolling the
# database back would disagree with the new kit/images. Failures from
# merge_env / load_env_and_render / pull_images / restart_db / start_services /
# verify_health keep today's behaviour (clear error, no auto-rollback).
#
# Best-effort, not a surgical inverse. pg_restore --clean --if-exists only
# drops objects that are PRESENT IN THE DUMP. Objects created by a migration
# that fully committed during this run are absent from pre-update.dump, so
# --clean cannot drop them — they survive the restore. That leak happens only
# when the chain applies one or more files and a LATER one fails (or schema
# health then fails): each m_*.sql is wrapped in BEGIN; ... COMMIT;, so a
# failing file leaves nothing of its own. After restore, schema_version and
# app.schema_migrations come from the dump (old), while leftover objects from
# the committed files remain.
#
# Drop/recreate of the database is deliberately rejected. pg_cron is
# configured with cron.database_name = 'maindb' and holds connections;
# a failed DROP/CREATE would destroy the installation. Surfacing exact vs
# best-effort (and pointing at a full deploy-kit/scripts/backup/backup-create.sh archive) is safer
# than trading a recoverable leak for an unrecoverable drop.
rollback_database() {
  if [[ -z "${SNAPSHOT_PATH:-}" ]] || [[ ! -f "$SNAPSHOT_PATH" ]]; then
    log_tee " ${SYM_FAIL} snapshot file missing (${SNAPSHOT_PATH:-unset}); cannot roll back"
    return 1
  fi

  local db_name
  db_name="$(get_postgres_db_name)"

  if ! podman container inspect db --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    log_tee " ${SYM_FAIL} db container is not running; cannot roll back"
    return 1
  fi

  log_tee "restoring database from ${SNAPSHOT_PATH}..."
  if ! podman cp "${SNAPSHOT_PATH}" "db:/tmp/maindb.dump"; then
    log_tee " ${SYM_FAIL} failed to copy dump into db container"
    return 1
  fi

  # Proven flags from deploy-kit/install.sh restore path.
  # pg_restore --clean may exit non-zero on warnings about existing objects;
  # install.sh treats that as success and so do we.
  if ! podman exec db pg_restore -U postgres -d "${db_name}" \
       --clean --if-exists --no-owner \
       /tmp/maindb.dump 2>/dev/null; then
    log_tee " ${SYM_WARN} pg_restore completed with warnings (this is usually normal)"
  fi
  podman exec db rm -f /tmp/maindb.dump 2>/dev/null || true

  if ! podman exec db pg_isready -U postgres -d "${db_name}" >/dev/null 2>&1; then
    log_tee " ${SYM_FAIL} database is not ready after pg_restore"
    return 1
  fi

  log_tee " ${SYM_OK} database restored from pre-migration snapshot"
  return 0
}

# Triggered only when run_migrations or validate_schema_health fails.
handle_schema_failure() {
  local reason="$1"
  log_tee " ${SYM_FAIL} ${reason} — rolling back the database to the pre-migration snapshot"
  if rollback_database; then
    log_tee "bringing services back up on the OLD images (kit and env were not replaced)"
    start_services

    local applied_n
    applied_n="$(applied_mig_count)"
    if [[ "$APPLIED_MIG_STATE" != "known" ]]; then
      log_tee " ${SYM_WARN} rollback completeness UNKNOWN: could not parse how many migrations committed from runner output"
      log_tee " ${SYM_WARN} treat this as BEST-EFFORT. If you need a guaranteed-clean database, restore a full backup"
      log_tee "   (deploy-kit/scripts/backup/backup-create.sh archive, restored through install.sh)"
    elif [[ "$applied_n" -eq 0 ]]; then
      log_tee " ${SYM_OK} rollback is EXACT: no migration committed during this run"
      log_tee "   A failing migration's transaction rolls itself back (BEGIN/COMMIT)."
      log_tee "   The dump restore returned the database to its pre-update state."
    else
      log_tee " ${SYM_WARN} rollback is BEST-EFFORT: ${applied_n} migration(s) had already committed:"
      local mig
      for mig in $APPLIED_MIG_LIST; do
        log_tee "   - ${mig}"
      done
      log_tee " ${SYM_WARN} objects those migrations created are not in the pre-update dump, so --clean cannot drop them."
      log_tee "   schema_version / schema_migrations are restored to the old values; leftover objects remain."
      log_tee " ${SYM_WARN} for a guaranteed-clean state, restore a full backup"
      log_tee "   (deploy-kit/scripts/backup/backup-create.sh archive, restored through install.sh)"
    fi

    cleanup_update_lock_and_write_result "rolled_back" "1" "$reason"
    log_tee " ${SYM_WARN} update aborted and database rolled back"
    log_tee " ${SYM_WARN} snapshot kept at ${SNAPSHOT_PATH}"
    return 1
  fi

  log_tee " ${SYM_FAIL} ROLLBACK FAILED. The database may be at an intermediate schema version."
  log_tee " ${SYM_FAIL} Do NOT delete the snapshot. Restore it manually:"
  log_tee "   podman cp \"${SNAPSHOT_PATH}\" db:/tmp/maindb.dump"
  log_tee "   podman exec db pg_restore -U postgres -d \"$(get_postgres_db_name)\" --clean --if-exists --no-owner /tmp/maindb.dump"
  cleanup_update_lock_and_write_result "rollback_failed" "2" "$reason"
  return 1
}

# --- Run database migrations from STAGING (on-disk kit is still the old one) ---
# When the runner supports --applied-list-file, committed basenames are read
# from that file. Stdout parsing is only the fallback for an older runner.
run_migrations() {
  log_tee "running database migrations..."

  local migrations_script=""
  local use_migrations_dir_flag=0
  local use_applied_list=0
  local applied_list_file=""
  local staged_runner="${NEW_UPDATE_DIR}/scripts/run-migrations.sh"
  local ondisk_runner="${APP_HOME}/update/scripts/run-migrations.sh"

  if [[ -f "$staged_runner" && -r "$staged_runner" ]]; then
    migrations_script="$staged_runner"
    if runner_supports_migrations_dir "$staged_runner"; then
      use_migrations_dir_flag=1
    else
      log_tee " ${SYM_WARN} staged run-migrations.sh does not support --migrations-dir; running it without the flag (on-disk migrations)"
    fi
  elif [[ -f "$ondisk_runner" ]]; then
    migrations_script="$ondisk_runner"
    log_tee " ${SYM_WARN} staged run-migrations.sh missing; falling back to on-disk ${ondisk_runner}"
    if runner_supports_migrations_dir "$ondisk_runner"; then
      use_migrations_dir_flag=1
    fi
  else
    log_tee " ${SYM_WARN} run-migrations.sh not found; skipping"
    APPLIED_MIG_STATE="known"
    APPLIED_MIG_LIST=""
    return 0
  fi

  if runner_supports_applied_list_file "$migrations_script"; then
    applied_list_file=$(mktemp "${UPDATES_DIR}/applied-mig.XXXXXX" 2>/dev/null || true)
    if [[ -n "$applied_list_file" ]]; then
      use_applied_list=1
    else
      log_tee " ${SYM_WARN} could not create an applied-migration list file; parsing runner output instead"
    fi
  fi

  chmod +x "$migrations_script"
  local -a runner_args=("$APP_HOME")
  local runner_desc="$migrations_script"
  if [[ $use_migrations_dir_flag -eq 1 ]]; then
    runner_args+=(--migrations-dir "${NEW_UPDATE_DIR}/migrations")
    runner_desc="${runner_desc} --migrations-dir ${NEW_UPDATE_DIR}/migrations"
  fi
  if [[ $use_applied_list -eq 1 ]]; then
    runner_args+=(--applied-list-file "$applied_list_file")
    runner_desc="${runner_desc} --applied-list-file ${applied_list_file}"
  fi

  local mig_out mig_rc=0
  log_tee "   runner: ${runner_desc}"
  mig_out=$("$migrations_script" "${runner_args[@]}" 2>&1) || mig_rc=$?
  echo "$mig_out" | while IFS= read -r line; do log_tee "   [migration] $line"; done

  if [[ $use_applied_list -eq 1 && -f "$applied_list_file" ]]; then
    APPLIED_MIG_STATE="known"
    APPLIED_MIG_LIST=""
    local mig_name
    while IFS= read -r mig_name || [[ -n "$mig_name" ]]; do
      [[ -z "$mig_name" ]] && continue
      if [[ -z "$APPLIED_MIG_LIST" ]]; then
        APPLIED_MIG_LIST="$mig_name"
      else
        APPLIED_MIG_LIST="${APPLIED_MIG_LIST} ${mig_name}"
      fi
    done < "$applied_list_file"
    rm -f "$applied_list_file"
  elif [[ $use_applied_list -eq 1 ]]; then
    log_tee " ${SYM_WARN} applied migration list file is missing; treating applied set as unknown"
    APPLIED_MIG_STATE="unknown"
    APPLIED_MIG_LIST=""
    rm -f "$applied_list_file"
  else
    parse_applied_migrations_from_output "$mig_out"
  fi

  if [[ $mig_rc -ne 0 ]]; then
    log_tee " ${SYM_FAIL} database migrations failed"
    return 1
  fi
  log_tee " ${SYM_OK} database migrations completed"
  return 0
}

# Placement and publication invariants. A query failure or any reported problem
# returns 1 so the caller rolls the database back. The caller has errexit off.
validate_schema_health() {
  log_tee "validating schema health invariants..."

  local db_name result exit_code=0
  db_name="$(get_postgres_db_name)"
  result=$(podman exec db psql -v ON_ERROR_STOP=1 -U postgres -d "$db_name" -tAc "
    SELECT string_agg(problem, '; ')
    FROM (
        SELECT 'uq_section_product_lines_line missing' AS problem
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'uq_section_product_lines_line'
              AND conrelid = 'app.section_product_lines'::regclass
        )
        UNION ALL
        SELECT 'uq_product_line_products_product missing'
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'uq_product_line_products_product'
              AND conrelid = 'app.product_line_products'::regclass
        )
        UNION ALL
        SELECT 'uq_section_products_product missing'
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'uq_section_products_product'
              AND conrelid = 'app.section_products'::regclass
        )
        UNION ALL
        SELECT 'product_line_products publication columns still exist'
        WHERE EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'app' AND table_name = 'product_line_products'
              AND column_name IN ('is_published', 'published_by', 'published_at')
        )
        UNION ALL
        SELECT 'section_product_lines publication columns still exist'
        WHERE EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'app' AND table_name = 'section_product_lines'
              AND column_name IN ('published_by', 'published_at')
        )
        UNION ALL
        SELECT 'tgr_section_products_single_placement missing'
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_trigger
            WHERE tgname = 'tgr_section_products_single_placement'
              AND tgrelid = 'app.section_products'::regclass
        )
        UNION ALL
        SELECT 'tgr_product_line_products_single_placement missing'
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_trigger
            WHERE tgname = 'tgr_product_line_products_single_placement'
              AND tgrelid = 'app.product_line_products'::regclass
        )
    ) problems;
  " 2>&1) || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    log_tee " ${SYM_FAIL} schema health validation query failed"
    log_tee "   ${result}"
    return 1
  fi

  result=$(printf '%s' "$result" | tr -d '[:space:]')
  if [[ -n "$result" ]]; then
    log_tee " ${SYM_FAIL} schema health validation failed"
    log_tee "   ${result}"
    return 1
  fi

  log_tee " ${SYM_OK} schema health invariants OK"
  return 0
}

# Errexit is off for the run sequence, matching the previous apply-update.sh main.
# Fatal steps exit explicitly so a best-effort command cannot abort the phase.
set +e

stop_services
if ! ensure_db_running || ! pre_migration_snapshot; then
  log_tee "bringing services back up after snapshot failure..."
  start_services
  exit 1
fi
run_migrations || { handle_schema_failure "database migrations failed"; exit 1; }
validate_schema_health || { handle_schema_failure "schema health validation failed"; exit 1; }
exit 0

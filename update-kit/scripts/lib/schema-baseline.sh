#!/usr/bin/env bash
#
# Version: 0.28.5
# Purpose: Sourceable read-only catalog baseline for schema app. dump_catalog_baseline
#   prints one sorted unique row per table, column, constraint, index, function,
#   trigger, enum, setting key, permission key, and role group. compare_catalog_baselines
#   prints blocker and warning findings between a reference manifest, a live
#   manifest, and an optional target-release manifest. No shell options are
#   changed in the caller's shell. No output when sourced.
# File: schema-baseline.sh
#
# Changes in v0.28.5:
# - Initial library: dump_catalog_baseline and compare_catalog_baselines.
#

# Guard against double-sourcing. When executed directly (not sourced) the first
# load defines the functions; a second direct invocation is a new process.
if [[ "${APP_LIB_SCHEMA_BASELINE_SH:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
APP_LIB_SCHEMA_BASELINE_SH=1

# dump_catalog_baseline <db_container> <db_name>
# Read-only catalog manifest on stdout: SECTION, obj_key, spec, tab-separated.
# psql failure is the function status (the pipeline does not mask it).
dump_catalog_baseline() {
  local db_container="${1:-}"
  local db_name="${2:-}"
  local sql

  if [[ -z "${db_container}" || -z "${db_name}" ]]; then
    printf 'error: dump_catalog_baseline requires <db_container> <db_name>\n' >&2
    return 1
  fi

  sql="$(cat <<'SQL'
SELECT 'TABLE', c.relname::text, c.relkind::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'app' AND c.relkind IN ('r', 'v', 'm', 'p') AND NOT c.relispartition
UNION ALL
SELECT 'COLUMN',
       c.table_name || '.' || c.column_name,
       c.data_type || '|' || c.udt_name || '|' || c.is_nullable || '|' || COALESCE(regexp_replace(c.column_default, '[[:space:]]+', ' ', 'g'), '')
FROM information_schema.columns c
JOIN pg_class cl ON cl.relname = c.table_name
JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = c.table_schema
WHERE c.table_schema = 'app' AND NOT cl.relispartition
UNION ALL
SELECT 'CONSTRAINT',
       cl.relname || '.' || con.conname,
       con.contype::text || '|' || pg_get_constraintdef(con.oid, true)
FROM pg_constraint con
JOIN pg_class cl ON cl.oid = con.conrelid
JOIN pg_namespace n ON n.oid = cl.relnamespace
WHERE n.nspname = 'app' AND con.contype IN ('p', 'u', 'f', 'c') AND NOT cl.relispartition
UNION ALL
SELECT 'INDEX',
       t.relname || '.' || i.relname,
       pg_get_indexdef(ix.indexrelid)
FROM pg_index ix
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'app' AND NOT t.relispartition
UNION ALL
SELECT 'FUNCTION',
       p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
       COALESCE(pg_get_function_result(p.oid), 'PROCEDURE') || '|' || md5(
         regexp_replace(
           regexp_replace(
             regexp_replace(p.prosrc, '(^|\n)[ \t]*--[^\n]*', '', 'g'),
             '[ \t]+(\r?\n)', '\1', 'g'
           ),
           '^\s+|\s+$', '', 'g'
         )
       )
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'app'
UNION ALL
SELECT 'TRIGGER',
       cl.relname || '.' || tg.tgname,
       pg_get_triggerdef(tg.oid, true)
FROM pg_trigger tg
JOIN pg_class cl ON cl.oid = tg.tgrelid
JOIN pg_namespace n ON n.oid = cl.relnamespace
WHERE n.nspname = 'app' AND NOT tg.tgisinternal AND NOT cl.relispartition
UNION ALL
SELECT 'ENUM',
       t.typname::text,
       string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
JOIN pg_enum e ON e.enumtypid = t.oid
WHERE n.nspname = 'app'
GROUP BY t.typname
UNION ALL
SELECT 'SETTING_KEY',
       s.section_path || '|' || s.setting_name || '|' || s.environment::text,
       s.is_public::text || '|' || COALESCE(s.confidentiality::text, '') || '|' || md5(COALESCE(s.validation_schema::text, ''))
FROM app.app_settings s
UNION ALL
SELECT 'PERMISSION_KEY',
       p.permission_key,
       '1'
FROM app.permissions p
UNION ALL
SELECT 'ROLE_GROUP',
       g.group_name,
       '1'
FROM app.groups g
WHERE g.group_name LIKE 'role.%'
SQL
)"

  # pipefail is local to this subshell so a psql failure is not reported as
  # success of sed/sort, and the caller's shell options stay unchanged.
  (
    set -o pipefail
    podman exec "${db_container}" psql -U postgres -d "${db_name}" \
      -v ON_ERROR_STOP=1 -tAF $'\t' -c "${sql}" \
      | sed '/^$/d' | LC_ALL=C sort -u
  )
}

# compare_catalog_baselines <ref_manifest> <live_manifest> [target_manifest]
# Findings on stdout, one per line: SEVERITY, CODE, OBJECT, MESSAGE (tab-separated),
# sorted byte-wise. Exit 0 when the comparison ran, including when findings exist.
# target_manifest participates only when the path is given and the file is non-empty.
compare_catalog_baselines() {
  local ref_manifest="${1:-}"
  local live_manifest="${2:-}"
  local target_manifest="${3:-}"
  local use_target=0

  if [[ -z "${ref_manifest}" || -z "${live_manifest}" ]]; then
    printf 'error: compare_catalog_baselines requires <ref_manifest> <live_manifest> [target_manifest]\n' >&2
    return 1
  fi
  if [[ ! -f "${ref_manifest}" ]]; then
    printf 'error: reference manifest not found: %s\n' "${ref_manifest}" >&2
    return 1
  fi
  if [[ ! -f "${live_manifest}" ]]; then
    printf 'error: live manifest not found: %s\n' "${live_manifest}" >&2
    return 1
  fi
  if [[ -n "${target_manifest}" ]]; then
    if [[ ! -f "${target_manifest}" ]]; then
      printf 'error: target manifest not found: %s\n' "${target_manifest}" >&2
      return 1
    fi
    if [[ -s "${target_manifest}" ]]; then
      use_target=1
    fi
  fi

  (
    set -o pipefail
    # shellcheck disable=SC2016
    awk -v ref_path="${ref_manifest}" \
        -v live_path="${live_manifest}" \
        -v target_path="${target_manifest}" \
        -v use_target="${use_target}" '
BEGIN { FS = "\t"; OFS = "\t" }

function field_spec(    i, s) {
  if (NF < 3) return ""
  s = $3
  for (i = 4; i <= NF; i++) s = s "\t" $i
  return s
}

function is_system_key(sec) {
  return sec == "SETTING_KEY" || sec == "PERMISSION_KEY" || sec == "ROLE_GROUP"
}

function emit(sev, code, obj, msg) {
  printf "%s\t%s\t%s\t%s\n", sev, code, obj, msg
}

$0 ~ /^[ \t]*$/ { next }
NF < 2 || $1 == "" || $2 == "" { next }
{
  if (FILENAME == ref_path) {
    ref_spec[$1, $2] = field_spec()
  } else if (FILENAME == live_path) {
    live_spec[$1, $2] = field_spec()
  } else if (use_target == 1 && FILENAME == target_path) {
    tgt_spec[$1, $2] = field_spec()
  }
  next
}

END {
  for (key in ref_spec) {
    split(key, parts, SUBSEP)
    sec = parts[1]
    obj = parts[2]
    if (!(key in live_spec)) {
      if (is_system_key(sec)) {
        emit("BLOCKER", "missing_or_tampered_system_key", sec ":" obj,
             "Required system key " obj " (" sec ") is missing from the database")
      } else {
        emit("BLOCKER", "missing_schema_object", sec ":" obj,
             "Required schema object " obj " (" sec ") is missing from schema app")
      }
    } else if (ref_spec[key] != live_spec[key]) {
      if (sec == "SETTING_KEY") {
        emit("BLOCKER", "missing_or_tampered_system_key", "SETTING_KEY:" obj,
             "System setting metadata for " obj " differs from reference")
      } else if (sec == "FUNCTION" || sec == "TRIGGER") {
        emit("WARNING", "modified_function_or_trigger", sec ":" obj,
             "Definition of " sec " " obj " differs from reference")
      } else {
        emit("BLOCKER", "modified_schema_object", sec ":" obj,
             "Schema definition of " sec " " obj " differs from reference (expected " ref_spec[key] ", got " live_spec[key] ")")
      }
    }
  }
  for (key in live_spec) {
    if (key in ref_spec) continue
    split(key, parts, SUBSEP)
    sec = parts[1]
    obj = parts[2]
    if (use_target == 1 && (key in tgt_spec) && tgt_spec[key] != live_spec[key]) {
      emit("BLOCKER", "target_collision", sec ":" obj,
           "Custom object " obj " (" sec ") conflicts with target release definition")
    } else {
      emit("WARNING", "extra_schema_object", sec ":" obj,
           "Extra object " obj " (" sec ") is not in reference baseline")
    }
  }
}
' "${ref_manifest}" "${live_manifest}" ${use_target:+"${target_manifest}"} \
      | LC_ALL=C sort
  )
}

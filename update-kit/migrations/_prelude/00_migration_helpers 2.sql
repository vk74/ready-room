-- Version: 0.23.2
-- Description: Idempotent helper objects required by update-kit migrations. Applied
--   unconditionally before the migration chain on every update. Must never contain
--   schema changes (no tables, no columns, no data) — only CREATE OR REPLACE FUNCTION
--   / other idempotent helper definitions. Safe to re-run any number of times; the
--   only precondition is that app.schema_migrations exists (created by
--   db/init/02_schema.sql on every supported installation). Does not wrap in
--   BEGIN/COMMIT (the runner decides transaction scope) and does not touch
--   app.instance.schema_version.
-- Backend file: 00_migration_helpers.sql
--
-- Note: db/init/15_migration_helpers.sql is generated from this file by
--   dev-ops/release/scripts/sync-migration-helpers.sh and must not be hand-edited.
--
-- Changes in v0.23.2:
-- - Initial prelude: app.set_migration_output_summary (CREATE OR REPLACE), copied
--   from m_0.21.8 so the helper exists even when that migration is skipped on
--   fresh installs whose schema_version already covers 0.21.8.

CREATE OR REPLACE FUNCTION app.set_migration_output_summary(
    p_migration_id TEXT,
    p_summary TEXT
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE app.schema_migrations sm
    SET output_summary = p_summary
    WHERE sm.version = p_migration_id
      AND sm.applied_at = (
          SELECT MAX(applied_at)
          FROM app.schema_migrations
          WHERE version = p_migration_id
      );
END;
$$;

COMMENT ON FUNCTION app.set_migration_output_summary(TEXT, TEXT) IS
    'Sets output_summary on the latest schema_migrations row for a migration id (called at end of migration SQL).';

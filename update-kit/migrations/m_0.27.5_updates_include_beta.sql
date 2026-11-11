-- Version: 0.27.5
-- Description: Add include_beta boolean column to app.instance so the in-app Updates panel and background update-check worker can include pre-release (beta/rc) versions.
-- Backend file: m_0.27.5_updates_include_beta.sql
--
-- Changes in v0.27.5:
-- - Add include_beta BOOLEAN NOT NULL DEFAULT false to app.instance.

BEGIN;

ALTER TABLE app.instance
    ADD COLUMN IF NOT EXISTS include_beta BOOLEAN NOT NULL DEFAULT false;

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.27.5',
        'Added include_beta boolean column to app.instance for the in-app Updates beta release channel.'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.27.5', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

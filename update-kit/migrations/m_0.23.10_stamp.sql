-- Version: 0.23.10
-- Description: Release 0.23.10 schema (stamp slug: this release is mixed). Drops
--   the old process_templates stack; further 0.23.10 SQL appends in this file.
-- Backend file: m_0.23.10_stamp.sql
--
-- Destructive-affects: TABLE app.process_templates; TABLE app.process_template_versions; TYPE app.process_status; TYPE app.process_version_status; FUNCTION app.tgr_process_templates_validate_current_version
-- Destructive-data-loss: all rows in app.process_templates and app.process_template_versions
--
-- Changes in v0.23.10:
-- - Renamed from m_0.23.10_drop_process_templates.sql to m_0.23.10_stamp.sql
--   because 0.23.10 is not process-drop-only.
-- - Dropped app.process_templates and app.process_template_versions (CASCADE
--   removes their indexes and triggers), the process-only current-version
--   trigger function, and enums app.process_status / app.process_version_status.
-- - Deleted the AdminProcesses / allowed.languages settings row.
-- - Kept app.tgr_frozen_version_immutable for work_item_form_versions and
--   re-issued its COMMENT without process-version wording (dump-visible parity
--   with db/init).
-- - Product-owned text: adminServices role descriptions and
--   services.module.enabled description no longer name processes.
--
-- Idempotency: DROP CONSTRAINT / TABLE / FUNCTION / TYPE use IF EXISTS.
--   DELETE of AdminProcesses is a no-op when the row is already gone.
--   COMMENT ON and the product-owned UPDATEs re-apply the same literals.

BEGIN;

-- ===========================================================================
-- 1. Drop the deferred current-version FK (if the identity table is still there)
-- ===========================================================================

DO $$
BEGIN
    IF to_regclass('app.process_templates') IS NOT NULL THEN
        ALTER TABLE app.process_templates
            DROP CONSTRAINT IF EXISTS process_templates_current_version_id_fkey;
    END IF;
END $$;

-- ===========================================================================
-- 2. Drop process tables (indexes and triggers go with CASCADE)
-- ===========================================================================

DROP TABLE IF EXISTS app.process_template_versions, app.process_templates CASCADE;

-- ===========================================================================
-- 3. Drop the process-only current-version trigger function
-- ===========================================================================

DROP FUNCTION IF EXISTS app.tgr_process_templates_validate_current_version();

-- ===========================================================================
-- 4. Drop process enums
-- ===========================================================================

DROP TYPE IF EXISTS app.process_status;
DROP TYPE IF EXISTS app.process_version_status;

-- ===========================================================================
-- 5. Remove the process-module language-subset setting
-- ===========================================================================

DELETE FROM app.app_settings WHERE section_path = 'AdminProcesses';

-- ===========================================================================
-- 6. Form-version freeze function stays; COMMENT matches db/init
-- ===========================================================================

COMMENT ON FUNCTION app.tgr_frozen_version_immutable() IS
    'Enforces version immutability on app.work_item_form_versions: once a version leaves draft only status/change_note/audit columns may change, and it can never return to draft.';

-- ===========================================================================
-- 7. Product-owned text (never write app.app_settings.value)
-- ===========================================================================

UPDATE app.groups
SET group_description = 'Services Administrators with full access (catalog services, work-item forms, settings)'
WHERE group_name = 'role.adminServices.admin';

UPDATE app.groups
SET group_description = 'Services Auditors (read-only across catalog services, work-item forms and settings)'
WHERE group_name = 'role.adminServices.auditor';

UPDATE app.app_settings
SET description = 'Enable Services module in this installation. When disabled, the module is completely turned off for all users (catalog services, work-item forms).'
WHERE section_path = 'Application.System.Modules'
  AND setting_name = 'services.module.enabled';

-- ===========================================================================
-- 8. Version stamp
-- ===========================================================================

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.23.10',
        'Dropped process_templates / process_template_versions and related enums, the AdminProcesses setting, and process-only current-version trigger. Form version freeze function kept.'
    );
END $$;

UPDATE app.instance SET schema_version = '0.23.10', last_updated_at = NOW() WHERE id = 1;

COMMIT;

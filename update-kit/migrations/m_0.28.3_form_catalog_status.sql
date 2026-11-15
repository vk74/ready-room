-- Version: 0.28.3
-- Description: Replace app.work_item_forms.catalog_visible with catalog_status and app.services operational_status/pause_reason/catalog_visible with status. Demote a work-item form to draft when its service binding is cleared (and reset catalog_order) or when its current version is cleared while active, and demote a service to draft when its last catalog section placement is removed. Remove unused adminServices own-item permissions and the role.adminServices.auditor group, set role.adminServices.admin display name to Role Service Administrators, and grant role.service.auditor read-only access across catalog services, work-item forms, service settings, and all service requests.
-- Backend file: m_0.28.3_form_catalog_status.sql
--
-- Changes in v0.28.3:
-- - app.work_item_form_catalog_status (draft, active, on hold, discontinued).
-- - app.work_item_forms.catalog_status replaces catalog_visible. Visible offerings with a bound service and a current version become active; every other row becomes draft.
-- - chk_work_item_forms_catalog_status: draft is always legal; on hold and discontinued require service_id; active requires service_id and current_version_id.
-- - tgr_work_item_forms_demote_catalog_status fires BEFORE UPDATE OF service_id, current_version_id. Clearing service_id sets catalog_status to draft and catalog_order to 0. Clearing current_version_id while catalog_status is active sets catalog_status to draft.
-- - idx_work_item_forms_service_visible_order is replaced by idx_work_item_forms_service_status_order.
-- - schema_version set to 0.28.3.
-- - app.service_status (draft, active, planned_maintenance, emergency_maintenance, archived) replaces app.service_operational_status and app.service_pause_reason.
-- - app.services.status replaces operational_status, pause_reason, catalog_visible, and chk_services_pause_reason. Services that were catalog_visible with at least one section placement map available to active and keep planned_maintenance or emergency_maintenance; paused or unplaced/hidden services become draft.
-- - tgr_section_services_demote_service_status AFTER DELETE on app.section_services demotes the service to draft when its last catalog section placement is removed while status is active, planned_maintenance, or emergency_maintenance.
-- - Removed permissions adminServices:items:read:own, adminServices:items:update:own, and adminServices:items:delete:own, and their grants.
-- - Removed system group role.adminServices.auditor after clearing is_system, including its grants and memberships.
-- - role.adminServices.admin display name is Role Service Administrators.
-- - role.service.auditor description covers catalog services, work-item forms, service settings, and all service requests. The group is granted adminServices:module:access, adminServices:settings:access, adminServices:settings:read:all, adminServices:items:read:all, and service:requests:read:all.
--
-- Destructive-affects: COLUMN app.work_item_forms.catalog_visible; INDEX app.idx_work_item_forms_service_visible_order; COLUMN app.services.operational_status; COLUMN app.services.pause_reason; COLUMN app.services.catalog_visible; TYPE app.service_operational_status; TYPE app.service_pause_reason; ROW app.permissions adminServices:items:read:own; ROW app.permissions adminServices:items:update:own; ROW app.permissions adminServices:items:delete:own; GROUP app.groups role.adminServices.auditor
-- Destructive-data-loss: boolean values of app.work_item_forms.catalog_visible (visible rows with a service and a current version become catalog_status active; every other row becomes draft); app.services.operational_status, app.services.pause_reason, and app.services.catalog_visible (visible rows with section placement map available to active and keep planned_maintenance/emergency_maintenance; paused and hidden/unplaced rows become draft); grants and permission rows for adminServices:items:read:own, adminServices:items:update:own, and adminServices:items:delete:own; role.adminServices.auditor group row, its grants, and its memberships (read-only access moves to role.service.auditor)

BEGIN;

DO $$ BEGIN
    CREATE TYPE app.work_item_form_catalog_status AS ENUM ('draft', 'active', 'on hold', 'discontinued');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.work_item_form_catalog_status IS
    'Offering publication status of a work item form: draft, active, on hold, or discontinued.';

ALTER TABLE app.work_item_forms
    ADD COLUMN IF NOT EXISTS catalog_status app.work_item_form_catalog_status NOT NULL DEFAULT 'draft'::app.work_item_form_catalog_status;

-- Backfill while catalog_visible still exists. A second run parses because the
-- UPDATE is executed only when that column is present.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'work_item_forms'
          AND column_name = 'catalog_visible'
    ) THEN
        EXECUTE $backfill$
            UPDATE app.work_item_forms
            SET catalog_status = CASE
                WHEN catalog_visible = true
                 AND service_id IS NOT NULL
                 AND current_version_id IS NOT NULL
                    THEN 'active'::app.work_item_form_catalog_status
                ELSE 'draft'::app.work_item_form_catalog_status
            END
            WHERE catalog_status IS DISTINCT FROM (
                CASE
                    WHEN catalog_visible = true
                     AND service_id IS NOT NULL
                     AND current_version_id IS NOT NULL
                        THEN 'active'::app.work_item_form_catalog_status
                    ELSE 'draft'::app.work_item_form_catalog_status
                END
            )
        $backfill$;
    END IF;
END $$;

DROP INDEX IF EXISTS app.idx_work_item_forms_service_visible_order;

ALTER TABLE app.work_item_forms DROP COLUMN IF EXISTS catalog_visible;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_work_item_forms_catalog_status'
          AND conrelid = 'app.work_item_forms'::regclass
    ) THEN
        ALTER TABLE app.work_item_forms
            ADD CONSTRAINT chk_work_item_forms_catalog_status CHECK (
                catalog_status = 'draft'::app.work_item_form_catalog_status
                OR (
                    service_id IS NOT NULL
                    AND (
                        catalog_status <> 'active'::app.work_item_form_catalog_status
                        OR current_version_id IS NOT NULL
                    )
                )
            );
    END IF;
END $$;

CREATE OR REPLACE FUNCTION app.tgr_work_item_forms_demote_catalog_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.service_id IS NULL AND OLD.service_id IS NOT NULL THEN
        NEW.catalog_status := 'draft'::app.work_item_form_catalog_status;
        NEW.catalog_order := 0;
    END IF;
    IF NEW.current_version_id IS NULL
       AND OLD.current_version_id IS NOT NULL
       AND NEW.catalog_status = 'active'::app.work_item_form_catalog_status THEN
        NEW.catalog_status := 'draft'::app.work_item_form_catalog_status;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_work_item_forms_demote_catalog_status() IS
    'BEFORE UPDATE OF service_id, current_version_id on app.work_item_forms. When the service binding is cleared, including a foreign key ON DELETE SET NULL, sets catalog_status to draft and catalog_order to 0. When current_version_id is cleared while catalog_status is active, sets catalog_status to draft. Returns NEW unchanged otherwise. Not used on INSERT.';

DROP TRIGGER IF EXISTS tgr_work_item_forms_demote_catalog_status ON app.work_item_forms;

CREATE TRIGGER tgr_work_item_forms_demote_catalog_status
BEFORE UPDATE OF service_id, current_version_id ON app.work_item_forms
FOR EACH ROW EXECUTE FUNCTION app.tgr_work_item_forms_demote_catalog_status();

-- Catalog service page: bound forms of one service, by offering status then grid order.
CREATE INDEX IF NOT EXISTS idx_work_item_forms_service_status_order
    ON app.work_item_forms USING btree (service_id, catalog_status, catalog_order);

COMMENT ON COLUMN app.work_item_forms.catalog_status IS
    'Offering publication status. active is shown in the catalog and on the bound service; draft, on hold, and discontinued are hidden. Default draft. Cleared to draft when service_id becomes null.';

-- ===========================================================================
-- Services: replace operational_status, pause_reason, catalog_visible with status
-- ===========================================================================

DO $$ BEGIN
    CREATE TYPE app.service_status AS ENUM (
        'draft', 'active', 'planned_maintenance', 'emergency_maintenance', 'archived'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.service_status IS
    'Publication and operational status of a catalog service: draft, active, planned_maintenance, emergency_maintenance, or archived.';

ALTER TABLE app.services
    ADD COLUMN IF NOT EXISTS status app.service_status NOT NULL DEFAULT 'draft'::app.service_status;

-- Backfill while catalog_visible and operational_status still exist.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'services'
          AND column_name = 'catalog_visible'
    ) AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'services'
          AND column_name = 'operational_status'
    ) THEN
        EXECUTE $backfill_services$
            UPDATE app.services s
            SET status = CASE
                WHEN s.catalog_visible = true
                 AND EXISTS (SELECT 1 FROM app.section_services ss WHERE ss.service_id = s.id)
                THEN CASE s.operational_status::text
                    WHEN 'available' THEN 'active'::app.service_status
                    WHEN 'planned_maintenance' THEN 'planned_maintenance'::app.service_status
                    WHEN 'emergency_maintenance' THEN 'emergency_maintenance'::app.service_status
                    ELSE 'draft'::app.service_status
                END
                ELSE 'draft'::app.service_status
            END
        $backfill_services$;
    END IF;
END $$;

ALTER TABLE app.services DROP CONSTRAINT IF EXISTS chk_services_pause_reason;
ALTER TABLE app.services DROP COLUMN IF EXISTS operational_status;
ALTER TABLE app.services DROP COLUMN IF EXISTS pause_reason;
ALTER TABLE app.services DROP COLUMN IF EXISTS catalog_visible;

DROP TYPE IF EXISTS app.service_operational_status;
DROP TYPE IF EXISTS app.service_pause_reason;

COMMENT ON COLUMN app.services.status IS
    'Publication and operational status of the service: active, planned_maintenance, and emergency_maintenance are shown in the catalog (only active accepts new orders); draft and archived are hidden. Default draft.';

CREATE OR REPLACE FUNCTION app.tgr_section_services_demote_service_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.section_services ss
        WHERE ss.service_id = OLD.service_id
    ) THEN
        UPDATE app.services
        SET status = 'draft'::app.service_status
        WHERE id = OLD.service_id
          AND status IN (
              'active'::app.service_status,
              'planned_maintenance'::app.service_status,
              'emergency_maintenance'::app.service_status
          );
    END IF;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION app.tgr_section_services_demote_service_status() IS
    'AFTER DELETE on app.section_services. Demotes the service to draft when its last catalog section placement is removed while status is active, planned_maintenance, or emergency_maintenance.';

DROP TRIGGER IF EXISTS tgr_section_services_demote_service_status ON app.section_services;

CREATE TRIGGER tgr_section_services_demote_service_status
AFTER DELETE ON app.section_services
FOR EACH ROW EXECUTE FUNCTION app.tgr_section_services_demote_service_status();

-- Unused own-item permissions. Grants go first; permission_key is referenced
-- by app.group_permissions with ON DELETE CASCADE.
DELETE FROM app.group_permissions
WHERE permission_key IN (
    'adminServices:items:read:own',
    'adminServices:items:update:own',
    'adminServices:items:delete:own'
);

DELETE FROM app.permissions
WHERE permission_key IN (
    'adminServices:items:read:own',
    'adminServices:items:update:own',
    'adminServices:items:delete:own'
);

-- role.adminServices.auditor is replaced by role.service.auditor.
-- prevent_system_group_deletion blocks DELETE while is_system is true.
DELETE FROM app.group_permissions gp
USING app.groups g
WHERE gp.group_id = g.group_id
  AND g.group_name = 'role.adminServices.auditor';

UPDATE app.groups
SET is_system = false
WHERE group_name = 'role.adminServices.auditor';

DELETE FROM app.group_members gm
USING app.groups g
WHERE gm.group_id = g.group_id
  AND g.group_name = 'role.adminServices.auditor';

DELETE FROM app.groups
WHERE group_name = 'role.adminServices.auditor';

UPDATE app.groups
SET display_name = 'Role Service Administrators'
WHERE group_name = 'role.adminServices.admin';

UPDATE app.groups
SET display_name = 'Role Service Auditors',
    group_description = 'Service Auditors (read-only access across catalog services, work-item forms, service settings, and all service requests)'
WHERE group_name = 'role.service.auditor';

DO $$
DECLARE
    sys_user_id UUID;
    service_auditor_group_id UUID;
BEGIN
    SELECT user_id INTO sys_user_id FROM app.users WHERE username = 'admin' LIMIT 1;
    IF sys_user_id IS NULL THEN
        RAISE EXCEPTION 'role.service.auditor grant failed: system admin user (username=admin) not found.';
    END IF;

    SELECT group_id INTO service_auditor_group_id
    FROM app.groups
    WHERE group_name = 'role.service.auditor'
    LIMIT 1;
    IF service_auditor_group_id IS NULL THEN
        RAISE EXCEPTION 'role.service.auditor grant failed: group not found.';
    END IF;

    INSERT INTO app.group_permissions (group_id, permission_key, granted_by)
    SELECT service_auditor_group_id, permission_key, sys_user_id
    FROM app.permissions
    WHERE permission_key IN (
        'adminServices:module:access',
        'adminServices:settings:access',
        'adminServices:settings:read:all',
        'adminServices:items:read:all',
        'service:requests:read:all'
    )
    ON CONFLICT DO NOTHING;
END $$;

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.28.3',
        'Replaced app.work_item_forms.catalog_visible with catalog_status (draft, active, on hold, discontinued). Visible offerings with a bound service and a current version became active; every other form became draft. Active requires a bound service and a current version. Clearing a form service binding sets catalog_status to draft and catalog_order to 0; clearing current_version_id while active sets catalog_status to draft. Replaced app.services.operational_status, pause_reason, and catalog_visible with status (draft, active, planned_maintenance, emergency_maintenance, archived). Visible services with a section placement mapped available to active and kept planned_maintenance or emergency_maintenance; paused and hidden or unplaced services became draft. Removing the last catalog section placement of a service demotes active, planned_maintenance, or emergency_maintenance to draft. Removed unused adminServices own-item permissions and role.adminServices.auditor. role.adminServices.admin display name is Role Service Administrators. role.service.auditor is the read-only role across catalog services, work-item forms, service settings, and all service requests.'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.28.3', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

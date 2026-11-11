-- Version: 0.21.8
-- Description: Extend schema_migrations audit columns; idempotent repair of m_15 publication cutover
--   for databases where schema_version was bumped without the full m_15 DDL (partial apply / skip).
--   Also carries the service data model overhaul, the organizations short_name/system-org
--   cleanup, the organization_employees -> organization_staff rename, the Visibility ACL
--   is_public -> audience rename, the section_services placement table recreation, the
--   users.expiry-sweep index + pg_cron schedule, and the app.instance.available_releases
--   column for the (unreleased) 0.21.8 cycle.
-- Backend file: m_0.21.8_service_model_and_migration_audit.sql
--
-- Changes in v0.21.8:
-- - Added app.instance.available_releases JSONB (default '[]') — list of stable releases
--   newer than the installed version (version/min_version/compatible/release_notes/
--   published_at), written by evi-worker's update check for the in-app Updates page.
--
-- Changes in v1.8.0:
-- - Added idx_users_expires_at_active and registered users-expiry-sweep pg_cron job
--   (*/5 * * * * → users.expiry-sweep) so evi-worker can expire accounts past expires_at.
--
-- Changes in v1.7.0:
-- - Recreated app.section_services (dropped earlier in this same migration by the m_15 repair
--   section below) so catalog services can be placed into catalog sections and shown as cards,
--   mirroring app.section_product_lines (PK(section_id, service_id) + UNIQUE(service_id)).
--
-- Changes in v1.6.0:
-- - app.entity_acl: replaced is_public (bool) with audience (custom/staff/registered/public),
--   the Visibility subsystem's new explicit access-level ladder. Existing is_public=true rows
--   backfill to audience='registered' (exact behavioral match — is_public never meant
--   "no authentication required", only "all authenticated users", which is now spelled
--   "registered"). Appended to this file per the "append while unreleased" rule (see v1.1.0).
--
-- Changes in v1.5.0:
-- - Renamed app.organization_employees to app.organization_staff (table, unique constraint,
--   index), matching the org module's "employees" -> "staff" terminology rename.
-- - Renamed permission adminOrg:organizations:manage_employees:all to
--   adminOrg:organizations:manage_staff:all (existing group_permissions grants repointed).
-- - Backfilled app.organization_staff with a System Organization membership row for every
--   user whose app.users_standard_profiles.is_staff is true, so the pre-existing "organization
--   employee" flag (now surfaced as the "staff member" checkbox) keeps its meaning for pilot
--   installations where user accounts already exist.
--
-- Changes in v1.4.0:
-- - Organizations module has no pilot installations relying on short_name or on the system
--   org's name being fixed, so appended (same unreleased-cycle rule as the services section
--   above) a straight DDL change, no data migration: dropped app.organizations.short_name;
--   added uq_organizations_single_system partial unique index on (is_system) WHERE is_system
--   to guarantee at most one system organization row can ever exist.
--
-- Changes in v1.3.0:
-- - Service card visibility moved from per-row flags to global admin settings (same pattern as
--   the AdminProducts.product.card.visibility.* cutover earlier in this file): dropped
--   app.services.show_owner/show_technical_owner/show_dispatcher/show_support_tier1/2/3 and
--   idx_services_visibility_prefs; added AdminServices.service.card.visibility.{owner,
--   technical.owner,dispatcher,support.tier1,support.tier2,support.tier3} (public settings).
-- - Added adminServices:settings:update:all / adminServices:settings:read:all permissions,
--   granted to role.adminServices.admin (both) and role.adminServices.auditor (read:all only).
--
-- Changes in v1.2.0:
-- - Renamed from m_17_repair_m15_publication_cutover.sql to the release-versioned naming scheme
--   m_<X.Y.Z>_<description>.sql (migration id m_0.21.8). Legacy m_2..m_16 files removed from the
--   kit (all pilot installations are on 0.21.7; minVersion is raised to 0.21.7).
-- - Internal migration id references updated from 'm_17' to 'm_0.21.8'
--   (set_migration_output_summary calls and error messages).
--
-- Changes in v1.1.0:
-- - Service data model overhaul appended to this migration because 0.21.8 is still the current
--   unreleased cycle (no v0.21.8 tag yet), per the schema-version "append while unreleased" rule.
--   The services module is an early draft with no pilot installs, so app.services /
--   app.service_users / app.service_groups are empty everywhere; the section TRUNCATEs them and
--   recreates the service enums (value removals) with no data migration:
--   * app.service_status 10 -> 6 lifecycle values; added app.service_type (business/supporting).
--   * app.service_user_role -> (technical_owner, dispatcher); app.service_group_role ->
--     (support_tier1..3). Owner moved to a first-class app.services.owner_user_id; backup roles
--     and the old access_allowed/access_denied roles + is_public dropped (Visibility ACL now
--     governs read access).
--   * app.services: name/description_short/description_long/purpose moved to the new
--     app.service_translations table; added service_code, translation_key, service_type,
--     owner_user_id, review_date, service_hours; dropped show_backup_* card flags.
--
-- Changes in v1.0.1:
-- - Rescheduled 'evi-update-check' pg_cron job to run 3× daily at 00:07 / 08:07 / 16:07
--   (PostgreSQL server local time) — enqueues system.update-check.
--
-- Changes in v1.0.0:
-- - ALTER app.schema_migrations: migration_file, schema_version_before/after, status, errors, output_summary.
-- - app.set_migration_output_summary() helper for migrations to record a success summary.
-- - Idempotent re-apply of m_15 v1.1.0+ publication cleanup, placement UNIQUE constraints, triggers,
--   AdminProducts settings, and publisher RBAC removal (no catalog-count precondition).
-- - Post-repair validation; writes summary via set_migration_output_summary.
-- - Bumped app.instance.schema_version to 0.21.8.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Extend schema_migrations for per-migration audit (upgraded databases)
-- ---------------------------------------------------------------------------

ALTER TABLE app.schema_migrations
    ADD COLUMN IF NOT EXISTS migration_file VARCHAR(255),
    ADD COLUMN IF NOT EXISTS schema_version_before VARCHAR(20),
    ADD COLUMN IF NOT EXISTS schema_version_after VARCHAR(20),
    ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'success',
    ADD COLUMN IF NOT EXISTS error_message TEXT,
    ADD COLUMN IF NOT EXISTS error_detail TEXT,
    ADD COLUMN IF NOT EXISTS output_summary TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'schema_migrations_status_check'
          AND conrelid = 'app.schema_migrations'::regclass
    ) THEN
        ALTER TABLE app.schema_migrations
            ADD CONSTRAINT schema_migrations_status_check
            CHECK (status IN ('success', 'failed', 'skipped'));
    END IF;
END $$;

UPDATE app.schema_migrations
SET migration_file = COALESCE(migration_file, version || '.sql')
WHERE migration_file IS NULL;

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

-- ---------------------------------------------------------------------------
-- 2. Preflight: placement UNIQUE constraints need at most one row per product/line
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    dup_products BIGINT := 0;
    dup_lines BIGINT := 0;
BEGIN
    SELECT COUNT(*) INTO dup_products
    FROM (
        SELECT product_id FROM app.section_products GROUP BY product_id HAVING COUNT(*) > 1
        UNION ALL
        SELECT product_id FROM app.product_line_products GROUP BY product_id HAVING COUNT(*) > 1
    ) d;

    SELECT COUNT(*) INTO dup_lines
    FROM (
        SELECT line_id FROM app.section_product_lines GROUP BY line_id HAVING COUNT(*) > 1
    ) d;

    IF dup_products > 0 OR dup_lines > 0 THEN
        RAISE EXCEPTION
            'm_0.21.8 repair blocked: duplicate placement rows prevent UNIQUE constraints (duplicate_products=%, duplicate_lines=%). Resolve placements manually before retrying.',
            dup_products, dup_lines;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Idempotent m_15 publication cutover repair (no catalog-count precondition)
-- ---------------------------------------------------------------------------

DROP INDEX IF EXISTS idx_products_published;
DROP INDEX IF EXISTS idx_product_line_products_published;
DROP INDEX IF EXISTS idx_section_services_order;
DROP INDEX IF EXISTS idx_section_services_section;
DROP INDEX IF EXISTS idx_section_services_service;
DROP INDEX IF EXISTS idx_section_products_product;
DROP INDEX IF EXISTS idx_product_line_products_product;
DROP INDEX IF EXISTS idx_section_product_lines_line;

DROP TABLE IF EXISTS app.section_services;

ALTER TABLE app.products
    DROP COLUMN IF EXISTS is_published,
    DROP COLUMN IF EXISTS show_as_product_card,
    DROP COLUMN IF EXISTS is_visible_owner,
    DROP COLUMN IF EXISTS is_visible_groups,
    DROP COLUMN IF EXISTS is_visible_tech_specs,
    DROP COLUMN IF EXISTS is_visible_long_description;

ALTER TABLE app.products
    ADD COLUMN IF NOT EXISTS show_as_product_card BOOLEAN NOT NULL DEFAULT true;

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
('AdminProducts', 'product.card.visibility.owner', 'all', 'true', '{"type":"boolean"}', 'true', 'Show the product owner field on every product card in the catalog', true),
('AdminProducts', 'product.card.visibility.specialists', 'all', 'true', '{"type":"boolean"}', 'true', 'Show the product specialists (contacts) field on every product card in the catalog', true),
('AdminProducts', 'product.card.visibility.tech.specs', 'all', 'true', '{"type":"boolean"}', 'true', 'Show the technical specifications section on every product card in the catalog', true),
('AdminProducts', 'product.card.visibility.long.description', 'all', 'true', '{"type":"boolean"}', 'true', 'Show the long description section on every product card in the catalog', true)
ON CONFLICT (section_path, setting_name, environment) DO NOTHING;

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
('AdminProducts', 'auto.link.by.catalog.number.enabled', 'all', 'false', '{"type":"boolean"}', 'false', 'Automatically link products whose catalog numbers (product_code) share a common leading prefix by creating an optional product_options relation.', true),
('AdminProducts', 'auto.link.by.catalog.number.prefix.length', 'all', '6', '{"type":"integer","minimum":1,"maximum":50}', '6', 'Number of leading catalog-number characters compared when auto-linking products.', true),
('AdminProducts', 'auto.link.by.catalog.number.match.on.update', 'all', 'false', '{"type":"boolean"}', 'false', 'Also run catalog-number auto-linking when an existing product is updated (in addition to on create).', true)
ON CONFLICT (section_path, setting_name, environment) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_products_code_lower_pattern ON app.products (LOWER(product_code) varchar_pattern_ops);

ALTER TABLE app.product_lines
    DROP COLUMN IF EXISTS is_published;

ALTER TABLE app.product_line_products
    DROP COLUMN IF EXISTS is_published,
    DROP COLUMN IF EXISTS published_by,
    DROP COLUMN IF EXISTS published_at;

ALTER TABLE app.section_products
    DROP COLUMN IF EXISTS published_by,
    DROP COLUMN IF EXISTS published_at;

ALTER TABLE app.section_product_lines
    DROP COLUMN IF EXISTS published_by,
    DROP COLUMN IF EXISTS published_at;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_section_products_product'
          AND conrelid = 'app.section_products'::regclass
    ) THEN
        ALTER TABLE app.section_products
            ADD CONSTRAINT uq_section_products_product UNIQUE (product_id);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_product_line_products_product'
          AND conrelid = 'app.product_line_products'::regclass
    ) THEN
        ALTER TABLE app.product_line_products
            ADD CONSTRAINT uq_product_line_products_product UNIQUE (product_id);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_section_product_lines_line'
          AND conrelid = 'app.section_product_lines'::regclass
    ) THEN
        ALTER TABLE app.section_product_lines
            ADD CONSTRAINT uq_section_product_lines_line UNIQUE (line_id);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION app.tgr_catalog_product_single_placement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
    FROM app.products p
    WHERE p.product_id = NEW.product_id
    FOR UPDATE;

    IF TG_TABLE_NAME = 'section_products' THEN
        IF EXISTS (
            SELECT 1
            FROM app.product_line_products plp
            WHERE plp.product_id = NEW.product_id
        ) THEN
            RAISE EXCEPTION 'Placement conflict for product %: already assigned to product line', NEW.product_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'product_line_products' THEN
        IF EXISTS (
            SELECT 1
            FROM app.section_products sp
            WHERE sp.product_id = NEW.product_id
        ) THEN
            RAISE EXCEPTION 'Placement conflict for product %: already assigned to catalog section', NEW.product_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_section_products_single_placement ON app.section_products;
CREATE TRIGGER tgr_section_products_single_placement
BEFORE INSERT OR UPDATE ON app.section_products
FOR EACH ROW
EXECUTE FUNCTION app.tgr_catalog_product_single_placement();

DROP TRIGGER IF EXISTS tgr_product_line_products_single_placement ON app.product_line_products;
CREATE TRIGGER tgr_product_line_products_single_placement
BEFORE INSERT OR UPDATE ON app.product_line_products
FOR EACH ROW
EXECUTE FUNCTION app.tgr_catalog_product_single_placement();

DELETE FROM app.group_permissions
WHERE permission_key IN (
    'adminCatalog:publishing:services:read:all',
    'adminCatalog:publishing:services:update:all',
    'adminCatalog:publishing:products:read:all',
    'adminCatalog:publishing:products:update:all'
);

DELETE FROM app.permissions
WHERE permission_key IN (
    'adminCatalog:publishing:services:read:all',
    'adminCatalog:publishing:services:update:all',
    'adminCatalog:publishing:products:read:all',
    'adminCatalog:publishing:products:update:all'
);

UPDATE app.groups
SET is_system = false
WHERE group_name IN (
    'role.adminCatalog.products.publisher',
    'role.adminCatalog.services.publisher'
);

DELETE FROM app.group_members gm
USING app.groups g
WHERE gm.group_id = g.group_id
  AND g.group_name IN (
      'role.adminCatalog.products.publisher',
      'role.adminCatalog.services.publisher'
  );

DELETE FROM app.groups
WHERE group_name IN (
    'role.adminCatalog.products.publisher',
    'role.adminCatalog.services.publisher'
);

-- ---------------------------------------------------------------------------
-- 4. Post-repair validation (same invariants as m_15 v1.1.0+)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    problems TEXT[] := ARRAY[]::TEXT[];
    repaired TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF to_regclass('app.section_services') IS NULL THEN
        repaired := array_append(repaired, 'section_services dropped');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'products' AND column_name = 'is_published'
    ) THEN
        repaired := array_append(repaired, 'products publication columns cleaned');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_section_product_lines_line'
          AND conrelid = 'app.section_product_lines'::regclass
    ) THEN
        problems := array_append(problems, 'uq_section_product_lines_line missing');
    ELSE
        repaired := array_append(repaired, 'uq_section_product_lines_line present');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_product_line_products_product'
          AND conrelid = 'app.product_line_products'::regclass
    ) THEN
        problems := array_append(problems, 'uq_product_line_products_product missing');
    ELSE
        repaired := array_append(repaired, 'uq_product_line_products_product present');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_section_products_product'
          AND conrelid = 'app.section_products'::regclass
    ) THEN
        problems := array_append(problems, 'uq_section_products_product missing');
    ELSE
        repaired := array_append(repaired, 'uq_section_products_product present');
    END IF;

    IF array_length(problems, 1) IS NOT NULL THEN
        RAISE EXCEPTION 'm_0.21.8 repair validation failed: %', array_to_string(problems, '; ');
    END IF;

    PERFORM app.set_migration_output_summary(
        'm_0.21.8',
        'Publication cutover repair OK: ' || array_to_string(repaired, '; ')
    );
END $$;

-- ---------------------------------------------------------------------------
-- Update check schedule: 3× daily at 00:07 / 08:07 / 16:07 (PostgreSQL server local time)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    PERFORM cron.unschedule('evi-update-check');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'evi-update-check',
    '7 0,8,16 * * *',
    $$INSERT INTO app.worker_jobs (job_type, payload) VALUES ('system.update-check', '{}'::jsonb)$$
);

-- ---------------------------------------------------------------------------
-- 5. Service data model overhaul
--    The services module is an early draft with NO pilot installations using it, so
--    app.services / app.service_users / app.service_groups are empty in every environment.
--    That lets us recreate the service enums (value removals) and restructure the table with
--    no data migration. TRUNCATE guarantees the enum casts below never hit a legacy value.
-- ---------------------------------------------------------------------------

TRUNCATE TABLE app.services CASCADE;

-- 5.1 New service_type enum
DO $$ BEGIN
    CREATE TYPE app.service_type AS ENUM ('business', 'supporting');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- 5.2 service_status: 10 -> 6 lifecycle values (recreate by swap; guarded/idempotent)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
        WHERE t.typname = 'service_status' AND e.enumlabel = 'active'
    ) THEN
        ALTER TABLE app.services ALTER COLUMN status DROP DEFAULT;
        ALTER TYPE app.service_status RENAME TO service_status__old;
        CREATE TYPE app.service_status AS ENUM ('draft', 'pending_approval', 'active', 'under_maintenance', 'suspended', 'discontinued');
        ALTER TABLE app.services
            ALTER COLUMN status TYPE app.service_status USING status::text::app.service_status;
        ALTER TABLE app.services ALTER COLUMN status SET DEFAULT 'draft'::app.service_status;
        ALTER TABLE app.services ALTER COLUMN status SET NOT NULL;
        DROP TYPE app.service_status__old;
    END IF;
END $$;

-- 5.3 service_user_role: drop owner/backup roles + access_denied -> (technical_owner, dispatcher)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
        WHERE t.typname = 'service_user_role' AND e.enumlabel = 'owner'
    ) THEN
        ALTER TYPE app.service_user_role RENAME TO service_user_role__old;
        CREATE TYPE app.service_user_role AS ENUM ('technical_owner', 'dispatcher');
        ALTER TABLE app.service_users
            ALTER COLUMN role_type TYPE app.service_user_role USING role_type::text::app.service_user_role;
        DROP TYPE app.service_user_role__old;
    END IF;
END $$;

-- 5.4 service_group_role: drop access_allowed/access_denied -> (support_tier1..3)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
        WHERE t.typname = 'service_group_role' AND e.enumlabel = 'access_allowed'
    ) THEN
        ALTER TYPE app.service_group_role RENAME TO service_group_role__old;
        CREATE TYPE app.service_group_role AS ENUM ('support_tier1', 'support_tier2', 'support_tier3');
        ALTER TABLE app.service_groups
            ALTER COLUMN role_type TYPE app.service_group_role USING role_type::text::app.service_group_role;
        DROP TYPE app.service_group_role__old;
    END IF;
END $$;

-- 5.5 app.services table restructure
ALTER TABLE app.services
    DROP COLUMN IF EXISTS name,
    DROP COLUMN IF EXISTS description_short,
    DROP COLUMN IF EXISTS description_long,
    DROP COLUMN IF EXISTS purpose,
    DROP COLUMN IF EXISTS is_public,
    DROP COLUMN IF EXISTS show_backup_owner,
    DROP COLUMN IF EXISTS show_backup_technical_owner;

ALTER TABLE app.services
    ADD COLUMN IF NOT EXISTS service_code VARCHAR(150),
    ADD COLUMN IF NOT EXISTS translation_key VARCHAR(150),
    ADD COLUMN IF NOT EXISTS service_type app.service_type NOT NULL DEFAULT 'business'::app.service_type,
    ADD COLUMN IF NOT EXISTS owner_user_id UUID,
    ADD COLUMN IF NOT EXISTS review_date DATE,
    ADD COLUMN IF NOT EXISTS service_hours VARCHAR(100);

ALTER TABLE app.services ALTER COLUMN show_owner SET DEFAULT true;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_services_service_code' AND conrelid = 'app.services'::regclass
    ) THEN
        ALTER TABLE app.services ADD CONSTRAINT uq_services_service_code UNIQUE (service_code);
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_services_translation_key' AND conrelid = 'app.services'::regclass
    ) THEN
        ALTER TABLE app.services ADD CONSTRAINT uq_services_translation_key UNIQUE (translation_key);
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'services_owner_user_id_fkey' AND conrelid = 'app.services'::regclass
    ) THEN
        ALTER TABLE app.services
            ADD CONSTRAINT services_owner_user_id_fkey
            FOREIGN KEY (owner_user_id) REFERENCES app.users(user_id) ON DELETE RESTRICT;
    END IF;
END $$;

-- Tables are empty, so NOT NULL can be enforced without a backfill.
ALTER TABLE app.services ALTER COLUMN translation_key SET NOT NULL;
ALTER TABLE app.services ALTER COLUMN owner_user_id SET NOT NULL;

-- 5.6 app.service_translations (per-language, consumer-facing)
CREATE TABLE IF NOT EXISTS app.service_translations (
    translation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL,
    language_code app.system_language_code NOT NULL,
    name VARCHAR(250) NOT NULL,
    description_short VARCHAR(250),
    description_long VARCHAR(10000),
    purpose VARCHAR(10000),
    sla_summary VARCHAR(500),
    created_by UUID NOT NULL DEFAULT '00000000-0000-0000-0000-00000000dead',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT service_translations_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT uq_service_translations_one_per_lang UNIQUE (service_id, language_code),

    FOREIGN KEY (service_id) REFERENCES app.services(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES app.users(user_id) ON DELETE SET DEFAULT,
    FOREIGN KEY (updated_by) REFERENCES app.users(user_id) ON DELETE SET NULL
);

DROP TRIGGER IF EXISTS tgr_service_translations_set_updated_at ON app.service_translations;
CREATE TRIGGER tgr_service_translations_set_updated_at
BEFORE UPDATE ON app.service_translations
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

-- 5.7 Indexes: rebuild visibility-prefs index (dropped backup columns) + new indexes
DROP INDEX IF EXISTS idx_services_visibility_prefs;
CREATE INDEX IF NOT EXISTS idx_services_visibility_prefs ON app.services USING btree (
    show_owner, show_technical_owner,
    show_dispatcher, show_support_tier1, show_support_tier2, show_support_tier3
);
CREATE INDEX IF NOT EXISTS idx_services_owner_user_id ON app.services USING btree (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_service_translations_service_id ON app.service_translations USING btree (service_id);
CREATE INDEX IF NOT EXISTS idx_service_translations_lang ON app.service_translations USING btree (language_code);

-- ---------------------------------------------------------------------------
-- 6. Service card visibility: per-row flags -> global AdminServices settings
--    app.services is empty everywhere (no pilot install uses the services module yet),
--    so columns are dropped outright with no backfill (same premise as section 5 above).
-- ---------------------------------------------------------------------------

DROP INDEX IF EXISTS idx_services_visibility_prefs;

ALTER TABLE app.services
    DROP COLUMN IF EXISTS show_owner,
    DROP COLUMN IF EXISTS show_technical_owner,
    DROP COLUMN IF EXISTS show_dispatcher,
    DROP COLUMN IF EXISTS show_support_tier1,
    DROP COLUMN IF EXISTS show_support_tier2,
    DROP COLUMN IF EXISTS show_support_tier3;

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
('AdminServices', 'service.card.visibility.owner', 'all', 'true', '{"type":"boolean"}', 'true', 'Show the service owner field on every service card in the catalog', true),
('AdminServices', 'service.card.visibility.technical.owner', 'all', 'false', '{"type":"boolean"}', 'false', 'Show the service technical owner field on every service card in the catalog', true),
('AdminServices', 'service.card.visibility.dispatcher', 'all', 'true', '{"type":"boolean"}', 'true', 'Show the service dispatcher field on every service card in the catalog', true),
('AdminServices', 'service.card.visibility.support.tier1', 'all', 'true', '{"type":"boolean"}', 'true', 'Show the support tier 1 group on every service card in the catalog', true),
('AdminServices', 'service.card.visibility.support.tier2', 'all', 'false', '{"type":"boolean"}', 'false', 'Show the support tier 2 group on every service card in the catalog', true),
('AdminServices', 'service.card.visibility.support.tier3', 'all', 'false', '{"type":"boolean"}', 'false', 'Show the support tier 3 group on every service card in the catalog', true)
ON CONFLICT (section_path, setting_name, environment) DO NOTHING;

INSERT INTO app.permissions (permission_key, module, description)
VALUES
('adminServices:settings:read:all', 'adminServices', 'Read service settings (all)'),
('adminServices:settings:update:all', 'adminServices', 'Update service settings (all)')
ON CONFLICT (permission_key) DO NOTHING;

INSERT INTO app.group_permissions (group_id, permission_key, granted_by)
SELECT g.group_id, p.permission_key, '00000000-0000-0000-0000-00000000dead'
FROM app.groups g
CROSS JOIN app.permissions p
WHERE g.group_name = 'role.adminServices.admin'
  AND p.permission_key IN ('adminServices:settings:read:all', 'adminServices:settings:update:all')
ON CONFLICT DO NOTHING;

INSERT INTO app.group_permissions (group_id, permission_key, granted_by)
SELECT g.group_id, p.permission_key, '00000000-0000-0000-0000-00000000dead'
FROM app.groups g
CROSS JOIN app.permissions p
WHERE g.group_name = 'role.adminServices.auditor'
  AND p.permission_key = 'adminServices:settings:read:all'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Organizations: drop short_name, enforce single system organization
--    The org admin module has no pilot installations depending on short_name or on
--    the system org's name being fixed, so this is a straight DDL change (no data
--    migration): system organization becomes purely an attribute (is_system), and
--    its org_name is now freely editable, same as any other organization's name.
-- ---------------------------------------------------------------------------
ALTER TABLE app.organizations
    DROP COLUMN IF EXISTS short_name;

CREATE UNIQUE INDEX IF NOT EXISTS uq_organizations_single_system
ON app.organizations (is_system)
WHERE is_system;

COMMENT ON INDEX app.uq_organizations_single_system IS
    'Enforces at most one system organization (is_system = true) at a time.';

-- ---------------------------------------------------------------------------
-- 7. Rename app.organization_employees to app.organization_staff; rename the
--    manage_employees permission to manage_staff; backfill staff membership in
--    the System Organization from the existing is_staff profile flag so pilot
--    installations keep the same effective "staff member" set.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'app' AND table_name = 'organization_employees'
    ) THEN
        ALTER TABLE app.organization_employees RENAME TO organization_staff;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organization_employees_org_user_unique') THEN
        ALTER TABLE app.organization_staff
            RENAME CONSTRAINT organization_employees_org_user_unique TO organization_staff_org_user_unique;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'idx_organization_employees_org_id' AND n.nspname = 'app'
    ) THEN
        ALTER INDEX app.idx_organization_employees_org_id RENAME TO idx_organization_staff_org_id;
    END IF;
END $$;

COMMENT ON TABLE app.organization_staff IS 'Junction table linking users to organizations as staff members.';
COMMENT ON COLUMN app.organization_staff.org_id IS 'Organization the user belongs to.';
COMMENT ON COLUMN app.organization_staff.user_id IS 'User account registered as a staff member.';
COMMENT ON COLUMN app.organization_staff.added_by IS 'Admin user who created this membership.';

-- Rename the permission key, repointing existing role grants (no ON UPDATE CASCADE on the
-- permission_key FK, so old-key grants are moved to the new key rather than updated in place).
INSERT INTO app.permissions (permission_key, module, description)
VALUES ('adminOrg:organizations:manage_staff:all', 'adminOrg', 'Add/remove staff members from organizations')
ON CONFLICT (permission_key) DO NOTHING;

UPDATE app.group_permissions gp1
SET permission_key = 'adminOrg:organizations:manage_staff:all'
WHERE gp1.permission_key = 'adminOrg:organizations:manage_employees:all'
  AND NOT EXISTS (
      SELECT 1 FROM app.group_permissions gp2
      WHERE gp2.group_id = gp1.group_id
        AND gp2.permission_key = 'adminOrg:organizations:manage_staff:all'
  );

DELETE FROM app.group_permissions WHERE permission_key = 'adminOrg:organizations:manage_employees:all';
DELETE FROM app.permissions WHERE permission_key = 'adminOrg:organizations:manage_employees:all';

-- Backfill: every standard-profile user currently flagged is_staff becomes a System
-- Organization staff member, preserving the flag's intent now that it is also reflected
-- as real org membership (self-attributed added_by: no better actor is known at migration time).
INSERT INTO app.organization_staff (org_id, user_id, added_by)
SELECT sys_org.org_id, sp.user_id, sp.user_id
FROM app.users_standard_profiles sp
CROSS JOIN (SELECT org_id FROM app.organizations WHERE is_system = true LIMIT 1) sys_org
WHERE sp.is_staff = true
ON CONFLICT ON CONSTRAINT organization_staff_org_user_unique DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. Universal Visibility ACL: replace the ambiguous is_public boolean with an
--    explicit audience preset (custom/staff/registered/public — a strict ladder).
--    "public" now means exactly "no authentication required" everywhere in the
--    Visibility subsystem; the old is_public=true rows only ever granted access to
--    authenticated users, so they backfill to audience='registered' (an exact
--    behavioral match, not a broadening of access).
-- ---------------------------------------------------------------------------
ALTER TABLE app.entity_acl
    ADD COLUMN IF NOT EXISTS audience TEXT NOT NULL DEFAULT 'custom';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app' AND table_name = 'entity_acl' AND column_name = 'is_public'
    ) THEN
        UPDATE app.entity_acl SET audience = 'registered' WHERE is_public = true;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_entity_acl_audience' AND conrelid = 'app.entity_acl'::regclass
    ) THEN
        ALTER TABLE app.entity_acl
            ADD CONSTRAINT chk_entity_acl_audience CHECK (audience IN ('custom', 'staff', 'registered', 'public'));
    END IF;
END $$;

ALTER TABLE app.entity_acl
    DROP COLUMN IF EXISTS is_public;

COMMENT ON COLUMN app.entity_acl.audience IS 'Standard read-access preset: custom (default; use allow lists below) | staff (is_staff users) | registered (any authenticated active user) | public (no authentication required). Ladder: staff subset of registered subset of public.';

-- ---------------------------------------------------------------------------
-- 9. Recreate app.section_services: service placements in catalog sections.
--    Section 3 of this same (still-unreleased) migration dropped the original
--    app.section_services table as part of the m_15 publication cutover repair.
--    The catalog now needs service cards displayed per catalog section (same
--    UX as product-line "folder" cards), so this section restores the table
--    using the current section_product_lines shape/conventions: composite
--    PRIMARY KEY (section_id, service_id) plus UNIQUE(service_id) enforces
--    "one section per service" and both columns are already covered by these
--    two indexes (PK leads with section_id; UNIQUE indexes service_id) — no
--    extra CREATE INDEX statements needed, matching section_product_lines.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS app.section_services (
    section_id UUID NOT NULL REFERENCES app.catalog_sections(id) ON DELETE CASCADE,
    service_id UUID NOT NULL REFERENCES app.services(id) ON DELETE CASCADE,
    PRIMARY KEY (section_id, service_id),
    CONSTRAINT uq_section_services_service UNIQUE (service_id)
);

COMMENT ON TABLE app.section_services IS 'Service placements in catalog sections (one section per service, mirrors section_product_lines).';
COMMENT ON COLUMN app.section_services.section_id IS 'Reference to catalog section';
COMMENT ON COLUMN app.section_services.service_id IS 'Reference to service';

-- ---------------------------------------------------------------------------
-- 10. Account expiry sweep: partial index + pg_cron schedule.
--     evi-worker handles users.expiry-sweep (flip account_status to expired,
--     bump token_version, invalidate authz L1). Same cadence as fs-gc-sweep.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_users_expires_at_active
    ON app.users (expires_at)
    WHERE account_status = 'active' AND expires_at IS NOT NULL;

DO $$
BEGIN
    PERFORM cron.unschedule('users-expiry-sweep');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'users-expiry-sweep',
    '*/5 * * * *',
    $$INSERT INTO app.worker_jobs (job_type, payload) VALUES ('users.expiry-sweep', '{}'::jsonb)$$
);

-- ---------------------------------------------------------------------------
-- 11. available_releases: list of stable GitHub releases newer than the
--     installed version, written by evi-worker's daily update check alongside
--     the existing latest_stable_version/update_available columns. Each array
--     element is {version, min_version, compatible, release_notes,
--     published_at} — powers the "available releases" panel in the in-app
--     Updates page (front/src/modules/about/ModuleUpdates.vue), which lists
--     every pending release (not just the single latest) with its trimmed
--     release notes so admins can see what's new before installing.
-- ---------------------------------------------------------------------------
ALTER TABLE app.instance
    ADD COLUMN IF NOT EXISTS available_releases JSONB NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN app.instance.available_releases IS 'Stable releases newer than the installed version, from the last update check: [{version, min_version, compatible, release_notes, published_at}, ...]. Written by evi-worker (system.update-check); read by GET /api/about/updates.';

SELECT app.set_migration_output_summary(
    'm_0.21.8',
    'Publication cutover repair OK; service model overhaul OK; card visibility settings OK; organizations cleanup OK; organization_staff rename OK; entity_acl audience OK; section_services recreated OK; users expiry sweep index+cron OK; available_releases column OK'
);

UPDATE app.instance
SET schema_version = '0.21.8', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

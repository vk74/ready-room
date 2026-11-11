-- Version: 0.23.2
-- Description: Merge service_offerings into work_item_forms. Catalog binding
--   (service, order, visibility) and per-language title/subject now live on the
--   form; the offering catalog entity is dropped.
-- Backend file: m_0.23.2_merge_offerings_into_forms.sql
--
-- Changes in v0.23.2:
-- - work_item_forms gains service_id, catalog_order, catalog_visible and two
--   CHECKs (only service_request forms may bind a service; catalog_order >= 0).
-- - New app.work_item_form_catalog_translations (title / subject, one row per
--   form per language).
-- - Best-effort data copy from service_offerings / service_offering_translations
--   onto the matching form before drop (earliest offering wins per form_id).
-- - Dropped service_offerings, service_offering_translations and
--   app.service_offering_status.
-- - Dropped service_requests.offering_id; stamp-immutable trigger no longer
--   compares that column.
-- - COMMENT ON work_item_forms.name and service_requests table match db/init
--   (catalog translations / no offering wording) so upgrades dump the same schema.
--
-- Idempotency: every statement is IF NOT EXISTS, a duplicate_object-swallowing DO
-- block, DROP TRIGGER IF EXISTS + CREATE TRIGGER, CREATE OR REPLACE FUNCTION, or
-- DROP TABLE / DROP TYPE / DROP COLUMN / DROP INDEX IF EXISTS. Re-running the
-- file is a no-op after the first successful apply.
--
-- Applies to upgrades from released 0.23.1. Fresh installs take the merged shape
-- from db/init and skip this file (schema_version already 0.23.2).

BEGIN;

-- ===========================================================================
-- 1. work_item_forms — catalog binding columns
-- ===========================================================================

ALTER TABLE app.work_item_forms
    ADD COLUMN IF NOT EXISTS service_id UUID REFERENCES app.services(id) ON DELETE SET NULL;

ALTER TABLE app.work_item_forms
    ADD COLUMN IF NOT EXISTS catalog_order INTEGER NOT NULL DEFAULT 0;

ALTER TABLE app.work_item_forms
    ADD COLUMN IF NOT EXISTS catalog_visible BOOLEAN NOT NULL DEFAULT true;

DO $$
BEGIN
    ALTER TABLE app.work_item_forms
        ADD CONSTRAINT chk_work_item_forms_catalog_service_kind
        CHECK (service_id IS NULL OR work_item_kind = 'service_request'::app.work_item_kind);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE app.work_item_forms
        ADD CONSTRAINT chk_work_item_forms_catalog_order_positive
        CHECK (catalog_order >= 0);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN app.work_item_forms.service_id IS 'Catalog binding (nullable = unbound). Only service_request forms may set this (chk_work_item_forms_catalog_service_kind). ON DELETE SET NULL detaches rather than deleting the form.';
COMMENT ON COLUMN app.work_item_forms.catalog_order IS 'Position within the service''s catalog grid. Non-negative.';
COMMENT ON COLUMN app.work_item_forms.catalog_visible IS 'Admin toggle to pull the card from the catalog without touching publish state or the service binding. Defaults true so publishing a bound form shows up immediately.';
COMMENT ON COLUMN app.work_item_forms.name IS 'Single-language admin label. Not consumer-facing (the catalog shows work_item_form_catalog_translations.title), hence this column has no translations table.';

-- ===========================================================================
-- 2. work_item_form_catalog_translations
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.work_item_form_catalog_translations (
    translation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    form_id        UUID NOT NULL REFERENCES app.work_item_forms(id) ON DELETE CASCADE,
    language_code  app.system_language_code NOT NULL,
    title          VARCHAR(250) NOT NULL,
    subject        VARCHAR(250),
    created_by     UUID NOT NULL DEFAULT '00000000-0000-0000-0000-00000000dead',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_wif_catalog_tr_title_not_blank CHECK (btrim(title) <> ''),
    CONSTRAINT uq_wif_catalog_tr_one_per_lang UNIQUE (form_id, language_code),
    FOREIGN KEY (created_by) REFERENCES app.users(user_id) ON DELETE SET DEFAULT,
    FOREIGN KEY (updated_by) REFERENCES app.users(user_id) ON DELETE SET NULL
);

DROP TRIGGER IF EXISTS tgr_work_item_form_catalog_translations_set_updated_at
    ON app.work_item_form_catalog_translations;
CREATE TRIGGER tgr_work_item_form_catalog_translations_set_updated_at
BEFORE UPDATE ON app.work_item_form_catalog_translations
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.work_item_form_catalog_translations IS 'Per-language catalog card title and subject. One row per form per language, written only for languages the admin filled (single-language forms are valid). Same pattern as app.service_translations.';

-- ===========================================================================
-- 3. Data migration from service_offerings
-- ===========================================================================
-- Best-effort. Offerings without a form_id, or forms referenced by more than one
-- offering, cannot be losslessly migrated into the new 1-form-to-1-service model
-- and are dropped / collapsed. Acceptable: this subsystem is still unreleased to
-- end users. No production rows are expected; this is for leftover dev/test data.
-- Guarded so a re-run after the drop is a no-op.

DO $$
BEGIN
    IF to_regclass('app.service_offerings') IS NULL THEN
        RETURN;
    END IF;

    UPDATE app.work_item_forms AS f
    SET
        service_id      = src.service_id,
        catalog_order   = src."order",
        catalog_visible = (src.status = 'active')
    FROM (
        SELECT DISTINCT ON (form_id)
            form_id,
            service_id,
            "order",
            status
        FROM app.service_offerings
        WHERE form_id IS NOT NULL
        ORDER BY form_id, created_at ASC
    ) AS src
    WHERE f.id = src.form_id
      AND f.service_id IS NULL;

    INSERT INTO app.work_item_form_catalog_translations (
        form_id, language_code, title, subject,
        created_by, created_at, updated_by, updated_at
    )
    SELECT
        so.form_id,
        sot.language_code,
        sot.name,
        sot.description_short,
        sot.created_by,
        sot.created_at,
        sot.updated_by,
        sot.updated_at
    FROM app.service_offering_translations AS sot
    JOIN (
        SELECT DISTINCT ON (form_id)
            id,
            form_id
        FROM app.service_offerings
        WHERE form_id IS NOT NULL
        ORDER BY form_id, created_at ASC
    ) AS so ON so.id = sot.offering_id
    ON CONFLICT (form_id, language_code) DO NOTHING;
END
$$;

-- ===========================================================================
-- 4. Drop service_offerings, translations, enum
-- ===========================================================================

DROP INDEX IF EXISTS app.idx_service_offering_tr_name_trgm;
DROP INDEX IF EXISTS app.idx_service_offering_tr_lang;
DROP INDEX IF EXISTS app.idx_service_offering_tr_offering;
DROP INDEX IF EXISTS app.idx_service_offerings_form;
DROP INDEX IF EXISTS app.idx_service_offerings_service_status_order;
DROP INDEX IF EXISTS app.uq_service_offerings_id_lower;

DROP TABLE IF EXISTS app.service_offerings CASCADE;
DROP TABLE IF EXISTS app.service_offering_translations CASCADE;
DROP TYPE IF EXISTS app.service_offering_status CASCADE;

-- ===========================================================================
-- 5. service_requests — drop offering_id; stamp trigger without that clause
-- ===========================================================================

ALTER TABLE app.service_requests DROP COLUMN IF EXISTS offering_id;

COMMENT ON TABLE app.service_requests IS
    'Submitted service requests. Each row stamps catalog origin (service, frozen form version) and stores title, description, answers, urgency, impact, priority, status, pause_reason, channel, quantity, work_notes, watch_list, assignment pointers, and resolved/closed timestamps. channel is always NULL until inbound channels exist. impact, priority, watch_list, quantity, work_notes, pause_reason, assignment and resolved/closed stamps are stored only — no fill logic in this release.';

CREATE OR REPLACE FUNCTION app.tgr_service_requests_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    deleted_user CONSTANT UUID := '00000000-0000-0000-0000-00000000dead';
BEGIN
    IF NEW.request_number       IS DISTINCT FROM OLD.request_number
       OR NEW.service_id          IS DISTINCT FROM OLD.service_id
       OR NEW.form_version_id     IS DISTINCT FROM OLD.form_version_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR (
            NEW.requester_user_id IS DISTINCT FROM OLD.requester_user_id
            AND NEW.requester_user_id IS DISTINCT FROM deleted_user
          )
    THEN
        RAISE EXCEPTION 'service request %: submission stamp is immutable', OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

-- ===========================================================================
-- 6. New catalog indexes
-- ===========================================================================

CREATE INDEX IF NOT EXISTS idx_work_item_forms_service_status_order
    ON app.work_item_forms USING btree (service_id, status, catalog_order);
CREATE INDEX IF NOT EXISTS idx_work_item_form_catalog_tr_form
    ON app.work_item_form_catalog_translations USING btree (form_id);
CREATE INDEX IF NOT EXISTS idx_work_item_form_catalog_tr_lang
    ON app.work_item_form_catalog_translations USING btree (language_code);
CREATE INDEX IF NOT EXISTS idx_work_item_form_catalog_tr_title_trgm
    ON app.work_item_form_catalog_translations USING gin (lower(title) gin_trgm_ops);

-- ===========================================================================
-- 7. Version stamp
-- ===========================================================================

SELECT app.set_migration_output_summary('m_0.23.2', 'Merged service_offerings into work_item_forms: catalog binding (service_id, catalog_order, catalog_visible) plus per-language title/subject now live on the form; service_offerings and service_offering_translations dropped; service_requests.offering_id dropped.');

UPDATE app.instance SET schema_version = '0.23.2', last_updated_at = NOW() WHERE id = 1;

COMMIT;

-- Version: 0.23.2
-- Description: Service request subsystem — design-time forms and processes, the catalog
--   binding (service offerings), service_requests, work_item_history_events,
--   email_log, Work.Visibility settings, and a single-root staff tree.
-- Backend file: m_0.23.1_service_requests_and_processes.sql
--
-- Changes in v0.23.2:
-- - Seed AdminOrgMgmt.users.change.username.enabled (default false, not public)
--   so an upgrade from 0.22.1 converges with a fresh install. ON CONFLICT DO
--   NOTHING: an existing row keeps the administrator's value.
--
-- Changes in v0.23.1:
-- - Service-request stack: 13 enums and 9 tables (work-item forms and versions,
--   process templates and versions, offerings and translations, service_requests,
--   work_item_history_events, email_log).
-- - Enums, not lookup tables: these are code-driven states; adding a value is a
--   code change anyway.
-- - Identity/version split: published versions are frozen so a later correction
--   cannot rewrite a stamped document. Forms and processes carry a UUID PK plus
--   a server-generated admin id (form-{5hex} / proc-{5hex}); offerings use
--   offer-{5hex}.
-- - Request status vocabulary is new / pending_approval / approved / in_progress /
--   paused / resolved / reopened / closed / rejected / cancelled / failed.
-- - Hold is one state (paused) plus request_pause_reason (awaiting_requester /
--   awaiting_third_party / scheduled / other). The enum and column stay; there
--   is no CHECK or fill logic tying pause_reason / resolved_at / closed_at to status.
-- - service_requests attribute set: subject renamed to title (CHECK and trigram
--   index follow); description, impact, priority, watch_list, quantity, work_notes
--   added as nullable storage-only columns; channel is nullable with no default
--   (always NULL until inbound channels exist); stamp-immutable trigger no longer
--   compares channel. request_impact and request_priority use low/medium/high/critical;
--   priority is not computed from impact and urgency.
-- - service_offerings.service_id and form_id are nullable so an offering may be
--   authored unbound and attached later; catalog still only surfaces bound
--   active offerings. offering.form_id is a bare FK (no kind-check trigger).
-- - Request-stack user FKs (requester / requested_for / created_by, history
--   actor_user_id) use ON DELETE SET DEFAULT → seeded Deleted User so
--   hard-deleting a person does not require closing requests. Stamp-immutable
--   trigger allows only that requester_user_id substitution.
-- - Work item numbers: sr- + 6-char base36 (app.int_to_base36_6,
--   app.work_item_id_prefix). Prefix map also covers ir-/pr-/cr-/rr-. CHECK
--   ^sr-[0-9a-z]{6}$.
-- - app.work_item_history_event_type: created, updated, status_changed,
--   assigned_group, assigned_to, assigned_watcher, added_worknotes,
--   updated_priority, approved, rejected, cancelled, resolved, complete.
-- - Forms and processes are authorized via the existing adminServices module.
--   Work module access is gated by work.module.enabled (no requests:* module).
-- - Settings: allowed.languages for AdminForms / AdminProcesses; four
--   AdminServices.Fs.Quotas keys; seven Work.Visibility keys.
-- - Upgrade from the released 0.21.8 service model (still present on 0.22.1):
--   service_translations has no sla_summary; services has no review_date /
--   service_hours; services.service_id is VARCHAR(20) NOT NULL (from the released
--   service_code column) with a case-insensitive unique index.
-- - User hierarchy: users_standard_profiles.manager_user_id (FK ON DELETE SET
--   NULL), CHECK not-self, partial index. Trigger rejects cycles and depth > 64
--   and allows at most one root among standard staff (is_staff). End users sit
--   outside that tree; anyone may have NULL. No org-structure backfill — the
--   administrator builds the tree. Single-root check skipped when
--   app.manager_root_transfer = 1 (transaction-local root transfer).
-- - Service request tables have no due-date columns. No Service Level Management
--   tables, permissions, settings, or cron job.
--
-- Idempotency: every statement is IF NOT EXISTS, a duplicate_object-swallowing DO
-- block, DROP TRIGGER IF EXISTS + CREATE TRIGGER, CREATE OR REPLACE FUNCTION, or
-- DROP COLUMN IF EXISTS / DROP INDEX IF EXISTS. Re-running the file is a no-op.
--
-- Applies to upgrades from released 0.22.1. A database that already applied an
-- earlier draft of this same unreleased migration is not repaired — there are no
-- draft-era ALTER scaffolds, because the release never shipped and no such
-- installations exist. Dev databases are rebuilt from db/init.

BEGIN;

-- ===========================================================================
-- 1. Enums
-- ===========================================================================
-- Enums (not lookup tables) because these are code-driven states: the engine branches on
-- them in Go, so adding a value is a code change anyway.

DO $$ BEGIN CREATE TYPE app.work_item_kind AS ENUM ('service_request', 'incident', 'problem', 'change', 'release'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.work_item_form_status AS ENUM ('draft', 'active', 'archived'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.work_item_form_version_status AS ENUM ('draft', 'published', 'retired'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.process_status AS ENUM ('draft', 'active', 'archived'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.process_version_status AS ENUM ('draft', 'published', 'retired'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.service_offering_status AS ENUM ('draft', 'active', 'suspended', 'archived'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.request_urgency AS ENUM ('low', 'medium', 'high', 'critical'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.request_impact AS ENUM ('low', 'medium', 'high', 'critical'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE app.request_impact IS
    'Impact levels for a service request: low, medium, high, critical (same ladder as request_urgency). Stored only; no fill logic and no priority calculation from impact and urgency in this release.';
DO $$ BEGIN CREATE TYPE app.request_priority AS ENUM ('low', 'medium', 'high', 'critical'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE app.request_priority IS
    'Priority levels for a service request: low, medium, high, critical. Stored only; values are set manually. This release does not compute priority from impact and urgency.';
DO $$ BEGIN CREATE TYPE app.request_status AS ENUM (
    'new', 'pending_approval', 'approved', 'in_progress', 'paused',
    'resolved', 'reopened', 'closed', 'rejected', 'cancelled', 'failed'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE app.request_pause_reason AS ENUM (
    'awaiting_requester', 'awaiting_third_party', 'scheduled', 'other'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE app.request_pause_reason IS
    'Hold-reason codes for a paused service request. awaiting_requester and awaiting_third_party are outside the support team''s control, scheduled is planned work, other keeps the clock running. Stored on service_requests.pause_reason; no fill logic and no CHECK tying the column to status in this release.';
DO $$ BEGIN CREATE TYPE app.request_channel AS ENUM ('portal', 'email', 'api', 'agent'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Recreate the history event enum with the labels 0.23.1 ships. 0.23.1 never shipped, so
-- the only rows that can exist were written by a discarded draft of this same migration.
-- The table is dropped rather than patched column by column: nothing reads it yet, and
-- section 6 recreates it against the new type.
DROP TABLE IF EXISTS app.work_item_history_events;
DROP TYPE IF EXISTS app.work_item_history_event_type;
CREATE TYPE app.work_item_history_event_type AS ENUM (
    'created', 'updated', 'status_changed', 'assigned_group', 'assigned_to',
    'assigned_watcher', 'added_worknotes', 'updated_priority', 'approved',
    'rejected', 'cancelled', 'resolved', 'complete'
);

COMMENT ON TYPE app.work_item_history_event_type IS
    'Work item history event discriminator: created, updated, status_changed, assigned_group, assigned_to, assigned_watcher, added_worknotes, updated_priority, approved, rejected, cancelled, resolved, complete. Paired with a meta JSONB payload on app.work_item_history_events.';

-- ===========================================================================
-- 2. Work item forms (design time)
-- ===========================================================================
-- Identity / version split: a runtime work item references a frozen version, so correcting
-- a form can never rewrite the meaning of an item already in flight. Naming is
-- practice-neutral (work_item_*) — incidents and changes reuse these tables with a
-- different work_item_kind rather than getting tables of their own.

CREATE TABLE IF NOT EXISTS app.work_item_forms (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    form_id            VARCHAR(20) NOT NULL,
    work_item_kind     app.work_item_kind NOT NULL,
    name               VARCHAR(250) NOT NULL,
    status             app.work_item_form_status NOT NULL DEFAULT 'draft'::app.work_item_form_status,
    current_version_id UUID,
    owner_user_id      UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_by         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_work_item_forms_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT chk_work_item_forms_active_has_version
        CHECK (status <> 'active'::app.work_item_form_status OR current_version_id IS NOT NULL)
);

DROP TRIGGER IF EXISTS tgr_work_item_forms_set_updated_at ON app.work_item_forms;
CREATE TRIGGER tgr_work_item_forms_set_updated_at
BEFORE UPDATE ON app.work_item_forms
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.work_item_forms IS 'Work item form identity (service request, incident, problem, change). Carries no fields itself — those live on app.work_item_form_versions.';
COMMENT ON COLUMN app.work_item_forms.form_id IS 'Server-generated admin id: form-{5 lowercase hex}, assigned once on create. Case-insensitive unique. Distinct from the row UUID (id).';
COMMENT ON COLUMN app.work_item_forms.work_item_kind IS 'Practice this form serves. Product code, not admin data: decides which core field section applies and whether the form may be published in the service catalog at all.';
COMMENT ON COLUMN app.work_item_forms.name IS 'Single-language admin label. Not consumer-facing (the catalog shows the offering name), hence no translations table.';
COMMENT ON COLUMN app.work_item_forms.current_version_id IS 'Published version new work items start from. NULL while the form has only drafts.';

CREATE TABLE IF NOT EXISTS app.work_item_form_versions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    form_id    UUID NOT NULL REFERENCES app.work_item_forms(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    status         app.work_item_form_version_status NOT NULL DEFAULT 'draft'::app.work_item_form_version_status,
    definition     JSONB NOT NULL DEFAULT '{}'::jsonb,
    change_note    VARCHAR(500),
    published_at   TIMESTAMPTZ,
    published_by   UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    created_by     UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_work_item_form_versions_number UNIQUE (form_id, version_number),
    CONSTRAINT chk_wit_versions_number_positive CHECK (version_number >= 1),
    CONSTRAINT chk_wit_versions_definition_object CHECK (jsonb_typeof(definition) = 'object'),
    CONSTRAINT chk_wit_versions_publish_stamp CHECK (
        (status = 'draft'::app.work_item_form_version_status AND published_at IS NULL)
        OR (status <> 'draft'::app.work_item_form_version_status AND published_at IS NOT NULL)
    )
);

DROP TRIGGER IF EXISTS tgr_work_item_form_versions_set_updated_at ON app.work_item_form_versions;
CREATE TRIGGER tgr_work_item_form_versions_set_updated_at
BEFORE UPDATE ON app.work_item_form_versions
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.work_item_form_versions IS 'Immutable snapshot of a work item form body. Published versions are frozen; retired ones keep serving items that already reference them.';
COMMENT ON COLUMN app.work_item_form_versions.definition IS 'Frozen form document: {form:{fields:[{key,type,required,section,label,hint,enabled,allowRichText,options,...}]}, allowRequesterUrgency}. camelCase keys; localized strings are LocalizedText maps ({"english":"...","russian":"..."}) with one-language-only allowed. enabled/allowRichText default true when absent.';
COMMENT ON COLUMN app.work_item_form_versions.published_at IS 'Set when the version is published; from then on the row is frozen except status/change_note/audit columns.';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'work_item_forms_current_version_id_fkey'
          AND conrelid = 'app.work_item_forms'::regclass
    ) THEN
        ALTER TABLE app.work_item_forms
            ADD CONSTRAINT work_item_forms_current_version_id_fkey
            FOREIGN KEY (current_version_id)
            REFERENCES app.work_item_form_versions(id) ON DELETE SET NULL;
    END IF;
END $$;

-- ===========================================================================
-- 3. Processes (design time)
-- ===========================================================================
-- A process is a standalone entity: the same approval chain can be reused, and a
-- purely automated process has no parent work item at all. That is why there is
-- no process_kind enum here.

CREATE TABLE IF NOT EXISTS app.process_templates (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Server-assigned once on create: proc-{5 lowercase hex}, e.g. proc-2fed7.
    process_id         VARCHAR(20) NOT NULL,
    name               VARCHAR(250) NOT NULL,
    status             app.process_status NOT NULL DEFAULT 'draft'::app.process_status,
    current_version_id UUID,
    categories         JSONB NOT NULL DEFAULT '[]'::jsonb,
    owner_user_id      UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_by         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_process_templates_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT chk_process_templates_categories_array CHECK (jsonb_typeof(categories) = 'array'),
    CONSTRAINT chk_process_templates_active_has_version
        CHECK (status <> 'active'::app.process_status OR current_version_id IS NOT NULL)
);

DROP TRIGGER IF EXISTS tgr_process_templates_set_updated_at ON app.process_templates;
CREATE TRIGGER tgr_process_templates_set_updated_at
BEFORE UPDATE ON app.process_templates
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.process_templates IS 'Process identity — the reusable "how work is done" entity. Carries no body itself; that lives on app.process_template_versions.';
COMMENT ON COLUMN app.process_templates.process_id IS 'Server-generated admin id: proc-{5 lowercase hex}, assigned once on create. Case-insensitive unique. Distinct from the row UUID (id).';
COMMENT ON COLUMN app.process_templates.categories IS 'Free-form library labels as a JSONB array of strings. No semantics — never used to type the process.';

CREATE TABLE IF NOT EXISTS app.process_template_versions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id     UUID NOT NULL REFERENCES app.process_templates(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    status         app.process_version_status NOT NULL DEFAULT 'draft'::app.process_version_status,
    definition     JSONB NOT NULL DEFAULT '{}'::jsonb,
    change_note    VARCHAR(500),
    published_at   TIMESTAMPTZ,
    published_by   UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    created_by     UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_process_template_versions_number UNIQUE (process_id, version_number),
    CONSTRAINT chk_process_versions_number_positive CHECK (version_number >= 1),
    CONSTRAINT chk_process_versions_definition_object CHECK (jsonb_typeof(definition) = 'object'),
    CONSTRAINT chk_process_versions_publish_stamp CHECK (
        (status = 'draft'::app.process_version_status AND published_at IS NULL)
        OR (status <> 'draft'::app.process_version_status AND published_at IS NOT NULL)
    )
);

DROP TRIGGER IF EXISTS tgr_process_template_versions_set_updated_at ON app.process_template_versions;
CREATE TRIGGER tgr_process_template_versions_set_updated_at
BEFORE UPDATE ON app.process_template_versions
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.process_template_versions IS 'Immutable snapshot of a process body (node graph + start modes + outcomes). Published versions are frozen.';
COMMENT ON COLUMN app.process_template_versions.definition IS 'Frozen process document: graph of nodes/edges. Nodes may carry assignee (user selector), assignmentGroup, or deputy (reserved). Assignees are specific_group, specific_user, or system — never resolved people.';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'process_templates_current_version_id_fkey'
          AND conrelid = 'app.process_templates'::regclass
    ) THEN
        ALTER TABLE app.process_templates
            ADD CONSTRAINT process_templates_current_version_id_fkey
            FOREIGN KEY (current_version_id)
            REFERENCES app.process_template_versions(id) ON DELETE SET NULL;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3.1 Design-time invariants
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.tgr_frozen_version_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    mutable_keys TEXT[] := ARRAY['status', 'change_note', 'updated_by', 'updated_at'];
    old_row      JSONB  := to_jsonb(OLD);
    new_row      JSONB  := to_jsonb(NEW);
    old_status   TEXT   := to_jsonb(OLD) ->> 'status';
    new_status   TEXT   := to_jsonb(NEW) ->> 'status';
BEGIN
    IF old_status = 'draft' THEN
        RETURN NEW;
    END IF;

    IF (old_row - mutable_keys) IS DISTINCT FROM (new_row - mutable_keys) THEN
        RAISE EXCEPTION
            '%: version % is % and therefore frozen; create a new version instead of editing it',
            TG_TABLE_NAME, OLD.id, old_status
            USING ERRCODE = '23514';
    END IF;

    IF new_status = 'draft' THEN
        RAISE EXCEPTION '%: version % cannot return to draft once %', TG_TABLE_NAME, OLD.id, old_status
            USING ERRCODE = '23514';
    END IF;

    IF old_status = 'retired' AND new_status <> 'retired' THEN
        RAISE EXCEPTION '%: version % is retired and cannot be reactivated', TG_TABLE_NAME, OLD.id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_frozen_version_immutable() IS
    'Enforces version immutability on app.work_item_form_versions and app.process_template_versions: once a version leaves draft only status/change_note/audit columns may change, and it can never return to draft.';

DROP TRIGGER IF EXISTS tgr_work_item_form_versions_frozen ON app.work_item_form_versions;
CREATE TRIGGER tgr_work_item_form_versions_frozen
BEFORE UPDATE ON app.work_item_form_versions
FOR EACH ROW EXECUTE FUNCTION app.tgr_frozen_version_immutable();

DROP TRIGGER IF EXISTS tgr_process_template_versions_frozen ON app.process_template_versions;
CREATE TRIGGER tgr_process_template_versions_frozen
BEFORE UPDATE ON app.process_template_versions
FOR EACH ROW EXECUTE FUNCTION app.tgr_frozen_version_immutable();

CREATE OR REPLACE FUNCTION app.tgr_work_item_forms_validate_current_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_form_id UUID;
    v_status      app.work_item_form_version_status;
BEGIN
    IF NEW.current_version_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT form_id, status
    INTO v_form_id, v_status
    FROM app.work_item_form_versions
    WHERE id = NEW.current_version_id;

    IF v_form_id IS NULL THEN
        RAISE EXCEPTION 'work item form %: current version % not found', NEW.id, NEW.current_version_id
            USING ERRCODE = '23503';
    END IF;

    IF v_form_id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'work item form %: current version % belongs to another form', NEW.id, NEW.current_version_id
            USING ERRCODE = '23514';
    END IF;

    IF v_status <> 'published'::app.work_item_form_version_status THEN
        RAISE EXCEPTION 'work item form %: current version % must be published (is %)', NEW.id, NEW.current_version_id, v_status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_work_item_forms_validate_current_version ON app.work_item_forms;
CREATE TRIGGER tgr_work_item_forms_validate_current_version
BEFORE INSERT OR UPDATE OF current_version_id ON app.work_item_forms
FOR EACH ROW EXECUTE FUNCTION app.tgr_work_item_forms_validate_current_version();

CREATE OR REPLACE FUNCTION app.tgr_process_templates_validate_current_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_process_id UUID;
    v_status     app.process_version_status;
BEGIN
    IF NEW.current_version_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT process_id, status
    INTO v_process_id, v_status
    FROM app.process_template_versions
    WHERE id = NEW.current_version_id;

    IF v_process_id IS NULL THEN
        RAISE EXCEPTION 'process template %: current version % not found', NEW.id, NEW.current_version_id
            USING ERRCODE = '23503';
    END IF;

    IF v_process_id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'process template %: current version % belongs to another process', NEW.id, NEW.current_version_id
            USING ERRCODE = '23514';
    END IF;

    IF v_status <> 'published'::app.process_version_status THEN
        RAISE EXCEPTION 'process template %: current version % must be published (is %)', NEW.id, NEW.current_version_id, v_status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_process_templates_validate_current_version ON app.process_templates;
CREATE TRIGGER tgr_process_templates_validate_current_version
BEFORE INSERT OR UPDATE OF current_version_id ON app.process_templates
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_templates_validate_current_version();

-- ===========================================================================
-- 4. Service offerings (catalog binding)
-- ===========================================================================
-- Where a form meets a service. References the TEMPLATE, not a version: publishing a
-- new version is picked up automatically, while each request stamps the version it used.

CREATE TABLE IF NOT EXISTS app.service_offerings (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Nullable: an offering may be authored unbound and attached to a service later.
    service_id        UUID REFERENCES app.services(id) ON DELETE SET NULL,
    -- Server-assigned once on create: offer-{5 lowercase hex}, e.g. offer-a1b2c.
    -- Distinct from the row UUID (id): this is the human-readable catalog identifier.
    offering_id       VARCHAR(20) NOT NULL,
    -- Nullable: an offering may be drafted without a form and bound later.
    form_id       UUID REFERENCES app.work_item_forms(id) ON DELETE RESTRICT,
    status            app.service_offering_status NOT NULL DEFAULT 'draft'::app.service_offering_status,
    "order"           INTEGER NOT NULL DEFAULT 0,
    created_by        UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Uniqueness of offering_id is case-insensitive; see uq_service_offerings_id_lower
    -- in section 7 (same treatment as form_id and process_id).
    CONSTRAINT chk_service_offerings_order_positive CHECK ("order" >= 0)
);

DROP TRIGGER IF EXISTS tgr_service_offerings_set_updated_at ON app.service_offerings;
CREATE TRIGGER tgr_service_offerings_set_updated_at
BEFORE UPDATE ON app.service_offerings
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.service_offerings IS 'Catalog offering: may bind a service_request form to a service. May be authored without a parent service and/or without a form and bound later. References the form, not a version.';
COMMENT ON COLUMN app.service_offerings.service_id IS 'Parent service. NULL while the offering is unbound. ON DELETE SET NULL detaches rather than deleting the offering. Catalog/submit still require a bound active service to order.';
COMMENT ON COLUMN app.service_offerings.offering_id IS 'Server-generated admin id: offer-{5 lowercase hex}, assigned once on create. Case-insensitive unique. Distinct from the row UUID (id).';
COMMENT ON COLUMN app.service_offerings.form_id IS 'Form published through this offering. NULL while unbound. Bare FK to app.work_item_forms; no kind check at the database layer.';

-- Sparse per-language rows, exactly like app.service_translations: a single filled language
-- is a valid, complete offering, and read paths resolve requested language -> fallback
-- language -> any available row.
CREATE TABLE IF NOT EXISTS app.service_offering_translations (
    translation_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    offering_id       UUID NOT NULL,
    language_code     app.system_language_code NOT NULL,
    name              VARCHAR(250) NOT NULL,
    description_short VARCHAR(250),
    created_by        UUID NOT NULL DEFAULT '00000000-0000-0000-0000-00000000dead',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT service_offering_tr_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT uq_service_offering_tr_one_per_lang UNIQUE (offering_id, language_code),

    FOREIGN KEY (offering_id) REFERENCES app.service_offerings(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES app.users(user_id) ON DELETE SET DEFAULT,
    FOREIGN KEY (updated_by) REFERENCES app.users(user_id) ON DELETE SET NULL
);

DROP TRIGGER IF EXISTS tgr_service_offering_translations_set_updated_at ON app.service_offering_translations;
CREATE TRIGGER tgr_service_offering_translations_set_updated_at
BEFORE UPDATE ON app.service_offering_translations
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.service_offering_translations IS 'Per-language offering name and short description. One row per offering per language, written only for languages the admin filled (single-language offerings are valid). Same pattern as app.service_translations.';

-- ===========================================================================
-- 5. Service requests (runtime)
-- ===========================================================================

CREATE OR REPLACE FUNCTION app.int_to_base36_6(p_n bigint)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    chars constant text := '0123456789abcdefghijklmnopqrstuvwxyz';
    n bigint := p_n;
    result text := '';
BEGIN
    IF n = 0 THEN
        RETURN '000000';
    END IF;
    WHILE n > 0 LOOP
        result := substr(chars, (n % 36)::int + 1, 1) || result;
        n := n / 36;
    END LOOP;
    RETURN lpad(result, 6, '0');
END;
$$;

COMMENT ON FUNCTION app.int_to_base36_6(bigint) IS
    '6-character zero-padded base36 (0-9a-z). Used by work item request_number; KB keeps int_to_base36_7.';

CREATE OR REPLACE FUNCTION app.work_item_id_prefix(kind app.work_item_kind)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT CASE kind
        WHEN 'service_request'::app.work_item_kind THEN 'sr-'
        WHEN 'incident'::app.work_item_kind        THEN 'ir-'
        WHEN 'problem'::app.work_item_kind         THEN 'pr-'
        WHEN 'change'::app.work_item_kind          THEN 'cr-'
        WHEN 'release'::app.work_item_kind         THEN 'rr-'
    END;
$$;

COMMENT ON FUNCTION app.work_item_id_prefix(app.work_item_kind) IS
    'Human-readable work item prefix: sr- / ir- / pr- / cr- / rr-. Product-owned, not an admin setting.';

CREATE SEQUENCE IF NOT EXISTS app.seq_service_request_number
    AS BIGINT START WITH 1 INCREMENT BY 1
    MINVALUE 0 MAXVALUE 2176782335
    CACHE 1 NO CYCLE;

COMMENT ON SEQUENCE app.seq_service_request_number IS
    'Counter for service request numbers (base36 suffix, sr-000001..sr-zzzzzz). MAXVALUE = 36^6-1.';

CREATE TABLE IF NOT EXISTS app.service_requests (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_number        VARCHAR(32) NOT NULL,
    offering_id           UUID NOT NULL REFERENCES app.service_offerings(id) ON DELETE RESTRICT,
    service_id            UUID NOT NULL REFERENCES app.services(id) ON DELETE RESTRICT,
    form_version_id       UUID NOT NULL REFERENCES app.work_item_form_versions(id) ON DELETE RESTRICT,
    urgency               app.request_urgency NOT NULL,
    impact                app.request_impact,
    priority              app.request_priority,
    status                app.request_status NOT NULL DEFAULT 'new'::app.request_status,
    pause_reason          app.request_pause_reason,
    channel               app.request_channel,
    title                 VARCHAR(500) NOT NULL,
    description           TEXT,
    quantity              INTEGER,
    answers               JSONB NOT NULL DEFAULT '{}'::jsonb,
    requester_user_id     UUID NOT NULL DEFAULT '00000000-0000-0000-0000-00000000dead'
                          REFERENCES app.users(user_id) ON DELETE SET DEFAULT,
    requested_for_user_id UUID DEFAULT '00000000-0000-0000-0000-00000000dead'
                          REFERENCES app.users(user_id) ON DELETE SET DEFAULT,
    assigned_group_id     UUID REFERENCES app.groups(group_id) ON DELETE SET NULL,
    assigned_user_id      UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    watch_list            UUID[],
    work_notes            TEXT,
    resolved_at           TIMESTAMPTZ,
    closed_at             TIMESTAMPTZ,
    created_by            UUID NOT NULL DEFAULT '00000000-0000-0000-0000-00000000dead'
                          REFERENCES app.users(user_id) ON DELETE SET DEFAULT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by            UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_service_requests_request_number UNIQUE (request_number),
    CONSTRAINT chk_service_requests_request_number_format
        CHECK (request_number ~ '^sr-[0-9a-z]{6}$'),
    CONSTRAINT chk_service_requests_title_not_blank CHECK (btrim(title) <> ''),
    CONSTRAINT chk_service_requests_answers_object CHECK (jsonb_typeof(answers) = 'object')
);

DROP TRIGGER IF EXISTS tgr_service_requests_set_updated_at ON app.service_requests;
CREATE TRIGGER tgr_service_requests_set_updated_at
BEFORE UPDATE ON app.service_requests
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE OR REPLACE FUNCTION app.tgr_service_requests_assign_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.request_number IS NOT NULL AND btrim(NEW.request_number) <> '' THEN
        RETURN NEW;
    END IF;

    NEW.request_number := app.work_item_id_prefix('service_request'::app.work_item_kind)
        || app.int_to_base36_6(nextval('app.seq_service_request_number'));
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_service_requests_assign_number ON app.service_requests;
CREATE TRIGGER tgr_service_requests_assign_number
BEFORE INSERT ON app.service_requests
FOR EACH ROW EXECUTE FUNCTION app.tgr_service_requests_assign_number();

CREATE OR REPLACE FUNCTION app.tgr_service_requests_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    deleted_user CONSTANT UUID := '00000000-0000-0000-0000-00000000dead';
BEGIN
    IF NEW.request_number       IS DISTINCT FROM OLD.request_number
       OR NEW.offering_id         IS DISTINCT FROM OLD.offering_id
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

DROP TRIGGER IF EXISTS tgr_service_requests_stamp_immutable ON app.service_requests;
CREATE TRIGGER tgr_service_requests_stamp_immutable
BEFORE UPDATE ON app.service_requests
FOR EACH ROW EXECUTE FUNCTION app.tgr_service_requests_stamp_immutable();

COMMENT ON TABLE app.service_requests IS
    'Submitted service requests. Each row stamps catalog origin (offering, service, frozen form version) and stores title, description, answers, urgency, impact, priority, status, pause_reason, channel, quantity, work_notes, watch_list, assignment pointers, and resolved/closed timestamps. channel is always NULL until inbound channels exist. impact, priority, watch_list, quantity, work_notes, pause_reason, assignment and resolved/closed stamps are stored only — no fill logic in this release.';
COMMENT ON COLUMN app.service_requests.request_number IS 'Human-readable reference sr- + 6 base36 chars from app.seq_service_request_number; assigned by trigger on INSERT. Unique. Immutable after INSERT.';
COMMENT ON COLUMN app.service_requests.title IS 'Short title of the request. Promoted so lists and search need no JSONB walk. Required and non-blank.';
COMMENT ON COLUMN app.service_requests.description IS 'Free-text description stored as its own column, not inside answers. Nullable; no fill logic in this release — set manually.';
COMMENT ON COLUMN app.service_requests.impact IS 'Impact level (low/medium/high/critical). Stored only; no fill logic and no priority calculation from impact and urgency in this release.';
COMMENT ON COLUMN app.service_requests.priority IS 'Priority level (low/medium/high/critical). Stored only; set manually. This release does not compute priority from impact and urgency.';
COMMENT ON COLUMN app.service_requests.watch_list IS 'Array of watcher user ids. Nullable; no FK and no fill logic in this release.';
COMMENT ON COLUMN app.service_requests.quantity IS 'Quantity for product orders. Nullable; no fill logic in this release — set manually.';
COMMENT ON COLUMN app.service_requests.work_notes IS 'Internal support notes, not visible to the requester. Nullable; no fill logic in this release — set manually.';
COMMENT ON COLUMN app.service_requests.channel IS 'How the request reached the system (app.request_channel). Nullable, no default; always NULL in this release until inbound channels exist. Not part of the immutable submission stamp.';
COMMENT ON COLUMN app.service_requests.answers IS 'Filled form as {fieldKey: value} (camelCase keys mirror the form definition). Structure is validated by the application against the stamped form version, not by the DB.';
COMMENT ON COLUMN app.service_requests.requester_user_id IS 'Who raised the request. ON DELETE SET DEFAULT → seeded Deleted User so hard-deleting the account does not require closing requests.';
COMMENT ON COLUMN app.service_requests.requested_for_user_id IS 'Beneficiary when different from the requester; NULL means self. ON DELETE SET DEFAULT → Deleted User (preserves that a beneficiary existed).';
COMMENT ON COLUMN app.service_requests.created_by IS 'Audit author of the row (same as requester at portal submit). ON DELETE SET DEFAULT → Deleted User.';
COMMENT ON COLUMN app.service_requests.assigned_group_id IS 'Group currently responsible. Stored only; no fill logic and no read-access derivation from this column plus support tiers in this release.';
COMMENT ON COLUMN app.service_requests.assigned_user_id IS 'User currently assigned. Nullable. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.service_requests.pause_reason IS
    'Why the request is on hold. Stored only; no fill or clear-on-resume logic in this release, and no CHECK tying it to status. The four values separate waits by whose clock they are on: awaiting_requester and awaiting_third_party are outside the support team''s control, scheduled is planned work, other is everything else.';
COMMENT ON COLUMN app.service_requests.resolved_at IS 'Resolution timestamp. Stored only; no fill logic and no CHECK tying it to status in this release.';
COMMENT ON COLUMN app.service_requests.closed_at IS 'Closed timestamp. Stored only; no fill logic and no CHECK tying it to status in this release.';

CREATE TABLE IF NOT EXISTS app.work_item_history_events (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type   VARCHAR(64) NOT NULL,
    entity_id     UUID NOT NULL,
    event_type    app.work_item_history_event_type NOT NULL,
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_user_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-00000000dead'
                  REFERENCES app.users(user_id) ON DELETE SET DEFAULT,
    value_from    VARCHAR(250),
    value_to      VARCHAR(250),
    meta          JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT chk_work_item_history_meta_object CHECK (jsonb_typeof(meta) = 'object')
);

COMMENT ON TABLE app.work_item_history_events IS 'Immutable work item history stream (created, updated, status_changed, assigned_group, assigned_to, assigned_watcher, added_worknotes, updated_priority, approved, rejected, cancelled, resolved, complete). No FK to the work item so history survives deletion; meta JSONB carries event-specific detail without DDL.';
COMMENT ON COLUMN app.work_item_history_events.value_from IS 'Previous value as displayed at event time (enum label, group or user name). Snapshotted text, not a reference — renames must not rewrite history.';

-- ===========================================================================
-- 7. Indexes
-- ===========================================================================

-- Unique index on lower(form_id) is created in section 10.
CREATE INDEX IF NOT EXISTS idx_work_item_forms_kind_status
    ON app.work_item_forms USING btree (work_item_kind, status);
CREATE INDEX IF NOT EXISTS idx_work_item_forms_owner
    ON app.work_item_forms USING btree (owner_user_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wit_versions_single_draft
    ON app.work_item_form_versions (form_id)
    WHERE status = 'draft';
CREATE INDEX IF NOT EXISTS idx_wif_versions_form_number
    ON app.work_item_form_versions USING btree (form_id, version_number DESC);

-- Unique index on lower(process_id) is created in section 10.
CREATE INDEX IF NOT EXISTS idx_process_templates_status
    ON app.process_templates USING btree (status);
CREATE INDEX IF NOT EXISTS idx_process_templates_owner
    ON app.process_templates USING btree (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_process_templates_categories
    ON app.process_templates USING gin (categories);
CREATE UNIQUE INDEX IF NOT EXISTS uq_process_versions_single_draft
    ON app.process_template_versions (process_id)
    WHERE status = 'draft';
CREATE INDEX IF NOT EXISTS idx_process_versions_process_number
    ON app.process_template_versions USING btree (process_id, version_number DESC);
CREATE INDEX IF NOT EXISTS idx_process_versions_definition
    ON app.process_template_versions USING gin (definition jsonb_path_ops);

CREATE UNIQUE INDEX IF NOT EXISTS uq_service_offerings_id_lower
    ON app.service_offerings (lower(offering_id));
CREATE INDEX IF NOT EXISTS idx_service_offerings_service_status_order
    ON app.service_offerings USING btree (service_id, status, "order");
CREATE INDEX IF NOT EXISTS idx_service_offerings_form
    ON app.service_offerings USING btree (form_id);
CREATE INDEX IF NOT EXISTS idx_service_offering_tr_offering
    ON app.service_offering_translations USING btree (offering_id);
CREATE INDEX IF NOT EXISTS idx_service_offering_tr_lang
    ON app.service_offering_translations USING btree (language_code);
CREATE INDEX IF NOT EXISTS idx_service_offering_tr_name_trgm
    ON app.service_offering_translations USING gin (lower(name) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_service_requests_requester_created
    ON app.service_requests USING btree (requester_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_service_requests_requested_for_created
    ON app.service_requests USING btree (requested_for_user_id, created_at DESC)
    WHERE requested_for_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_service_requests_group_open
    ON app.service_requests USING btree (assigned_group_id, created_at DESC)
    WHERE status IN ('new', 'pending_approval', 'approved', 'in_progress', 'reopened', 'paused');
CREATE INDEX IF NOT EXISTS idx_service_requests_assignee_open
    ON app.service_requests USING btree (assigned_user_id, created_at DESC)
    WHERE status IN ('new', 'pending_approval', 'approved', 'in_progress', 'reopened', 'paused');
CREATE INDEX IF NOT EXISTS idx_service_requests_service_status
    ON app.service_requests USING btree (service_id, status);
CREATE INDEX IF NOT EXISTS idx_service_requests_answers
    ON app.service_requests USING gin (answers jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_service_requests_title_trgm
    ON app.service_requests USING gin (lower(title) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_service_requests_form_version
    ON app.service_requests USING btree (form_version_id);

CREATE INDEX IF NOT EXISTS idx_work_item_history_entity
    ON app.work_item_history_events USING btree (entity_type, entity_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_work_item_history_occurred
    ON app.work_item_history_events USING btree (occurred_at DESC);

-- ===========================================================================
-- 8. Role descriptions
-- ===========================================================================
-- Forms and processes stay inside the Services admin module. Work module access
-- is gated by work.module.enabled.

DO $$
BEGIN
    UPDATE app.groups
    SET group_description = 'Services Administrators with full access (catalog services, offerings, work-item forms, processes, settings)',
        display_name = 'Role Services Administrators'
    WHERE group_name = 'role.adminServices.admin';
    UPDATE app.groups
    SET group_description = 'Services Auditors (read-only across catalog services, offerings, forms, processes and settings)',
        display_name = 'Role Services Auditors'
    WHERE group_name = 'role.adminServices.auditor';
END $$;

-- ===========================================================================
-- 9. Settings
-- ===========================================================================
-- ON CONFLICT DO NOTHING: an installation that already tuned one of these keys keeps its
-- value; only missing rows are seeded.

INSERT INTO app.app_settings (section_path, setting_name, environment, value, validation_schema, default_value, description, is_public) VALUES
('AdminForms', 'allowed.languages', 'all', '["english","russian"]'::jsonb, '{"type":"array","items":{"type":"string"}}'::jsonb, '["english","russian"]'::jsonb, 'Languages enabled for the work item Forms module (subset of global allowed.languages). Drives the language tabs of the form editor: labels, help text and options are stored per language inside the version definition.', true),
('AdminProcesses', 'allowed.languages', 'all', '["english","russian"]'::jsonb, '{"type":"array","items":{"type":"string"}}'::jsonb, '["english","russian"]'::jsonb, 'Languages enabled for the Processes module (subset of global allowed.languages). Drives the language tabs of the process editor: node titles and instructions are stored per language inside the version definition.', true),
('AdminServices.Fs.Quotas', 'entity.max.bytes', 'all', '104857600'::jsonb, '{"type":"integer","minimum":0}'::jsonb, '104857600'::jsonb, 'Sum of all file bytes per single service request. 0 = unlimited.', false),
('AdminServices.Fs.Quotas', 'entity.max.count', 'all', '20'::jsonb, '{"type":"integer","minimum":1,"maximum":200}'::jsonb, '20'::jsonb, 'Hard cap of file count per service request.', false),
('AdminServices.Fs.Quotas', 'user.per.day.max.bytes', 'all', '1073741824'::jsonb, '{"type":"integer","minimum":0}'::jsonb, '1073741824'::jsonb, 'Anti-abuse: max bytes uploaded as service-request files per user per day. 0 = unlimited.', false),
('AdminServices.Fs.Quotas', 'module.total.storage.max.bytes', 'all', '0'::jsonb, '{"type":"integer","minimum":0}'::jsonb, '0'::jsonb, 'Services-wide ceiling: sum of all service-request stored file bytes. 0 = unlimited.', false)
ON CONFLICT (section_path, setting_name, environment) DO NOTHING;

-- ===========================================================================
-- 10. Drop unused service columns
-- ===========================================================================
-- Columns introduced with the service model overhaul and never used outside the
-- admin ServiceEditor. Fresh installs omit them from db/init; existing installs
-- drop them here. IF EXISTS keeps each statement idempotent.

ALTER TABLE app.service_translations DROP COLUMN IF EXISTS sla_summary;
ALTER TABLE app.services DROP COLUMN IF EXISTS review_date;
ALTER TABLE app.services DROP COLUMN IF EXISTS service_hours;

-- service_code → service_id (human-readable svc-{5hex}, assigned on create).
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'services'
          AND column_name = 'service_code'
    ) THEN
        ALTER TABLE app.services RENAME COLUMN service_code TO service_id;
    END IF;
END $$;
ALTER TABLE app.services DROP CONSTRAINT IF EXISTS uq_services_service_code;
ALTER TABLE app.services
    ALTER COLUMN service_id TYPE VARCHAR(20)
    USING CASE
        WHEN service_id IS NULL THEN NULL
        ELSE left(service_id, 20)
    END;
ALTER TABLE app.services ALTER COLUMN service_id SET NOT NULL;
DROP INDEX IF EXISTS app.uq_services_id_lower;
CREATE UNIQUE INDEX IF NOT EXISTS uq_services_id_lower
    ON app.services (lower(service_id));
COMMENT ON COLUMN app.services.service_id IS 'Server-generated admin id: svc-{5 lowercase hex}, assigned once on create. Case-insensitive unique. Distinct from the row UUID (id).';
COMMENT ON COLUMN app.price_lists.item_code IS 'Code to match against product_code, service_id, or activity_code';

CREATE UNIQUE INDEX IF NOT EXISTS uq_work_item_forms_id_lower
    ON app.work_item_forms (lower(form_id));
COMMENT ON COLUMN app.work_item_forms.form_id IS 'Server-generated admin id: form-{5 lowercase hex}, assigned once on create. Case-insensitive unique. Distinct from the row UUID (id).';

CREATE UNIQUE INDEX IF NOT EXISTS uq_process_templates_id_lower
    ON app.process_templates (lower(process_id));
COMMENT ON COLUMN app.process_templates.process_id IS 'Server-generated admin id: proc-{5 lowercase hex}, assigned once on create. Case-insensitive unique. Distinct from the row UUID (id).';

-- ===========================================================================
-- 11. User hierarchy — manager_user_id column
-- ===========================================================================

ALTER TABLE app.users_standard_profiles
  ADD COLUMN IF NOT EXISTS manager_user_id UUID;

DO $$
BEGIN
  ALTER TABLE app.users_standard_profiles
    ADD CONSTRAINT fk_users_standard_profiles_manager
    FOREIGN KEY (manager_user_id) REFERENCES app.users(user_id) ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE app.users_standard_profiles
    ADD CONSTRAINT chk_users_standard_profiles_manager_not_self
    CHECK (manager_user_id IS NULL OR manager_user_id <> user_id);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DROP INDEX IF EXISTS app.uq_users_standard_profiles_single_root;

CREATE INDEX IF NOT EXISTS idx_users_standard_profiles_manager
  ON app.users_standard_profiles (manager_user_id)
  WHERE manager_user_id IS NOT NULL;

-- ===========================================================================
-- 12. Email log (admin SMTP diagnostics)
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.email_log (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key    VARCHAR(240) NOT NULL,
    recipient          TEXT NOT NULL,
    subject            TEXT NOT NULL DEFAULT '',
    status             VARCHAR(32) NOT NULL,
    smtp_response_code INTEGER,
    error_msg          TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_email_log_idempotency UNIQUE (idempotency_key),
    CONSTRAINT chk_email_log_status CHECK (status IN ('sent', 'failed'))
);

COMMENT ON TABLE app.email_log IS 'SMTP send fact for the email transport. Used by admin SMTP diagnostics.';

-- ===========================================================================
-- 13. Work.Visibility settings
-- ===========================================================================

-- ON CONFLICT DO NOTHING: an installation that already tuned one of these keys keeps its
-- value; only missing rows are seeded.

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
('Work.Visibility', 'work-items', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'When true the work items tree root is intended to be visible in the Work module. Not consumed by the tree yet.', true),
('Work.Visibility', 'quotations', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'When true the quotations tree root is intended to be visible in the Work module. Not consumed by the tree yet.', true),
('Work.Visibility', 'service-requests', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'When true the service requests practice folder is intended to be visible under work items. Not consumed by the tree yet.', true),
('Work.Visibility', 'incidents', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'When true the incidents practice folder is intended to be visible under work items. Not consumed by the tree yet.', true),
('Work.Visibility', 'problems', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'When true the problems practice folder is intended to be visible under work items. Not consumed by the tree yet.', true),
('Work.Visibility', 'changes', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'When true the changes practice folder is intended to be visible under work items. Not consumed by the tree yet.', true),
('Work.Visibility', 'activities', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'When true the activities practice folder is intended to be visible under work items. Not consumed by the tree yet.', true)
ON CONFLICT (section_path, setting_name, environment) DO NOTHING;

-- ===========================================================================
-- 14. User hierarchy — single staff-root trigger
-- ===========================================================================

CREATE OR REPLACE FUNCTION app.tgr_users_standard_profiles_manager_no_cycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  cur UUID;
  depth INT := 0;
  subject_type app.account_type;
BEGIN
  SELECT account_type INTO subject_type
  FROM app.users
  WHERE user_id = NEW.user_id;

  -- Single staff-tree root: only among standard staff (is_staff). End users may have
  -- NULL manager; that is not a second org root. System accounts are excluded.
  -- app.manager_root_transfer=1 (transaction-local) allows a brief second root during takeover.
  IF NEW.manager_user_id IS NULL
     AND subject_type = 'standard'::app.account_type
     AND NEW.is_staff THEN
    IF COALESCE(current_setting('app.manager_root_transfer', true), '') = '1' THEN
      RETURN NEW;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM app.users_standard_profiles sp
      JOIN app.users u ON u.user_id = sp.user_id
      WHERE sp.manager_user_id IS NULL
        AND u.account_type = 'standard'::app.account_type
        AND sp.is_staff
        AND sp.user_id <> NEW.user_id
    ) THEN
      RAISE EXCEPTION 'only one staff-account hierarchy root is allowed'
        USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.manager_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.manager_user_id = NEW.user_id THEN
    RAISE EXCEPTION 'manager_user_id cannot equal user_id'
      USING ERRCODE = 'check_violation';
  END IF;

  cur := NEW.manager_user_id;
  WHILE cur IS NOT NULL LOOP
    depth := depth + 1;
    IF depth > 64 THEN
      RAISE EXCEPTION 'manager hierarchy depth exceeds 64 (cycle or corrupt data)'
        USING ERRCODE = 'check_violation';
    END IF;
    IF cur = NEW.user_id THEN
      RAISE EXCEPTION 'manager hierarchy cycle detected'
        USING ERRCODE = 'check_violation';
    END IF;
    SELECT p.manager_user_id INTO cur
    FROM app.users_standard_profiles p
    WHERE p.user_id = cur;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_users_standard_profiles_manager_no_cycle
  ON app.users_standard_profiles;

CREATE TRIGGER tgr_users_standard_profiles_manager_no_cycle
  BEFORE INSERT OR UPDATE OF manager_user_id, is_staff ON app.users_standard_profiles
  FOR EACH ROW
  EXECUTE FUNCTION app.tgr_users_standard_profiles_manager_no_cycle();

COMMENT ON FUNCTION app.tgr_users_standard_profiles_manager_no_cycle() IS
  'Rejects manager cycles/depth overflow; enforces at most one standard-staff hierarchy root (is_staff; system accounts and end users excluded). Single-root check skipped when app.manager_root_transfer=1 (tx-local hard takeover).';

COMMENT ON COLUMN app.users_standard_profiles.manager_user_id IS
  'Line manager (reports-to). NULL = no manager. Among standard staff (is_staff) at most one such root is allowed; end users sit outside that tree and may all have NULL. System accounts are outside the org hierarchy. ON DELETE SET NULL supports atomic root succession when only the successor still references the deleted user.';

-- ===========================================================================
-- 15. AdminOrgMgmt.users.change.username.enabled
-- ===========================================================================
-- Seeded in db/init/11_app_settings.sql for fresh installs; this row was missing
-- from the original 0.23.1 migration. ON CONFLICT DO NOTHING: an installation
-- that already has the row keeps the administrator's value.

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
('AdminOrgMgmt', 'users.change.username.enabled', 'all', 'false'::jsonb, '{"type":"boolean"}'::jsonb, 'false'::jsonb, 'Allow signed-in users to change their own username on My account', false)
ON CONFLICT (section_path, setting_name, environment) DO NOTHING;

-- ===========================================================================
-- 16. Version stamp
-- ===========================================================================

SELECT app.set_migration_output_summary(
    'm_0.23.1',
    'Service request stack (forms, processes, offerings, service_requests, history, email_log); Work.Visibility; staff-tree single-root'
);

UPDATE app.instance SET schema_version = '0.23.1', last_updated_at = NOW() WHERE id = 1;

COMMIT;

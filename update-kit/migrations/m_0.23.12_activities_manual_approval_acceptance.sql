-- Version: 0.23.12
-- Description: Activity data model — three practice-specific tables (manual
--   task, approval, acceptance) with own status/outcome/pause_reason enums,
--   number sequences/triggers, stamp-immutable triggers, and an app.users
--   BEFORE DELETE reattribution trigger for completed activities. Also
--   renames app.work_item_service_requests back to app.service_requests
--   (practice table; work_item_ prefix stays on objects shared by all kinds).
--   Adds the process engine core: processes / process_versions (design time)
--   and process_instances / process_tokens (runtime) with versioning and
--   token state-machine triggers.
-- Backend file: m_0.23.12_activities_manual_approval_acceptance.sql
--
-- Changes in v0.23.12:
-- - Added app.activity_parent_kind and the per-practice activity enums
--   (activity_manual_task_status / outcome / pause_reason,
--   activity_approval_status / outcome / pause_reason,
--   activity_acceptance_status / outcome). Activities are not a
--   work_item_kind; each practice has its own table and own enums.
-- - Added app.activity_manual_tasks, app.activity_approvals,
--   app.activity_acceptances (own sequences, number triggers,
--   stamp-immutable triggers) and
--   app.tgr_users_reattribute_completed_activities on app.users.
-- - Added assignee/group open-queue, status, parent and title-trigram
--   indexes on all three tables; kb_article partial index on manual tasks.
-- - Added Work.Fs.Quotas seed (entity.max.bytes/count, user.per.day.max.bytes,
--   module.total.storage.max.bytes) for Work activity (manual_task, acceptance)
--   attachments; QuotaModule Work.
-- - Renamed app.work_item_service_requests back to app.service_requests with
--   its sequence, indexes, constraints, trigger functions and triggers —
--   a practice table carries no work_item_ prefix.
-- - Added process engine core: app.process_version_status /
--   process_instance_status / process_token_state enums; app.processes /
--   process_versions / process_instances / process_tokens tables; deferred
--   current_version FK; frozen-version, validate, guard and notify triggers;
--   process indexes. Re-issued COMMENT ON FUNCTION
--   app.tgr_frozen_version_immutable to cover process_versions.
-- - Organization staff membership rules: unique index uq_organization_staff_user;
--   app.sync_bot_org_membership; triggers tgr_organization_staff_guard /
--   tgr_organization_staff_after / tgr_users_standard_profiles_staff_mirror /
--   tgr_users_bot_profiles_org_sync; one-shot bot membership sync pass (no
--   human membership rewrite).
-- - Registered pg_cron 'email-log-cleanup' (23 3 * * *) enqueueing
--   email.log-cleanup so evi-worker can delete app.email_log rows older than
--   90 days (idempotent unschedule/schedule; dump-identical to
--   db/init/12_pg_cron_setup.sql).
-- - Re-issued COMMENT ON COLUMN app.api_keys.id so the plaintext key prefix is bkey_ (dump-identical to db/init/05_tables.sql).
--
-- Destructive-affects: TABLE app.work_item_service_requests; SEQUENCE app.seq_work_item_service_request_number
-- Destructive-data-loss: none — metadata-only renames (table, sequence, indexes, constraints, triggers, trigger functions); no rows rewritten.
--
-- Idempotency: CREATE TYPE swallows duplicate_object. CREATE TABLE /
--   CREATE SEQUENCE / CREATE INDEX use IF NOT EXISTS. CREATE OR REPLACE
--   keeps function bodies current. DROP TRIGGER IF EXISTS + CREATE TRIGGER
--   re-applies trigger definitions. COMMENT ON is re-issued with the same
--   literals as db/init (dump-visible parity). app_settings INSERT uses
--   ON CONFLICT (section_path, setting_name, environment) DO UPDATE.
--   Rename guards check the old name (table, sequence and functions also
--   the absence of the new name), so a re-run is a no-op.

BEGIN;

-- ===========================================================================
-- 1. Enums
-- ===========================================================================

-- ===========================================================================
-- Activities (not a work_item_kind)
-- ===========================================================================
-- Status / outcome / pause_reason for the three independent activity tables.
-- These are NOT a work_item_kind and do not share app.work_item_status: each
-- practice has its own table and its own enums, for the same reason
-- app.service_requests stands alone rather than folding future
-- incident/problem/change rows into one table with a kind column (see the
-- comment above CREATE TABLE app.work_item_forms in 05_tables.sql).
-- app.activity_parent_kind is the one shared enum (the parent may be a
-- service request or a process).

-- Shared parent discriminator used by all three activity tables.
DO $$ BEGIN
    CREATE TYPE app.activity_parent_kind AS ENUM ('service_request', 'process');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_parent_kind IS
    'Discriminator for an activity''s parent: service_request or process. Shared by activity_manual_tasks, activity_approvals and activity_acceptances. parent_id is a bare UUID (no FK); resolving the parent is a later slice.';

-- Manual task lifecycle, outcome and hold reason. Own to app.activity_manual_tasks.
DO $$ BEGIN
    CREATE TYPE app.activity_manual_task_status AS ENUM ('new', 'in_progress', 'paused', 'complete');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_manual_task_status IS
    'Lifecycle status for a manual task: new, in_progress, paused, complete. Own to app.activity_manual_tasks; not app.work_item_status. Stored only; no fill logic in this release.';

DO $$ BEGIN
    CREATE TYPE app.activity_manual_task_outcome AS ENUM ('succeeded', 'cancelled', 'failed', 'skipped');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_manual_task_outcome IS
    'Terminal outcome for a manual task: succeeded, cancelled, failed, skipped. Own to app.activity_manual_tasks. Stored only; no fill logic and no CHECK tying it to status in this release.';

DO $$ BEGIN
    CREATE TYPE app.activity_manual_task_pause_reason AS ENUM (
        'awaiting_requester', 'awaiting_third_party', 'awaiting_parts', 'scheduled'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_manual_task_pause_reason IS
    'Hold-reason codes for a paused manual task. awaiting_requester and awaiting_third_party are outside the assignee''s control, awaiting_parts is a material wait, scheduled is planned work. Stored on activity_manual_tasks.pause_reason; no fill logic and no CHECK tying the column to status in this release.';

-- Approval lifecycle, outcome and hold reason. Own to app.activity_approvals.
DO $$ BEGIN
    CREATE TYPE app.activity_approval_status AS ENUM ('new', 'in_progress', 'paused', 'complete');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_approval_status IS
    'Lifecycle status for an approval: new, in_progress, paused, complete. Own to app.activity_approvals; not app.work_item_status and not app.work_item_approval_status. Stored only; no fill logic in this release.';

DO $$ BEGIN
    CREATE TYPE app.activity_approval_outcome AS ENUM ('approved', 'rejected');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_approval_outcome IS
    'Terminal outcome for an approval: approved, rejected. Own to app.activity_approvals. Stored only; no fill logic and no CHECK tying it to status in this release.';

DO $$ BEGIN
    CREATE TYPE app.activity_approval_pause_reason AS ENUM (
        'more_info_required', 'awaiting_additional_approver', 'awaiting_cab', 'deferred'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_approval_pause_reason IS
    'Hold-reason codes for a paused approval. more_info_required waits on the requester, awaiting_additional_approver and awaiting_cab wait on other approvers, deferred is a planned postponement. Stored on activity_approvals.pause_reason; no fill logic and no CHECK tying the column to status in this release.';

-- Acceptance lifecycle and outcome. Acceptance never pauses, so there is no
-- activity_acceptance_pause_reason enum.
DO $$ BEGIN
    CREATE TYPE app.activity_acceptance_status AS ENUM ('new', 'in_progress', 'complete');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_acceptance_status IS
    'Lifecycle status for an acceptance: new, in_progress, complete. Own to app.activity_acceptances; there is no paused value because an acceptance never pauses. Stored only; no fill logic in this release.';

DO $$ BEGIN
    CREATE TYPE app.activity_acceptance_outcome AS ENUM ('accepted', 'rejected');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.activity_acceptance_outcome IS
    'Terminal outcome for an acceptance: accepted, rejected. Own to app.activity_acceptances. Stored only; no fill logic and no CHECK tying it to status in this release.';

-- ===========================================================================
-- 2. Tables, sequences, triggers, comments
-- ===========================================================================

-- ===========================================================================
-- Activities (runtime: manual task, approval, acceptance)
-- ===========================================================================
-- Three independent practice-specific tables for human-in-the-loop steps that
-- live under a service request or a process. There is no shared runtime table
-- and no activity_type discriminator — same reasoning that already keeps
-- app.service_requests standing alone rather than folding future
-- incident/problem/change rows into one table with a kind column (see the
-- comment above CREATE TABLE app.work_item_forms).
--
-- Activities are not a work_item_kind: number prefixes are literals (ma-/ap-/ac-),
-- not app.work_item_id_prefix. parent_id is a bare UUID (no FK); the parent may
-- be a service request or a process, and resolving that is a later slice.
-- Storage only in this release — no fill logic, no Go/FE readers.

CREATE SEQUENCE IF NOT EXISTS app.seq_activity_manual_task_number
    AS BIGINT START WITH 1 INCREMENT BY 1
    MINVALUE 0 MAXVALUE 2176782335
    CACHE 1 NO CYCLE;

COMMENT ON SEQUENCE app.seq_activity_manual_task_number IS
    'Counter for manual task numbers (base36 suffix, ma-000001..ma-zzzzzz). MAXVALUE = 36^6-1.';

CREATE TABLE IF NOT EXISTS app.activity_manual_tasks (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_number       VARCHAR(32) NOT NULL,
    parent_kind       app.activity_parent_kind NOT NULL,
    -- Bare UUID: the parent may be a service request or a process. No FK in this release.
    parent_id         UUID NOT NULL,
    title             VARCHAR(500) NOT NULL,
    description       TEXT,
    kb_article_id     UUID REFERENCES app.kb_articles(id) ON DELETE SET NULL,
    -- SET NULL: losing an assignee must not block admin housekeeping.
    assigned_group_id UUID REFERENCES app.groups(group_id) ON DELETE SET NULL,
    assigned_user_id  UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    status            app.activity_manual_task_status NOT NULL DEFAULT 'new'::app.activity_manual_task_status,
    outcome           app.activity_manual_task_outcome,
    pause_reason      app.activity_manual_task_pause_reason,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at      TIMESTAMPTZ,
    CONSTRAINT uq_activity_manual_tasks_number UNIQUE (task_number),
    CONSTRAINT chk_activity_manual_tasks_number_format CHECK (task_number ~ '^ma-[0-9a-z]{6}$'),
    CONSTRAINT chk_activity_manual_tasks_title_not_blank CHECK (btrim(title) <> '')
);

DROP TRIGGER IF EXISTS tgr_activity_manual_tasks_set_updated_at ON app.activity_manual_tasks;
CREATE TRIGGER tgr_activity_manual_tasks_set_updated_at
BEFORE UPDATE ON app.activity_manual_tasks
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

-- Assigns task_number on INSERT unless the caller supplied one (import paths).
-- The number is generated here rather than in the backend so that concurrent inserts and
-- direct SQL imports can never produce a duplicate: the sequence is the single allocator.
-- Prefix is the activity-owned literal 'ma-' (not app.work_item_id_prefix — activities
-- are not a work_item_kind) plus 6-char base36 via app.int_to_base36_6.
CREATE OR REPLACE FUNCTION app.tgr_activity_manual_tasks_assign_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.task_number IS NOT NULL AND btrim(NEW.task_number) <> '' THEN
        RETURN NEW;
    END IF;

    NEW.task_number := 'ma-' || app.int_to_base36_6(nextval('app.seq_activity_manual_task_number'));
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_activity_manual_tasks_assign_number ON app.activity_manual_tasks;
CREATE TRIGGER tgr_activity_manual_tasks_assign_number
BEFORE INSERT ON app.activity_manual_tasks
FOR EACH ROW EXECUTE FUNCTION app.tgr_activity_manual_tasks_assign_number();

-- The creation stamp is immutable: task_number, parent_kind, parent_id, created_at.
-- Title, description, assignment, status, outcome, pause_reason and completed_at stay open.
CREATE OR REPLACE FUNCTION app.tgr_activity_manual_tasks_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.task_number IS DISTINCT FROM OLD.task_number
       OR NEW.parent_kind  IS DISTINCT FROM OLD.parent_kind
       OR NEW.parent_id    IS DISTINCT FROM OLD.parent_id
       OR NEW.created_at   IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'manual task %: creation stamp is immutable', OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_activity_manual_tasks_stamp_immutable ON app.activity_manual_tasks;
CREATE TRIGGER tgr_activity_manual_tasks_stamp_immutable
BEFORE UPDATE ON app.activity_manual_tasks
FOR EACH ROW EXECUTE FUNCTION app.tgr_activity_manual_tasks_stamp_immutable();

COMMENT ON TABLE app.activity_manual_tasks IS
    'Human-in-the-loop manual tasks under a service request or a process. Practice-specific table, not a work_item_kind and not a row in a shared activity table — same reasoning that keeps app.service_requests standing alone rather than folding future incident/problem/change rows into one table with a kind column (see the comment above app.work_item_forms). Storage only in this release — no fill logic, no Go/FE readers. Future attachments-panel entity_type value reserved as ''manual_task'' (documentation only; no registration in this release).';
COMMENT ON COLUMN app.activity_manual_tasks.id IS 'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.activity_manual_tasks.task_number IS 'Human-readable reference ma- + 6 base36 chars from app.seq_activity_manual_task_number; assigned by trigger on INSERT. Unique. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_manual_tasks.parent_kind IS 'What the parent is (service_request or process). Immutable after INSERT. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_manual_tasks.parent_id IS 'UUID of the parent service request or process. Bare column — intentionally no FK; resolving the parent is a later slice. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_manual_tasks.title IS 'Short title of the task. Required and non-blank.';
COMMENT ON COLUMN app.activity_manual_tasks.description IS 'Free-text description. Nullable; no fill logic in this release — set manually.';
COMMENT ON COLUMN app.activity_manual_tasks.kb_article_id IS 'Optional linked KB article. ON DELETE SET NULL. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_manual_tasks.assigned_group_id IS 'Group currently responsible. ON DELETE SET NULL. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_manual_tasks.assigned_user_id IS 'User currently assigned. ON DELETE SET NULL for still-open rows. Completed rows are re-pointed at the seeded Deleted User by app.tgr_users_reattribute_completed_activities before the user row is deleted. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_manual_tasks.status IS
    'Lifecycle status (app.activity_manual_task_status): new / in_progress / paused / complete. Default new. Stored only; no fill logic and no CHECK tying outcome, pause_reason or completed_at to this column in this release.';
COMMENT ON COLUMN app.activity_manual_tasks.outcome IS
    'Terminal outcome (app.activity_manual_task_outcome): succeeded / cancelled / failed / skipped. Nullable; stored only; no fill logic and no CHECK tying it to status in this release.';
COMMENT ON COLUMN app.activity_manual_tasks.pause_reason IS
    'Why the task is on hold (app.activity_manual_task_pause_reason). Stored only; no fill or clear-on-resume logic in this release, and no CHECK tying it to status.';
COMMENT ON COLUMN app.activity_manual_tasks.created_at IS 'Row creation timestamp. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_manual_tasks.updated_at IS 'Last-update timestamp. Maintained by app.tgr_set_updated_at().';
COMMENT ON COLUMN app.activity_manual_tasks.completed_at IS 'Completion timestamp. Stored only; no fill logic and no CHECK tying it to status in this release.';

CREATE SEQUENCE IF NOT EXISTS app.seq_activity_approval_number
    AS BIGINT START WITH 1 INCREMENT BY 1
    MINVALUE 0 MAXVALUE 2176782335
    CACHE 1 NO CYCLE;

COMMENT ON SEQUENCE app.seq_activity_approval_number IS
    'Counter for approval numbers (base36 suffix, ap-000001..ap-zzzzzz). MAXVALUE = 36^6-1.';

CREATE TABLE IF NOT EXISTS app.activity_approvals (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    approval_number   VARCHAR(32) NOT NULL,
    parent_kind       app.activity_parent_kind NOT NULL,
    -- Bare UUID: the parent may be a service request or a process. No FK in this release.
    parent_id         UUID NOT NULL,
    title             VARCHAR(500) NOT NULL,
    description       TEXT,
    -- SET NULL: losing an assignee must not block admin housekeeping.
    assigned_group_id UUID REFERENCES app.groups(group_id) ON DELETE SET NULL,
    assigned_user_id  UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    status            app.activity_approval_status NOT NULL DEFAULT 'new'::app.activity_approval_status,
    outcome           app.activity_approval_outcome,
    pause_reason      app.activity_approval_pause_reason,
    approval_notes    TEXT,
    rejection_notes   TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at      TIMESTAMPTZ,
    CONSTRAINT uq_activity_approvals_number UNIQUE (approval_number),
    CONSTRAINT chk_activity_approvals_number_format CHECK (approval_number ~ '^ap-[0-9a-z]{6}$'),
    CONSTRAINT chk_activity_approvals_title_not_blank CHECK (btrim(title) <> '')
);

DROP TRIGGER IF EXISTS tgr_activity_approvals_set_updated_at ON app.activity_approvals;
CREATE TRIGGER tgr_activity_approvals_set_updated_at
BEFORE UPDATE ON app.activity_approvals
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

-- Assigns approval_number on INSERT unless the caller supplied one (import paths).
-- The number is generated here rather than in the backend so that concurrent inserts and
-- direct SQL imports can never produce a duplicate: the sequence is the single allocator.
-- Prefix is the activity-owned literal 'ap-' (not app.work_item_id_prefix — activities
-- are not a work_item_kind) plus 6-char base36 via app.int_to_base36_6.
CREATE OR REPLACE FUNCTION app.tgr_activity_approvals_assign_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.approval_number IS NOT NULL AND btrim(NEW.approval_number) <> '' THEN
        RETURN NEW;
    END IF;

    NEW.approval_number := 'ap-' || app.int_to_base36_6(nextval('app.seq_activity_approval_number'));
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_activity_approvals_assign_number ON app.activity_approvals;
CREATE TRIGGER tgr_activity_approvals_assign_number
BEFORE INSERT ON app.activity_approvals
FOR EACH ROW EXECUTE FUNCTION app.tgr_activity_approvals_assign_number();

-- The creation stamp is immutable: approval_number, parent_kind, parent_id, created_at.
-- Title, description, assignment, status, outcome, pause_reason, notes and completed_at stay open.
CREATE OR REPLACE FUNCTION app.tgr_activity_approvals_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.approval_number IS DISTINCT FROM OLD.approval_number
       OR NEW.parent_kind    IS DISTINCT FROM OLD.parent_kind
       OR NEW.parent_id      IS DISTINCT FROM OLD.parent_id
       OR NEW.created_at     IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'approval %: creation stamp is immutable', OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_activity_approvals_stamp_immutable ON app.activity_approvals;
CREATE TRIGGER tgr_activity_approvals_stamp_immutable
BEFORE UPDATE ON app.activity_approvals
FOR EACH ROW EXECUTE FUNCTION app.tgr_activity_approvals_stamp_immutable();

COMMENT ON TABLE app.activity_approvals IS
    'Human-in-the-loop approvals under a service request or a process. Practice-specific table, not a work_item_kind and not a row in a shared activity table — same reasoning that keeps app.service_requests standing alone rather than folding future incident/problem/change rows into one table with a kind column (see the comment above app.work_item_forms). Storage only in this release — no fill logic, no Go/FE readers.';
COMMENT ON COLUMN app.activity_approvals.id IS 'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.activity_approvals.approval_number IS 'Human-readable reference ap- + 6 base36 chars from app.seq_activity_approval_number; assigned by trigger on INSERT. Unique. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_approvals.parent_kind IS 'What the parent is (service_request or process). Immutable after INSERT. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_approvals.parent_id IS 'UUID of the parent service request or process. Bare column — intentionally no FK; resolving the parent is a later slice. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_approvals.title IS 'Short title of the approval. Required and non-blank.';
COMMENT ON COLUMN app.activity_approvals.description IS 'Free-text description. Nullable; no fill logic in this release — set manually.';
COMMENT ON COLUMN app.activity_approvals.assigned_group_id IS 'Group currently responsible. ON DELETE SET NULL. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_approvals.assigned_user_id IS 'User currently assigned. ON DELETE SET NULL for still-open rows. Completed rows are re-pointed at the seeded Deleted User by app.tgr_users_reattribute_completed_activities before the user row is deleted. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_approvals.status IS
    'Lifecycle status (app.activity_approval_status): new / in_progress / paused / complete. Default new. Stored only; no fill logic and no CHECK tying outcome, pause_reason or completed_at to this column in this release.';
COMMENT ON COLUMN app.activity_approvals.outcome IS
    'Terminal outcome (app.activity_approval_outcome): approved / rejected. Nullable; stored only; no fill logic and no CHECK tying it to status in this release.';
COMMENT ON COLUMN app.activity_approvals.pause_reason IS
    'Why the approval is on hold (app.activity_approval_pause_reason). Stored only; no fill or clear-on-resume logic in this release, and no CHECK tying it to status.';
COMMENT ON COLUMN app.activity_approvals.approval_notes IS 'Free-text notes recorded when approving. Nullable; stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_approvals.rejection_notes IS 'Free-text notes recorded when rejecting. Nullable; stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_approvals.created_at IS 'Row creation timestamp. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_approvals.updated_at IS 'Last-update timestamp. Maintained by app.tgr_set_updated_at().';
COMMENT ON COLUMN app.activity_approvals.completed_at IS 'Completion timestamp. Stored only; no fill logic and no CHECK tying it to status in this release.';

CREATE SEQUENCE IF NOT EXISTS app.seq_activity_acceptance_number
    AS BIGINT START WITH 1 INCREMENT BY 1
    MINVALUE 0 MAXVALUE 2176782335
    CACHE 1 NO CYCLE;

COMMENT ON SEQUENCE app.seq_activity_acceptance_number IS
    'Counter for acceptance numbers (base36 suffix, ac-000001..ac-zzzzzz). MAXVALUE = 36^6-1.';

CREATE TABLE IF NOT EXISTS app.activity_acceptances (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    acceptance_number VARCHAR(32) NOT NULL,
    parent_kind       app.activity_parent_kind NOT NULL,
    -- Bare UUID: the parent may be a service request or a process. No FK in this release.
    parent_id         UUID NOT NULL,
    title             VARCHAR(500) NOT NULL,
    description       TEXT,
    -- SET NULL: losing an assignee must not block admin housekeeping.
    assigned_group_id UUID REFERENCES app.groups(group_id) ON DELETE SET NULL,
    assigned_user_id  UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    status            app.activity_acceptance_status NOT NULL DEFAULT 'new'::app.activity_acceptance_status,
    outcome           app.activity_acceptance_outcome,
    acceptance_notes  TEXT,
    rejection_notes   TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at      TIMESTAMPTZ,
    CONSTRAINT uq_activity_acceptances_number UNIQUE (acceptance_number),
    CONSTRAINT chk_activity_acceptances_number_format CHECK (acceptance_number ~ '^ac-[0-9a-z]{6}$'),
    CONSTRAINT chk_activity_acceptances_title_not_blank CHECK (btrim(title) <> '')
);

DROP TRIGGER IF EXISTS tgr_activity_acceptances_set_updated_at ON app.activity_acceptances;
CREATE TRIGGER tgr_activity_acceptances_set_updated_at
BEFORE UPDATE ON app.activity_acceptances
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

-- Assigns acceptance_number on INSERT unless the caller supplied one (import paths).
-- The number is generated here rather than in the backend so that concurrent inserts and
-- direct SQL imports can never produce a duplicate: the sequence is the single allocator.
-- Prefix is the activity-owned literal 'ac-' (not app.work_item_id_prefix — activities
-- are not a work_item_kind) plus 6-char base36 via app.int_to_base36_6.
CREATE OR REPLACE FUNCTION app.tgr_activity_acceptances_assign_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.acceptance_number IS NOT NULL AND btrim(NEW.acceptance_number) <> '' THEN
        RETURN NEW;
    END IF;

    NEW.acceptance_number := 'ac-' || app.int_to_base36_6(nextval('app.seq_activity_acceptance_number'));
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_activity_acceptances_assign_number ON app.activity_acceptances;
CREATE TRIGGER tgr_activity_acceptances_assign_number
BEFORE INSERT ON app.activity_acceptances
FOR EACH ROW EXECUTE FUNCTION app.tgr_activity_acceptances_assign_number();

-- The creation stamp is immutable: acceptance_number, parent_kind, parent_id, created_at.
-- Title, description, assignment, status, outcome, notes and completed_at stay open.
CREATE OR REPLACE FUNCTION app.tgr_activity_acceptances_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.acceptance_number IS DISTINCT FROM OLD.acceptance_number
       OR NEW.parent_kind      IS DISTINCT FROM OLD.parent_kind
       OR NEW.parent_id        IS DISTINCT FROM OLD.parent_id
       OR NEW.created_at       IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'acceptance %: creation stamp is immutable', OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tgr_activity_acceptances_stamp_immutable ON app.activity_acceptances;
CREATE TRIGGER tgr_activity_acceptances_stamp_immutable
BEFORE UPDATE ON app.activity_acceptances
FOR EACH ROW EXECUTE FUNCTION app.tgr_activity_acceptances_stamp_immutable();

COMMENT ON TABLE app.activity_acceptances IS
    'Human-in-the-loop acceptances under a service request or a process. Practice-specific table, not a work_item_kind and not a row in a shared activity table — same reasoning that keeps app.service_requests standing alone rather than folding future incident/problem/change rows into one table with a kind column (see the comment above app.work_item_forms). Acceptance never pauses (no pause_reason column). Storage only in this release — no fill logic, no Go/FE readers. Future attachments-panel entity_type value reserved as ''acceptance'' (documentation only; no registration in this release).';
COMMENT ON COLUMN app.activity_acceptances.id IS 'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.activity_acceptances.acceptance_number IS 'Human-readable reference ac- + 6 base36 chars from app.seq_activity_acceptance_number; assigned by trigger on INSERT. Unique. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_acceptances.parent_kind IS 'What the parent is (service_request or process). Immutable after INSERT. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_acceptances.parent_id IS 'UUID of the parent service request or process. Bare column — intentionally no FK; resolving the parent is a later slice. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_acceptances.title IS 'Short title of the acceptance. Required and non-blank.';
COMMENT ON COLUMN app.activity_acceptances.description IS 'Free-text description. Nullable; no fill logic in this release — set manually.';
COMMENT ON COLUMN app.activity_acceptances.assigned_group_id IS 'Group currently responsible. ON DELETE SET NULL. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_acceptances.assigned_user_id IS 'User currently assigned. ON DELETE SET NULL for still-open rows. Completed rows are re-pointed at the seeded Deleted User by app.tgr_users_reattribute_completed_activities before the user row is deleted. Stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_acceptances.status IS
    'Lifecycle status (app.activity_acceptance_status): new / in_progress / complete. Default new. Stored only; no fill logic and no CHECK tying outcome or completed_at to this column in this release.';
COMMENT ON COLUMN app.activity_acceptances.outcome IS
    'Terminal outcome (app.activity_acceptance_outcome): accepted / rejected. Nullable; stored only; no fill logic and no CHECK tying it to status in this release.';
COMMENT ON COLUMN app.activity_acceptances.acceptance_notes IS 'Free-text notes recorded when accepting. Nullable; stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_acceptances.rejection_notes IS 'Free-text notes recorded when rejecting. Nullable; stored only; no fill logic in this release.';
COMMENT ON COLUMN app.activity_acceptances.created_at IS 'Row creation timestamp. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_acceptances.updated_at IS 'Last-update timestamp. Maintained by app.tgr_set_updated_at().';
COMMENT ON COLUMN app.activity_acceptances.completed_at IS 'Completion timestamp. Stored only; no fill logic and no CHECK tying it to status in this release.';

-- Hard-deleting a user must not silently erase who decided a completed activity,
-- but must free up a still-open one for reassignment. A single static
-- ON DELETE SET NULL FK cannot branch on row status, so this BEFORE DELETE
-- trigger runs first: it re-points every already-complete row at the seeded
-- Deleted User (00000000-0000-0000-0000-00000000dead). Rows still open
-- (new / in_progress / paused) are left pointing at OLD.user_id, so when the
-- DELETE proceeds the assigned_user_id ... ON DELETE SET NULL foreign keys
-- release them to NULL.
CREATE OR REPLACE FUNCTION app.tgr_users_reattribute_completed_activities()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    deleted_user CONSTANT UUID := '00000000-0000-0000-0000-00000000dead';
BEGIN
    UPDATE app.activity_manual_tasks
       SET assigned_user_id = deleted_user
     WHERE assigned_user_id = OLD.user_id
       AND status = 'complete'::app.activity_manual_task_status;

    UPDATE app.activity_approvals
       SET assigned_user_id = deleted_user
     WHERE assigned_user_id = OLD.user_id
       AND status = 'complete'::app.activity_approval_status;

    UPDATE app.activity_acceptances
       SET assigned_user_id = deleted_user
     WHERE assigned_user_id = OLD.user_id
       AND status = 'complete'::app.activity_acceptance_status;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS tgr_users_reattribute_completed_activities ON app.users;
CREATE TRIGGER tgr_users_reattribute_completed_activities
BEFORE DELETE ON app.users
FOR EACH ROW EXECUTE FUNCTION app.tgr_users_reattribute_completed_activities();

COMMENT ON FUNCTION app.tgr_users_reattribute_completed_activities() IS
    'BEFORE DELETE on app.users. Re-points every already-complete activity (manual task / approval / acceptance) at the seeded Deleted User (00000000-0000-0000-0000-00000000dead) so hard-deleting a user does not silently erase who decided a completed row. Still-open rows (new / in_progress / paused) are left pointing at OLD.user_id; when the DELETE proceeds immediately afterward, the assigned_user_id ON DELETE SET NULL foreign keys on the three activity tables release those open rows to NULL.';

-- ===========================================================================
-- 3. Indexes
-- ===========================================================================

-- ============================================
-- Activities (runtime: manual task, approval, acceptance)
-- ============================================

-- Personal queue of the individually assigned handler (open rows only).
CREATE INDEX IF NOT EXISTS idx_activity_manual_tasks_assignee_open
    ON app.activity_manual_tasks USING btree (assigned_user_id, created_at DESC)
    WHERE status IN ('new', 'in_progress', 'paused');

-- The dispatcher queue: open work per assigned group.
CREATE INDEX IF NOT EXISTS idx_activity_manual_tasks_group_open
    ON app.activity_manual_tasks USING btree (assigned_group_id, created_at DESC)
    WHERE status IN ('new', 'in_progress', 'paused');

CREATE INDEX IF NOT EXISTS idx_activity_manual_tasks_status
    ON app.activity_manual_tasks USING btree (status);

CREATE INDEX IF NOT EXISTS idx_activity_manual_tasks_parent
    ON app.activity_manual_tasks USING btree (parent_kind, parent_id);

-- Case-insensitive title search.
CREATE INDEX IF NOT EXISTS idx_activity_manual_tasks_title_trgm
    ON app.activity_manual_tasks USING gin (lower(title) gin_trgm_ops);

-- Reverse lookup before retiring a KB article ("what still links to it?").
CREATE INDEX IF NOT EXISTS idx_activity_manual_tasks_kb_article
    ON app.activity_manual_tasks USING btree (kb_article_id)
    WHERE kb_article_id IS NOT NULL;

-- Personal queue of the individually assigned approver (open rows only).
CREATE INDEX IF NOT EXISTS idx_activity_approvals_assignee_open
    ON app.activity_approvals USING btree (assigned_user_id, created_at DESC)
    WHERE status IN ('new', 'in_progress', 'paused');

-- The dispatcher queue: open approvals per assigned group.
CREATE INDEX IF NOT EXISTS idx_activity_approvals_group_open
    ON app.activity_approvals USING btree (assigned_group_id, created_at DESC)
    WHERE status IN ('new', 'in_progress', 'paused');

CREATE INDEX IF NOT EXISTS idx_activity_approvals_status
    ON app.activity_approvals USING btree (status);

CREATE INDEX IF NOT EXISTS idx_activity_approvals_parent
    ON app.activity_approvals USING btree (parent_kind, parent_id);

-- Case-insensitive title search.
CREATE INDEX IF NOT EXISTS idx_activity_approvals_title_trgm
    ON app.activity_approvals USING gin (lower(title) gin_trgm_ops);

-- Personal queue of the individually assigned acceptor (open rows only).
CREATE INDEX IF NOT EXISTS idx_activity_acceptances_assignee_open
    ON app.activity_acceptances USING btree (assigned_user_id, created_at DESC)
    WHERE status IN ('new', 'in_progress');

-- The dispatcher queue: open acceptances per assigned group.
CREATE INDEX IF NOT EXISTS idx_activity_acceptances_group_open
    ON app.activity_acceptances USING btree (assigned_group_id, created_at DESC)
    WHERE status IN ('new', 'in_progress');

CREATE INDEX IF NOT EXISTS idx_activity_acceptances_status
    ON app.activity_acceptances USING btree (status);

CREATE INDEX IF NOT EXISTS idx_activity_acceptances_parent
    ON app.activity_acceptances USING btree (parent_kind, parent_id);

-- Case-insensitive title search.
CREATE INDEX IF NOT EXISTS idx_activity_acceptances_title_trgm
    ON app.activity_acceptances USING gin (lower(title) gin_trgm_ops);

-- ===========================================================================
-- 4. Work.Fs.Quotas settings
-- ===========================================================================
-- Work file storage — quotas for Work activity (manual_task, acceptance) attachments.
-- QuotaModule on the FS registry is Work. Same INSERT shape as
-- db/init/11_app_settings.sql (ON CONFLICT updates the seed rows).

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
('Work.Fs.Quotas', 'entity.max.bytes', 'all',
 '104857600', '{"type":"integer","minimum":0}', '104857600',
 'Sum of all file bytes per single activity (manual task or acceptance). 0 = unlimited.', false),
('Work.Fs.Quotas', 'entity.max.count', 'all',
 '20', '{"type":"integer","minimum":1,"maximum":200}', '20',
 'Hard cap of file count per activity.', false),
('Work.Fs.Quotas', 'user.per.day.max.bytes', 'all',
 '1073741824', '{"type":"integer","minimum":0}', '1073741824',
 'Anti-abuse: max bytes uploaded as activity files per user per day. 0 = unlimited.', false),
('Work.Fs.Quotas', 'module.total.storage.max.bytes', 'all',
 '0', '{"type":"integer","minimum":0}', '0',
 'Work-wide ceiling: sum of all activity stored file bytes. 0 = unlimited.', false)
ON CONFLICT (section_path, setting_name, environment) DO UPDATE SET
    value = EXCLUDED.value,
    validation_schema = EXCLUDED.validation_schema,
    default_value = EXCLUDED.default_value,
    description = EXCLUDED.description,
    is_public = EXCLUDED.is_public,
    updated_at = CURRENT_TIMESTAMP;

-- ===========================================================================
-- 5. Service requests: app.work_item_service_requests -> app.service_requests
-- ===========================================================================
-- m_0.23.8 renamed the table the other way, guarded by
-- to_regclass('app.service_requests'). After this section that name exists
-- again, so m_0.23.8 must never be edited — a checksum change would re-apply
-- it and flip the name back. Table, sequence and function renames check old
-- exists AND new absent; index, constraint and trigger renames check the old name.

-- 5.1 table
DO $$
BEGIN
    IF to_regclass('app.work_item_service_requests') IS NOT NULL
       AND to_regclass('app.service_requests') IS NULL
    THEN
        ALTER TABLE app.work_item_service_requests RENAME TO service_requests;
    END IF;
END $$;

-- 5.2 sequence
DO $$
BEGIN
    IF to_regclass('app.seq_work_item_service_request_number') IS NOT NULL
       AND to_regclass('app.seq_service_request_number') IS NULL
    THEN
        ALTER SEQUENCE app.seq_work_item_service_request_number
            RENAME TO seq_service_request_number;
    END IF;
END $$;

COMMENT ON SEQUENCE app.seq_service_request_number IS
    'Counter for service request numbers (base36 suffix, sr-000001..sr-zzzzzz). MAXVALUE = 36^6-1.';

-- 5.3 indexes
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT * FROM (VALUES
            ('idx_work_item_service_requests_requester_created',     'idx_service_requests_requester_created'),
            ('idx_work_item_service_requests_requested_for_created', 'idx_service_requests_requested_for_created'),
            ('idx_work_item_service_requests_group_open',            'idx_service_requests_group_open'),
            ('idx_work_item_service_requests_assignee_open',         'idx_service_requests_assignee_open'),
            ('idx_work_item_service_requests_service_status',        'idx_service_requests_service_status'),
            ('idx_work_item_service_requests_answers',               'idx_service_requests_answers'),
            ('idx_work_item_service_requests_title_trgm',            'idx_service_requests_title_trgm'),
            ('idx_work_item_service_requests_form_version',          'idx_service_requests_form_version')
        ) AS t(old_name, new_name)
    LOOP
        IF to_regclass('app.' || rec.old_name) IS NOT NULL THEN
            EXECUTE format('ALTER INDEX app.%I RENAME TO %I', rec.old_name, rec.new_name);
        END IF;
    END LOOP;
END $$;

-- 5.4 constraints (named CHECKs/UNIQUE plus implicit PK/FKs from CREATE TABLE,
--     plus PG 16+ named NOT NULL constraints `{table}_{column}_not_null`,
--     which RENAME TABLE does not rewrite). Includes approval_status_not_null
--     (added after m_0.23.8's rename).
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT * FROM (VALUES
            ('uq_work_item_service_requests_request_number',          'uq_service_requests_request_number'),
            ('chk_work_item_service_requests_request_number_format',  'chk_service_requests_request_number_format'),
            ('chk_work_item_service_requests_title_not_blank',        'chk_service_requests_title_not_blank'),
            ('chk_work_item_service_requests_answers_object',         'chk_service_requests_answers_object'),
            ('work_item_service_requests_pkey',                       'service_requests_pkey'),
            ('work_item_service_requests_service_id_fkey',            'service_requests_service_id_fkey'),
            ('work_item_service_requests_form_version_id_fkey',       'service_requests_form_version_id_fkey'),
            ('work_item_service_requests_requester_user_id_fkey',     'service_requests_requester_user_id_fkey'),
            ('work_item_service_requests_requested_for_user_id_fkey', 'service_requests_requested_for_user_id_fkey'),
            ('work_item_service_requests_assigned_group_id_fkey',     'service_requests_assigned_group_id_fkey'),
            ('work_item_service_requests_assigned_user_id_fkey',      'service_requests_assigned_user_id_fkey'),
            ('work_item_service_requests_created_by_fkey',            'service_requests_created_by_fkey'),
            ('work_item_service_requests_updated_by_fkey',            'service_requests_updated_by_fkey'),
            ('work_item_service_requests_id_not_null',                    'service_requests_id_not_null'),
            ('work_item_service_requests_request_number_not_null',        'service_requests_request_number_not_null'),
            ('work_item_service_requests_service_id_not_null',            'service_requests_service_id_not_null'),
            ('work_item_service_requests_form_version_id_not_null',       'service_requests_form_version_id_not_null'),
            ('work_item_service_requests_urgency_not_null',               'service_requests_urgency_not_null'),
            ('work_item_service_requests_status_not_null',                'service_requests_status_not_null'),
            ('work_item_service_requests_title_not_null',                 'service_requests_title_not_null'),
            ('work_item_service_requests_answers_not_null',               'service_requests_answers_not_null'),
            ('work_item_service_requests_requester_user_id_not_null',     'service_requests_requester_user_id_not_null'),
            ('work_item_service_requests_created_by_not_null',            'service_requests_created_by_not_null'),
            ('work_item_service_requests_created_at_not_null',            'service_requests_created_at_not_null'),
            ('work_item_service_requests_updated_at_not_null',            'service_requests_updated_at_not_null'),
            ('work_item_service_requests_approval_status_not_null',       'service_requests_approval_status_not_null')
        ) AS t(old_name, new_name)
    LOOP
        IF EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class rel ON rel.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = rel.relnamespace
            WHERE n.nspname = 'app'
              AND rel.relname = 'service_requests'
              AND c.conname = rec.old_name
        ) THEN
            EXECUTE format(
                'ALTER TABLE app.service_requests RENAME CONSTRAINT %I TO %I',
                rec.old_name, rec.new_name
            );
        END IF;
    END LOOP;
END $$;

-- 5.5 trigger functions (rename, then replace body so the sequence name matches)
DO $$
BEGIN
    IF to_regprocedure('app.tgr_work_item_service_requests_assign_number()') IS NOT NULL
       AND to_regprocedure('app.tgr_service_requests_assign_number()') IS NULL
    THEN
        ALTER FUNCTION app.tgr_work_item_service_requests_assign_number()
            RENAME TO tgr_service_requests_assign_number;
    END IF;

    IF to_regprocedure('app.tgr_work_item_service_requests_stamp_immutable()') IS NOT NULL
       AND to_regprocedure('app.tgr_service_requests_stamp_immutable()') IS NULL
    THEN
        ALTER FUNCTION app.tgr_work_item_service_requests_stamp_immutable()
            RENAME TO tgr_service_requests_stamp_immutable;
    END IF;
END $$;

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

-- 5.6 triggers on the renamed table (shared tgr_set_updated_at is not renamed)
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT * FROM (VALUES
            ('tgr_work_item_service_requests_set_updated_at',  'tgr_service_requests_set_updated_at'),
            ('tgr_work_item_service_requests_assign_number',   'tgr_service_requests_assign_number'),
            ('tgr_work_item_service_requests_stamp_immutable', 'tgr_service_requests_stamp_immutable')
        ) AS t(old_name, new_name)
    LOOP
        IF EXISTS (
            SELECT 1
            FROM pg_trigger trg
            JOIN pg_class rel ON rel.oid = trg.tgrelid
            JOIN pg_namespace n ON n.oid = rel.relnamespace
            WHERE n.nspname = 'app'
              AND rel.relname = 'service_requests'
              AND trg.tgname = rec.old_name
              AND NOT trg.tgisinternal
        ) THEN
            EXECUTE format(
                'ALTER TRIGGER %I ON app.service_requests RENAME TO %I',
                rec.old_name, rec.new_name
            );
        END IF;
    END LOOP;
END $$;

-- 5.7 COMMENT ON — same literals as db/init (dump-visible parity)
COMMENT ON COLUMN app.service_requests.request_number IS 'Human-readable reference sr- + 6 base36 chars from app.seq_service_request_number; assigned by trigger on INSERT. Unique. Immutable after INSERT.';
COMMENT ON TYPE app.work_item_pause_reason IS
    'Hold-reason codes for a paused service request. awaiting_requester and awaiting_third_party are outside the support team''s control, scheduled is planned work, other keeps the clock running. Stored on service_requests.pause_reason; no fill logic and no CHECK tying the column to status in this release.';

-- ===========================================================================
-- 6. Processes (design time + runtime)
-- ===========================================================================
-- Design-time process definitions with versioning (mirrors work item forms)
-- and runtime process_instances / process_tokens. Enums, tables, deferred FK,
-- triggers/functions, indexes and COMMENT ON literals match db/init.

-- Lifecycle enums for the process engine: one version of a process definition,
-- one running instance, and one token (arrival of an instance at one element).

DO $$ BEGIN
    CREATE TYPE app.process_version_status AS ENUM ('draft', 'active', 'retired');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.process_version_status IS
    'Lifecycle of one process definition version: draft (editable), active (frozen; new instances start here), retired (frozen; keeps serving instances already stamped on it). Same semantics as app.work_item_form_version_status.';

DO $$ BEGIN
    CREATE TYPE app.process_instance_status AS ENUM ('running', 'completed', 'cancelled');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.process_instance_status IS
    'Lifecycle of one process instance: running, completed, cancelled. completed and cancelled are terminal; a terminal instance is frozen history.';

DO $$ BEGIN
    CREATE TYPE app.process_token_state AS ENUM ('ready', 'waiting', 'completed', 'cancelled', 'incident');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.process_token_state IS
    'State of one token (one arrival of an instance at one element): ready = arrived, the executor must process it; waiting = parked at a wait state until an external signal; completed = left the element; cancelled = killed by instance cancellation; incident = processing failed, needs an administrator retry. completed and cancelled are terminal.';

-- ===========================================================================
-- Processes (design time + runtime)
-- ===========================================================================
-- Design time mirrors work item forms: a process identity carries no body;
-- the body lives on process_versions. Runtime: one process_instances row per
-- run on a frozen active version, and process_tokens as arrivals at elements.

CREATE TABLE IF NOT EXISTS app.processes (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id         VARCHAR(20) NOT NULL,
    name               VARCHAR(250) NOT NULL,
    current_version_id UUID,
    owner_user_id      UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_by         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_processes_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT chk_processes_process_id_format CHECK (process_id ~ '^proc-[0-9a-f]{5}$')
);

DROP TRIGGER IF EXISTS tgr_processes_set_updated_at ON app.processes;
CREATE TRIGGER tgr_processes_set_updated_at
BEFORE UPDATE ON app.processes
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.processes IS
    'Process identity. Carries no body — the executable model and diagram live on app.process_versions.';
COMMENT ON COLUMN app.processes.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.processes.process_id IS
    'Server-generated admin id: proc-{5 lowercase hex}, assigned once on create. Case-insensitive unique. Distinct from the row UUID (id).';
COMMENT ON COLUMN app.processes.name IS
    'Admin label for the process. Required and non-blank.';
COMMENT ON COLUMN app.processes.current_version_id IS
    'Active version new instances start from. NULL while the process has only drafts.';
COMMENT ON COLUMN app.processes.owner_user_id IS
    'First-class accountable owner. ON DELETE RESTRICT.';
COMMENT ON COLUMN app.processes.created_by IS
    'User who created the process. ON DELETE RESTRICT.';
COMMENT ON COLUMN app.processes.created_at IS
    'Row creation timestamp.';
COMMENT ON COLUMN app.processes.updated_by IS
    'User who last updated the process. ON DELETE SET NULL.';
COMMENT ON COLUMN app.processes.updated_at IS
    'Last-update timestamp. Maintained by app.tgr_set_updated_at().';

-- Immutable snapshot of a process definition. Frozen when the version becomes
-- active by tgr_frozen_version_immutable.
CREATE TABLE IF NOT EXISTS app.process_versions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id     UUID NOT NULL REFERENCES app.processes(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    status         app.process_version_status NOT NULL DEFAULT 'draft'::app.process_version_status,
    definition     JSONB NOT NULL DEFAULT '{}'::jsonb,
    diagram        JSONB NOT NULL DEFAULT '{}'::jsonb,
    change_note    VARCHAR(500),
    published_at   TIMESTAMPTZ,
    published_by   UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    created_by     UUID NOT NULL REFERENCES app.users(user_id) ON DELETE RESTRICT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by     UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_process_versions_number UNIQUE (process_id, version_number),
    CONSTRAINT chk_process_versions_number_positive CHECK (version_number >= 1),
    CONSTRAINT chk_process_versions_definition_object CHECK (jsonb_typeof(definition) = 'object'),
    CONSTRAINT chk_process_versions_diagram_object CHECK (jsonb_typeof(diagram) = 'object'),
    CONSTRAINT chk_process_versions_publish_stamp CHECK (
        (status = 'draft'::app.process_version_status AND published_at IS NULL)
        OR (status <> 'draft'::app.process_version_status AND published_at IS NOT NULL)
    )
);

DROP TRIGGER IF EXISTS tgr_process_versions_set_updated_at ON app.process_versions;
CREATE TRIGGER tgr_process_versions_set_updated_at
BEFORE UPDATE ON app.process_versions
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.process_versions IS
    'One version of a process definition. Draft is editable; active and retired are frozen by tgr_frozen_version_immutable. Retired versions keep serving instances already stamped on them.';
COMMENT ON COLUMN app.process_versions.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.process_versions.process_id IS
    'Parent process row UUID (FK to app.processes.id). ON DELETE CASCADE.';
COMMENT ON COLUMN app.process_versions.version_number IS
    'Monotonic version number within the process, starting at 1. Unique per process.';
COMMENT ON COLUMN app.process_versions.status IS
    'Lifecycle: draft (editable), active (frozen; new instances start here), retired (frozen).';
COMMENT ON COLUMN app.process_versions.definition IS
    'Executable process model read by the engine. camelCase JSON document: schemaVersion, elements, flows. Must be a JSON object.';
COMMENT ON COLUMN app.process_versions.diagram IS
    'Layout for the graph editor (positions, flow bends). Opaque to the engine; frozen with the version. Must be a JSON object.';
COMMENT ON COLUMN app.process_versions.change_note IS
    'Short note shown in the version history list.';
COMMENT ON COLUMN app.process_versions.published_at IS
    'Set when the version leaves draft; from then on the row is frozen except status/change_note/audit columns.';
COMMENT ON COLUMN app.process_versions.published_by IS
    'User who published the version. ON DELETE SET NULL.';
COMMENT ON COLUMN app.process_versions.created_by IS
    'User who created the version. ON DELETE RESTRICT.';
COMMENT ON COLUMN app.process_versions.created_at IS
    'Row creation timestamp.';
COMMENT ON COLUMN app.process_versions.updated_by IS
    'User who last updated the version. ON DELETE SET NULL.';
COMMENT ON COLUMN app.process_versions.updated_at IS
    'Last-update timestamp. Maintained by app.tgr_set_updated_at().';

-- Deferred FK: processes and versions reference each other, so the constraint
-- is added once both tables exist. SET NULL keeps the process row if its
-- current version is deleted.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'processes_current_version_id_fkey'
          AND conrelid = 'app.processes'::regclass
    ) THEN
        ALTER TABLE app.processes
            ADD CONSTRAINT processes_current_version_id_fkey
            FOREIGN KEY (current_version_id)
            REFERENCES app.process_versions(id) ON DELETE SET NULL;
    END IF;
END $$;

DROP TRIGGER IF EXISTS tgr_process_versions_frozen ON app.process_versions;
CREATE TRIGGER tgr_process_versions_frozen
BEFORE UPDATE ON app.process_versions
FOR EACH ROW EXECUTE FUNCTION app.tgr_frozen_version_immutable();

-- current_version_id must point at an active version of the same process.
-- Without this, new instances could start from a draft.
CREATE OR REPLACE FUNCTION app.tgr_processes_validate_current_version()
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
    FROM app.process_versions
    WHERE id = NEW.current_version_id;

    IF v_process_id IS NULL THEN
        RAISE EXCEPTION 'process %: current version % not found', NEW.id, NEW.current_version_id
            USING ERRCODE = '23503';
    END IF;

    IF v_process_id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'process %: current version % belongs to another process', NEW.id, NEW.current_version_id
            USING ERRCODE = '23514';
    END IF;

    IF v_status <> 'active'::app.process_version_status THEN
        RAISE EXCEPTION 'process %: current version % must be active (is %)', NEW.id, NEW.current_version_id, v_status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_processes_validate_current_version() IS
    'BEFORE INSERT OR UPDATE OF current_version_id on app.processes. NULL is allowed; otherwise the version must exist, belong to the same process, and have status active.';

DROP TRIGGER IF EXISTS tgr_processes_validate_current_version ON app.processes;
CREATE TRIGGER tgr_processes_validate_current_version
BEFORE INSERT OR UPDATE OF current_version_id ON app.processes
FOR EACH ROW EXECUTE FUNCTION app.tgr_processes_validate_current_version();

CREATE TABLE IF NOT EXISTS app.process_instances (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id  UUID NOT NULL REFERENCES app.processes(id) ON DELETE RESTRICT,
    version_id  UUID NOT NULL REFERENCES app.process_versions(id) ON DELETE RESTRICT,
    status      app.process_instance_status NOT NULL DEFAULT 'running'::app.process_instance_status,
    variables   JSONB NOT NULL DEFAULT '{}'::jsonb,
    step_count  INTEGER NOT NULL DEFAULT 0,
    started_by  UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at    TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_process_instances_variables_object CHECK (jsonb_typeof(variables) = 'object'),
    CONSTRAINT chk_process_instances_step_count_non_negative CHECK (step_count >= 0),
    CONSTRAINT chk_process_instances_ended_stamp CHECK (
        (status = 'running'::app.process_instance_status AND ended_at IS NULL)
        OR (status <> 'running'::app.process_instance_status AND ended_at IS NOT NULL)
    )
);

DROP TRIGGER IF EXISTS tgr_process_instances_set_updated_at ON app.process_instances;
CREATE TRIGGER tgr_process_instances_set_updated_at
BEFORE UPDATE ON app.process_instances
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.process_instances IS
    'One run of a process on one frozen version. A process may have many instances at once. A terminal instance (completed/cancelled) is frozen history.';
COMMENT ON COLUMN app.process_instances.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.process_instances.process_id IS
    'Parent process. ON DELETE RESTRICT. Immutable after INSERT.';
COMMENT ON COLUMN app.process_instances.version_id IS
    'Frozen process version this instance runs on. Must be active at INSERT. Immutable after INSERT.';
COMMENT ON COLUMN app.process_instances.status IS
    'Lifecycle: running, completed, cancelled. completed and cancelled are terminal.';
COMMENT ON COLUMN app.process_instances.variables IS
    'Process context as a JSON object. Must be a JSON object.';
COMMENT ON COLUMN app.process_instances.step_count IS
    'Executor steps taken on this instance. Guarded by the engine step budget. Non-negative.';
COMMENT ON COLUMN app.process_instances.started_by IS
    'User who started the instance. NULL means system start or a deleted user (ON DELETE SET NULL). May only be released to NULL after INSERT.';
COMMENT ON COLUMN app.process_instances.started_at IS
    'Instance start timestamp. Immutable after INSERT.';
COMMENT ON COLUMN app.process_instances.ended_at IS
    'Set when the instance becomes terminal (completed or cancelled). NULL while running.';
COMMENT ON COLUMN app.process_instances.updated_at IS
    'Last-update timestamp. Maintained by app.tgr_set_updated_at().';

-- A new instance may only start on an active version of the same process.
CREATE OR REPLACE FUNCTION app.tgr_process_instances_validate_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_process_id UUID;
    v_status     app.process_version_status;
BEGIN
    SELECT process_id, status INTO v_process_id, v_status
    FROM app.process_versions WHERE id = NEW.version_id;
    IF v_process_id IS NULL THEN
        RAISE EXCEPTION 'process instance: version % not found', NEW.version_id USING ERRCODE = '23503';
    END IF;
    IF v_process_id IS DISTINCT FROM NEW.process_id THEN
        RAISE EXCEPTION 'process instance: version % belongs to another process', NEW.version_id USING ERRCODE = '23514';
    END IF;
    IF v_status <> 'active'::app.process_version_status THEN
        RAISE EXCEPTION 'process instance: version % is %, only an active version can start an instance', NEW.version_id, v_status USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_process_instances_validate_version() IS
    'BEFORE INSERT on app.process_instances. version_id must exist, belong to the same process_id, and have status active.';

DROP TRIGGER IF EXISTS tgr_process_instances_validate_version ON app.process_instances;
CREATE TRIGGER tgr_process_instances_validate_version
BEFORE INSERT ON app.process_instances
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_instances_validate_version();

-- Creation stamp is immutable; a terminal instance is frozen; becoming
-- terminal requires all tokens to be terminal first.
CREATE OR REPLACE FUNCTION app.tgr_process_instances_guard_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    free_keys TEXT[] := ARRAY['started_by', 'updated_at'];
BEGIN
    IF NEW.process_id IS DISTINCT FROM OLD.process_id
       OR NEW.version_id IS DISTINCT FROM OLD.version_id
       OR NEW.started_at IS DISTINCT FROM OLD.started_at
    THEN
        RAISE EXCEPTION 'process instance %: creation stamp is immutable', OLD.id USING ERRCODE = '23514';
    END IF;

    -- started_by may only be released to NULL (ON DELETE SET NULL when the user is deleted).
    IF NEW.started_by IS DISTINCT FROM OLD.started_by AND NEW.started_by IS NOT NULL THEN
        RAISE EXCEPTION 'process instance %: started_by can only be released to NULL', OLD.id USING ERRCODE = '23514';
    END IF;

    -- A terminal instance is frozen (history). Only the started_by release and updated_at may change.
    IF OLD.status <> 'running'::app.process_instance_status THEN
        IF (to_jsonb(OLD) - free_keys) IS DISTINCT FROM (to_jsonb(NEW) - free_keys) THEN
            RAISE EXCEPTION 'process instance %: instance is % and therefore frozen', OLD.id, OLD.status USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    -- An instance may become terminal only after all of its tokens are terminal.
    IF NEW.status <> 'running'::app.process_instance_status AND EXISTS (
        SELECT 1 FROM app.process_tokens t
        WHERE t.instance_id = OLD.id
          AND t.state IN ('ready'::app.process_token_state, 'waiting'::app.process_token_state, 'incident'::app.process_token_state)
    ) THEN
        RAISE EXCEPTION 'process instance %: cannot become % while it has active tokens', OLD.id, NEW.status USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_process_instances_guard_update() IS
    'BEFORE UPDATE on app.process_instances. Freezes process_id/version_id/started_at; allows started_by only to NULL; freezes terminal instances except started_by/updated_at; blocks becoming terminal while active tokens remain.';

DROP TRIGGER IF EXISTS tgr_process_instances_guard_update ON app.process_instances;
CREATE TRIGGER tgr_process_instances_guard_update
BEFORE UPDATE ON app.process_instances
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_instances_guard_update();

CREATE TABLE IF NOT EXISTS app.process_tokens (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id     UUID NOT NULL REFERENCES app.process_instances(id) ON DELETE CASCADE,
    element_id      VARCHAR(64) NOT NULL,
    element_type    VARCHAR(64) NOT NULL,
    via_flow_id     VARCHAR(64),
    state           app.process_token_state NOT NULL DEFAULT 'ready'::app.process_token_state,
    result          JSONB,
    incident_code   VARCHAR(100),
    incident_detail TEXT,
    arrived_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    left_at         TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_process_tokens_left_stamp CHECK (
        (state IN ('completed'::app.process_token_state, 'cancelled'::app.process_token_state)) = (left_at IS NOT NULL)
    ),
    CONSTRAINT chk_process_tokens_incident_code CHECK (
        state <> 'incident'::app.process_token_state OR incident_code IS NOT NULL
    ),
    CONSTRAINT chk_process_tokens_result_object CHECK (result IS NULL OR jsonb_typeof(result) = 'object')
);

DROP TRIGGER IF EXISTS tgr_process_tokens_set_updated_at ON app.process_tokens;
CREATE TRIGGER tgr_process_tokens_set_updated_at
BEFORE UPDATE ON app.process_tokens
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

COMMENT ON TABLE app.process_tokens IS
    'One arrival of an instance at one element (element instance). Active tokens (ready/waiting/incident) are the position on the graph; closed tokens are the path taken. At most one active token per instance in this release (linear processes), enforced by a partial unique index.';
COMMENT ON COLUMN app.process_tokens.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.process_tokens.instance_id IS
    'Parent process instance. ON DELETE CASCADE. Immutable after INSERT.';
COMMENT ON COLUMN app.process_tokens.element_id IS
    'Element id inside the frozen process_versions.definition. Immutable after INSERT.';
COMMENT ON COLUMN app.process_tokens.element_type IS
    'Element type inside the frozen definition (e.g. startEvent, userTask). Immutable after INSERT.';
COMMENT ON COLUMN app.process_tokens.via_flow_id IS
    'Sequence flow the token arrived by. NULL at the start event. Immutable after INSERT.';
COMMENT ON COLUMN app.process_tokens.state IS
    'Token state machine: ready, waiting, completed, cancelled, incident. completed and cancelled are terminal.';
COMMENT ON COLUMN app.process_tokens.result IS
    'Payload that completed a waiting token. NULL or a JSON object.';
COMMENT ON COLUMN app.process_tokens.incident_code IS
    'Last failure code when state is incident. Required while in incident; kept after retry as history.';
COMMENT ON COLUMN app.process_tokens.incident_detail IS
    'Internal failure detail. Kept after retry as history; never returned to API clients.';
COMMENT ON COLUMN app.process_tokens.arrived_at IS
    'Time the token arrived at the element. Immutable after INSERT.';
COMMENT ON COLUMN app.process_tokens.left_at IS
    'Time the token left the element. Set exactly when state becomes completed or cancelled.';
COMMENT ON COLUMN app.process_tokens.updated_at IS
    'Last-update timestamp. Maintained by app.tgr_set_updated_at().';

-- New tokens only on a running instance, and only starting in ready.
CREATE OR REPLACE FUNCTION app.tgr_process_tokens_guard_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status app.process_instance_status;
BEGIN
    SELECT status INTO v_status FROM app.process_instances WHERE id = NEW.instance_id;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'process token: instance % not found', NEW.instance_id USING ERRCODE = '23503';
    END IF;
    IF v_status <> 'running'::app.process_instance_status THEN
        RAISE EXCEPTION 'process token: instance % is %, no new tokens allowed', NEW.instance_id, v_status USING ERRCODE = '23514';
    END IF;
    IF NEW.state <> 'ready'::app.process_token_state THEN
        RAISE EXCEPTION 'process token: a new token must start in ready, got %', NEW.state USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_process_tokens_guard_insert() IS
    'BEFORE INSERT on app.process_tokens. Instance must exist and be running; a new token must start in ready.';

DROP TRIGGER IF EXISTS tgr_process_tokens_guard_insert ON app.process_tokens;
CREATE TRIGGER tgr_process_tokens_guard_insert
BEFORE INSERT ON app.process_tokens
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_tokens_guard_insert();

-- Token identity is immutable; terminal tokens are frozen; state transitions
-- follow the ready/waiting/incident state machine.
CREATE OR REPLACE FUNCTION app.tgr_process_tokens_guard_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.instance_id IS DISTINCT FROM OLD.instance_id
       OR NEW.element_id IS DISTINCT FROM OLD.element_id
       OR NEW.element_type IS DISTINCT FROM OLD.element_type
       OR NEW.via_flow_id IS DISTINCT FROM OLD.via_flow_id
       OR NEW.arrived_at IS DISTINCT FROM OLD.arrived_at
    THEN
        RAISE EXCEPTION 'process token %: identity columns are immutable', OLD.id USING ERRCODE = '23514';
    END IF;

    IF OLD.state IN ('completed'::app.process_token_state, 'cancelled'::app.process_token_state) THEN
        RAISE EXCEPTION 'process token %: token is % and therefore frozen', OLD.id, OLD.state USING ERRCODE = '23514';
    END IF;

    IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
           (OLD.state = 'ready'::app.process_token_state
                AND NEW.state IN ('waiting'::app.process_token_state, 'completed'::app.process_token_state, 'cancelled'::app.process_token_state, 'incident'::app.process_token_state))
        OR (OLD.state = 'waiting'::app.process_token_state
                AND NEW.state IN ('completed'::app.process_token_state, 'cancelled'::app.process_token_state, 'incident'::app.process_token_state))
        OR (OLD.state = 'incident'::app.process_token_state
                AND NEW.state IN ('ready'::app.process_token_state, 'cancelled'::app.process_token_state))
    ) THEN
        RAISE EXCEPTION 'process token %: transition % -> % is not allowed', OLD.id, OLD.state, NEW.state USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_process_tokens_guard_update() IS
    'BEFORE UPDATE on app.process_tokens. Freezes identity columns and terminal tokens; enforces the ready/waiting/incident state-machine transitions.';

DROP TRIGGER IF EXISTS tgr_process_tokens_guard_update ON app.process_tokens;
CREATE TRIGGER tgr_process_tokens_guard_update
BEFORE UPDATE ON app.process_tokens
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_tokens_guard_update();

-- Wake the process executor when a token becomes ready. The payload is a
-- wake-up signal only; the executor claims work with FOR UPDATE SKIP LOCKED
-- and never trusts the payload (same idea as notify_event_outbox).
CREATE OR REPLACE FUNCTION app.tgr_process_tokens_notify()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.state = 'ready'::app.process_token_state THEN
        PERFORM pg_notify('process_tokens_channel', NEW.instance_id::text);
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_process_tokens_notify() IS
    'AFTER INSERT OR UPDATE OF state on app.process_tokens. pg_notify process_tokens_channel with the instance id when state is ready. Wake-up signal only; the executor claims work with FOR UPDATE SKIP LOCKED and never trusts the payload.';

DROP TRIGGER IF EXISTS tgr_process_tokens_notify ON app.process_tokens;
CREATE TRIGGER tgr_process_tokens_notify
AFTER INSERT OR UPDATE OF state ON app.process_tokens
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_tokens_notify();

-- Re-issue: COMMENT literal now covers process_versions as well (dump parity).
COMMENT ON FUNCTION app.tgr_frozen_version_immutable() IS
    'Enforces version immutability on app.work_item_form_versions and app.process_versions: once a version leaves draft only status/change_note/audit columns may change, and it can never return to draft.';

-- ============================================
-- Processes
-- ============================================

-- process_id is required and unique case-insensitively (server-generated proc-{5hex}).
CREATE UNIQUE INDEX IF NOT EXISTS uq_processes_process_id_lower
    ON app.processes (lower(process_id));

-- At most one draft per process: the editor always resumes "the" draft.
CREATE UNIQUE INDEX IF NOT EXISTS uq_process_versions_single_draft
    ON app.process_versions (process_id)
    WHERE status = 'draft';

-- Version history panel (newest first) and "latest active version" lookups.
CREATE INDEX IF NOT EXISTS idx_process_versions_process_number
    ON app.process_versions USING btree (process_id, version_number DESC);

-- Instance list for one process (newest first).
CREATE INDEX IF NOT EXISTS idx_process_instances_process
    ON app.process_instances USING btree (process_id, started_at DESC);

-- Reverse lookup: instances stamped on a given version.
CREATE INDEX IF NOT EXISTS idx_process_instances_version
    ON app.process_instances USING btree (version_id);

-- Token history for one instance (arrival order).
CREATE INDEX IF NOT EXISTS idx_process_tokens_instance
    ON app.process_tokens USING btree (instance_id, arrived_at);

-- Executor ready queue: claim the oldest ready token.
CREATE INDEX IF NOT EXISTS idx_process_tokens_ready
    ON app.process_tokens USING btree (arrived_at)
    WHERE state = 'ready';

-- At most one active token per instance (linear processes in this release).
CREATE UNIQUE INDEX IF NOT EXISTS uq_process_tokens_one_active
    ON app.process_tokens (instance_id)
    WHERE state IN ('ready', 'waiting', 'incident');

-- ===========================================================================
-- 7. Organization staff membership rules
-- ===========================================================================
-- Same functions, triggers and unique index as db/init/05_tables.sql
-- (golden-master dump compares function bodies). Idempotent. No human
-- membership backfill — only a bot sync pass for existing bot profiles.

CREATE UNIQUE INDEX IF NOT EXISTS uq_organization_staff_user
ON app.organization_staff (user_id);

COMMENT ON INDEX app.uq_organization_staff_user IS 'Enforces at most one organization_staff row per user.';

COMMENT ON TABLE app.organization_staff IS 'Junction table linking users to organizations as staff members. At most one row per user; is_staff on a standard profile mirrors membership in the system organization; bot rows are derived from accountable_user_id.';

-- Rewrites organization_staff for every descendant bot of root_user_id to match
-- root's membership (or removes them when root has none). Walks accountable_user_id
-- with depth limit 16 and a path array so a cycle stops.
CREATE OR REPLACE FUNCTION app.sync_bot_org_membership(root_user_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_org_id uuid;
  v_added_by uuid;
  v_actor_raw text;
  bot_ids uuid[];
BEGIN
  PERFORM set_config('app.org_staff_bot_sync', '1', true);

  WITH RECURSIVE descendants AS (
    SELECT bp.user_id,
           ARRAY[root_user_id, bp.user_id] AS path,
           1 AS depth
    FROM app.users_bot_profiles bp
    WHERE bp.accountable_user_id = root_user_id
    UNION ALL
    SELECT bp.user_id,
           d.path || bp.user_id,
           d.depth + 1
    FROM app.users_bot_profiles bp
    JOIN descendants d ON bp.accountable_user_id = d.user_id
    WHERE d.depth < 16
      AND NOT (bp.user_id = ANY (d.path))
  )
  SELECT COALESCE(array_agg(DISTINCT user_id), ARRAY[]::uuid[])
  INTO bot_ids
  FROM descendants;

  DELETE FROM app.organization_staff
  WHERE user_id = ANY (bot_ids);

  SELECT os.org_id, os.added_by
  INTO v_org_id, v_added_by
  FROM app.organization_staff os
  WHERE os.user_id = root_user_id;

  IF v_org_id IS NOT NULL THEN
    v_actor_raw := current_setting('app.org_staff_actor', true);
    IF v_actor_raw IS NOT NULL AND btrim(v_actor_raw) <> '' THEN
      BEGIN
        v_added_by := v_actor_raw::uuid;
      EXCEPTION
        WHEN invalid_text_representation THEN
          NULL; -- keep accountable user's added_by
      END;
    END IF;

    INSERT INTO app.organization_staff (org_id, user_id, added_by)
    SELECT v_org_id, b.bot_id, COALESCE(v_added_by, root_user_id)
    FROM unnest(bot_ids) AS b(bot_id)
    ON CONFLICT (user_id) DO NOTHING;
  END IF;

  PERFORM set_config('app.org_staff_bot_sync', '', true);
END;
$$;

COMMENT ON FUNCTION app.sync_bot_org_membership(uuid) IS
  'Sets app.org_staff_bot_sync, deletes organization_staff for every descendant bot of root_user_id (accountable_user_id walk, depth 16, cycle-safe), then if root has a membership inserts the same org_id for each of those bots. Clears the bot-sync flag immediately after.';

-- BEFORE INSERT/UPDATE/DELETE: reject direct bot edits unless bot-sync; lock
-- system accounts and the staff hierarchy root to the system organization.
CREATE OR REPLACE FUNCTION app.tgr_organization_staff_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  uid uuid;
  oid uuid;
  acct app.account_type;
  staff boolean;
  mgr uuid;
  org_is_system boolean;
  is_protected boolean;
BEGIN
  IF COALESCE(current_setting('app.org_staff_bot_sync', true), '') = '1' THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    uid := OLD.user_id;
    oid := OLD.org_id;
  ELSE
    uid := NEW.user_id;
    oid := NEW.org_id;
  END IF;

  SELECT u.account_type INTO acct
  FROM app.users u
  WHERE u.user_id = uid;

  IF acct = 'bot'::app.account_type THEN
    RAISE EXCEPTION 'bot organization membership is derived'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT sp.is_staff, sp.manager_user_id INTO staff, mgr
  FROM app.users_standard_profiles sp
  WHERE sp.user_id = uid;

  is_protected := (acct = 'system'::app.account_type)
    OR (acct = 'standard'::app.account_type AND staff IS TRUE AND mgr IS NULL);

  IF is_protected THEN
    SELECT o.is_system INTO org_is_system
    FROM app.organizations o
    WHERE o.org_id = oid;

    IF TG_OP = 'DELETE' THEN
      IF COALESCE(org_is_system, false) THEN
        RAISE EXCEPTION 'account may only belong to the system organization'
          USING ERRCODE = 'check_violation';
      END IF;
    ELSE
      IF NOT COALESCE(org_is_system, false) THEN
        RAISE EXCEPTION 'account may only belong to the system organization'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_organization_staff_guard() IS
  'BEFORE INSERT OR UPDATE OR DELETE on app.organization_staff. Ignores writes under app.org_staff_bot_sync. Rejects direct bot membership edits. System accounts and the standard staff hierarchy root may belong only to the system organization (non-system row delete allowed for legacy cleanup).';

DROP TRIGGER IF EXISTS tgr_organization_staff_guard ON app.organization_staff;
CREATE TRIGGER tgr_organization_staff_guard
  BEFORE INSERT OR UPDATE OR DELETE ON app.organization_staff
  FOR EACH ROW
  EXECUTE FUNCTION app.tgr_organization_staff_guard();

-- AFTER membership change: mirror is_staff for standard and system profiles, then sync bots.
CREATE OR REPLACE FUNCTION app.tgr_organization_staff_after()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  uid uuid;
  acct app.account_type;
  want_staff boolean;
  cur_staff boolean;
BEGIN
  IF COALESCE(current_setting('app.org_staff_bot_sync', true), '') = '1' THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    uid := OLD.user_id;
  ELSE
    uid := NEW.user_id;
  END IF;

  SELECT u.account_type INTO acct
  FROM app.users u
  WHERE u.user_id = uid;

  -- When the profile trigger is driving the membership write (mirror flag),
  -- is_staff already has the intended value — do not overwrite it (e.g. a
  -- non-system DELETE while promoting is_staff must not clear the flag).
  IF acct IN ('standard'::app.account_type, 'system'::app.account_type)
     AND COALESCE(current_setting('app.org_staff_mirror', true), '') <> '1' THEN
    IF TG_OP = 'DELETE' THEN
      want_staff := false;
    ELSE
      want_staff := EXISTS (
        SELECT 1
        FROM app.organizations o
        WHERE o.org_id = NEW.org_id
          AND o.is_system
      );
    END IF;

    SELECT sp.is_staff INTO cur_staff
    FROM app.users_standard_profiles sp
    WHERE sp.user_id = uid;

    IF cur_staff IS DISTINCT FROM want_staff THEN
      PERFORM set_config('app.org_staff_mirror', '1', true);
      UPDATE app.users_standard_profiles
      SET is_staff = want_staff
      WHERE user_id = uid;
      PERFORM set_config('app.org_staff_mirror', '', true);
    END IF;
  END IF;

  PERFORM app.sync_bot_org_membership(uid);

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_organization_staff_after() IS
  'AFTER INSERT OR UPDATE OR DELETE on app.organization_staff. Ignores bot-sync writes. For standard and system profiles, mirrors is_staff to system-organization membership unless app.org_staff_mirror is already set (skips UPDATE when already equal; wraps the UPDATE in app.org_staff_mirror). Then calls app.sync_bot_org_membership.';

DROP TRIGGER IF EXISTS tgr_organization_staff_after ON app.organization_staff;
CREATE TRIGGER tgr_organization_staff_after
  AFTER INSERT OR UPDATE OR DELETE ON app.organization_staff
  FOR EACH ROW
  EXECUTE FUNCTION app.tgr_organization_staff_after();

-- AFTER is_staff change: mirror system-organization membership (and the reverse).
CREATE OR REPLACE FUNCTION app.tgr_users_standard_profiles_staff_mirror()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  acct app.account_type;
  sys_org uuid;
  actor uuid;
  actor_raw text;
BEGIN
  IF COALESCE(current_setting('app.org_staff_mirror', true), '') = '1' THEN
    RETURN NEW;
  END IF;

  SELECT u.account_type INTO acct
  FROM app.users u
  WHERE u.user_id = NEW.user_id;

  -- Reject clearing is_staff on a protected account (system with staff, or
  -- standard hierarchy root). INSERT of is_staff=false (e.g. Deleted User) is allowed.
  IF NOT NEW.is_staff AND TG_OP = 'UPDATE' AND OLD.is_staff THEN
    IF acct = 'system'::app.account_type
       OR (acct = 'standard'::app.account_type AND OLD.manager_user_id IS NULL) THEN
      RAISE EXCEPTION 'account may only belong to the system organization'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  actor := NEW.user_id;
  actor_raw := current_setting('app.org_staff_actor', true);
  IF actor_raw IS NOT NULL AND btrim(actor_raw) <> '' THEN
    BEGIN
      actor := actor_raw::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        actor := NEW.user_id;
    END;
  END IF;

  IF NEW.is_staff THEN
    SELECT o.org_id INTO sys_org
    FROM app.organizations o
    WHERE o.is_system
    LIMIT 1;

    PERFORM set_config('app.org_staff_mirror', '1', true);

    DELETE FROM app.organization_staff os
    USING app.organizations o
    WHERE os.user_id = NEW.user_id
      AND os.org_id = o.org_id
      AND NOT o.is_system;

    IF sys_org IS NOT NULL THEN
      INSERT INTO app.organization_staff (org_id, user_id, added_by)
      VALUES (sys_org, NEW.user_id, actor)
      ON CONFLICT (user_id) DO NOTHING;
    END IF;

    PERFORM set_config('app.org_staff_mirror', '', true);
  ELSE
    PERFORM set_config('app.org_staff_mirror', '1', true);

    DELETE FROM app.organization_staff os
    USING app.organizations o
    WHERE os.user_id = NEW.user_id
      AND os.org_id = o.org_id
      AND o.is_system;

    PERFORM set_config('app.org_staff_mirror', '', true);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_users_standard_profiles_staff_mirror() IS
  'AFTER INSERT OR UPDATE OF is_staff on app.users_standard_profiles. Ignores app.org_staff_mirror. Rejects clearing is_staff on protected accounts. When is_staff becomes true: under the mirror flag, deletes non-system membership and inserts the system-org row if missing (skips insert when no system organization exists yet). When is_staff becomes false (and not protected): deletes the system-org membership.';

DROP TRIGGER IF EXISTS tgr_users_standard_profiles_staff_mirror ON app.users_standard_profiles;
CREATE TRIGGER tgr_users_standard_profiles_staff_mirror
  AFTER INSERT OR UPDATE OF is_staff ON app.users_standard_profiles
  FOR EACH ROW
  EXECUTE FUNCTION app.tgr_users_standard_profiles_staff_mirror();

-- Bot accountable_user_id change: rewrite that bot tree from the new accountable.
CREATE OR REPLACE FUNCTION app.tgr_users_bot_profiles_org_sync()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM app.sync_bot_org_membership(NEW.accountable_user_id);
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_users_bot_profiles_org_sync() IS
  'AFTER INSERT OR UPDATE OF accountable_user_id on app.users_bot_profiles. Calls app.sync_bot_org_membership for the (new) accountable user so bot organization_staff rows stay derived.';

DROP TRIGGER IF EXISTS tgr_users_bot_profiles_org_sync ON app.users_bot_profiles;
CREATE TRIGGER tgr_users_bot_profiles_org_sync
  AFTER INSERT OR UPDATE OF accountable_user_id ON app.users_bot_profiles
  FOR EACH ROW
  EXECUTE FUNCTION app.tgr_users_bot_profiles_org_sync();

-- One-shot: sync bot organization_staff from each distinct accountable user.
-- Does not rewrite human membership rows. sync_bot_org_membership sets
-- app.org_staff_bot_sync around its own writes.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT accountable_user_id
    FROM app.users_bot_profiles
  LOOP
    PERFORM app.sync_bot_org_membership(r.accountable_user_id);
  END LOOP;
END $$;

-- ===========================================================================
-- 8. Email log retention — pg_cron schedule (dump-identical to
--    db/init/12_pg_cron_setup.sql). Enqueues email.log-cleanup daily at 03:23
--    server local time; evi-worker deletes rows older than 90 days.
-- ===========================================================================

DO $$
BEGIN
    PERFORM cron.unschedule('email-log-cleanup');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'email-log-cleanup',
    '23 3 * * *',
    $$INSERT INTO app.worker_jobs (job_type, payload) VALUES ('email.log-cleanup', '{}'::jsonb)$$
);

-- ===========================================================================
-- 8b. API key id comment — plaintext prefix bkey_ (dump-identical to
--     db/init/05_tables.sql). Upgrades from 0.23.11 and earlier still have
--     the evik_ literal; COMMENT ON is idempotent.
-- ===========================================================================

COMMENT ON COLUMN app.api_keys.id IS 'Public key id, embedded in the plaintext key as bkey_<id>_<secret>; used for the indexed lookup before constant-time hash comparison.';

-- ===========================================================================
-- 9. Version stamp
-- ===========================================================================

SELECT app.set_migration_output_summary(
    'm_0.23.12',
    'Activity data model: activity_manual_tasks, activity_approvals, activity_acceptances (own status/outcome/pause_reason enums each); app.users reattribution trigger for completed activities; Work.Fs.Quotas seed for activity attachments; renamed app.work_item_service_requests back to app.service_requests; process engine core: processes, process_versions, process_instances, process_tokens; organization staff rules (one row per user, is_staff mirrors system org, bot membership follows accountable_user_id); pg_cron email-log-cleanup (daily 03:23 → email.log-cleanup)'
);

UPDATE app.instance SET schema_version = '0.23.12', last_updated_at = NOW() WHERE id = 1;

COMMIT;

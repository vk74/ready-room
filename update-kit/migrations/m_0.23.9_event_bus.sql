-- Version: 0.23.9
-- Description: Add app.event_outbox — Transactional Outbox staging for the
--   event-bus relay (enum, table, triggers, pending-created index).
-- Backend file: m_0.23.9_event_bus.sql
--
-- Changes in v0.23.9:
-- - Added app.event_outbox_status ENUM (pending / processing / failed).
--   No 'sent'/'done' value: a successfully relayed row is deleted.
-- - Added app.event_outbox with update_event_outbox_updated_at /
--   trg_event_outbox_updated_at and notify_event_outbox /
--   trg_event_outbox_notify (pg_notify event_outbox_channel).
-- - Added partial index idx_event_outbox_pending_created on
--   app.event_outbox (created_at) WHERE status = 'pending'.
-- - Renamed the pg_cron job from 'evi-update-check' to 'update-check'; leftover
--   wipe of the old name stays so existing installs stay idempotent.
--
-- Idempotency: CREATE TYPE swallows duplicate_object. CREATE TABLE /
--   CREATE INDEX use IF NOT EXISTS. CREATE OR REPLACE keeps function
--   bodies current. DROP TRIGGER IF EXISTS + CREATE TRIGGER re-applies
--   trigger definitions. COMMENT ON is re-issued with the same literals
--   as db/init (dump-visible parity).

BEGIN;

-- ===========================================================================
-- 1. Enum
-- ===========================================================================

DO $$ BEGIN
    CREATE TYPE app.event_outbox_status AS ENUM ('pending', 'processing', 'failed');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- ===========================================================================
-- 2. Table, trigger functions, triggers, comments
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.event_outbox (
    id             UUID                     PRIMARY KEY DEFAULT gen_random_uuid(),
    domain         VARCHAR(50)              NOT NULL,
    event_name     VARCHAR(150)             NOT NULL,
    event_version  INT                      NOT NULL DEFAULT 1,
    occurred_at    TIMESTAMPTZ              NOT NULL DEFAULT NOW(),
    trace_id       VARCHAR(32)              NOT NULL,
    span_id        VARCHAR(16)              NOT NULL,
    parent_span_id VARCHAR(16),
    correlation_id VARCHAR(64),
    causation_id   UUID,
    producer       VARCHAR(100)             NOT NULL,
    actor_user_id  VARCHAR(100)             NOT NULL DEFAULT 'system',
    payload        JSONB                    NOT NULL DEFAULT '{}',
    status         app.event_outbox_status  NOT NULL DEFAULT 'pending',
    created_at     TIMESTAMPTZ              NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ              NOT NULL DEFAULT NOW(),
    attempts       INT                      NOT NULL DEFAULT 0,
    max_attempts   INT                      NOT NULL DEFAULT 3,
    claimed_at     TIMESTAMPTZ,
    error_msg      TEXT
);

CREATE OR REPLACE FUNCTION app.update_event_outbox_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_event_outbox_updated_at ON app.event_outbox;
CREATE TRIGGER trg_event_outbox_updated_at
    BEFORE UPDATE ON app.event_outbox
    FOR EACH ROW EXECUTE FUNCTION app.update_event_outbox_updated_at();

CREATE OR REPLACE FUNCTION app.notify_event_outbox()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('event_outbox_channel', NEW.id::text);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_event_outbox_notify ON app.event_outbox;
CREATE TRIGGER trg_event_outbox_notify
    AFTER INSERT ON app.event_outbox
    FOR EACH ROW EXECUTE FUNCTION app.notify_event_outbox();

COMMENT ON TABLE app.event_outbox IS 'Transactional Outbox staging for the event-bus relay. Insert within a business transaction for atomic publish. Successfully relayed rows are deleted; failed rows are kept for inspection.';
COMMENT ON COLUMN app.event_outbox.id IS 'Envelope EventID. The row primary key is the event identity on the wire.';
COMMENT ON COLUMN app.event_outbox.domain IS 'Routes the relay to Valkey stream event:{domain}.';
COMMENT ON COLUMN app.event_outbox.trace_id IS 'W3C trace context trace id (32 hex). Created once per business operation.';
COMMENT ON COLUMN app.event_outbox.span_id IS 'W3C trace context span id (16 hex) for this event.';
COMMENT ON COLUMN app.event_outbox.causation_id IS 'Originating event id when this event was caused by another; NULL for the first event in a chain.';
COMMENT ON COLUMN app.event_outbox.claimed_at IS 'Timestamp when the evi-be relay claimed the row. Used by stuck-row recovery: if claimed_at is older than 5 min and status is still processing, the row is reset to pending (or failed if attempts exhausted).';
COMMENT ON COLUMN app.event_outbox.error_msg IS 'Last error message recorded on failure. Set by the evi-be relay.';

-- ===========================================================================
-- 3. Index
-- ===========================================================================

CREATE INDEX IF NOT EXISTS idx_event_outbox_pending_created
    ON app.event_outbox (created_at) WHERE status = 'pending';

-- ===========================================================================
-- 4. pg_cron: rename evi-update-check → update-check
--    Dump-identical to db/init/12_pg_cron_setup.sql (unschedule old name,
--    unschedule new name, schedule new name). job_type stays system.update-check.
-- ===========================================================================

-- update-check: enqueue the update-check job 3× daily at 00:07 / 08:07 / 16:07
-- (PostgreSQL server local time).
DO $$
BEGIN
    PERFORM cron.unschedule('evi-update-check');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
    PERFORM cron.unschedule('update-check');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'update-check',
    '7 0,8,16 * * *',
    $$INSERT INTO app.worker_jobs (job_type, payload) VALUES ('system.update-check', '{}'::jsonb)$$
);

-- ===========================================================================
-- 5. Version stamp
-- ===========================================================================

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.23.9',
        'Added app.event_outbox_status enum, app.event_outbox table with updated_at and LISTEN/NOTIFY triggers, idx_event_outbox_pending_created, and renamed the pg_cron job evi-update-check to update-check.'
    );
END $$;

UPDATE app.instance SET schema_version = '0.23.9', last_updated_at = NOW() WHERE id = 1;

COMMIT;

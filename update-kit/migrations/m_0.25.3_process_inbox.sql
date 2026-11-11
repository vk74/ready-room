-- Version: 0.25.3
-- Description: Creates app.process_inbox, app.tgr_process_inbox_notify(),
--   trigger tgr_process_inbox_notify, and index idx_process_inbox_created_at
--   for externalActivity worker completions. Same objects as
--   db/init/05_tables.sql and db/init/06_indexes.sql.
-- Backend file: m_0.25.3_process_inbox.sql
--
-- Changes in v0.25.3:
-- - Create app.process_inbox, function app.tgr_process_inbox_notify, trigger
--   tgr_process_inbox_notify, and index idx_process_inbox_created_at.
-- - schema_version set to 0.25.3.

BEGIN;

CREATE TABLE IF NOT EXISTS app.process_inbox (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_id     UUID NOT NULL REFERENCES app.process_tokens(id) ON DELETE CASCADE,
    outcome      VARCHAR(32) NOT NULL,
    output       JSONB,
    error_code   VARCHAR(100),
    error_detail TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_process_inbox_token_id
        UNIQUE (token_id),
    CONSTRAINT chk_process_inbox_outcome
        CHECK (outcome IN ('completed', 'failed')),
    CONSTRAINT chk_process_inbox_output_object
        CHECK (output IS NULL OR jsonb_typeof(output) = 'object'),
    CONSTRAINT chk_process_inbox_error_code
        CHECK (outcome <> 'failed' OR (error_code IS NOT NULL AND btrim(error_code) <> ''))
);

COMMENT ON TABLE app.process_inbox IS
    'Completion inbox for externalActivity jobs finished by worker. Worker inserts one row per waiting token; the process-engine executor in be drains the row under the instance lock and deletes it in the same transaction.';
COMMENT ON COLUMN app.process_inbox.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT.';
COMMENT ON COLUMN app.process_inbox.token_id IS
    'Waiting process token (app.process_tokens.id) that enqueued the externalActivity job. ON DELETE CASCADE. Unique so worker retries are idempotent.';
COMMENT ON COLUMN app.process_inbox.outcome IS
    'Result of the externalActivity execution: completed or failed.';
COMMENT ON COLUMN app.process_inbox.output IS
    'JSON object of output fields recorded under context.activities.<elementId> when outcome is completed. NULL when failed.';
COMMENT ON COLUMN app.process_inbox.error_code IS
    'Machine-readable incident code when outcome is failed. NULL when completed.';
COMMENT ON COLUMN app.process_inbox.error_detail IS
    'Internal failure detail when outcome is failed. NULL when completed.';
COMMENT ON COLUMN app.process_inbox.created_at IS
    'Row creation timestamp.';

CREATE OR REPLACE FUNCTION app.tgr_process_inbox_notify()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_notify('process_tokens_channel', NEW.token_id::text);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_process_inbox_notify() IS
    'AFTER INSERT on app.process_inbox. pg_notify process_tokens_channel with the token id so the process-engine executor wakes and drains the inbox.';

DROP TRIGGER IF EXISTS tgr_process_inbox_notify ON app.process_inbox;
CREATE TRIGGER tgr_process_inbox_notify
AFTER INSERT ON app.process_inbox
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_inbox_notify();

-- Executor inbox queue: drain externalActivity completions in arrival order.
CREATE INDEX IF NOT EXISTS idx_process_inbox_created_at
    ON app.process_inbox USING btree (created_at, id);

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.25.3',
        'Created app.process_inbox, tgr_process_inbox_notify, and idx_process_inbox_created_at for externalActivity worker completions'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.25.3', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

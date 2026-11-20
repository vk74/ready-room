-- Version: 0.28.7
-- Description: Add instance registration passport and pulse state columns to app.instance, protect deployed_at and accepted registration fields in app.tgr_instance_protect_instance_id, and schedule monthly instance-pulse in pg_cron.
-- Backend file: m_0.28.7_instance_registration.sql
--
-- Changes in v0.28.7:
-- - Add instance registration passport and pulse columns to app.instance, with chk_instance_registration_data and the region and registration_status checks.
-- - Replace app.tgr_instance_protect_instance_id so deployed_at cannot change and registration_accepted, organization_name, and region cannot be cleared once registration is accepted.
-- - Schedule monthly instance-pulse (15 4 1 * *) to enqueue system.instance-pulse when registration_accepted is true.

BEGIN;

ALTER TABLE app.instance
    ADD COLUMN IF NOT EXISTS ed25519_public_key TEXT,
    ADD COLUMN IF NOT EXISTS ed25519_private_key TEXT,
    ADD COLUMN IF NOT EXISTS organization_name VARCHAR(255),
    ADD COLUMN IF NOT EXISTS region VARCHAR(10)
        CHECK (region IS NULL OR region IN ('KZ', 'RU', 'ROW')),
    ADD COLUMN IF NOT EXISTS registration_accepted BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS telemetry_accepted BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS consented_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS registration_status VARCHAR(20) NOT NULL DEFAULT 'unregistered'
        CHECK (registration_status IN ('unregistered', 'pending', 'registered', 'conflict')),
    ADD COLUMN IF NOT EXISTS registered_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS last_registration_sent_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS last_registration_outcome VARCHAR(20),
    ADD COLUMN IF NOT EXISTS last_registration_error TEXT,
    ADD COLUMN IF NOT EXISTS registration_retry_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS next_registration_retry_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS last_registered_version VARCHAR(20),
    ADD COLUMN IF NOT EXISTS last_pulse_payload JSONB;

-- Unnamed column CHECKs in db/init/02_schema.sql are stored as
-- instance_region_check and instance_registration_status_check.
-- ADD COLUMN IF NOT EXISTS skips the CHECK when the column already exists,
-- so add the same names when they are missing.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'instance_region_check'
          AND conrelid = 'app.instance'::regclass
    ) THEN
        ALTER TABLE app.instance
            ADD CONSTRAINT instance_region_check
            CHECK (region IS NULL OR region IN ('KZ', 'RU', 'ROW'));
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'instance_registration_status_check'
          AND conrelid = 'app.instance'::regclass
    ) THEN
        ALTER TABLE app.instance
            ADD CONSTRAINT instance_registration_status_check
            CHECK (registration_status IN ('unregistered', 'pending', 'registered', 'conflict'));
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_instance_registration_data'
          AND conrelid = 'app.instance'::regclass
    ) THEN
        ALTER TABLE app.instance
            ADD CONSTRAINT chk_instance_registration_data CHECK (
                NOT registration_accepted OR (
                    btrim(COALESCE(organization_name, '')) <> ''
                    AND region IN ('KZ', 'RU', 'ROW')
                    AND consented_at IS NOT NULL
                )
            );
    END IF;
END $$;

-- Forbid changing instance_id or deployed_at after initial insert, and forbid
-- clearing registration_accepted, organization_name, or region once accepted.
CREATE OR REPLACE FUNCTION app.tgr_instance_protect_instance_id()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.instance_id IS DISTINCT FROM NEW.instance_id THEN
    RAISE EXCEPTION 'instance_id must not be changed after installation';
  END IF;
  IF OLD.deployed_at IS DISTINCT FROM NEW.deployed_at THEN
    RAISE EXCEPTION 'deployed_at must not be changed after installation';
  END IF;
  IF OLD.registration_accepted = true THEN
    IF NEW.registration_accepted IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'registration_accepted must not be reverted once accepted';
    END IF;
    IF btrim(COALESCE(NEW.organization_name, '')) = '' THEN
      RAISE EXCEPTION 'organization_name must not be cleared once registration is accepted';
    END IF;
    IF NEW.region IS NULL OR NEW.region NOT IN ('KZ', 'RU', 'ROW') THEN
      RAISE EXCEPTION 'region must not be cleared once registration is accepted';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- =========================================================================
-- Instance registration pulse — monthly confirmation to pulse.evi.team.
-- Enqueues system.instance-pulse on the 1st of each month at 04:15 when the
-- instance has completed initial registration onboarding.
-- =========================================================================

DO $$
BEGIN
    PERFORM cron.unschedule('instance-pulse');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'instance-pulse',
    '15 4 1 * *',
    $$INSERT INTO app.worker_jobs (job_type, payload) SELECT 'system.instance-pulse', '{}'::jsonb FROM app.instance WHERE id = 1 AND registration_accepted = true$$
);

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.28.7',
        'Added instance registration passport and pulse columns to app.instance and scheduled monthly instance-pulse job.'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.28.7', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

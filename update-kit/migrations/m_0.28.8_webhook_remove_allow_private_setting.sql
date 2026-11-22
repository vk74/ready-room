-- Version: 0.28.8
-- Description: Remove Application.Notifications.Webhook allow.private.network setting from app.app_settings. Unschedule instance-pulse in pg_cron, delete queued system.instance-pulse jobs, and reset app.instance registration and pulse columns to the unregistered state.
-- Backend file: m_0.28.8_webhook_remove_allow_private_setting.sql
--
-- Changes in v0.28.8:
-- - Delete Application.Notifications.Webhook allow.private.network from app.app_settings; private network targets are allowed by default while loopback remains blocked.
-- - work.sr.my_group_unassigned and work.activity.my_group_unassigned now default to enabled.
-- - Unschedule instance-pulse in pg_cron, delete queued system.instance-pulse jobs, and reset app.instance registration and pulse columns to the unregistered state.

BEGIN;

DELETE FROM app.app_settings
WHERE section_path = 'Application.Notifications.Webhook'
  AND setting_name = 'allow.private.network'
  AND environment = 'all';

DO $$
BEGIN
    PERFORM cron.unschedule('instance-pulse');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

DELETE FROM app.worker_jobs
WHERE job_type = 'system.instance-pulse';

-- tgr_instance_protect_instance_id rejects clearing registration_accepted,
-- organization_name, and region once registration is accepted.
ALTER TABLE app.instance DISABLE TRIGGER tgr_instance_protect_instance_id;

UPDATE app.instance
SET ed25519_public_key = NULL,
    ed25519_private_key = NULL,
    organization_name = NULL,
    region = NULL,
    registration_accepted = false,
    telemetry_accepted = false,
    consented_at = NULL,
    registration_status = 'unregistered',
    registered_at = NULL,
    last_registration_sent_at = NULL,
    last_registration_outcome = NULL,
    last_registration_error = NULL,
    registration_retry_count = 0,
    next_registration_retry_at = NULL,
    last_registered_version = NULL,
    last_pulse_payload = NULL
WHERE id = 1;

ALTER TABLE app.instance ENABLE TRIGGER tgr_instance_protect_instance_id;

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.28.8',
        'Removed Application.Notifications.Webhook allow.private.network setting; private network webhook targets are allowed by default while loopback remains blocked. work.sr.my_group_unassigned and work.activity.my_group_unassigned now default to enabled. Unscheduled instance-pulse in pg_cron, deleted queued system.instance-pulse jobs, and reset app.instance registration and pulse columns to the unregistered state.'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.28.8', last_updated_at = NOW()
WHERE id = 1;

UPDATE app.notification_templates
SET default_enabled = true
WHERE template_key IN ('work.sr.my_group_unassigned', 'work.activity.my_group_unassigned');

COMMIT;

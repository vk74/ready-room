-- Version: 0.28.2
-- Description: Notification channels, subscription categories, in-app inbox, object mutes, outbound webhook delivery log, Application.Notifications.Webhook settings, and cleanup cron schedules.
-- Backend file: m_0.28.2_notification_channels.sql
--
-- Changes in v0.28.2:
-- - app.comm_conversation_kind, app.comm_channel_visibility, app.comm_member_role, app.comm_message_kind, app.comm_call_status, and app.comm_call_participant_state.
-- - app.comm_conversations, app.comm_conversation_members, app.comm_messages, app.comm_message_reactions, app.comm_calls, and app.comm_call_participants, with comments and updated_at triggers. Call recording and transcript file ids reference app.fs.
-- - Indexes idx_comm_conversations_entity, idx_comm_conversations_last_message, idx_comm_conversation_members_user, idx_comm_messages_conversation_created, idx_comm_messages_thread_root, idx_comm_messages_pinned, idx_comm_message_reactions_user, idx_comm_calls_conversation_started, and idx_comm_call_participants_user.
-- - Communications domain comm, object comm.message at schema version 1, and event types comm.message.posted, comm.message.updated, and comm.message.deleted.
-- - Communications.Fs.Quotas settings. Conflict refreshes product-owned columns and does not write value.
-- - app.notifications.template_key and app.notification_templates (catalog, updated_at trigger, system-row delete guard) with the 11 system template rows.
-- - work.service_request event object, schema version 1, and created, updated, and cancelled event types.
-- - app.notification_channel_type (in_app, email, webhook).
-- - app.user_notification_channels with comments and tgr_user_notification_channels_set_updated_at.
-- - app.webhook_log with its table comment.
-- - Indexes idx_user_notification_channels_user, idx_webhook_log_created_at, and idx_email_log_created_at.
-- - Application.Notifications.Webhook settings enabled, timeout.seconds, and allow.private.network. Conflict refreshes product-owned columns and does not write value.
-- - webhook-log-cleanup cron schedule (28 3 * * *) enqueues webhook.log-cleanup.
-- - app.notifications inbox table and column comments.
-- - app.notification_category (assigned_to_me, my_requests, mentions_and_replies, watched_items, team_queue).
-- - app.notifications category, event_count, and updated_at, including ADD COLUMN for an earlier draft of this migration, chk_notifications_event_count_positive, and tgr_notifications_set_updated_at.
-- - app.user_notification_mutes with its unique target and table comment.
-- - Indexes idx_notifications_user_created, idx_notifications_user_unread, idx_notifications_user_subject_unread, idx_notifications_read_at, idx_notifications_created_at, and idx_user_notification_mutes_user.
-- - notifications-cleanup cron schedule (33 * * * *) enqueues notifications.cleanup hourly.
-- - app.notification_dispatch_receipts and app.kb_subscriptions, their comments, and indexes idx_notification_dispatch_receipts_created_at, idx_kb_subscriptions_scope, and idx_kb_subscriptions_tree_user.
-- - schema_version set to 0.28.2.

BEGIN;

-- ===========================================================================
-- Notifications
-- ===========================================================================

DO $$ BEGIN
    CREATE TYPE app.notification_channel_type AS ENUM ('in_app', 'email', 'webhook');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.notification_channel_type IS
    'Notification delivery channel type for a principal: in_app (internal inbox), email (SMTP), or webhook (outbound HTTP POST for bot principals).';

DO $$ BEGIN
    CREATE TYPE app.notification_category AS ENUM (
        'assigned_to_me',
        'my_requests',
        'mentions_and_replies',
        'watched_items',
        'team_queue'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.notification_category IS
    'Subscription category of an in-app or external notification: assigned_to_me, my_requests, mentions_and_replies, watched_items, or team_queue.';

-- ===========================================================================
-- Notifications channels and outbound webhook delivery log
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.user_notification_channels (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    channel_type    app.notification_channel_type NOT NULL,
    enabled         BOOLEAN NOT NULL DEFAULT false,
    config          JSONB NOT NULL DEFAULT '{}'::jsonb,
    secret_value    VARCHAR(512),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_user_notification_channels_user_channel
        UNIQUE (user_id, channel_type),
    CONSTRAINT chk_user_notification_channels_config_object
        CHECK (jsonb_typeof(config) = 'object' AND octet_length(config::text) <= 4096),
    CONSTRAINT chk_user_notification_channels_secret_scope
        CHECK (channel_type = 'webhook'::app.notification_channel_type OR secret_value IS NULL)
);

COMMENT ON TABLE app.user_notification_channels IS
    'Per-principal notification channel preferences and transport configuration (standard and bot accounts).';
COMMENT ON COLUMN app.user_notification_channels.config IS
    'Non-confidential channel configuration JSON object (for webhook: preset, url), bounded to 4096 bytes.';
COMMENT ON COLUMN app.user_notification_channels.secret_value IS
    'Confidential channel secret (for webhook: HMAC-SHA256 signing secret, max 512 chars). NULL for non-webhook channels. Never returned in API read responses.';

DROP TRIGGER IF EXISTS tgr_user_notification_channels_set_updated_at ON app.user_notification_channels;
CREATE TRIGGER tgr_user_notification_channels_set_updated_at
BEFORE UPDATE ON app.user_notification_channels
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE TABLE IF NOT EXISTS app.webhook_log (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key    VARCHAR(240) NOT NULL,
    bot_user_id        UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    target_url         VARCHAR(2048) NOT NULL,
    status             VARCHAR(32) NOT NULL,
    http_status_code   INTEGER,
    error_msg          VARCHAR(1000),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_webhook_log_idempotency
        UNIQUE (idempotency_key),
    CONSTRAINT chk_webhook_log_status
        CHECK (status IN ('sent', 'failed')),
    CONSTRAINT chk_webhook_log_http_status_code
        CHECK (http_status_code IS NULL OR (http_status_code >= 100 AND http_status_code <= 599))
);

COMMENT ON TABLE app.webhook_log IS
    'Outbound bot webhook delivery fact and idempotency guard. Used by bot webhook transport and send-test diagnostics.';

CREATE TABLE IF NOT EXISTS app.notifications (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    actor_user_id   UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    category        app.notification_category NOT NULL DEFAULT 'assigned_to_me'::app.notification_category,
    template_key    VARCHAR(100),
    module          VARCHAR(64) NOT NULL,
    event_type      VARCHAR(128) NOT NULL,
    subject_type    VARCHAR(64) NOT NULL,
    subject_id      UUID NOT NULL,
    subject_number  VARCHAR(64),
    title           VARCHAR(500) NOT NULL DEFAULT '',
    meta            JSONB NOT NULL DEFAULT '{}'::jsonb,
    event_count     INTEGER NOT NULL DEFAULT 1,
    read_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_notifications_module_nonempty
        CHECK (btrim(module) <> ''),
    CONSTRAINT chk_notifications_event_type_nonempty
        CHECK (btrim(event_type) <> ''),
    CONSTRAINT chk_notifications_subject_type_nonempty
        CHECK (btrim(subject_type) <> ''),
    CONSTRAINT chk_notifications_event_count_positive
        CHECK (event_count >= 1),
    CONSTRAINT chk_notifications_meta_object
        CHECK (jsonb_typeof(meta) = 'object' AND octet_length(meta::text) <= 4096)
);

-- An earlier draft of this migration may already have created app.notifications
-- without category, event_count, or updated_at. ADD COLUMN is a no-op when
-- CREATE TABLE above created the current definition.
ALTER TABLE app.notifications
    ADD COLUMN IF NOT EXISTS category app.notification_category NOT NULL DEFAULT 'assigned_to_me'::app.notification_category;

ALTER TABLE app.notifications
    ADD COLUMN IF NOT EXISTS event_count INTEGER NOT NULL DEFAULT 1;

ALTER TABLE app.notifications
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- An earlier draft of this migration may already have created app.notifications
-- without template_key. ADD COLUMN is a no-op when CREATE TABLE above created it.
ALTER TABLE app.notifications
    ADD COLUMN IF NOT EXISTS template_key VARCHAR(100);

DO $$
BEGIN
    ALTER TABLE app.notifications
        ADD CONSTRAINT chk_notifications_event_count_positive
        CHECK (event_count >= 1);
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON TABLE app.notifications IS
    'In-app notification inbox for standard and bot principals. Stores routing coordinates, category, coalesced event_count, and bounded metadata without unbounded text columns.';
COMMENT ON COLUMN app.notifications.meta IS
    'Bounded JSON object (max 4096 bytes) carrying module-specific routing or display attributes (for example tree_id, status, priority).';
COMMENT ON COLUMN app.notifications.template_key IS
    'Notification template key (app.notification_templates.template_key) that produced this inbox row. NULL until a dispatcher writes it.';

DROP TRIGGER IF EXISTS tgr_notifications_set_updated_at ON app.notifications;
CREATE TRIGGER tgr_notifications_set_updated_at
BEFORE UPDATE ON app.notifications
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE TABLE IF NOT EXISTS app.user_notification_mutes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    subject_type    VARCHAR(64) NOT NULL,
    subject_id      UUID NOT NULL,
    subject_number  VARCHAR(64),
    subject_title   VARCHAR(500) NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_user_notification_mutes_target
        UNIQUE (user_id, subject_type, subject_id),
    CONSTRAINT chk_user_notification_mutes_subject_type
        CHECK (btrim(subject_type) <> '')
);

COMMENT ON TABLE app.user_notification_mutes IS
    'Per-principal muted entities (subject_type + subject_id). Suppresses notifications for noisy items without unbounded text columns.';

CREATE TABLE IF NOT EXISTS app.notification_templates (
    template_key           VARCHAR(100) PRIMARY KEY,
    module                 VARCHAR(64) NOT NULL,
    section                VARCHAR(64) NOT NULL,
    category               app.notification_category NOT NULL,
    default_enabled        BOOLEAN NOT NULL DEFAULT true,
    sort_order             SMALLINT NOT NULL DEFAULT 1,
    name                   JSONB NOT NULL,
    description            JSONB NOT NULL,
    in_app_title_template  JSONB NOT NULL,
    email_subject_template JSONB NOT NULL,
    email_body_template    JSONB NOT NULL,
    available_variables    JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_system              BOOLEAN NOT NULL DEFAULT true,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_notification_templates_key_format
        CHECK (template_key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
    CONSTRAINT chk_notification_templates_module_nonempty
        CHECK (btrim(module) <> ''),
    CONSTRAINT chk_notification_templates_section_nonempty
        CHECK (btrim(section) <> ''),
    CONSTRAINT chk_notification_templates_name_localized
        CHECK (app.is_localized_text(name)),
    CONSTRAINT chk_notification_templates_description_localized
        CHECK (app.is_localized_text(description)),
    CONSTRAINT chk_notification_templates_in_app_localized
        CHECK (app.is_localized_text(in_app_title_template)),
    CONSTRAINT chk_notification_templates_email_subject_localized
        CHECK (app.is_localized_text(email_subject_template)),
    CONSTRAINT chk_notification_templates_email_body_localized
        CHECK (app.is_localized_text(email_body_template)),
    CONSTRAINT chk_notification_templates_variables_array
        CHECK (jsonb_typeof(available_variables) = 'array' AND octet_length(available_variables::text) <= 2048)
);

COMMENT ON TABLE app.notification_templates IS
    'System catalog of notification types and localized templates (in-app title, email subject, email body) grouped by module and section.';

DROP TRIGGER IF EXISTS tgr_notification_templates_set_updated_at ON app.notification_templates;
CREATE TRIGGER tgr_notification_templates_set_updated_at
BEFORE UPDATE ON app.notification_templates
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE OR REPLACE FUNCTION app.prevent_system_notification_template_deletion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_system = true THEN
        RAISE EXCEPTION 'system notification template % cannot be deleted', OLD.template_key
            USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION app.prevent_system_notification_template_deletion() IS
    'BEFORE DELETE row guard for app.notification_templates. Raises object_not_in_prerequisite_state (55000) when is_system is true.';

DROP TRIGGER IF EXISTS tgr_notification_templates_prevent_system_delete ON app.notification_templates;
CREATE TRIGGER tgr_notification_templates_prevent_system_delete
BEFORE DELETE ON app.notification_templates
FOR EACH ROW EXECUTE FUNCTION app.prevent_system_notification_template_deletion();


-- ============================================
-- Notifications and transport logs
-- ============================================

CREATE INDEX IF NOT EXISTS idx_user_notification_channels_user
    ON app.user_notification_channels USING btree (user_id);

CREATE INDEX IF NOT EXISTS idx_webhook_log_created_at
    ON app.webhook_log USING btree (created_at);

CREATE INDEX IF NOT EXISTS idx_email_log_created_at
    ON app.email_log USING btree (created_at);

CREATE INDEX IF NOT EXISTS idx_notifications_user_created
    ON app.notifications USING btree (user_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
    ON app.notifications USING btree (user_id, created_at DESC)
    WHERE read_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_notifications_user_subject_unread
    ON app.notifications USING btree (user_id, subject_type, subject_id)
    WHERE read_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_notifications_read_at
    ON app.notifications USING btree (read_at)
    WHERE read_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notifications_created_at
    ON app.notifications USING btree (created_at);

CREATE INDEX IF NOT EXISTS idx_user_notification_mutes_user
    ON app.user_notification_mutes USING btree (user_id, created_at DESC);

-- value is set only on insert. Conflict refreshes product-owned columns and does not write value.
INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
    ('Application.Notifications.Webhook', 'enabled', 'all', 'true'::jsonb, '{"type":"boolean"}'::jsonb, 'true'::jsonb, 'Enable outbound webhook notifications for bot accounts', false),
    ('Application.Notifications.Webhook', 'timeout.seconds', 'all', '10'::jsonb, '{"type":"integer","minimum":3,"maximum":60}'::jsonb, '10'::jsonb, 'HTTP request timeout in seconds for outbound bot webhooks', false),
    ('Application.Notifications.Webhook', 'allow.private.network', 'all', 'false'::jsonb, '{"type":"boolean"}'::jsonb, 'false'::jsonb, 'Allow outbound bot webhooks to target loopback and private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7) for local agent deployments', false)
ON CONFLICT (section_path, setting_name, environment) DO UPDATE SET
    validation_schema = EXCLUDED.validation_schema,
    default_value = EXCLUDED.default_value,
    description = EXCLUDED.description,
    is_public = EXCLUDED.is_public,
    updated_at = CURRENT_TIMESTAMP;

-- =========================================================================
-- Webhook log retention — periodic cleanup of app.webhook_log.
-- The table is also the send_bot_webhook idempotency guard; retention (90 days
-- in the worker handler) stays far above the retry window (minutes).
-- =========================================================================

-- webhook-log-cleanup: enqueue the cleanup job daily at 03:28 (PostgreSQL
-- server local time). The handler deletes up to 100_000 rows older than
-- 90 days per run; leftovers are picked up on the next tick.
DO $$
BEGIN
    PERFORM cron.unschedule('webhook-log-cleanup');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'webhook-log-cleanup',
    '28 3 * * *',
    $$INSERT INTO app.worker_jobs (job_type, payload) VALUES ('webhook.log-cleanup', '{}'::jsonb)$$
);

-- =========================================================================
-- Notifications inbox retention — periodic cleanup of app.notifications.
-- Read notifications older than 48 hours (by read_at) and unread notifications
-- older than 30 days are deleted in bounded batches by the worker handler.
-- =========================================================================

-- notifications-cleanup: enqueue the cleanup job hourly at minute 33.
-- The handler deletes up to 100_000 expired rows per run.
DO $$
BEGIN
    PERFORM cron.unschedule('notifications-cleanup');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

SELECT cron.schedule(
    'notifications-cleanup',
    '33 * * * *',
    $$INSERT INTO app.worker_jobs (job_type, payload) VALUES ('notifications.cleanup', '{}'::jsonb)$$
);

-- Service request facts owned by the work module.
INSERT INTO app.event_objects (
    object_key, domain, object_name, has_custom, name, description
) VALUES (
    'work.service_request',
    'work',
    'service_request',
    false,
    $nt${"english":"Service request","russian":"Сервисная заявка"}$nt$::jsonb,
    $nt${"english":"A service request raised for a catalog service. Owned by the work module (table app.service_requests).","russian":"Сервисная заявка по услуге из каталога. Владелец — модуль work (таблица app.service_requests)."}$nt$::jsonb
)
ON CONFLICT (object_key) DO UPDATE SET
    domain = EXCLUDED.domain,
    object_name = EXCLUDED.object_name,
    has_custom = EXCLUDED.has_custom,
    name = EXCLUDED.name,
    description = EXCLUDED.description;

INSERT INTO app.event_object_schemas (
    object_key, schema_version, core_schema, example_core, change_note, introduced_in
) VALUES (
    'work.service_request',
    1,
    $work_sr_schema${
  "type": "object",
  "additionalProperties": false,
  "required": [
    "request_number",
    "service_id",
    "form_version_id",
    "status",
    "approval_status",
    "urgency",
    "impact",
    "priority",
    "title",
    "description",
    "requester_user_id",
    "requested_for_user_id",
    "assigned_group_id",
    "assigned_user_id",
    "watch_list",
    "pause_reason",
    "estimated_minutes",
    "actual_minutes"
  ],
  "properties": {
    "request_number": {
      "type": "string",
      "x-label": {
        "english": "Request number",
        "russian": "Номер заявки"
      }
    },
    "service_id": {
      "type": "string",
      "format": "uuid",
      "x-label": {
        "english": "Service ID",
        "russian": "ID услуги"
      }
    },
    "form_version_id": {
      "type": "string",
      "format": "uuid",
      "x-label": {
        "english": "Form version ID",
        "russian": "ID версии формы"
      }
    },
    "status": {
      "type": "string",
      "enum": [
        "new",
        "in_progress",
        "paused",
        "resolved",
        "reopened",
        "closed",
        "cancelled",
        "failed"
      ],
      "x-label": {
        "english": "Status",
        "russian": "Статус"
      }
    },
    "approval_status": {
      "type": "string",
      "enum": [
        "not_required",
        "pending",
        "approved",
        "rejected"
      ],
      "x-label": {
        "english": "Approval status",
        "russian": "Статус согласования"
      }
    },
    "urgency": {
      "type": "string",
      "enum": [
        "low",
        "medium",
        "high",
        "critical"
      ],
      "x-label": {
        "english": "Urgency",
        "russian": "Срочность"
      }
    },
    "impact": {
      "type": [
        "string",
        "null"
      ],
      "enum": [
        "low",
        "medium",
        "high",
        "critical",
        null
      ],
      "x-label": {
        "english": "Impact",
        "russian": "Влияние"
      }
    },
    "priority": {
      "type": [
        "integer",
        "null"
      ],
      "x-label": {
        "english": "Priority",
        "russian": "Приоритет"
      }
    },
    "title": {
      "type": "string",
      "x-label": {
        "english": "Title",
        "russian": "Заголовок"
      }
    },
    "description": {
      "type": [
        "string",
        "null"
      ],
      "x-label": {
        "english": "Description",
        "russian": "Описание"
      }
    },
    "requester_user_id": {
      "type": "string",
      "format": "uuid",
      "x-label": {
        "english": "Requester",
        "russian": "Заявитель"
      }
    },
    "requested_for_user_id": {
      "type": [
        "string",
        "null"
      ],
      "format": "uuid",
      "x-label": {
        "english": "Recipient",
        "russian": "Получатель"
      }
    },
    "assigned_group_id": {
      "type": [
        "string",
        "null"
      ],
      "format": "uuid",
      "x-label": {
        "english": "Assigned group",
        "russian": "Назначенная группа"
      }
    },
    "assigned_user_id": {
      "type": [
        "string",
        "null"
      ],
      "format": "uuid",
      "x-label": {
        "english": "Assigned specialist",
        "russian": "Назначенный специалист"
      }
    },
    "watch_list": {
      "type": "array",
      "items": {
        "type": "string",
        "format": "uuid"
      },
      "x-label": {
        "english": "Watch list",
        "russian": "Список наблюдателей"
      }
    },
    "pause_reason": {
      "type": [
        "string",
        "null"
      ],
      "enum": [
        "awaiting_requester",
        "awaiting_third_party",
        "scheduled",
        "other",
        null
      ],
      "x-label": {
        "english": "Pause reason",
        "russian": "Причина паузы"
      }
    },
    "estimated_minutes": {
      "type": [
        "integer",
        "null"
      ],
      "x-label": {
        "english": "Estimated minutes",
        "russian": "Плановое время (мин)"
      }
    },
    "actual_minutes": {
      "type": [
        "integer",
        "null"
      ],
      "x-label": {
        "english": "Actual minutes",
        "russian": "Фактическое время (мин)"
      }
    }
  }
}$work_sr_schema$::jsonb,
    $work_sr_example${"request_number": "sr-00012k", "service_id": "4f6c2a1e-8b3d-4c9a-9e21-7d5b0c3a1f42", "form_version_id": "9e4a1d36-8c0f-4b53-9e27-4a8d0c3f6b92", "status": "in_progress", "approval_status": "not_required", "urgency": "high", "impact": "medium", "priority": 2, "title": "VPN access for a new hire", "description": "The requester needs VPN access on the first day.", "requester_user_id": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "requested_for_user_id": null, "assigned_group_id": "c3b1e8a4-6d2f-4a91-8e55-0b7c2d4f1a63", "assigned_user_id": "1b9e4c72-5a30-4d8f-9c16-2e7a0b5d3f84", "watch_list": [], "pause_reason": null, "estimated_minutes": 60, "actual_minutes": null}$work_sr_example$::jsonb,
    NULL,
    '0.28.2'
)
ON CONFLICT (object_key, schema_version) DO UPDATE SET
    core_schema = EXCLUDED.core_schema,
    example_core = EXCLUDED.example_core,
    change_note = EXCLUDED.change_note,
    introduced_in = EXCLUDED.introduced_in;

INSERT INTO app.event_types (
    event_type, object_key, action, status, has_changes, is_deletion,
    name, summary, description, introduced_in
) VALUES (
    'work.service_request.created',
    'work.service_request',
    'created',
    'active',
    false,
    false,
    $nt${"english":"Service request created","russian":"Сервисная заявка создана"}$nt$::jsonb,
    $nt${"english":"A service request was created.","russian":"Создана сервисная заявка."}$nt$::jsonb,
    $nt${"english":"Published by the work module in the same transaction that inserts the service request into app.service_requests. object_id is the service request id; object_version is 1.\n\ncore carries the full service request snapshot: request number, service, form version, status, approval status, urgency, impact, priority, title, description, requester, recipient, assignment, watch list, pause reason, and estimated and actual minutes. There is no custom block. There is no changes block: the request is created, not changed.\n\nTypical subscribers: notifications and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая вставляет сервисную заявку в app.service_requests. object_id — id сервисной заявки; object_version равен 1.\n\ncore содержит полный снимок заявки: номер, услугу, версию формы, статус, статус согласования, срочность, влияние, приоритет, заголовок, описание, заявителя, получателя, назначение, список наблюдателей, причину паузы, плановое и фактическое время. Блока custom нет. Блока changes нет: заявка создаётся, а не изменяется.\n\nТипичные подписчики: уведомления и реплики для отчётов."}$nt$::jsonb,
    '0.28.2'
)
ON CONFLICT (event_type) DO UPDATE SET
    object_key = EXCLUDED.object_key,
    action = EXCLUDED.action,
    status = EXCLUDED.status,
    has_changes = EXCLUDED.has_changes,
    is_deletion = EXCLUDED.is_deletion,
    name = EXCLUDED.name,
    summary = EXCLUDED.summary,
    description = EXCLUDED.description,
    introduced_in = EXCLUDED.introduced_in;

INSERT INTO app.event_types (
    event_type, object_key, action, status, has_changes, is_deletion,
    name, summary, description, introduced_in
) VALUES (
    'work.service_request.updated',
    'work.service_request',
    'updated',
    'active',
    true,
    false,
    $nt${"english":"Service request updated","russian":"Сервисная заявка обновлена"}$nt$::jsonb,
    $nt${"english":"A service request was updated.","russian":"Сервисная заявка обновлена."}$nt$::jsonb,
    $nt${"english":"Published by the work module in the same transaction that updates the service request when at least one core attribute changes. object_id is the service request id; object_version is the service request object_version after that update.\n\ncore carries the full service request snapshot after the update. There is no custom block. changes carries the core attributes that differ from the previous state. An update that changes no core attribute is not published.\n\nTypical subscribers: notifications and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая обновляет сервисную заявку, если изменился хотя бы один атрибут core. object_id — id сервисной заявки; object_version — номер состояния заявки после этого обновления.\n\ncore содержит полный снимок заявки после обновления. Блока custom нет. changes содержит атрибуты core, которые отличаются от предыдущего состояния. Обновление без изменений core не публикуется.\n\nТипичные подписчики: уведомления и реплики для отчётов."}$nt$::jsonb,
    '0.28.2'
)
ON CONFLICT (event_type) DO UPDATE SET
    object_key = EXCLUDED.object_key,
    action = EXCLUDED.action,
    status = EXCLUDED.status,
    has_changes = EXCLUDED.has_changes,
    is_deletion = EXCLUDED.is_deletion,
    name = EXCLUDED.name,
    summary = EXCLUDED.summary,
    description = EXCLUDED.description,
    introduced_in = EXCLUDED.introduced_in;

INSERT INTO app.event_types (
    event_type, object_key, action, status, has_changes, is_deletion,
    name, summary, description, introduced_in
) VALUES (
    'work.service_request.cancelled',
    'work.service_request',
    'cancelled',
    'active',
    true,
    false,
    $nt${"english":"Service request cancelled","russian":"Сервисная заявка отменена"}$nt$::jsonb,
    $nt${"english":"A service request was cancelled.","russian":"Сервисная заявка отменена."}$nt$::jsonb,
    $nt${"english":"Published by the work module in the same transaction that cancels the service request. object_id is the service request id; object_version is the service request object_version after cancellation.\n\ncore carries the full service request snapshot after cancellation. There is no custom block. changes carries the core attributes that differ, and always includes status.\n\nTypical subscribers: notifications and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая отменяет сервисную заявку. object_id — id сервисной заявки; object_version — номер состояния заявки после отмены.\n\ncore содержит полный снимок заявки после отмены. Блока custom нет. changes содержит отличающиеся атрибуты core и всегда включает status.\n\nТипичные подписчики: уведомления и реплики для отчётов."}$nt$::jsonb,
    '0.28.2'
)
ON CONFLICT (event_type) DO UPDATE SET
    object_key = EXCLUDED.object_key,
    action = EXCLUDED.action,
    status = EXCLUDED.status,
    has_changes = EXCLUDED.has_changes,
    is_deletion = EXCLUDED.is_deletion,
    name = EXCLUDED.name,
    summary = EXCLUDED.summary,
    description = EXCLUDED.description,
    introduced_in = EXCLUDED.introduced_in;

-- System notification template catalog. Email subjects reuse the in-app title line.
INSERT INTO app.notification_templates (
    template_key,
    module,
    section,
    category,
    default_enabled,
    sort_order,
    name,
    description,
    in_app_title_template,
    email_subject_template,
    email_body_template,
    available_variables,
    is_system
) VALUES
(
    'work.sr.assigned_to_me',
    'work',
    'service_requests',
    'assigned_to_me'::app.notification_category,
    true,
    1,
    $nt${"english":"Service request assigned to me","russian":"На меня назначена сервисная заявка"}$nt$::jsonb,
    $nt${"english":"When you are assigned as the specialist for a new or existing service request.","russian":"Когда вас назначили исполнителем новой или существующей сервисной заявки."}$nt$::jsonb,
    $nt${"english":"request {{subject_number}} assigned to you: {{title}}","russian":"заявка {{subject_number}} назначена вам: {{title}}"}$nt$::jsonb,
    $nt${"english":"request {{subject_number}} assigned to you: {{title}}","russian":"заявка {{subject_number}} назначена вам: {{title}}"}$nt$::jsonb,
    $nt${"english":"You were assigned as the specialist for request {{subject_number}}: {{title}}.","russian":"Вас назначили исполнителем заявки {{subject_number}}: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
),
(
    'work.sr.my_group_unassigned',
    'work',
    'service_requests',
    'team_queue'::app.notification_category,
    false,
    2,
    $nt${"english":"Unassigned service request placed in my group queue","russian":"В очередь моей группы поступила заявка без исполнителя"}$nt$::jsonb,
    $nt${"english":"When a service request is routed to your support group without an assigned specialist.","russian":"Когда заявка направлена в вашу группу поддержки и ждёт назначения специалиста."}$nt$::jsonb,
    $nt${"english":"new request in group queue {{subject_number}}: {{title}}","russian":"новая заявка в очереди группы {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"new request in group queue {{subject_number}}: {{title}}","russian":"новая заявка в очереди группы {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"A service request was routed to your support group without an assigned specialist. Request {{subject_number}}: {{title}}.","russian":"В вашу группу поддержки поступила заявка без назначенного специалиста. Заявка {{subject_number}}: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
),
(
    'work.sr.my_request_status_changed',
    'work',
    'service_requests',
    'my_requests'::app.notification_category,
    true,
    3,
    $nt${"english":"Status changed on my service request (as requester or recipient)","russian":"Изменился статус моей заявки (как заявителя или получателя)"}$nt$::jsonb,
    $nt${"english":"When a request submitted by or for you moves to in progress, paused, resolved, or closed.","russian":"Когда поданная вами или для вас заявка взята в работу, поставлена на паузу, решена или закрыта."}$nt$::jsonb,
    $nt${"english":"your request {{subject_number}} status changed to \"{{status}}\": {{title}}","russian":"статус вашей заявки {{subject_number}} изменён на «{{status}}»: {{title}}"}$nt$::jsonb,
    $nt${"english":"your request {{subject_number}} status changed to \"{{status}}\": {{title}}","russian":"статус вашей заявки {{subject_number}} изменён на «{{status}}»: {{title}}"}$nt$::jsonb,
    $nt${"english":"The status of your request {{subject_number}} changed to \"{{status}}\": {{title}}.","russian":"Статус вашей заявки {{subject_number}} изменён на «{{status}}»: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","status","title"]$nt$::jsonb,
    true
),
(
    'work.sr.watched_updated',
    'work',
    'service_requests',
    'watched_items'::app.notification_category,
    true,
    4,
    $nt${"english":"Update or cancellation on a request I handle or watch","russian":"Обновление или отмена заявки, которую я веду или отслеживаю"}$nt$::jsonb,
    $nt${"english":"When status or priority changes, or the requester cancels a request where you are the assignee or a watcher.","russian":"Когда изменился статус, приоритет или заявитель отменил заявку, где вы исполнитель или наблюдатель."}$nt$::jsonb,
    $nt${"english":"request {{subject_number}} updated ({{status}}): {{title}}","russian":"обновлена заявка {{subject_number}} ({{status}}): {{title}}"}$nt$::jsonb,
    $nt${"english":"request {{subject_number}} updated ({{status}}): {{title}}","russian":"обновлена заявка {{subject_number}} ({{status}}): {{title}}"}$nt$::jsonb,
    $nt${"english":"Request {{subject_number}} was updated ({{status}}): {{title}}.","russian":"Заявка {{subject_number}} обновлена ({{status}}): {{title}}."}$nt$::jsonb,
    $nt$["subject_number","status","title"]$nt$::jsonb,
    true
),
(
    'work.activity.assigned_to_me',
    'work',
    'activities',
    'assigned_to_me'::app.notification_category,
    true,
    5,
    $nt${"english":"Manual task, approval, or acceptance assigned to me","russian":"Мне назначена ручная задача, согласование или приёмка результата"}$nt$::jsonb,
    $nt${"english":"When a task, approval decision, or acceptance confirmation is assigned to you.","russian":"Когда требуется ваше выполнение задачи, решение по согласованию или подтверждение приёмки."}$nt$::jsonb,
    $nt${"english":"activity {{subject_number}} assigned to you: {{title}}","russian":"вам назначено задание {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"activity {{subject_number}} assigned to you: {{title}}","russian":"вам назначено задание {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"Activity {{subject_number}} was assigned to you: {{title}}.","russian":"Вам назначено задание {{subject_number}}: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
),
(
    'work.activity.my_group_unassigned',
    'work',
    'activities',
    'team_queue'::app.notification_category,
    false,
    6,
    $nt${"english":"Unassigned manual task or approval placed in my group queue","russian":"В очередь моей группы поступила задача или согласование без исполнителя"}$nt$::jsonb,
    $nt${"english":"When an activity is assigned to your group without an individual assignee.","russian":"Когда активность назначена на вашу группу без конкретного исполнителя."}$nt$::jsonb,
    $nt${"english":"activity in group queue {{subject_number}}: {{title}}","russian":"задание в очереди группы {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"activity in group queue {{subject_number}}: {{title}}","russian":"задание в очереди группы {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"An activity was assigned to your group without an individual assignee. Activity {{subject_number}}: {{title}}.","russian":"На вашу группу назначена активность без конкретного исполнителя. Задание {{subject_number}}: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
),
(
    'work.activity.child_completed',
    'work',
    'activities',
    'assigned_to_me'::app.notification_category,
    true,
    7,
    $nt${"english":"Task, approval, or acceptance completed on a request I handle","russian":"Завершена задача, согласование или приёмка по заявке, которую я веду"}$nt$::jsonb,
    $nt${"english":"When a performer or approver completes an activity linked to your service request.","russian":"Когда исполнитель или согласующий завершил шаг по вашей сервисной заявке."}$nt$::jsonb,
    $nt${"english":"activity {{subject_number}} completed ({{outcome}}): {{title}}","russian":"завершено задание {{subject_number}} ({{outcome}}): {{title}}"}$nt$::jsonb,
    $nt${"english":"activity {{subject_number}} completed ({{outcome}}): {{title}}","russian":"завершено задание {{subject_number}} ({{outcome}}): {{title}}"}$nt$::jsonb,
    $nt${"english":"Activity {{subject_number}} was completed ({{outcome}}): {{title}}.","russian":"Задание {{subject_number}} завершено ({{outcome}}): {{title}}."}$nt$::jsonb,
    $nt$["subject_number","outcome","title"]$nt$::jsonb,
    true
),
(
    'kb.watched.published_or_updated',
    'kb',
    'knowledge_base',
    'watched_items'::app.notification_category,
    true,
    8,
    $nt${"english":"Article published or updated in my watched knowledge bases, folders, or articles","russian":"Опубликована или обновлена статья в отслеживаемых мной разделах и статьях"}$nt$::jsonb,
    $nt${"english":"When a published article is created or updated inside a tree, folder, or article you watch.","russian":"Когда выходит новая опубликованная статья или обновляется существующая в базе знаний, папке или статье, на которую вы подписаны."}$nt$::jsonb,
    $nt${"english":"article {{subject_number}} updated: {{title}}","russian":"обновлена статья {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"article {{subject_number}} updated: {{title}}","russian":"обновлена статья {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"Article {{subject_number}} was published or updated: {{title}}.","russian":"Статья {{subject_number}} опубликована или обновлена: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
),
(
    'kb.watched.deleted_or_archived',
    'kb',
    'knowledge_base',
    'watched_items'::app.notification_category,
    true,
    9,
    $nt${"english":"Watched article archived or deleted","russian":"Отслеживаемая статья удалена или перенесена в архив"}$nt$::jsonb,
    $nt${"english":"When a published article you watch is archived or removed.","russian":"Когда опубликованная статья, на которую вы подписаны, архивируется или удаляется."}$nt$::jsonb,
    $nt${"english":"article {{subject_number}} archived or deleted: {{title}}","russian":"статья {{subject_number}} перенесена в архив или удалена: {{title}}"}$nt$::jsonb,
    $nt${"english":"article {{subject_number}} archived or deleted: {{title}}","russian":"статья {{subject_number}} перенесена в архив или удалена: {{title}}"}$nt$::jsonb,
    $nt${"english":"Article {{subject_number}} was archived or deleted: {{title}}.","russian":"Статья {{subject_number}} перенесена в архив или удалена: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
),
(
    'comm.chat.mention_or_reply',
    'comm',
    'communications',
    'mentions_and_replies'::app.notification_category,
    true,
    10,
    $nt${"english":"I was mentioned (@) or replied to in a chat","russian":"Меня упомянули (@) или ответили на моё сообщение в чате"}$nt$::jsonb,
    $nt${"english":"When someone mentions you or replies to your message in a discussion.","russian":"Когда коллега или заявитель обратился к вам напрямую в обсуждении."}$nt$::jsonb,
    $nt${"english":"mention in chat {{subject_number}}: {{title}}","russian":"упоминание в чате {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"mention in chat {{subject_number}}: {{title}}","russian":"упоминание в чате {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"You were mentioned or replied to in chat {{subject_number}}: {{title}}.","russian":"Вас упомянули или ответили вам в чате {{subject_number}}: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
),
(
    'comm.chat.request_message',
    'comm',
    'communications',
    'my_requests'::app.notification_category,
    true,
    11,
    $nt${"english":"New message in a chat of a request I submitted or handle","russian":"Новое сообщение в чате заявки, которую я подал или веду"}$nt$::jsonb,
    $nt${"english":"When a new message is posted in the chat of your service request.","russian":"Когда в чате вашей заявки появилось новое сообщение."}$nt$::jsonb,
    $nt${"english":"new message on request {{subject_number}}: {{title}}","russian":"новое сообщение по заявке {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"new message on request {{subject_number}}: {{title}}","russian":"новое сообщение по заявке {{subject_number}}: {{title}}"}$nt$::jsonb,
    $nt${"english":"A new message was posted on request {{subject_number}}: {{title}}.","russian":"Новое сообщение по заявке {{subject_number}}: {{title}}."}$nt$::jsonb,
    $nt$["subject_number","title"]$nt$::jsonb,
    true
)
ON CONFLICT (template_key) DO UPDATE SET
    module = EXCLUDED.module,
    section = EXCLUDED.section,
    category = EXCLUDED.category,
    default_enabled = EXCLUDED.default_enabled,
    sort_order = EXCLUDED.sort_order,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    in_app_title_template = EXCLUDED.in_app_title_template,
    email_subject_template = EXCLUDED.email_subject_template,
    email_body_template = EXCLUDED.email_body_template,
    available_variables = EXCLUDED.available_variables,
    is_system = EXCLUDED.is_system;

CREATE TABLE IF NOT EXISTS app.notification_dispatch_receipts (
    event_id        UUID NOT NULL,
    user_id         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    notification_id UUID REFERENCES app.notifications(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, user_id)
);

COMMENT ON TABLE app.notification_dispatch_receipts IS
    'Idempotency receipts for notifications:dispatcher so a redelivered Valkey stream entry never increments event_count or enqueues external transports twice.';

CREATE TABLE IF NOT EXISTS app.kb_subscriptions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    scope_type      VARCHAR(16) NOT NULL,
    scope_id        UUID NOT NULL,
    tree_id         UUID NOT NULL REFERENCES app.kb_trees(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_kb_subscriptions_user_scope
        UNIQUE (user_id, scope_type, scope_id),
    CONSTRAINT chk_kb_subscriptions_scope_type
        CHECK (scope_type IN ('tree', 'folder', 'article'))
);

COMMENT ON TABLE app.kb_subscriptions IS
    'Per-user watch subscriptions on KB trees, folders, and articles. Cascaded when the owning tree or user is deleted.';

CREATE INDEX IF NOT EXISTS idx_notification_dispatch_receipts_created_at
    ON app.notification_dispatch_receipts USING btree (created_at);

CREATE INDEX IF NOT EXISTS idx_kb_subscriptions_scope
    ON app.kb_subscriptions USING btree (scope_type, scope_id);

CREATE INDEX IF NOT EXISTS idx_kb_subscriptions_tree_user
    ON app.kb_subscriptions USING btree (tree_id, user_id);

-- ===========================================================================
-- Communications (chats and calls)
-- ===========================================================================

DO $$ BEGIN
    CREATE TYPE app.comm_conversation_kind AS ENUM ('entity', 'channel', 'direct');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.comm_conversation_kind IS
    'Discriminator for a communication space: entity (contextual chat attached to a business object via entity_type + entity_id + channel_key), channel (standalone public or private topic channel), or direct (1-on-1 or small-group direct conversation).';

DO $$ BEGIN
    CREATE TYPE app.comm_channel_visibility AS ENUM ('entity_bound', 'public', 'private', 'direct');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.comm_channel_visibility IS
    'Access visibility of a conversation: entity_bound (governed by the parent entity module resolver), public (joinable by any active user), private (members only), or direct (explicit participants only).';

DO $$ BEGIN
    CREATE TYPE app.comm_member_role AS ENUM ('owner', 'admin', 'member');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.comm_member_role IS
    'Participant role inside a conversation: owner, admin, or member.';

DO $$ BEGIN
    CREATE TYPE app.comm_message_kind AS ENUM ('user', 'system', 'call_event');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.comm_message_kind IS
    'Kind of message in a conversation stream: user (authored by a standard, system, or bot account), system (automated lifecycle event), or call_event (timeline card representing a voice/video call session).';

DO $$ BEGIN
    CREATE TYPE app.comm_call_status AS ENUM ('ringing', 'active', 'ended', 'missed', 'cancelled');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.comm_call_status IS
    'Lifecycle status of a voice/video call session inside a conversation: ringing, active, ended, missed, or cancelled.';

DO $$ BEGIN
    CREATE TYPE app.comm_call_participant_state AS ENUM ('invited', 'ringing', 'joined', 'left', 'declined');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

COMMENT ON TYPE app.comm_call_participant_state IS
    'Participation state of an account in a call session: invited, ringing, joined, left, or declined.';

-- ===========================================================================
-- Communications (conversations, messages, reactions, and calls)
-- ===========================================================================
-- recording_file_id and transcript_file_id reference app.fs. There is no app.files table.

CREATE TABLE IF NOT EXISTS app.comm_conversations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            app.comm_conversation_kind NOT NULL,
    visibility      app.comm_channel_visibility NOT NULL DEFAULT 'entity_bound'::app.comm_channel_visibility,
    entity_type     VARCHAR(64),
    entity_id       UUID,
    channel_key     VARCHAR(64),
    slug            VARCHAR(120),
    title           VARCHAR(250) NOT NULL DEFAULT '',
    topic           VARCHAR(1000) NOT NULL DEFAULT '',
    linked_group_id UUID REFERENCES app.groups(group_id) ON DELETE SET NULL,
    direct_pair_key VARCHAR(100),
    created_by      UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    is_archived     BOOLEAN NOT NULL DEFAULT false,
    message_count   INTEGER NOT NULL DEFAULT 0,
    last_message_id UUID,
    last_message_at TIMESTAMPTZ,
    active_call_id  UUID,
    meta            JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_comm_conversations_entity
        UNIQUE (entity_type, entity_id, channel_key),
    CONSTRAINT uq_comm_conversations_slug
        UNIQUE (slug),
    CONSTRAINT uq_comm_conversations_direct_pair
        UNIQUE (direct_pair_key),
    CONSTRAINT chk_comm_conversations_entity_shape
        CHECK (
            (kind = 'entity'::app.comm_conversation_kind
                AND entity_type IS NOT NULL AND btrim(entity_type) <> ''
                AND entity_id IS NOT NULL
                AND channel_key IS NOT NULL AND btrim(channel_key) <> '')
            OR
            (kind <> 'entity'::app.comm_conversation_kind
                AND entity_type IS NULL
                AND entity_id IS NULL
                AND channel_key IS NULL)
        ),
    CONSTRAINT chk_comm_conversations_slug_format
        CHECK (slug IS NULL OR slug ~ '^[a-z0-9][a-z0-9_-]{1,119}$'),
    CONSTRAINT chk_comm_conversations_message_count_nonneg
        CHECK (message_count >= 0),
    CONSTRAINT chk_comm_conversations_meta_object
        CHECK (jsonb_typeof(meta) = 'object' AND octet_length(meta::text) <= 4096)
);

COMMENT ON TABLE app.comm_conversations IS
    'Unified communication spaces covering entity-bound contextual chats (entity_type + entity_id + channel_key), standalone channels, and direct messages.';
COMMENT ON COLUMN app.comm_conversations.channel_key IS
    'Channel slot within an entity (for example requester or internal on a service request). Required when kind is entity; NULL otherwise.';
COMMENT ON COLUMN app.comm_conversations.active_call_id IS
    'Currently active voice/video call session (app.comm_calls.id) in this conversation; NULL when no call is live.';

DROP TRIGGER IF EXISTS tgr_comm_conversations_set_updated_at ON app.comm_conversations;
CREATE TRIGGER tgr_comm_conversations_set_updated_at
BEFORE UPDATE ON app.comm_conversations
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE TABLE IF NOT EXISTS app.comm_conversation_members (
    conversation_id      UUID NOT NULL REFERENCES app.comm_conversations(id) ON DELETE CASCADE,
    user_id              UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    role                 app.comm_member_role NOT NULL DEFAULT 'member'::app.comm_member_role,
    last_read_message_id UUID,
    last_read_at         TIMESTAMPTZ,
    last_mention_read_at TIMESTAMPTZ,
    is_muted             BOOLEAN NOT NULL DEFAULT false,
    joined_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, user_id)
);

COMMENT ON TABLE app.comm_conversation_members IS
    'Conversation membership, per-user read cursors (last_read_message_id, last_read_at), and per-conversation mute state.';

DROP TRIGGER IF EXISTS tgr_comm_conversation_members_set_updated_at ON app.comm_conversation_members;
CREATE TRIGGER tgr_comm_conversation_members_set_updated_at
BEFORE UPDATE ON app.comm_conversation_members
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE TABLE IF NOT EXISTS app.comm_messages (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id      UUID NOT NULL REFERENCES app.comm_conversations(id) ON DELETE CASCADE,
    author_user_id       UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    kind                 app.comm_message_kind NOT NULL DEFAULT 'user'::app.comm_message_kind,
    body                 VARCHAR(8000) NOT NULL DEFAULT '',
    reply_to_message_id  UUID REFERENCES app.comm_messages(id) ON DELETE SET NULL,
    thread_root_id       UUID REFERENCES app.comm_messages(id) ON DELETE CASCADE,
    thread_reply_count   INTEGER NOT NULL DEFAULT 0,
    thread_last_reply_at TIMESTAMPTZ,
    mentioned_user_ids   UUID[] NOT NULL DEFAULT '{}'::uuid[],
    mention_everyone     BOOLEAN NOT NULL DEFAULT false,
    has_attachments      BOOLEAN NOT NULL DEFAULT false,
    pinned_at            TIMESTAMPTZ,
    pinned_by            UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    revision             INTEGER NOT NULL DEFAULT 1,
    edited_at            TIMESTAMPTZ,
    deleted_at           TIMESTAMPTZ,
    deleted_by           UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    meta                 JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_comm_messages_thread_reply_count_nonneg
        CHECK (thread_reply_count >= 0),
    CONSTRAINT chk_comm_messages_revision_positive
        CHECK (revision >= 1),
    CONSTRAINT chk_comm_messages_mentions_cap
        CHECK (cardinality(mentioned_user_ids) <= 50),
    CONSTRAINT chk_comm_messages_meta_object
        CHECK (jsonb_typeof(meta) = 'object' AND octet_length(meta::text) <= 4096)
);

COMMENT ON TABLE app.comm_messages IS
    'Messages in a conversation stream. Supports linear quote-replies (reply_to_message_id), optional channel sub-threads (thread_root_id), @mentions, file attachments via core/fs (entity_type comm_message), pins, edits, and soft deletion.';

DROP TRIGGER IF EXISTS tgr_comm_messages_set_updated_at ON app.comm_messages;
CREATE TRIGGER tgr_comm_messages_set_updated_at
BEFORE UPDATE ON app.comm_messages
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE TABLE IF NOT EXISTS app.comm_message_reactions (
    message_id UUID NOT NULL REFERENCES app.comm_messages(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    emoji      VARCHAR(32) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id, emoji),
    CONSTRAINT chk_comm_message_reactions_emoji_nonempty
        CHECK (btrim(emoji) <> '')
);

COMMENT ON TABLE app.comm_message_reactions IS
    'Per-user emoji reactions on communication messages.';

CREATE TABLE IF NOT EXISTS app.comm_calls (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id        UUID NOT NULL REFERENCES app.comm_conversations(id) ON DELETE CASCADE,
    call_message_id        UUID REFERENCES app.comm_messages(id) ON DELETE SET NULL,
    status                 app.comm_call_status NOT NULL DEFAULT 'ringing'::app.comm_call_status,
    initiated_by           UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    is_video_enabled       BOOLEAN NOT NULL DEFAULT false,
    is_screen_share_active BOOLEAN NOT NULL DEFAULT false,
    external_room_id       VARCHAR(128),
    started_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    answered_at            TIMESTAMPTZ,
    ended_at               TIMESTAMPTZ,
    duration_seconds       INTEGER,
    recording_file_id      UUID REFERENCES app.fs(id) ON DELETE SET NULL,
    transcript_status      VARCHAR(32) NOT NULL DEFAULT 'none',
    transcript_file_id     UUID REFERENCES app.fs(id) ON DELETE SET NULL,
    ai_summary             VARCHAR(4000),
    meta                   JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_comm_calls_duration_nonneg
        CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    CONSTRAINT chk_comm_calls_transcript_status
        CHECK (transcript_status IN ('none', 'processing', 'ready', 'failed')),
    CONSTRAINT chk_comm_calls_meta_object
        CHECK (jsonb_typeof(meta) = 'object' AND octet_length(meta::text) <= 4096)
);

COMMENT ON TABLE app.comm_calls IS
    'Voice, video, and screen-sharing call sessions anchored to a conversation and linked to a call_event timeline message, with hooks for call recording, transcript, and AI summary.';

DROP TRIGGER IF EXISTS tgr_comm_calls_set_updated_at ON app.comm_calls;
CREATE TRIGGER tgr_comm_calls_set_updated_at
BEFORE UPDATE ON app.comm_calls
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

CREATE TABLE IF NOT EXISTS app.comm_call_participants (
    call_id           UUID NOT NULL REFERENCES app.comm_calls(id) ON DELETE CASCADE,
    user_id           UUID NOT NULL REFERENCES app.users(user_id) ON DELETE CASCADE,
    state             app.comm_call_participant_state NOT NULL DEFAULT 'invited'::app.comm_call_participant_state,
    joined_at         TIMESTAMPTZ,
    left_at           TIMESTAMPTZ,
    is_muted          BOOLEAN NOT NULL DEFAULT false,
    is_video_on       BOOLEAN NOT NULL DEFAULT false,
    is_screen_sharing BOOLEAN NOT NULL DEFAULT false,
    is_hand_raised    BOOLEAN NOT NULL DEFAULT false,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (call_id, user_id)
);

COMMENT ON TABLE app.comm_call_participants IS
    'Per-user participation and media state (mute, camera, screen share, raised hand) within a call session.';

DROP TRIGGER IF EXISTS tgr_comm_call_participants_set_updated_at ON app.comm_call_participants;
CREATE TRIGGER tgr_comm_call_participants_set_updated_at
BEFORE UPDATE ON app.comm_call_participants
FOR EACH ROW EXECUTE FUNCTION app.tgr_set_updated_at();

-- ===========================================================================
-- Communications (conversations, messages, reactions, and calls)
-- ===========================================================================

CREATE INDEX IF NOT EXISTS idx_comm_conversations_entity
    ON app.comm_conversations USING btree (entity_type, entity_id)
    WHERE kind = 'entity'::app.comm_conversation_kind;

CREATE INDEX IF NOT EXISTS idx_comm_conversations_last_message
    ON app.comm_conversations USING btree (last_message_at DESC NULLS LAST, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_comm_conversation_members_user
    ON app.comm_conversation_members USING btree (user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_comm_messages_conversation_created
    ON app.comm_messages USING btree (conversation_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_comm_messages_thread_root
    ON app.comm_messages USING btree (thread_root_id, created_at ASC, id ASC)
    WHERE thread_root_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_comm_messages_pinned
    ON app.comm_messages USING btree (conversation_id, pinned_at DESC)
    WHERE pinned_at IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_comm_message_reactions_user
    ON app.comm_message_reactions USING btree (user_id);

CREATE INDEX IF NOT EXISTS idx_comm_calls_conversation_started
    ON app.comm_calls USING btree (conversation_id, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_comm_call_participants_user
    ON app.comm_call_participants USING btree (user_id, updated_at DESC);

-- Communications domain: entity chats, channels, direct messages, and calls.
-- Insert order matches the catalog seed: domain, object, schema, types.
-- Placed after the kb domain events. Process procedure seeds live in db/init/17_process_procedures.sql.

INSERT INTO app.event_domains (domain, module, name, description)
VALUES (
    'comm',
    'communications',
    '{"english":"Communications","russian":"Коммуникации"}'::jsonb,
    '{"english":"Domain events from contextual entity chats, channels, direct messages, and calls.","russian":"Доменные события контекстных чатов объектов, каналов, личных сообщений и звонков."}'::jsonb
)
ON CONFLICT (domain) DO UPDATE SET
    module = EXCLUDED.module,
    name = EXCLUDED.name,
    description = EXCLUDED.description;

INSERT INTO app.event_objects (
    object_key, domain, object_name, has_custom, name, description
) VALUES (
    'comm.message',
    'comm',
    'message',
    false,
    '{"english":"Chat message","russian":"Сообщение чата"}'::jsonb,
    '{"english":"A message in an entity chat, channel, or direct conversation. Owned by the communications module (table app.comm_messages).","russian":"Сообщение в контекстном чате объекта, канале или личном диалоге. Владелец — модуль communications (таблица app.comm_messages)."}'::jsonb
)
ON CONFLICT (object_key) DO UPDATE SET
    domain = EXCLUDED.domain,
    object_name = EXCLUDED.object_name,
    has_custom = EXCLUDED.has_custom,
    name = EXCLUDED.name,
    description = EXCLUDED.description;

INSERT INTO app.event_object_schemas (
    object_key, schema_version, core_schema, example_core, change_note, introduced_in
) VALUES (
    'comm.message',
    1,
    $comm_message_schema${
  "type": "object",
  "additionalProperties": false,
  "required": [
    "conversation_id",
    "conversation_kind",
    "entity_type",
    "entity_id",
    "channel_key",
    "subject_number",
    "subject_title",
    "author_user_id",
    "body_preview",
    "reply_to_message_id",
    "reply_to_author_id",
    "mentioned_user_ids",
    "recipient_user_ids",
    "recipient_group_id",
    "has_attachments",
    "revision"
  ],
  "properties": {
    "conversation_id": {
      "type": "string",
      "format": "uuid",
      "x-label": {
        "english": "Conversation ID",
        "russian": "ID диалога"
      }
    },
    "conversation_kind": {
      "type": "string",
      "enum": [
        "entity",
        "channel",
        "direct"
      ],
      "x-label": {
        "english": "Conversation kind",
        "russian": "Вид диалога"
      }
    },
    "entity_type": {
      "type": [
        "string",
        "null"
      ],
      "x-label": {
        "english": "Entity type",
        "russian": "Тип объекта"
      }
    },
    "entity_id": {
      "type": [
        "string",
        "null"
      ],
      "format": "uuid",
      "x-label": {
        "english": "Entity ID",
        "russian": "ID объекта"
      }
    },
    "channel_key": {
      "type": [
        "string",
        "null"
      ],
      "x-label": {
        "english": "Channel key",
        "russian": "Ключ канала"
      }
    },
    "subject_number": {
      "type": [
        "string",
        "null"
      ],
      "x-label": {
        "english": "Subject number",
        "russian": "Номер предмета"
      }
    },
    "subject_title": {
      "type": [
        "string",
        "null"
      ],
      "x-label": {
        "english": "Subject title",
        "russian": "Название предмета"
      }
    },
    "author_user_id": {
      "type": "string",
      "format": "uuid",
      "x-label": {
        "english": "Author",
        "russian": "Автор"
      }
    },
    "body_preview": {
      "type": "string",
      "x-label": {
        "english": "Body preview",
        "russian": "Превью текста"
      }
    },
    "reply_to_message_id": {
      "type": [
        "string",
        "null"
      ],
      "format": "uuid",
      "x-label": {
        "english": "Reply to message",
        "russian": "Ответ на сообщение"
      }
    },
    "reply_to_author_id": {
      "type": [
        "string",
        "null"
      ],
      "format": "uuid",
      "x-label": {
        "english": "Reply to author",
        "russian": "Автор исходного сообщения"
      }
    },
    "mentioned_user_ids": {
      "type": "array",
      "items": {
        "type": "string",
        "format": "uuid"
      },
      "x-label": {
        "english": "Mentioned users",
        "russian": "Упомянутые пользователи"
      }
    },
    "recipient_user_ids": {
      "type": "array",
      "items": {
        "type": "string",
        "format": "uuid"
      },
      "x-label": {
        "english": "Recipient users",
        "russian": "Получатели"
      }
    },
    "recipient_group_id": {
      "type": [
        "string",
        "null"
      ],
      "format": "uuid",
      "x-label": {
        "english": "Recipient group",
        "russian": "Группа получателей"
      }
    },
    "has_attachments": {
      "type": "boolean",
      "x-label": {
        "english": "Has attachments",
        "russian": "Есть вложения"
      }
    },
    "revision": {
      "type": "integer",
      "x-label": {
        "english": "Revision",
        "russian": "Ревизия"
      }
    }
  }
}$comm_message_schema$::jsonb,
    $comm_message_example${"conversation_id": "a1c0e001-0000-4000-8000-000000000001", "conversation_kind": "entity", "entity_type": "service_request", "entity_id": "4f6c2a1e-8b3d-4c9a-9e21-7d5b0c3a1f42", "channel_key": "requester", "subject_number": "sr-00012k", "subject_title": "VPN access for a new hire", "author_user_id": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "body_preview": "The access form is attached.", "reply_to_message_id": null, "reply_to_author_id": null, "mentioned_user_ids": [], "recipient_user_ids": ["1b9e4c72-5a30-4d8f-9c16-2e7a0b5d3f84"], "recipient_group_id": null, "has_attachments": true, "revision": 1}$comm_message_example$::jsonb,
    NULL,
    '0.28.2'
)
ON CONFLICT (object_key, schema_version) DO UPDATE SET
    core_schema = EXCLUDED.core_schema,
    example_core = EXCLUDED.example_core,
    change_note = EXCLUDED.change_note,
    introduced_in = EXCLUDED.introduced_in;

INSERT INTO app.event_types (
    event_type, object_key, action, status, has_changes, is_deletion,
    name, summary, description, introduced_in
) VALUES (
    'comm.message.posted',
    'comm.message',
    'posted',
    'active',
    false,
    false,
    '{"english":"Chat message posted","russian":"Сообщение чата опубликовано"}'::jsonb,
    '{"english":"A chat message was posted.","russian":"Опубликовано сообщение чата."}'::jsonb,
    $comm_message_posted${"english":"Published by the communications module in the same transaction that inserts the message into app.comm_messages. object_id is the message id; object_version is 1.\n\ncore carries the message snapshot: conversation, conversation kind, optional parent entity, subject number and title, author, body preview, reply target, mentioned accounts, recipient accounts and group, attachment flag, and revision. There is no custom block. There is no changes block: the message is posted, not changed.\n\nTypical subscribers: notifications.","russian":"Публикуется модулем communications в той же транзакции, которая вставляет сообщение в app.comm_messages. object_id — id сообщения; object_version равен 1.\n\ncore содержит снимок сообщения: диалог, вид диалога, необязательный родительский объект, номер и название предмета, автора, превью текста, цель ответа, упомянутые учётные записи, получателей и группу, признак вложений и ревизию. Блока custom нет. Блока changes нет: сообщение публикуется, а не изменяется.\n\nТипичные подписчики: уведомления."}$comm_message_posted$::jsonb,
    '0.28.2'
)
ON CONFLICT (event_type) DO UPDATE SET
    object_key = EXCLUDED.object_key,
    action = EXCLUDED.action,
    status = EXCLUDED.status,
    has_changes = EXCLUDED.has_changes,
    is_deletion = EXCLUDED.is_deletion,
    name = EXCLUDED.name,
    summary = EXCLUDED.summary,
    description = EXCLUDED.description,
    introduced_in = EXCLUDED.introduced_in;

INSERT INTO app.event_types (
    event_type, object_key, action, status, has_changes, is_deletion,
    name, summary, description, introduced_in
) VALUES (
    'comm.message.updated',
    'comm.message',
    'updated',
    'active',
    true,
    false,
    '{"english":"Chat message updated","russian":"Сообщение чата изменено"}'::jsonb,
    '{"english":"A chat message was updated.","russian":"Сообщение чата изменено."}'::jsonb,
    $comm_message_updated${"english":"Published by the communications module in the same transaction that updates the message when at least one core attribute changes. object_id is the message id; object_version is the message revision after that update.\n\ncore carries the message snapshot after the update. There is no custom block. changes carries the core attributes that differ from the previous state. An update that changes no core attribute is not published.\n\nTypical subscribers: notifications.","russian":"Публикуется модулем communications в той же транзакции, которая изменяет сообщение, если изменился хотя бы один атрибут core. object_id — id сообщения; object_version — ревизия сообщения после этого изменения.\n\ncore содержит снимок сообщения после изменения. Блока custom нет. changes содержит атрибуты core, которые отличаются от предыдущего состояния. Изменение без отличий core не публикуется.\n\nТипичные подписчики: уведомления."}$comm_message_updated$::jsonb,
    '0.28.2'
)
ON CONFLICT (event_type) DO UPDATE SET
    object_key = EXCLUDED.object_key,
    action = EXCLUDED.action,
    status = EXCLUDED.status,
    has_changes = EXCLUDED.has_changes,
    is_deletion = EXCLUDED.is_deletion,
    name = EXCLUDED.name,
    summary = EXCLUDED.summary,
    description = EXCLUDED.description,
    introduced_in = EXCLUDED.introduced_in;

INSERT INTO app.event_types (
    event_type, object_key, action, status, has_changes, is_deletion,
    name, summary, description, introduced_in
) VALUES (
    'comm.message.deleted',
    'comm.message',
    'deleted',
    'active',
    false,
    true,
    '{"english":"Chat message deleted","russian":"Сообщение чата удалено"}'::jsonb,
    '{"english":"A chat message was deleted.","russian":"Сообщение чата удалено."}'::jsonb,
    $comm_message_deleted${"english":"Published by the communications module in the same transaction that deletes the message from app.comm_messages. object_id is the deleted message id; object_version is the revision the row held when it was deleted.\n\ncore carries the final snapshot of the message right before deletion. There is no custom block. There is no changes block.\n\nTypical subscribers: notifications.","russian":"Публикуется модулем communications в той же транзакции, которая удаляет сообщение из app.comm_messages. object_id — id удалённого сообщения; object_version — ревизия, которая была у строки в момент удаления.\n\ncore содержит финальный снимок сообщения непосредственно перед удалением. Блока custom нет. Блока changes нет.\n\nТипичные подписчики: уведомления."}$comm_message_deleted$::jsonb,
    '0.28.2'
)
ON CONFLICT (event_type) DO UPDATE SET
    object_key = EXCLUDED.object_key,
    action = EXCLUDED.action,
    status = EXCLUDED.status,
    has_changes = EXCLUDED.has_changes,
    is_deletion = EXCLUDED.is_deletion,
    name = EXCLUDED.name,
    summary = EXCLUDED.summary,
    description = EXCLUDED.description,
    introduced_in = EXCLUDED.introduced_in;

-- ===========================================================================
-- Communications file storage — quotas for chat message attachments (comm_message).
-- QuotaModule on the FS registry is Communications.
-- value is set only on insert. Conflict refreshes product-owned columns and does not write value.
-- ===========================================================================
INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
('Communications.Fs.Quotas', 'entity.max.bytes', 'all',
 '52428800', '{"type":"integer","minimum":0}', '52428800',
 'Sum of all file bytes per single chat message. 0 = unlimited.', false),
('Communications.Fs.Quotas', 'entity.max.count', 'all',
 '10', '{"type":"integer","minimum":1,"maximum":200}', '10',
 'Hard cap of file count per single chat message.', false),
('Communications.Fs.Quotas', 'user.per.day.max.bytes', 'all',
 '1073741824', '{"type":"integer","minimum":0}', '1073741824',
 'Anti-abuse: max bytes uploaded as chat attachments per user per day. 0 = unlimited.', false),
('Communications.Fs.Quotas', 'module.total.storage.max.bytes', 'all',
 '0', '{"type":"integer","minimum":0}', '0',
 'Communications-wide ceiling: sum of all chat stored file bytes. 0 = unlimited.', false)
ON CONFLICT (section_path, setting_name, environment) DO UPDATE SET
    validation_schema = EXCLUDED.validation_schema,
    default_value = EXCLUDED.default_value,
    description = EXCLUDED.description,
    is_public = EXCLUDED.is_public,
    updated_at = CURRENT_TIMESTAMP;

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.28.2',
        'Added app.user_notification_channels, app.notification_category, app.notifications, app.notification_templates, app.user_notification_mutes, app.webhook_log, app.notification_dispatch_receipts, app.kb_subscriptions, Application.Notifications.Webhook settings, work.service_request event types, webhook-log-cleanup, and hourly notifications-cleanup schedules, app.comm_* tables, comm.message.* event types, and Communications.Fs.Quotas settings'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.28.2', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

-- Version: 0.25.2
-- Description: Adds process_token_id, completed_by and object_version on
--   app.activity_manual_tasks, app.activity_approvals and app.activity_acceptances.
--   Adds cancelled to app.activity_approval_outcome and app.activity_acceptance_outcome.
--   Seeds the work domain in the events library (manual task, approval, acceptance).
--   Same events-library rows as db/init/08_system_entities.sql.
--   Adds wake_at on app.process_tokens for a waiting timer token, with
--   chk_process_tokens_wake_at_waiting, a notify when a waiting token sets
--   wake_at, and idx_process_tokens_wake_at. Same objects as db/init/05_tables.sql
--   and db/init/06_indexes.sql.
--   Also updates the Application.System.Fs.Policies mime.allow settings row.
-- Backend file: m_0.25.2_manual_activities_and_events.sql
--
-- Changes in v0.25.2:
-- - Approval and acceptance outcome enums gain cancelled.
-- - The three manual activity tables gain process_token_id, completed_by and
--   object_version (positive check), an immutable process_token_id stamp, and
--   a partial unique index on process_token_id.
-- - tgr_users_reattribute_completed_activities also re-points completed_by on
--   completed rows at the seeded Deleted User.
-- - Events library domain work, schema version 1 for work.manual_task,
--   work.approval and work.acceptance, and the created and completed types.
-- - app.process_tokens gains wake_at TIMESTAMPTZ and
--   chk_process_tokens_wake_at_waiting. tgr_process_tokens_notify also
--   notifies when a waiting token sets wake_at.
-- - Partial index idx_process_tokens_wake_at on waiting tokens with wake_at.
-- - Dropped uq_process_tokens_one_active and updated the app.process_tokens table comment for parallel branches.
-- - schema_version set to 0.25.2.
-- - Create app.process_manual_procedures, function app.prevent_process_manual_procedure_deletion, and trigger tgr_process_manual_procedures_prevent_system_delete, seed the 9 manual activity procedures, and remove the 6 manual activity update/delete rows from app.process_system_procedures.
-- - mime.allow validation_schema and default_value gain the 16 catalog types; value gains those 16 types when absent, and other entries already stored stay as they are.
-- - Drop tgr_users_reattribute_completed_activities before recreating it, so an upgrade from 0.23.12 does not fail because the trigger already exists.

BEGIN;

ALTER TYPE app.activity_approval_outcome ADD VALUE IF NOT EXISTS 'cancelled';
ALTER TYPE app.activity_acceptance_outcome ADD VALUE IF NOT EXISTS 'cancelled';

COMMENT ON TYPE app.activity_approval_outcome IS
    'Terminal outcome for an approval: approved, rejected, cancelled. Own to app.activity_approvals. Stored only; no fill logic and no CHECK tying it to status in this release.';

COMMENT ON TYPE app.activity_acceptance_outcome IS
    'Terminal outcome for an acceptance: accepted, rejected, cancelled. Own to app.activity_acceptances. Stored only; no fill logic and no CHECK tying it to status in this release.';

-- Column order matches a fresh install: process_token_id, completed_by, object_version.
ALTER TABLE app.activity_manual_tasks
    ADD COLUMN IF NOT EXISTS process_token_id UUID,
    ADD COLUMN IF NOT EXISTS completed_by UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS object_version INTEGER NOT NULL DEFAULT 1;

ALTER TABLE app.activity_approvals
    ADD COLUMN IF NOT EXISTS process_token_id UUID,
    ADD COLUMN IF NOT EXISTS completed_by UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS object_version INTEGER NOT NULL DEFAULT 1;

ALTER TABLE app.activity_acceptances
    ADD COLUMN IF NOT EXISTS process_token_id UUID,
    ADD COLUMN IF NOT EXISTS completed_by UUID REFERENCES app.users(user_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS object_version INTEGER NOT NULL DEFAULT 1;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_activity_manual_tasks_object_version_positive'
          AND conrelid = 'app.activity_manual_tasks'::regclass
    ) THEN
        ALTER TABLE app.activity_manual_tasks
            ADD CONSTRAINT chk_activity_manual_tasks_object_version_positive
            CHECK (object_version >= 1);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_activity_approvals_object_version_positive'
          AND conrelid = 'app.activity_approvals'::regclass
    ) THEN
        ALTER TABLE app.activity_approvals
            ADD CONSTRAINT chk_activity_approvals_object_version_positive
            CHECK (object_version >= 1);
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_activity_acceptances_object_version_positive'
          AND conrelid = 'app.activity_acceptances'::regclass
    ) THEN
        ALTER TABLE app.activity_acceptances
            ADD CONSTRAINT chk_activity_acceptances_object_version_positive
            CHECK (object_version >= 1);
    END IF;
END $$;

COMMENT ON COLUMN app.activity_approvals.outcome IS
    'Terminal outcome (app.activity_approval_outcome): approved / rejected / cancelled. Nullable; stored only; no fill logic and no CHECK tying it to status in this release.';

COMMENT ON COLUMN app.activity_acceptances.outcome IS
    'Terminal outcome (app.activity_acceptance_outcome): accepted / rejected / cancelled. Nullable; stored only; no fill logic and no CHECK tying it to status in this release.';

COMMENT ON COLUMN app.activity_manual_tasks.process_token_id IS 'Waiting process token (app.process_tokens.id) that created this manual task; NULL when created outside a process step. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_manual_tasks.completed_by IS 'User account that completed the manual task. Re-pointed at the seeded Deleted User by app.tgr_users_reattribute_completed_activities before the user row is deleted.';
COMMENT ON COLUMN app.activity_manual_tasks.object_version IS 'Monotonic state version of the manual task (1 on INSERT, +1 on each update) carried by domain events.';

COMMENT ON COLUMN app.activity_approvals.process_token_id IS 'Waiting process token (app.process_tokens.id) that created this approval; NULL when created outside a process step. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_approvals.completed_by IS 'User account that completed the approval. Re-pointed at the seeded Deleted User by app.tgr_users_reattribute_completed_activities before the user row is deleted.';
COMMENT ON COLUMN app.activity_approvals.object_version IS 'Monotonic state version of the approval (1 on INSERT, +1 on each update) carried by domain events.';

COMMENT ON COLUMN app.activity_acceptances.process_token_id IS 'Waiting process token (app.process_tokens.id) that created this acceptance; NULL when created outside a process step. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_acceptances.completed_by IS 'User account that completed the acceptance. Re-pointed at the seeded Deleted User by app.tgr_users_reattribute_completed_activities before the user row is deleted.';
COMMENT ON COLUMN app.activity_acceptances.object_version IS 'Monotonic state version of the acceptance (1 on INSERT, +1 on each update) carried by domain events.';

-- The creation stamp is immutable: task_number, parent_kind, parent_id,
-- process_token_id, created_at.
-- Title, description, assignment, status, outcome, pause_reason, completed_by,
-- object_version and completed_at stay open.
CREATE OR REPLACE FUNCTION app.tgr_activity_manual_tasks_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.task_number      IS DISTINCT FROM OLD.task_number
       OR NEW.parent_kind   IS DISTINCT FROM OLD.parent_kind
       OR NEW.parent_id     IS DISTINCT FROM OLD.parent_id
       OR NEW.process_token_id IS DISTINCT FROM OLD.process_token_id
       OR NEW.created_at    IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'manual task %: creation stamp is immutable', OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

-- The creation stamp is immutable: approval_number, parent_kind, parent_id,
-- process_token_id, created_at.
-- Title, description, assignment, status, outcome, pause_reason, notes,
-- completed_by, object_version and completed_at stay open.
CREATE OR REPLACE FUNCTION app.tgr_activity_approvals_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.approval_number IS DISTINCT FROM OLD.approval_number
       OR NEW.parent_kind    IS DISTINCT FROM OLD.parent_kind
       OR NEW.parent_id      IS DISTINCT FROM OLD.parent_id
       OR NEW.process_token_id IS DISTINCT FROM OLD.process_token_id
       OR NEW.created_at     IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'approval %: creation stamp is immutable', OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

-- The creation stamp is immutable: acceptance_number, parent_kind, parent_id,
-- process_token_id, created_at.
-- Title, description, assignment, status, outcome, notes, completed_by,
-- object_version and completed_at stay open.
CREATE OR REPLACE FUNCTION app.tgr_activity_acceptances_stamp_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.acceptance_number IS DISTINCT FROM OLD.acceptance_number
       OR NEW.parent_kind      IS DISTINCT FROM OLD.parent_kind
       OR NEW.parent_id        IS DISTINCT FROM OLD.parent_id
       OR NEW.process_token_id IS DISTINCT FROM OLD.process_token_id
       OR NEW.created_at       IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'acceptance %: creation stamp is immutable', OLD.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

-- Hard-deleting a user must not silently erase who was assigned to, or who
-- completed, a completed activity, but must free up a still-open one for
-- reassignment. A single static ON DELETE SET NULL FK cannot branch on row
-- status, so this BEFORE DELETE trigger runs first: it re-points
-- assigned_user_id and completed_by on every already-complete row at the
-- seeded Deleted User (00000000-0000-0000-0000-00000000dead). Rows still open
-- (new / in_progress / paused) are left pointing at OLD.user_id, so when the
-- DELETE proceeds the assigned_user_id and completed_by ON DELETE SET NULL
-- foreign keys release them to NULL.
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

    UPDATE app.activity_manual_tasks
       SET completed_by = deleted_user
     WHERE completed_by = OLD.user_id
       AND status = 'complete'::app.activity_manual_task_status;

    UPDATE app.activity_approvals
       SET assigned_user_id = deleted_user
     WHERE assigned_user_id = OLD.user_id
       AND status = 'complete'::app.activity_approval_status;

    UPDATE app.activity_approvals
       SET completed_by = deleted_user
     WHERE completed_by = OLD.user_id
       AND status = 'complete'::app.activity_approval_status;

    UPDATE app.activity_acceptances
       SET assigned_user_id = deleted_user
     WHERE assigned_user_id = OLD.user_id
       AND status = 'complete'::app.activity_acceptance_status;

    UPDATE app.activity_acceptances
       SET completed_by = deleted_user
     WHERE completed_by = OLD.user_id
       AND status = 'complete'::app.activity_acceptance_status;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS tgr_users_reattribute_completed_activities ON app.users;
CREATE TRIGGER tgr_users_reattribute_completed_activities
BEFORE DELETE ON app.users
FOR EACH ROW EXECUTE FUNCTION app.tgr_users_reattribute_completed_activities();

COMMENT ON FUNCTION app.tgr_users_reattribute_completed_activities() IS
    'BEFORE DELETE on app.users. Re-points assigned_user_id and completed_by on every already-complete activity (manual task / approval / acceptance) at the seeded Deleted User (00000000-0000-0000-0000-00000000dead) so hard-deleting a user does not silently erase who was assigned to, or who completed, a completed row. Still-open rows (new / in_progress / paused) are left pointing at OLD.user_id; when the DELETE proceeds immediately afterward, the assigned_user_id and completed_by ON DELETE SET NULL foreign keys on the three activity tables release those open rows to NULL.';


-- At most one manual task per waiting process token.
CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_manual_tasks_process_token
    ON app.activity_manual_tasks USING btree (process_token_id)
    WHERE process_token_id IS NOT NULL;

-- At most one approval per waiting process token.
CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_approvals_process_token
    ON app.activity_approvals USING btree (process_token_id)
    WHERE process_token_id IS NOT NULL;

-- At most one acceptance per waiting process token.
CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_acceptances_process_token
    ON app.activity_acceptances USING btree (process_token_id)
    WHERE process_token_id IS NOT NULL;

-- Work domain: manual tasks, approvals and acceptances.
-- Insert order matches the catalog seed: domain, object, schema, types.

INSERT INTO app.event_domains (domain, module, name, description)
VALUES (
    'work',
    'work',
    '{"english":"Work","russian":"Работа"}'::jsonb,
    '{"english":"Service requests and human-in-the-loop activities (manual tasks, approvals, acceptances).","russian":"Сервисные запросы и ручные активности с участием человека (ручные задачи, согласования, приёмки)."}'::jsonb
)
ON CONFLICT (domain) DO UPDATE SET
    module = EXCLUDED.module,
    name = EXCLUDED.name,
    description = EXCLUDED.description;

INSERT INTO app.event_objects (
    object_key, domain, object_name, has_custom, name, description
) VALUES (
    'work.manual_task',
    'work',
    'manual_task',
    false,
    '{"english":"Manual task","russian":"Ручная задача"}'::jsonb,
    '{"english":"A human-in-the-loop manual task under a service request or a process. Owned by the work module (table app.activity_manual_tasks).","russian":"Ручная задача с участием человека в составе сервисного запроса или процесса. Владелец — модуль work (таблица app.activity_manual_tasks)."}'::jsonb
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
    'work.manual_task',
    1,
    $work_mt_schema${
  "type": "object",
  "additionalProperties": false,
  "required": ["task_number", "parent_kind", "parent_id", "process_token_id", "title", "description", "kb_article_id", "assigned_group_id", "assigned_user_id", "status", "outcome", "pause_reason", "completed_by", "completed_at"],
  "properties": {
    "task_number": {"type": "string", "x-label": {"english": "Task number", "russian": "Номер задачи"}, "x-description": {"english": "Human-readable manual task reference (ma-XXXXXX).", "russian": "Читаемый номер ручной задачи (ma-XXXXXX)."}},
    "parent_kind": {"type": "string", "enum": ["service_request", "process"], "x-label": {"english": "Parent kind", "russian": "Тип родителя"}},
    "parent_id": {"type": "string", "format": "uuid", "x-label": {"english": "Parent ID", "russian": "ID родителя"}},
    "process_token_id": {"type": ["string", "null"], "format": "uuid", "x-correlation": true, "x-label": {"english": "Process token ID", "russian": "ID токена процесса"}, "x-description": {"english": "Id of the waiting process token that requested this manual task; null when created outside a process.", "russian": "Идентификатор ждущего токена процесса, запросившего эту ручную задачу; null, если создана вне процесса."}},
    "title": {"type": "string", "x-label": {"english": "Title", "russian": "Заголовок"}},
    "description": {"type": ["string", "null"], "x-label": {"english": "Description", "russian": "Описание"}},
    "kb_article_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "KB article", "russian": "Статья базы знаний"}},
    "assigned_group_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Assigned group", "russian": "Назначенная группа"}},
    "assigned_user_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Assigned user", "russian": "Назначенный исполнитель"}},
    "status": {"type": "string", "enum": ["new", "in_progress", "paused", "complete"], "x-label": {"english": "Status", "russian": "Статус"}},
    "outcome": {"type": ["string", "null"], "enum": ["succeeded", "cancelled", "failed", "skipped", null], "x-label": {"english": "Outcome", "russian": "Результат"}},
    "pause_reason": {"type": ["string", "null"], "enum": ["awaiting_requester", "awaiting_third_party", "awaiting_parts", "scheduled", null], "x-label": {"english": "Pause reason", "russian": "Причина паузы"}},
    "completed_by": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Completed by", "russian": "Кто завершил"}},
    "completed_at": {"type": ["string", "null"], "format": "date-time", "x-label": {"english": "Completed at", "russian": "Время завершения"}}
  }
}$work_mt_schema$::jsonb,
    '{"task_number": "ma-00012k", "parent_kind": "service_request", "parent_id": "4f6c2a1e-8b3d-4c9a-9e21-7d5b0c3a1f42", "process_token_id": "7c2e9b14-6a8d-4f31-9c05-2e6b8a1d4f70", "title": "Confirm VPN access", "description": "Check that the contractor can connect.", "kb_article_id": null, "assigned_group_id": "770e8400-e29b-41d4-a716-446655440001", "assigned_user_id": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "status": "complete", "outcome": "succeeded", "pause_reason": null, "completed_by": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "completed_at": "2026-10-26T09:30:00Z"}'::jsonb,
    NULL,
    '0.25.2'
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
    'work.manual_task.created',
    'work.manual_task',
    'created',
    'active',
    false,
    false,
    '{"english":"Manual task created","russian":"Ручная задача создана"}'::jsonb,
    '{"english":"A manual task was created.","russian":"Создана ручная задача."}'::jsonb,
    $work_mt_created${"english":"Published by the work module in the same transaction that inserts the manual task into app.activity_manual_tasks. object_id is the task id; object_version is 1.\n\ncore carries the full manual-task snapshot: task number, parent, process token, title, description, KB article, assignment, status, outcome, pause reason, completed_by and completed_at. process_token_id correlates this task to the waiting process token and is null when the task was created outside a process. There is no custom block. There is no changes block: the task is created, not changed.\n\nTypical subscribers: the process engine, notifications, and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая вставляет ручную задачу в app.activity_manual_tasks. object_id — id задачи; object_version равен 1.\n\ncore содержит полный снимок ручной задачи: номер, родителя, токен процесса, заголовок, описание, статью базы знаний, назначение, статус, результат, причину паузы, completed_by и completed_at. process_token_id связывает задачу с ждущим токеном процесса и равен null, если задача создана вне процесса. Блока custom нет. Блока changes нет: задача создаётся, а не изменяется.\n\nТипичные подписчики: процессный движок, уведомления и реплики для отчётов."}$work_mt_created$::jsonb,
    '0.25.2'
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
    'work.manual_task.completed',
    'work.manual_task',
    'completed',
    'active',
    true,
    false,
    '{"english":"Manual task completed","russian":"Ручная задача завершена"}'::jsonb,
    '{"english":"A manual task was completed.","russian":"Ручная задача завершена."}'::jsonb,
    $work_mt_completed${"english":"Published by the work module in the same transaction that marks the manual task complete. object_id is the task id; object_version is the task object_version after that update.\n\ncore carries the full manual-task snapshot after completion, including outcome, completed_by and completed_at. process_token_id correlates this task to the waiting process token and is null when the task was created outside a process. There is no custom block. changes carries the attributes that differ from the previous state, including status, outcome, completed_by and completed_at.\n\nTypical subscribers: the process engine (resume the waiting token correlated by process_token_id), notifications, and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая завершает ручную задачу. object_id — id задачи; object_version — номер состояния задачи после этого обновления.\n\ncore содержит полный снимок ручной задачи после завершения, включая результат, completed_by и completed_at. process_token_id связывает задачу с ждущим токеном процесса и равен null, если задача создана вне процесса. Блока custom нет. changes содержит атрибуты, которые отличаются от предыдущего состояния, включая статус, результат, completed_by и completed_at.\n\nТипичные подписчики: процессный движок (возобновление ждущего токена по process_token_id), уведомления и реплики для отчётов."}$work_mt_completed$::jsonb,
    '0.25.2'
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

INSERT INTO app.event_objects (
    object_key, domain, object_name, has_custom, name, description
) VALUES (
    'work.approval',
    'work',
    'approval',
    false,
    '{"english":"Approval","russian":"Согласование"}'::jsonb,
    '{"english":"A human-in-the-loop approval under a service request or a process. Owned by the work module (table app.activity_approvals).","russian":"Согласование с участием человека в составе сервисного запроса или процесса. Владелец — модуль work (таблица app.activity_approvals)."}'::jsonb
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
    'work.approval',
    1,
    $work_ap_schema${
  "type": "object",
  "additionalProperties": false,
  "required": ["approval_number", "parent_kind", "parent_id", "process_token_id", "title", "description", "assigned_group_id", "assigned_user_id", "status", "outcome", "pause_reason", "approval_notes", "rejection_notes", "completed_by", "completed_at"],
  "properties": {
    "approval_number": {"type": "string", "x-label": {"english": "Approval number", "russian": "Номер согласования"}, "x-description": {"english": "Human-readable approval reference (ap-XXXXXX).", "russian": "Читаемый номер согласования (ap-XXXXXX)."}},
    "parent_kind": {"type": "string", "enum": ["service_request", "process"], "x-label": {"english": "Parent kind", "russian": "Тип родителя"}},
    "parent_id": {"type": "string", "format": "uuid", "x-label": {"english": "Parent ID", "russian": "ID родителя"}},
    "process_token_id": {"type": ["string", "null"], "format": "uuid", "x-correlation": true, "x-label": {"english": "Process token ID", "russian": "ID токена процесса"}, "x-description": {"english": "Id of the waiting process token that requested this approval; null when created outside a process.", "russian": "Идентификатор ждущего токена процесса, запросившего это согласование; null, если создано вне процесса."}},
    "title": {"type": "string", "x-label": {"english": "Title", "russian": "Заголовок"}},
    "description": {"type": ["string", "null"], "x-label": {"english": "Description", "russian": "Описание"}},
    "assigned_group_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Assigned group", "russian": "Назначенная группа"}},
    "assigned_user_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Assigned user", "russian": "Назначенный согласующий"}},
    "status": {"type": "string", "enum": ["new", "in_progress", "paused", "complete"], "x-label": {"english": "Status", "russian": "Статус"}},
    "outcome": {"type": ["string", "null"], "enum": ["approved", "rejected", "cancelled", null], "x-label": {"english": "Outcome", "russian": "Решение"}},
    "pause_reason": {"type": ["string", "null"], "enum": ["more_info_required", "awaiting_additional_approver", "awaiting_cab", "deferred", null], "x-label": {"english": "Pause reason", "russian": "Причина паузы"}},
    "approval_notes": {"type": ["string", "null"], "x-label": {"english": "Approval notes", "russian": "Комментарий к согласованию"}},
    "rejection_notes": {"type": ["string", "null"], "x-label": {"english": "Rejection notes", "russian": "Комментарий к отклонению"}},
    "completed_by": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Completed by", "russian": "Кто завершил"}},
    "completed_at": {"type": ["string", "null"], "format": "date-time", "x-label": {"english": "Completed at", "russian": "Время завершения"}}
  }
}$work_ap_schema$::jsonb,
    '{"approval_number": "ap-00012k", "parent_kind": "service_request", "parent_id": "4f6c2a1e-8b3d-4c9a-9e21-7d5b0c3a1f42", "process_token_id": "8d3f0c25-7b9e-4a42-8d16-3f7c9b2e5a81", "title": "Approve contractor VPN access", "description": "Line manager approval before access is granted.", "assigned_group_id": null, "assigned_user_id": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "status": "complete", "outcome": "approved", "pause_reason": null, "approval_notes": "Approved until the end of the year.", "rejection_notes": null, "completed_by": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "completed_at": "2026-10-26T09:30:00Z"}'::jsonb,
    NULL,
    '0.25.2'
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
    'work.approval.created',
    'work.approval',
    'created',
    'active',
    false,
    false,
    '{"english":"Approval created","russian":"Согласование создано"}'::jsonb,
    '{"english":"An approval was created.","russian":"Создано согласование."}'::jsonb,
    $work_ap_created${"english":"Published by the work module in the same transaction that inserts the approval into app.activity_approvals. object_id is the approval id; object_version is 1.\n\ncore carries the full approval snapshot: approval number, parent, process token, title, description, assignment, status, outcome, pause reason, approval notes, rejection notes, completed_by and completed_at. process_token_id correlates this approval to the waiting process token and is null when the approval was created outside a process. There is no custom block. There is no changes block: the approval is created, not changed.\n\nTypical subscribers: the process engine, notifications, and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая вставляет согласование в app.activity_approvals. object_id — id согласования; object_version равен 1.\n\ncore содержит полный снимок согласования: номер, родителя, токен процесса, заголовок, описание, назначение, статус, решение, причину паузы, комментарий к согласованию, комментарий к отклонению, completed_by и completed_at. process_token_id связывает согласование с ждущим токеном процесса и равен null, если согласование создано вне процесса. Блока custom нет. Блока changes нет: согласование создаётся, а не изменяется.\n\nТипичные подписчики: процессный движок, уведомления и реплики для отчётов."}$work_ap_created$::jsonb,
    '0.25.2'
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
    'work.approval.completed',
    'work.approval',
    'completed',
    'active',
    true,
    false,
    '{"english":"Approval completed","russian":"Согласование завершено"}'::jsonb,
    '{"english":"An approval was completed.","russian":"Согласование завершено."}'::jsonb,
    $work_ap_completed${"english":"Published by the work module in the same transaction that marks the approval complete. object_id is the approval id; object_version is the approval object_version after that update.\n\ncore carries the full approval snapshot after completion, including outcome, approval notes, rejection notes, completed_by and completed_at. process_token_id correlates this approval to the waiting process token and is null when the approval was created outside a process. There is no custom block. changes carries the attributes that differ from the previous state, including status, outcome, approval notes, rejection notes, completed_by and completed_at.\n\nTypical subscribers: the process engine (resume the waiting token correlated by process_token_id), notifications, and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая завершает согласование. object_id — id согласования; object_version — номер состояния согласования после этого обновления.\n\ncore содержит полный снимок согласования после завершения, включая решение, комментарий к согласованию, комментарий к отклонению, completed_by и completed_at. process_token_id связывает согласование с ждущим токеном процесса и равен null, если согласование создано вне процесса. Блока custom нет. changes содержит атрибуты, которые отличаются от предыдущего состояния, включая статус, решение, комментарии, completed_by и completed_at.\n\nТипичные подписчики: процессный движок (возобновление ждущего токена по process_token_id), уведомления и реплики для отчётов."}$work_ap_completed$::jsonb,
    '0.25.2'
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

INSERT INTO app.event_objects (
    object_key, domain, object_name, has_custom, name, description
) VALUES (
    'work.acceptance',
    'work',
    'acceptance',
    false,
    '{"english":"Acceptance","russian":"Приёмка"}'::jsonb,
    '{"english":"A human-in-the-loop acceptance under a service request or a process. Owned by the work module (table app.activity_acceptances). Acceptance never pauses.","russian":"Приёмка с участием человека в составе сервисного запроса или процесса. Владелец — модуль work (таблица app.activity_acceptances). У приёмки нет паузы."}'::jsonb
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
    'work.acceptance',
    1,
    $work_ac_schema${
  "type": "object",
  "additionalProperties": false,
  "required": ["acceptance_number", "parent_kind", "parent_id", "process_token_id", "title", "description", "assigned_group_id", "assigned_user_id", "status", "outcome", "acceptance_notes", "rejection_notes", "completed_by", "completed_at"],
  "properties": {
    "acceptance_number": {"type": "string", "x-label": {"english": "Acceptance number", "russian": "Номер приёмки"}, "x-description": {"english": "Human-readable acceptance reference (ac-XXXXXX).", "russian": "Читаемый номер приёмки (ac-XXXXXX)."}},
    "parent_kind": {"type": "string", "enum": ["service_request", "process"], "x-label": {"english": "Parent kind", "russian": "Тип родителя"}},
    "parent_id": {"type": "string", "format": "uuid", "x-label": {"english": "Parent ID", "russian": "ID родителя"}},
    "process_token_id": {"type": ["string", "null"], "format": "uuid", "x-correlation": true, "x-label": {"english": "Process token ID", "russian": "ID токена процесса"}, "x-description": {"english": "Id of the waiting process token that requested this acceptance; null when created outside a process.", "russian": "Идентификатор ждущего токена процесса, запросившего эту приёмку; null, если создана вне процесса."}},
    "title": {"type": "string", "x-label": {"english": "Title", "russian": "Заголовок"}},
    "description": {"type": ["string", "null"], "x-label": {"english": "Description", "russian": "Описание"}},
    "assigned_group_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Assigned group", "russian": "Назначенная группа"}},
    "assigned_user_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Assigned user", "russian": "Назначенный принимающий"}},
    "status": {"type": "string", "enum": ["new", "in_progress", "complete"], "x-label": {"english": "Status", "russian": "Статус"}},
    "outcome": {"type": ["string", "null"], "enum": ["accepted", "rejected", "cancelled", null], "x-label": {"english": "Outcome", "russian": "Результат"}},
    "acceptance_notes": {"type": ["string", "null"], "x-label": {"english": "Acceptance notes", "russian": "Комментарий к приёмке"}},
    "rejection_notes": {"type": ["string", "null"], "x-label": {"english": "Rejection notes", "russian": "Комментарий к отклонению"}},
    "completed_by": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Completed by", "russian": "Кто завершил"}},
    "completed_at": {"type": ["string", "null"], "format": "date-time", "x-label": {"english": "Completed at", "russian": "Время завершения"}}
  }
}$work_ac_schema$::jsonb,
    '{"acceptance_number": "ac-00012k", "parent_kind": "service_request", "parent_id": "4f6c2a1e-8b3d-4c9a-9e21-7d5b0c3a1f42", "process_token_id": "9e4a1d36-8c0f-4b53-9e27-4a8d0c3f6b92", "title": "Accept delivered VPN access", "description": "The requester confirms the access works.", "assigned_group_id": null, "assigned_user_id": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "status": "complete", "outcome": "accepted", "acceptance_notes": "Connected successfully.", "rejection_notes": null, "completed_by": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "completed_at": "2026-10-26T09:45:00Z"}'::jsonb,
    NULL,
    '0.25.2'
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
    'work.acceptance.created',
    'work.acceptance',
    'created',
    'active',
    false,
    false,
    '{"english":"Acceptance created","russian":"Приёмка создана"}'::jsonb,
    '{"english":"An acceptance was created.","russian":"Создана приёмка."}'::jsonb,
    $work_ac_created${"english":"Published by the work module in the same transaction that inserts the acceptance into app.activity_acceptances. object_id is the acceptance id; object_version is 1.\n\ncore carries the full acceptance snapshot: acceptance number, parent, process token, title, description, assignment, status, outcome, acceptance notes, rejection notes, completed_by and completed_at. process_token_id correlates this acceptance to the waiting process token and is null when the acceptance was created outside a process. There is no custom block. There is no changes block: the acceptance is created, not changed.\n\nTypical subscribers: the process engine, notifications, and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая вставляет приёмку в app.activity_acceptances. object_id — id приёмки; object_version равен 1.\n\ncore содержит полный снимок приёмки: номер, родителя, токен процесса, заголовок, описание, назначение, статус, результат, комментарий к приёмке, комментарий к отклонению, completed_by и completed_at. process_token_id связывает приёмку с ждущим токеном процесса и равен null, если приёмка создана вне процесса. Блока custom нет. Блока changes нет: приёмка создаётся, а не изменяется.\n\nТипичные подписчики: процессный движок, уведомления и реплики для отчётов."}$work_ac_created$::jsonb,
    '0.25.2'
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
    'work.acceptance.completed',
    'work.acceptance',
    'completed',
    'active',
    true,
    false,
    '{"english":"Acceptance completed","russian":"Приёмка завершена"}'::jsonb,
    '{"english":"An acceptance was completed.","russian":"Приёмка завершена."}'::jsonb,
    $work_ac_completed${"english":"Published by the work module in the same transaction that marks the acceptance complete. object_id is the acceptance id; object_version is the acceptance object_version after that update.\n\ncore carries the full acceptance snapshot after completion, including outcome, acceptance notes, rejection notes, completed_by and completed_at. process_token_id correlates this acceptance to the waiting process token and is null when the acceptance was created outside a process. There is no custom block. changes carries the attributes that differ from the previous state, including status, outcome, acceptance notes, rejection notes, completed_by and completed_at.\n\nTypical subscribers: the process engine (resume the waiting token correlated by process_token_id), notifications, and reporting replicas.","russian":"Публикуется модулем work в той же транзакции, которая завершает приёмку. object_id — id приёмки; object_version — номер состояния приёмки после этого обновления.\n\ncore содержит полный снимок приёмки после завершения, включая результат, комментарий к приёмке, комментарий к отклонению, completed_by и completed_at. process_token_id связывает приёмку с ждущим токеном процесса и равен null, если приёмка создана вне процесса. Блока custom нет. changes содержит атрибуты, которые отличаются от предыдущего состояния, включая статус, результат, комментарии, completed_by и completed_at.\n\nТипичные подписчики: процессный движок (возобновление ждущего токена по process_token_id), уведомления и реплики для отчётов."}$work_ac_completed$::jsonb,
    '0.25.2'
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


ALTER TABLE app.process_tokens
    ADD COLUMN IF NOT EXISTS wake_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_process_tokens_wake_at_waiting'
          AND conrelid = 'app.process_tokens'::regclass
    ) THEN
        ALTER TABLE app.process_tokens
            ADD CONSTRAINT chk_process_tokens_wake_at_waiting
            CHECK (wake_at IS NULL OR state = 'waiting'::app.process_token_state);
    END IF;
END $$;

COMMENT ON COLUMN app.process_tokens.wake_at IS
    'Scheduled wake-up timestamp for a waiting timer token (intermediateCatchEvent). NULL when not waiting on a timer.';

CREATE OR REPLACE FUNCTION app.tgr_process_tokens_notify()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.state = 'ready'::app.process_token_state
       OR (NEW.state = 'waiting'::app.process_token_state AND NEW.wake_at IS NOT NULL)
    THEN
        PERFORM pg_notify('process_tokens_channel', NEW.instance_id::text);
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_process_tokens_notify() IS
    'AFTER INSERT OR UPDATE OF state, wake_at on app.process_tokens. pg_notify process_tokens_channel with the instance id when state is ready or when a waiting token sets wake_at. Wake-up signal only; the executor claims work with FOR UPDATE SKIP LOCKED and never trusts the payload.';

DROP TRIGGER IF EXISTS tgr_process_tokens_notify ON app.process_tokens;
CREATE TRIGGER tgr_process_tokens_notify
AFTER INSERT OR UPDATE OF state, wake_at ON app.process_tokens
FOR EACH ROW EXECUTE FUNCTION app.tgr_process_tokens_notify();

-- Executor timer queue: wake waiting tokens whose timer has expired.
CREATE INDEX IF NOT EXISTS idx_process_tokens_wake_at
    ON app.process_tokens USING btree (wake_at)
    WHERE state = 'waiting' AND wake_at IS NOT NULL;

DROP INDEX IF EXISTS app.uq_process_tokens_one_active;

COMMENT ON TABLE app.process_tokens IS
    'One arrival of an instance at one element (element instance). Active tokens (ready/waiting/incident) are the position on the graph; closed tokens are the path taken.';

COMMENT ON COLUMN app.process_system_procedures.entity IS
    'Entity key within the module (e.g. service_request, incident, problem, change, service_order).';

-- ===========================================================================
-- Process manual procedures catalog (manualActivity actions)
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.process_manual_procedures (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    procedure_key   VARCHAR(120) NOT NULL,
    module          VARCHAR(50) NOT NULL,
    entity          VARCHAR(50) NOT NULL,
    action          VARCHAR(50) NOT NULL,
    module_name     JSONB NOT NULL,
    entity_name     JSONB NOT NULL,
    name            JSONB NOT NULL,
    description     JSONB NOT NULL,
    input_schema    JSONB NOT NULL DEFAULT '[]'::jsonb,
    output_schema   JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_system       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_process_manual_procedures_key
        UNIQUE (procedure_key),
    CONSTRAINT chk_process_manual_procedures_module_format
        CHECK (module ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_manual_procedures_entity_format
        CHECK (entity ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_manual_procedures_action_format
        CHECK (action ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_manual_procedures_key_match
        CHECK (procedure_key = module || '.' || entity || '.' || action),
    CONSTRAINT chk_process_manual_procedures_module_name_localized
        CHECK (app.is_localized_text(module_name)),
    CONSTRAINT chk_process_manual_procedures_entity_name_localized
        CHECK (app.is_localized_text(entity_name)),
    CONSTRAINT chk_process_manual_procedures_name_localized
        CHECK (app.is_localized_text(name)),
    CONSTRAINT chk_process_manual_procedures_description_localized
        CHECK (app.is_localized_text(description)),
    CONSTRAINT chk_process_manual_procedures_input_schema_array
        CHECK (jsonb_typeof(input_schema) = 'array'),
    CONSTRAINT chk_process_manual_procedures_output_schema_array
        CHECK (jsonb_typeof(output_schema) = 'array')
);

COMMENT ON TABLE app.process_manual_procedures IS
    'Catalog of human-in-the-loop and manual-activity procedures available to manualActivity in the process engine, organized by module, entity, and action. System rows (is_system = true) are protected from deletion by tgr_process_manual_procedures_prevent_system_delete.';
COMMENT ON COLUMN app.process_manual_procedures.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT or seeded deterministically.';
COMMENT ON COLUMN app.process_manual_procedures.procedure_key IS
    'Stable key in <module>.<entity>.<action> format (e.g. work.manual_task.create). Unique.';
COMMENT ON COLUMN app.process_manual_procedures.module IS
    'Owning application module key (e.g. work).';
COMMENT ON COLUMN app.process_manual_procedures.entity IS
    'Manual activity entity key within the module (e.g. manual_task, approval, acceptance).';
COMMENT ON COLUMN app.process_manual_procedures.action IS
    'Operation key on the entity (e.g. create, update, delete).';
COMMENT ON COLUMN app.process_manual_procedures.module_name IS
    'Localized display name of the module. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_manual_procedures.entity_name IS
    'Localized display name of the entity. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_manual_procedures.name IS
    'Localized display name of the procedure action. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_manual_procedures.description IS
    'Localized description of what the procedure does, its inputs, and its outputs. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_manual_procedures.input_schema IS
    'JSON array of input attribute descriptors ({key, type, required, source, enum?, label, description}).';
COMMENT ON COLUMN app.process_manual_procedures.output_schema IS
    'JSON array of output variable descriptors ({key, type, enum?, label, description, example}) written to context.activities.<elementId>.';
COMMENT ON COLUMN app.process_manual_procedures.is_system IS
    'True for platform-seeded procedures that cannot be deleted.';
COMMENT ON COLUMN app.process_manual_procedures.created_at IS
    'Row creation timestamp.';

CREATE OR REPLACE FUNCTION app.prevent_process_manual_procedure_deletion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_system = true THEN
        RAISE EXCEPTION 'manual procedure % cannot be deleted', OLD.procedure_key
            USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION app.prevent_process_manual_procedure_deletion() IS
    'BEFORE DELETE row guard for app.process_manual_procedures. Raises object_not_in_prerequisite_state (55000) when is_system is true.';

DROP TRIGGER IF EXISTS tgr_process_manual_procedures_prevent_system_delete ON app.process_manual_procedures;

CREATE TRIGGER tgr_process_manual_procedures_prevent_system_delete
BEFORE DELETE ON app.process_manual_procedures
FOR EACH ROW EXECUTE FUNCTION app.prevent_process_manual_procedure_deletion();

-- Clear is_system first so tgr_process_system_procedures_prevent_system_delete does not raise 55000.
UPDATE app.process_system_procedures
SET is_system = false
WHERE procedure_key IN (
    'work.manual_task.update',
    'work.manual_task.delete',
    'work.approval.update',
    'work.approval.delete',
    'work.acceptance.update',
    'work.acceptance.delete'
);

DELETE FROM app.process_system_procedures
WHERE procedure_key IN (
    'work.manual_task.update',
    'work.manual_task.delete',
    'work.approval.update',
    'work.approval.delete',
    'work.acceptance.update',
    'work.acceptance.delete'
);

-- Manual procedures catalog (9 rows across work.manual_task, work.approval, and work.acceptance).
-- created_at stays at the first insert: conflict updates do not touch it.
INSERT INTO app.process_manual_procedures (
    id, procedure_key, module, entity, action,
    module_name, entity_name, name, description,
    input_schema, output_schema, is_system
) VALUES
(
    '991e8400-e29b-41d4-a716-446655440001',
    'work.manual_task.create',
    'work',
    'manual_task',
    'create',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Manual task", "russian": "Ручная задача"}'::jsonb,
    '{"english": "Create", "russian": "Создать"}'::jsonb,
    '{"english": "Creates a manual task assigned to a participant, account, or group, with an optional description and KB article, and waits until the assignee completes it. Writes the task id, number, outcome, completed_by, and completed_at.", "russian": "Создаёт ручную задачу, назначенную участнику, учётной записи или группе, с необязательными описанием и статьёй БЗ, и переводит токен в ожидание до её завершения. Записывает id задачи, номер, результат, кто завершил и время завершения."}'::jsonb,
    $pmp_in_01$
[
  {
    "key": "assignee",
    "type": "assignee",
    "required": true,
    "source": "literal_only",
    "label": {
      "english": "Assignee",
      "russian": "Исполнитель"
    },
    "description": {
      "english": "Assigned group, account, or participant.",
      "russian": "Ответственная группа, учётная запись или участник."
    }
  },
  {
    "key": "description",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Description",
      "russian": "Описание"
    },
    "description": {
      "english": "Instructions for the manual task.",
      "russian": "Описание ручной задачи для исполнителя."
    }
  },
  {
    "key": "kb_article",
    "type": "kb_article",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "KB article",
      "russian": "Статья БЗ"
    },
    "description": {
      "english": "Published Knowledge Base article linked to the manual task.",
      "russian": "Опубликованная статья базы знаний, привязанная к задаче."
    }
  }
]
$pmp_in_01$::jsonb,
    $pmp_out_01$
[
  {
    "key": "activity_id",
    "type": "uuid",
    "label": {
      "english": "Activity id",
      "russian": "Идентификатор активности"
    },
    "description": {
      "english": "Id of the completed manual task.",
      "russian": "Идентификатор завершённой ручной задачи."
    },
    "example": "<uuid>"
  },
  {
    "key": "number",
    "type": "string",
    "label": {
      "english": "Number",
      "russian": "Номер"
    },
    "description": {
      "english": "Display number of the manual task (ma-XXXXXX).",
      "russian": "Номер ручной задачи для отображения (ma-XXXXXX)."
    },
    "example": "ma-000105"
  },
  {
    "key": "outcome",
    "type": "enum",
    "enum": [
      "succeeded",
      "cancelled",
      "failed",
      "skipped"
    ],
    "label": {
      "english": "Outcome",
      "russian": "Результат"
    },
    "description": {
      "english": "How the manual task finished.",
      "russian": "Чем завершилась ручная задача."
    },
    "example": "succeeded"
  },
  {
    "key": "completed_by",
    "type": "uuid",
    "label": {
      "english": "Completed by",
      "russian": "Кто завершил"
    },
    "description": {
      "english": "Account that completed the manual task.",
      "russian": "Учётная запись, которая завершила ручную задачу."
    },
    "example": "<uuid>"
  },
  {
    "key": "completed_at",
    "type": "date-time",
    "label": {
      "english": "Completed at",
      "russian": "Время завершения"
    },
    "description": {
      "english": "When the manual task was completed.",
      "russian": "Когда ручная задача была завершена."
    },
    "example": "2026-10-20T12:00:00Z"
  }
]
$pmp_out_01$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440013',
    'work.manual_task.update',
    'work',
    'manual_task',
    'update',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Manual task", "russian": "Ручная задача"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the manual task identified by target_id from the process context. Optional inputs set the assignee, the description, and the lifecycle status. Writes the task id and the status after the update.", "russian": "Обновляет ручную задачу, id которой (target_id) берётся из контекста процесса. Необязательные входы задают исполнителя, описание и статус жизненного цикла. Записывает id задачи и статус после обновления."}'::jsonb,
    $pmp_in_02$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target manual task ID",
      "russian": "ID целевой ручной задачи"
    },
    "description": {
      "english": "UUID of the manual task to update (from process context).",
      "russian": "UUID обновляемой ручной задачи (из контекста процесса)."
    }
  },
  {
    "key": "assignee",
    "type": "assignee",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Assignee",
      "russian": "Исполнитель"
    },
    "description": {
      "english": "New assigned group, account, or participant.",
      "russian": "Новая ответственная группа, учётная запись или участник."
    }
  },
  {
    "key": "description",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Description",
      "russian": "Описание"
    },
    "description": {
      "english": "Updated description of the manual task.",
      "russian": "Обновлённое описание ручной задачи."
    }
  },
  {
    "key": "status",
    "type": "enum",
    "required": false,
    "source": "both",
    "enum": [
      "new",
      "in_progress",
      "paused",
      "complete"
    ],
    "label": {
      "english": "Status",
      "russian": "Статус"
    },
    "description": {
      "english": "New lifecycle status.",
      "russian": "Новый статус жизненного цикла."
    }
  }
]
$pmp_in_02$::jsonb,
    $pmp_out_02$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Manual task ID",
      "russian": "ID ручной задачи"
    },
    "description": {
      "english": "UUID of the updated manual task.",
      "russian": "UUID обновлённой ручной задачи."
    },
    "example": "<uuid>"
  },
  {
    "key": "status",
    "type": "enum",
    "enum": [
      "new",
      "in_progress",
      "paused",
      "complete"
    ],
    "label": {
      "english": "Status",
      "russian": "Статус"
    },
    "description": {
      "english": "Status after update.",
      "russian": "Статус после обновления."
    },
    "example": "in_progress"
  }
]
$pmp_out_02$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440014',
    'work.manual_task.delete',
    'work',
    'manual_task',
    'delete',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Manual task", "russian": "Ручная задача"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the manual task identified by target_id from the process context. Writes the id of the deleted task.", "russian": "Удаляет ручную задачу, id которой (target_id) берётся из контекста процесса. Записывает id удалённой задачи."}'::jsonb,
    $pmp_in_03$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target manual task ID",
      "russian": "ID целевой ручной задачи"
    },
    "description": {
      "english": "UUID of the manual task to delete (from process context).",
      "russian": "UUID удаляемой ручной задачи (из контекста процесса)."
    }
  }
]
$pmp_in_03$::jsonb,
    $pmp_out_03$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted manual task ID",
      "russian": "ID удалённой ручной задачи"
    },
    "description": {
      "english": "UUID of the deleted manual task.",
      "russian": "UUID удалённой ручной задачи."
    },
    "example": "<uuid>"
  }
]
$pmp_out_03$::jsonb,
    true
),
(
    '991e8400-e29b-41d4-a716-446655440002',
    'work.approval.create',
    'work',
    'approval',
    'create',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Approval", "russian": "Согласование"}'::jsonb,
    '{"english": "Create", "russian": "Создать"}'::jsonb,
    '{"english": "Creates an approval assigned to a participant, account, or group, with an optional description, and waits until the approver decides. Writes the approval id, number, outcome, approval_notes, rejection_notes, completed_by, and completed_at.", "russian": "Создаёт согласование, назначенное участнику, учётной записи или группе, с необязательным описанием, и переводит токен в ожидание решения. Записывает id согласования, номер, результат, комментарии, кто завершил и время завершения."}'::jsonb,
    $pmp_in_04$
[
  {
    "key": "assignee",
    "type": "assignee",
    "required": true,
    "source": "literal_only",
    "label": {
      "english": "Assignee",
      "russian": "Исполнитель"
    },
    "description": {
      "english": "Assigned group, account, or participant.",
      "russian": "Ответственная группа, учётная запись или участник."
    }
  },
  {
    "key": "description",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Description",
      "russian": "Описание"
    },
    "description": {
      "english": "Instructions for the approval.",
      "russian": "Описание согласования для согласующего."
    }
  }
]
$pmp_in_04$::jsonb,
    $pmp_out_04$
[
  {
    "key": "activity_id",
    "type": "uuid",
    "label": {
      "english": "Activity id",
      "russian": "Идентификатор активности"
    },
    "description": {
      "english": "Id of the completed approval.",
      "russian": "Идентификатор завершённого согласования."
    },
    "example": "<uuid>"
  },
  {
    "key": "number",
    "type": "string",
    "label": {
      "english": "Number",
      "russian": "Номер"
    },
    "description": {
      "english": "Display number of the approval (ap-XXXXXX).",
      "russian": "Номер согласования для отображения (ap-XXXXXX)."
    },
    "example": "ap-000105"
  },
  {
    "key": "outcome",
    "type": "enum",
    "enum": [
      "approved",
      "rejected",
      "cancelled"
    ],
    "label": {
      "english": "Outcome",
      "russian": "Результат"
    },
    "description": {
      "english": "How the approval finished.",
      "russian": "Чем завершилось согласование."
    },
    "example": "approved"
  },
  {
    "key": "approval_notes",
    "type": "string",
    "label": {
      "english": "Approval notes",
      "russian": "Комментарий к согласованию"
    },
    "description": {
      "english": "Notes recorded when approved.",
      "russian": "Комментарий к согласованию."
    }
  },
  {
    "key": "rejection_notes",
    "type": "string",
    "label": {
      "english": "Rejection notes",
      "russian": "Комментарий к отклонению"
    },
    "description": {
      "english": "Notes recorded when rejected.",
      "russian": "Комментарий к отклонению."
    }
  },
  {
    "key": "completed_by",
    "type": "uuid",
    "label": {
      "english": "Completed by",
      "russian": "Кто завершил"
    },
    "description": {
      "english": "Account that completed the approval.",
      "russian": "Учётная запись, которая завершила согласование."
    },
    "example": "<uuid>"
  },
  {
    "key": "completed_at",
    "type": "date-time",
    "label": {
      "english": "Completed at",
      "russian": "Время завершения"
    },
    "description": {
      "english": "When the approval was completed.",
      "russian": "Когда согласование было завершено."
    },
    "example": "2026-10-20T12:00:00Z"
  }
]
$pmp_out_04$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440015',
    'work.approval.update',
    'work',
    'approval',
    'update',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Approval", "russian": "Согласование"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the approval identified by target_id from the process context. Optional inputs set the assignee, the description, and the lifecycle status. Writes the approval id and the status after the update.", "russian": "Обновляет согласование, id которого (target_id) берётся из контекста процесса. Необязательные входы задают исполнителя, описание и статус жизненного цикла. Записывает id согласования и статус после обновления."}'::jsonb,
    $pmp_in_05$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target approval ID",
      "russian": "ID целевого согласования"
    },
    "description": {
      "english": "UUID of the approval to update (from process context).",
      "russian": "UUID обновляемого согласования (из контекста процесса)."
    }
  },
  {
    "key": "assignee",
    "type": "assignee",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Assignee",
      "russian": "Исполнитель"
    },
    "description": {
      "english": "New assigned group, account, or participant.",
      "russian": "Новая ответственная группа, учётная запись или участник."
    }
  },
  {
    "key": "description",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Description",
      "russian": "Описание"
    },
    "description": {
      "english": "Updated description of the approval.",
      "russian": "Обновлённое описание согласования."
    }
  },
  {
    "key": "status",
    "type": "enum",
    "required": false,
    "source": "both",
    "enum": [
      "new",
      "in_progress",
      "paused",
      "complete"
    ],
    "label": {
      "english": "Status",
      "russian": "Статус"
    },
    "description": {
      "english": "New lifecycle status.",
      "russian": "Новый статус жизненного цикла."
    }
  }
]
$pmp_in_05$::jsonb,
    $pmp_out_05$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Approval ID",
      "russian": "ID согласования"
    },
    "description": {
      "english": "UUID of the updated approval.",
      "russian": "UUID обновлённого согласования."
    },
    "example": "<uuid>"
  },
  {
    "key": "status",
    "type": "enum",
    "enum": [
      "new",
      "in_progress",
      "paused",
      "complete"
    ],
    "label": {
      "english": "Status",
      "russian": "Статус"
    },
    "description": {
      "english": "Status after update.",
      "russian": "Статус после обновления."
    },
    "example": "in_progress"
  }
]
$pmp_out_05$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440016',
    'work.approval.delete',
    'work',
    'approval',
    'delete',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Approval", "russian": "Согласование"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the approval identified by target_id from the process context. Writes the id of the deleted approval.", "russian": "Удаляет согласование, id которого (target_id) берётся из контекста процесса. Записывает id удалённого согласования."}'::jsonb,
    $pmp_in_06$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target approval ID",
      "russian": "ID целевого согласования"
    },
    "description": {
      "english": "UUID of the approval to delete (from process context).",
      "russian": "UUID удаляемого согласования (из контекста процесса)."
    }
  }
]
$pmp_in_06$::jsonb,
    $pmp_out_06$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted approval ID",
      "russian": "ID удалённого согласования"
    },
    "description": {
      "english": "UUID of the deleted approval.",
      "russian": "UUID удалённого согласования."
    },
    "example": "<uuid>"
  }
]
$pmp_out_06$::jsonb,
    true
),
(
    '991e8400-e29b-41d4-a716-446655440003',
    'work.acceptance.create',
    'work',
    'acceptance',
    'create',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Acceptance", "russian": "Приёмка"}'::jsonb,
    '{"english": "Create", "russian": "Создать"}'::jsonb,
    '{"english": "Creates an acceptance assigned to a participant, account, or group, with an optional description, and waits until the recipient accepts or rejects the result. Writes the acceptance id, number, outcome, acceptance_notes, rejection_notes, completed_by, and completed_at.", "russian": "Создаёт приёмку, назначенную участнику, учётной записи или группе, с необязательным описанием, и переводит токен в ожидание решения. Записывает id приёмки, номер, результат, комментарии, кто завершил и время завершения."}'::jsonb,
    $pmp_in_07$
[
  {
    "key": "assignee",
    "type": "assignee",
    "required": true,
    "source": "literal_only",
    "label": {
      "english": "Assignee",
      "russian": "Исполнитель"
    },
    "description": {
      "english": "Assigned group, account, or participant.",
      "russian": "Ответственная группа, учётная запись или участник."
    }
  },
  {
    "key": "description",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Description",
      "russian": "Описание"
    },
    "description": {
      "english": "Instructions for the acceptance.",
      "russian": "Описание приёмки для принимающего."
    }
  }
]
$pmp_in_07$::jsonb,
    $pmp_out_07$
[
  {
    "key": "activity_id",
    "type": "uuid",
    "label": {
      "english": "Activity id",
      "russian": "Идентификатор активности"
    },
    "description": {
      "english": "Id of the completed acceptance.",
      "russian": "Идентификатор завершённой приёмки."
    },
    "example": "<uuid>"
  },
  {
    "key": "number",
    "type": "string",
    "label": {
      "english": "Number",
      "russian": "Номер"
    },
    "description": {
      "english": "Display number of the acceptance (ac-XXXXXX).",
      "russian": "Номер приёмки для отображения (ac-XXXXXX)."
    },
    "example": "ac-000105"
  },
  {
    "key": "outcome",
    "type": "enum",
    "enum": [
      "accepted",
      "rejected",
      "cancelled"
    ],
    "label": {
      "english": "Outcome",
      "russian": "Результат"
    },
    "description": {
      "english": "How the acceptance finished.",
      "russian": "Чем завершилась приёмка."
    },
    "example": "accepted"
  },
  {
    "key": "acceptance_notes",
    "type": "string",
    "label": {
      "english": "Acceptance notes",
      "russian": "Комментарий к приёмке"
    },
    "description": {
      "english": "Notes recorded when accepted.",
      "russian": "Комментарий к приёмке."
    }
  },
  {
    "key": "rejection_notes",
    "type": "string",
    "label": {
      "english": "Rejection notes",
      "russian": "Комментарий к отклонению"
    },
    "description": {
      "english": "Notes recorded when rejected.",
      "russian": "Комментарий к отклонению."
    }
  },
  {
    "key": "completed_by",
    "type": "uuid",
    "label": {
      "english": "Completed by",
      "russian": "Кто завершил"
    },
    "description": {
      "english": "Account that completed the acceptance.",
      "russian": "Учётная запись, которая завершила приёмку."
    },
    "example": "<uuid>"
  },
  {
    "key": "completed_at",
    "type": "date-time",
    "label": {
      "english": "Completed at",
      "russian": "Время завершения"
    },
    "description": {
      "english": "When the acceptance was completed.",
      "russian": "Когда приёмка была завершена."
    },
    "example": "2026-10-20T12:00:00Z"
  }
]
$pmp_out_07$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440017',
    'work.acceptance.update',
    'work',
    'acceptance',
    'update',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Acceptance", "russian": "Приёмка"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the acceptance identified by target_id from the process context. Optional inputs set the assignee, the description, and the lifecycle status. An acceptance has no paused state. Writes the acceptance id and the status after the update.", "russian": "Обновляет приёмку, id которой (target_id) берётся из контекста процесса. Необязательные входы задают исполнителя, описание и статус жизненного цикла. У приёмки нет состояния паузы. Записывает id приёмки и статус после обновления."}'::jsonb,
    $pmp_in_08$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target acceptance ID",
      "russian": "ID целевой приёмки"
    },
    "description": {
      "english": "UUID of the acceptance to update (from process context).",
      "russian": "UUID обновляемой приёмки (из контекста процесса)."
    }
  },
  {
    "key": "assignee",
    "type": "assignee",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Assignee",
      "russian": "Исполнитель"
    },
    "description": {
      "english": "New assigned group, account, or participant.",
      "russian": "Новая ответственная группа, учётная запись или участник."
    }
  },
  {
    "key": "description",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Description",
      "russian": "Описание"
    },
    "description": {
      "english": "Updated description of the acceptance.",
      "russian": "Обновлённое описание приёмки."
    }
  },
  {
    "key": "status",
    "type": "enum",
    "required": false,
    "source": "both",
    "enum": [
      "new",
      "in_progress",
      "complete"
    ],
    "label": {
      "english": "Status",
      "russian": "Статус"
    },
    "description": {
      "english": "New lifecycle status.",
      "russian": "Новый статус жизненного цикла."
    }
  }
]
$pmp_in_08$::jsonb,
    $pmp_out_08$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Acceptance ID",
      "russian": "ID приёмки"
    },
    "description": {
      "english": "UUID of the updated acceptance.",
      "russian": "UUID обновлённой приёмки."
    },
    "example": "<uuid>"
  },
  {
    "key": "status",
    "type": "enum",
    "enum": [
      "new",
      "in_progress",
      "complete"
    ],
    "label": {
      "english": "Status",
      "russian": "Статус"
    },
    "description": {
      "english": "Status after update.",
      "russian": "Статус после обновления."
    },
    "example": "in_progress"
  }
]
$pmp_out_08$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440018',
    'work.acceptance.delete',
    'work',
    'acceptance',
    'delete',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Acceptance", "russian": "Приёмка"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the acceptance identified by target_id from the process context. Writes the id of the deleted acceptance.", "russian": "Удаляет приёмку, id которой (target_id) берётся из контекста процесса. Записывает id удалённой приёмки."}'::jsonb,
    $pmp_in_09$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target acceptance ID",
      "russian": "ID целевой приёмки"
    },
    "description": {
      "english": "UUID of the acceptance to delete (from process context).",
      "russian": "UUID удаляемой приёмки (из контекста процесса)."
    }
  }
]
$pmp_in_09$::jsonb,
    $pmp_out_09$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted acceptance ID",
      "russian": "ID удалённой приёмки"
    },
    "description": {
      "english": "UUID of the deleted acceptance.",
      "russian": "UUID удалённой приёмки."
    },
    "example": "<uuid>"
  }
]
$pmp_out_09$::jsonb,
    true
)
ON CONFLICT (procedure_key) DO UPDATE SET
    module = EXCLUDED.module,
    entity = EXCLUDED.entity,
    action = EXCLUDED.action,
    module_name = EXCLUDED.module_name,
    entity_name = EXCLUDED.entity_name,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    input_schema = EXCLUDED.input_schema,
    output_schema = EXCLUDED.output_schema,
    is_system = EXCLUDED.is_system;

UPDATE app.app_settings AS s
SET
    value = CASE
        WHEN jsonb_typeof(s.value) = 'array' THEN (
            SELECT jsonb_agg(merged.mime ORDER BY merged.mime COLLATE "C")
            FROM (
                SELECT DISTINCT src.mime
                FROM (
                    SELECT jsonb_array_elements_text(s.value) AS mime
                    UNION ALL
                    SELECT t.mime
                    FROM unnest(ARRAY[
                        'application/gzip',
                        'application/vnd.ms-visio.drawing.main+xml',
                        'application/vnd.oasis.opendocument.presentation',
                        'application/vnd.oasis.opendocument.spreadsheet',
                        'application/vnd.rar',
                        'application/x-7z-compressed',
                        'application/x-tar',
                        'audio/mpeg',
                        'audio/wav',
                        'audio/x-m4a',
                        'image/bmp',
                        'image/tiff',
                        'text/calendar',
                        'text/yaml',
                        'video/quicktime',
                        'video/webm'
                    ]::text[]) AS t(mime)
                ) AS src
            ) AS merged
        )
        ELSE s.value
    END,
    validation_schema = '{"type":"array","items":{"type":"string","enum":["application/gzip","application/json","application/msword","application/pdf","application/rtf","application/vnd.ms-excel","application/vnd.ms-powerpoint","application/vnd.ms-visio.drawing.main+xml","application/vnd.oasis.opendocument.presentation","application/vnd.oasis.opendocument.spreadsheet","application/vnd.oasis.opendocument.text","application/vnd.openxmlformats-officedocument.presentationml.presentation","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","application/vnd.openxmlformats-officedocument.wordprocessingml.document","application/vnd.rar","application/x-7z-compressed","application/x-tar","application/xml","application/zip","audio/mpeg","audio/wav","audio/x-m4a","image/bmp","image/gif","image/jpeg","image/png","image/svg+xml","image/tiff","image/webp","text/calendar","text/csv","text/markdown","text/plain","text/yaml","video/mp4","video/quicktime","video/webm","video/x-matroska"]},"uniqueItems":true}'::jsonb,
    default_value = '["application/gzip","application/json","application/msword","application/pdf","application/rtf","application/vnd.ms-excel","application/vnd.ms-powerpoint","application/vnd.ms-visio.drawing.main+xml","application/vnd.oasis.opendocument.presentation","application/vnd.oasis.opendocument.spreadsheet","application/vnd.oasis.opendocument.text","application/vnd.openxmlformats-officedocument.presentationml.presentation","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","application/vnd.openxmlformats-officedocument.wordprocessingml.document","application/vnd.rar","application/x-7z-compressed","application/x-tar","application/xml","application/zip","audio/mpeg","audio/wav","audio/x-m4a","image/bmp","image/gif","image/jpeg","image/png","image/tiff","image/webp","text/calendar","text/csv","text/markdown","text/plain","text/yaml","video/mp4","video/quicktime","video/webm","video/x-matroska"]'::jsonb,
    description = 'Allowlist of MIME types accepted for uploads. Values must come from the closed release-defined catalog (38 types). image/svg+xml is in the catalog but excluded from the default allowlist (stored-XSS risk); an admin may re-enable it here if genuinely required.'
WHERE section_path = 'Application.System.Fs.Policies'
  AND setting_name = 'mime.allow'
  AND environment = 'all';

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.25.2',
        'Added process_token_id, completed_by, and object_version on manual activity tables, cancelled outcome on approvals and acceptances, work domain events in the events library, and wake_at timer wake-up on process tokens and the app.process_manual_procedures catalog; the mime.allow validation schema and factory default now include the 16 catalog types, and the stored allowlist gains those 16 types when absent'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.25.2', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

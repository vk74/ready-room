-- Version: 0.25.4
-- Description: Adds optional app.users_standard_profiles.position (job title).
--   Adds service_order to app.activity_parent_kind before service_request and
--   refreshes the type comment and the parent_kind / parent_id column comments
--   on activity_manual_tasks, activity_approvals and activity_acceptances.
--   Updates work.manual_task, work.approval and work.acceptance event object
--   schemas (version 1) so parent_kind allows service_order, and adds optional
--   title and parent_id to the create manual procedure input schemas.
--   Rewrites organization, KB attachment, worker_jobs, and event_outbox
--   comments so they no longer name the product, evi-fs, evi-worker, or evi-be.
--   Same objects as db/init/04_enums.sql, db/init/05_tables.sql and
--   db/init/08_system_entities.sql.
-- Backend file: m_0.25.4_user_position.sql
--
-- Changes in v0.25.4:
-- - Add app.users_standard_profiles.position VARCHAR(100), optional job title, NULL when unset.
-- - app.activity_parent_kind adds service_order before service_request; type and parent column comments name service_order.
-- - work.manual_task, work.approval and work.acceptance event_object_schemas version 1 allow service_order in parent_kind.
-- - work.manual_task.create, work.approval.create and work.acceptance.create input_schema include optional title (source both) and optional parent_id (source context_only).
-- - schema_version set to 0.25.4.
-- - Organization, KB attachment, worker_jobs, and event_outbox comments no longer name the product, evi-fs, evi-worker, or evi-be.

BEGIN;

ALTER TABLE app.users_standard_profiles
    ADD COLUMN IF NOT EXISTS position VARCHAR(100);

COMMENT ON COLUMN app.users_standard_profiles.position IS
    'Optional job title. NULL when unset.';

ALTER TYPE app.activity_parent_kind ADD VALUE IF NOT EXISTS 'service_order' BEFORE 'service_request';

COMMENT ON TYPE app.activity_parent_kind IS
    'Discriminator for an activity''s parent: service_order, service_request or process. Shared by activity_manual_tasks, activity_approvals and activity_acceptances. parent_id is a bare UUID (no FK).';

COMMENT ON COLUMN app.activity_manual_tasks.parent_kind IS 'What the parent is (service_order, service_request or process). Immutable after INSERT.';
COMMENT ON COLUMN app.activity_manual_tasks.parent_id IS 'UUID of the parent service order, service request or process. Bare column — intentionally no FK. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_approvals.parent_kind IS 'What the parent is (service_order, service_request or process). Immutable after INSERT.';
COMMENT ON COLUMN app.activity_approvals.parent_id IS 'UUID of the parent service order, service request or process. Bare column — intentionally no FK. Immutable after INSERT.';
COMMENT ON COLUMN app.activity_acceptances.parent_kind IS 'What the parent is (service_order, service_request or process). Immutable after INSERT.';
COMMENT ON COLUMN app.activity_acceptances.parent_id IS 'UUID of the parent service order, service request or process. Bare column — intentionally no FK. Immutable after INSERT.';

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
    "parent_kind": {"type": "string", "enum": ["service_order", "service_request", "process"], "x-label": {"english": "Parent kind", "russian": "Тип родителя"}},
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
    "parent_kind": {"type": "string", "enum": ["service_order", "service_request", "process"], "x-label": {"english": "Parent kind", "russian": "Тип родителя"}},
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
    "parent_kind": {"type": "string", "enum": ["service_order", "service_request", "process"], "x-label": {"english": "Parent kind", "russian": "Тип родителя"}},
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
    "key": "title",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Title",
      "russian": "Заголовок"
    },
    "description": {
      "english": "Short title of the activity; defaults to the step name when omitted.",
      "russian": "Краткий заголовок активности; если не указан, используется название шага."
    }
  },
  {
    "key": "parent_id",
    "type": "uuid",
    "required": false,
    "source": "context_only",
    "label": {
      "english": "Parent object ID",
      "russian": "ID родительского объекта"
    },
    "description": {
      "english": "UUID of the parent object from the process context (for example a service order or service request).",
      "russian": "UUID родительского объекта из контекста процесса (например заказа услуги или сервисного запроса)."
    }
  },
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
    "key": "title",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Title",
      "russian": "Заголовок"
    },
    "description": {
      "english": "Short title of the activity; defaults to the step name when omitted.",
      "russian": "Краткий заголовок активности; если не указан, используется название шага."
    }
  },
  {
    "key": "parent_id",
    "type": "uuid",
    "required": false,
    "source": "context_only",
    "label": {
      "english": "Parent object ID",
      "russian": "ID родительского объекта"
    },
    "description": {
      "english": "UUID of the parent object from the process context (for example a service order or service request).",
      "russian": "UUID родительского объекта из контекста процесса (например заказа услуги или сервисного запроса)."
    }
  },
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
    "key": "title",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Title",
      "russian": "Заголовок"
    },
    "description": {
      "english": "Short title of the activity; defaults to the step name when omitted.",
      "russian": "Краткий заголовок активности; если не указан, используется название шага."
    }
  },
  {
    "key": "parent_id",
    "type": "uuid",
    "required": false,
    "source": "context_only",
    "label": {
      "english": "Parent object ID",
      "russian": "ID родительского объекта"
    },
    "description": {
      "english": "UUID of the parent object from the process context (for example a service order or service request).",
      "russian": "UUID родительского объекта из контекста процесса (например заказа услуги или сервисного запроса)."
    }
  },
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

COMMENT ON TABLE app.organizations IS 'Organization registry. The system organization (is_system=true) represents the deployment owner; it is just an attribute, not a fixed identity, so its org_name is fully editable.';
COMMENT ON TABLE app.kb_article_attachments IS 'File references for KB articles. Actual files stored in object storage (fs); this table holds metadata and paths.';
COMMENT ON TABLE app.worker_jobs IS 'Transactional Outbox queue for the background worker. Insert within a business transaction for atomic job scheduling. done rows are deleted; failed rows are kept for inspection.';
COMMENT ON COLUMN app.worker_jobs.claimed_at IS 'Timestamp when the worker claimed the job. Used by stuck-job recovery: if claimed_at is older than 5 min and status is still processing, the job is reset to pending (or failed if attempts exhausted).';
COMMENT ON COLUMN app.worker_jobs.error_msg IS 'Last error message recorded on failure. Set by the worker.';
COMMENT ON COLUMN app.event_outbox.claimed_at IS 'Timestamp when the backend relay claimed the row. Used by stuck-row recovery: if claimed_at is older than 5 min and status is still processing, the row is reset to pending (or failed if attempts exhausted).';
COMMENT ON COLUMN app.event_outbox.error_msg IS 'Last error message recorded on failure. Set by the backend relay.';

DO $$ BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.25.4',
        'Added optional users_standard_profiles.position; activity_parent_kind service_order and manual procedure inputs; comments drop product names'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.25.4', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

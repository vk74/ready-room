-- Version: 0.24.6
-- Description: Rename pricing permission keys from adminPricing to referencePricing, role names from role.adminPricing.* to role.referencePricing.*, and app_settings section_path prefixes AdminPricing to ReferencePricing, AdminProducts to AdminApp.Products, AdminCatalog to AdminApp.Catalog, AdminServices to AdminApp.Services, and AdminForms to AdminApp.Forms. Adds work_item_kind organization and the regional organization schema on app.organizations (region_id, address, answers) and app.work_item_forms (region_id). Updates catalog.service_order schema version 1 so core includes form_id, form_version_id, quantity, and watch_list, and updates the catalog.service_order.submitted description. Converts app.service_requests.priority to SMALLINT (1..5, 1 highest) with chk_service_requests_priority_range. Seeds AdminApp.Practices/priority.matrix. Updates the input_schema priority enum of work.service_request.create and work.service_request.update.
-- Backend file: m_0.24.6_reference_pricing.sql
--
-- Changes in v0.24.6:
-- - Insert referencePricing permission rows copied from adminPricing rows. permission_key is the primary key of app.permissions and app.group_permissions.permission_key references it with ON DELETE CASCADE and no ON UPDATE CASCADE, so the primary key is not updated in place.
-- - Point app.group_permissions at the new key when that group does not already have it, then delete remaining adminPricing grants and permission rows.
-- - Rename app.groups.group_name from role.adminPricing. to role.referencePricing. when the new name does not already exist. Membership stays on group_id.
-- - Rename app.app_settings.section_path from AdminPricing to ReferencePricing, including the AdminPricing. prefix, when the new primary key (section_path, setting_name, environment) is free.
-- - Rename app.app_settings.section_path prefixes AdminProducts to AdminApp.Products and AdminCatalog to AdminApp.Catalog, including dotted suffixes, when the new primary key is free. Rows that still use the old prefix are then deleted.
-- - Rename app.app_settings.section_path prefixes AdminServices to AdminApp.Services and AdminForms to AdminApp.Forms, including dotted suffixes, when the new primary key is free. Rows that still use the old prefix are then deleted.
-- - app.work_item_kind adds organization for regional organization forms.
-- - app.organizations: drop tax_id, registration_number, legal_address, and actual_address; add region_id (fk_organizations_region_id, ON DELETE SET NULL), address (VARCHAR(500)), and answers (JSONB NOT NULL DEFAULT '{}'::jsonb, chk_organizations_answers_object). legal_address is coalesced into address, then actual_address when legal_address is null.
-- - app.work_item_forms: add region_id (fk_work_item_forms_region_id, ON DELETE RESTRICT), chk_work_item_forms_region_kind, and uq_work_item_forms_region_id (one organization form per region).
-- - catalog.service_order schema version 1 core_schema and example_core include form_id, form_version_id, quantity, and watch_list (12 required core keys). catalog.service_order.submitted description updated accordingly.
-- - app.service_requests.priority is retyped to SMALLINT. critical, high, medium, and low map to 1, 2, 3, and 4; digit strings 1..5 map to those integers; any other value becomes NULL. chk_service_requests_priority_range allows NULL or 1..5. The column comment names AdminApp.Practices/priority.matrix.
-- - Seed AdminApp.Practices/priority.matrix (is_public false). ON CONFLICT updates value, validation_schema, default_value, description, and is_public.
-- - work.service_request.create input_schema priority enum is calculated, 1, 2, 3, 4, 5. work.service_request.update input_schema priority enum is 1, 2, 3, 4, 5.
--
-- Destructive-affects: COLUMN app.organizations.tax_id; COLUMN app.organizations.registration_number; COLUMN app.organizations.legal_address; COLUMN app.organizations.actual_address; COLUMN app.service_requests.priority
-- Destructive-data-loss: values of app.organizations.tax_id and app.organizations.registration_number; app.organizations.actual_address when legal_address is also populated (coalesced into app.organizations.address); app.service_requests.priority values other than critical, high, medium, low, or 1..5 become NULL when the column is retyped to SMALLINT

BEGIN;

INSERT INTO app.permissions (permission_key, module, description)
SELECT replace(permission_key, 'adminPricing:', 'referencePricing:'),
       'referencePricing',
       description
FROM app.permissions
WHERE permission_key LIKE 'adminPricing:%'
ON CONFLICT (permission_key) DO NOTHING;

UPDATE app.group_permissions AS gp
SET permission_key = replace(gp.permission_key, 'adminPricing:', 'referencePricing:')
WHERE gp.permission_key LIKE 'adminPricing:%'
  AND NOT EXISTS (
      SELECT 1
      FROM app.group_permissions AS existing
      WHERE existing.group_id = gp.group_id
        AND existing.permission_key = replace(gp.permission_key, 'adminPricing:', 'referencePricing:')
  );

DELETE FROM app.group_permissions
WHERE permission_key LIKE 'adminPricing:%';

DELETE FROM app.permissions
WHERE permission_key LIKE 'adminPricing:%';

UPDATE app.groups AS g
SET group_name = replace(g.group_name, 'role.adminPricing.', 'role.referencePricing.')
WHERE g.group_name LIKE 'role.adminPricing.%'
  AND NOT EXISTS (
      SELECT 1
      FROM app.groups AS existing
      WHERE existing.group_name = replace(g.group_name, 'role.adminPricing.', 'role.referencePricing.')
  );

UPDATE app.app_settings AS s
SET section_path = 'ReferencePricing' || substring(s.section_path FROM char_length('AdminPricing') + 1)
WHERE (s.section_path = 'AdminPricing' OR s.section_path LIKE 'AdminPricing.%')
  AND NOT EXISTS (
      SELECT 1
      FROM app.app_settings AS existing
      WHERE existing.section_path = 'ReferencePricing' || substring(s.section_path FROM char_length('AdminPricing') + 1)
        AND existing.setting_name = s.setting_name
        AND existing.environment = s.environment
  );

UPDATE app.app_settings AS s
SET section_path = 'AdminApp.Products' || substring(s.section_path FROM char_length('AdminProducts') + 1)
WHERE (s.section_path = 'AdminProducts' OR s.section_path LIKE 'AdminProducts.%')
  AND NOT EXISTS (
      SELECT 1
      FROM app.app_settings AS existing
      WHERE existing.section_path = 'AdminApp.Products' || substring(s.section_path FROM char_length('AdminProducts') + 1)
        AND existing.setting_name = s.setting_name
        AND existing.environment = s.environment
  );

DELETE FROM app.app_settings
WHERE section_path = 'AdminProducts' OR section_path LIKE 'AdminProducts.%';

UPDATE app.app_settings AS s
SET section_path = 'AdminApp.Catalog' || substring(s.section_path FROM char_length('AdminCatalog') + 1)
WHERE (s.section_path = 'AdminCatalog' OR s.section_path LIKE 'AdminCatalog.%')
  AND NOT EXISTS (
      SELECT 1
      FROM app.app_settings AS existing
      WHERE existing.section_path = 'AdminApp.Catalog' || substring(s.section_path FROM char_length('AdminCatalog') + 1)
        AND existing.setting_name = s.setting_name
        AND existing.environment = s.environment
  );

DELETE FROM app.app_settings
WHERE section_path = 'AdminCatalog' OR section_path LIKE 'AdminCatalog.%';

UPDATE app.app_settings AS s
SET section_path = 'AdminApp.Services' || substring(s.section_path FROM char_length('AdminServices') + 1)
WHERE (s.section_path = 'AdminServices' OR s.section_path LIKE 'AdminServices.%')
  AND NOT EXISTS (
      SELECT 1
      FROM app.app_settings AS existing
      WHERE existing.section_path = 'AdminApp.Services' || substring(s.section_path FROM char_length('AdminServices') + 1)
        AND existing.setting_name = s.setting_name
        AND existing.environment = s.environment
  );

DELETE FROM app.app_settings
WHERE section_path = 'AdminServices' OR section_path LIKE 'AdminServices.%';

UPDATE app.app_settings AS s
SET section_path = 'AdminApp.Forms' || substring(s.section_path FROM char_length('AdminForms') + 1)
WHERE (s.section_path = 'AdminForms' OR s.section_path LIKE 'AdminForms.%')
  AND NOT EXISTS (
      SELECT 1
      FROM app.app_settings AS existing
      WHERE existing.section_path = 'AdminApp.Forms' || substring(s.section_path FROM char_length('AdminForms') + 1)
        AND existing.setting_name = s.setting_name
        AND existing.environment = s.environment
  );

DELETE FROM app.app_settings
WHERE section_path = 'AdminForms' OR section_path LIKE 'AdminForms.%';

-- app.work_item_kind: organization, for regional organization forms.
ALTER TYPE app.work_item_kind ADD VALUE IF NOT EXISTS 'organization';

-- app.organizations: region binding, one address, custom form answers.
ALTER TABLE app.organizations ADD COLUMN IF NOT EXISTS region_id INTEGER;
ALTER TABLE app.organizations ADD COLUMN IF NOT EXISTS address VARCHAR(500);
ALTER TABLE app.organizations ADD COLUMN IF NOT EXISTS answers JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Coalesce legacy addresses into address while those columns still exist.
-- legal_address wins when both are populated. Re-running after the DROP is a no-op.
DO $$
DECLARE
    has_legal boolean;
    has_actual boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'organizations'
          AND column_name = 'legal_address'
    ) INTO has_legal;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'organizations'
          AND column_name = 'actual_address'
    ) INTO has_actual;

    IF has_legal AND has_actual THEN
        EXECUTE 'UPDATE app.organizations SET address = COALESCE(legal_address, actual_address) WHERE address IS NULL';
    ELSIF has_legal THEN
        EXECUTE 'UPDATE app.organizations SET address = legal_address WHERE address IS NULL';
    ELSIF has_actual THEN
        EXECUTE 'UPDATE app.organizations SET address = actual_address WHERE address IS NULL';
    END IF;
END $$;

ALTER TABLE app.organizations DROP COLUMN IF EXISTS tax_id;
ALTER TABLE app.organizations DROP COLUMN IF EXISTS registration_number;
ALTER TABLE app.organizations DROP COLUMN IF EXISTS legal_address;
ALTER TABLE app.organizations DROP COLUMN IF EXISTS actual_address;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_organizations_answers_object'
          AND conrelid = 'app.organizations'::regclass
    ) THEN
        ALTER TABLE app.organizations
            ADD CONSTRAINT chk_organizations_answers_object
            CHECK (jsonb_typeof(answers) = 'object');
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_organizations_region_id'
          AND conrelid = 'app.organizations'::regclass
    ) THEN
        ALTER TABLE app.organizations
            ADD CONSTRAINT fk_organizations_region_id
            FOREIGN KEY (region_id)
            REFERENCES app.regions(region_id)
            ON DELETE SET NULL;
    END IF;
END $$;

COMMENT ON COLUMN app.organizations.region_id IS 'Reference to app.regions.region_id. Determines which regional organization form applies. Set to NULL when the region is deleted.';
COMMENT ON COLUMN app.organizations.address IS 'General organization address (max 500 chars).';
COMMENT ON COLUMN app.organizations.answers IS 'Custom regional form answers as {fieldKey: value}. Validated against the active organization form for region_id.';

CREATE INDEX IF NOT EXISTS idx_organizations_region_id
    ON app.organizations USING btree (region_id);

-- app.work_item_forms: one region binding, required only for organization forms.
ALTER TABLE app.work_item_forms ADD COLUMN IF NOT EXISTS region_id INTEGER;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_work_item_forms_region_id'
          AND conrelid = 'app.work_item_forms'::regclass
    ) THEN
        ALTER TABLE app.work_item_forms
            ADD CONSTRAINT fk_work_item_forms_region_id
            FOREIGN KEY (region_id)
            REFERENCES app.regions(region_id)
            ON DELETE RESTRICT;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_work_item_forms_region_kind'
          AND conrelid = 'app.work_item_forms'::regclass
    ) THEN
        ALTER TABLE app.work_item_forms
            ADD CONSTRAINT chk_work_item_forms_region_kind
            CHECK ((work_item_kind::text = 'organization' AND region_id IS NOT NULL) OR (work_item_kind::text <> 'organization' AND region_id IS NULL));
    END IF;
END $$;

COMMENT ON COLUMN app.work_item_forms.region_id IS 'Region binding for organization forms (nullable for other kinds; required when work_item_kind is organization). ON DELETE RESTRICT prevents deleting a region that still has an organization form.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_work_item_forms_region_id
    ON app.work_item_forms USING btree (region_id)
    WHERE (region_id IS NOT NULL);

INSERT INTO app.event_object_schemas (
    object_key, schema_version, core_schema, example_core, change_note, introduced_in
) VALUES (
    'catalog.service_order',
    1,
    $event_core_schema${
  "type": "object",
  "additionalProperties": false,
  "required": ["order_number", "service_id", "form_id", "form_version_id", "title", "description", "urgency", "impact", "quantity", "watch_list", "requester_user_id", "requested_for_user_id"],
  "properties": {
    "order_number": {"type": "string", "x-label": {"english": "Order number", "russian": "Номер заказа"}, "x-description": {"english": "Human-readable order reference: so- plus 6 base36 characters.", "russian": "Читаемый номер заказа: so- и 6 символов base36."}},
    "service_id": {"type": "string", "format": "uuid", "x-label": {"english": "Service", "russian": "Услуга"}, "x-description": {"english": "Id of the ordered service.", "russian": "Идентификатор заказанной услуги."}},
    "form_id": {"type": "string", "format": "uuid", "x-label": {"english": "Form", "russian": "Форма"}, "x-description": {"english": "Id of the work-item form used to submit the order.", "russian": "Идентификатор формы, по которой оформлен заказ."}},
    "form_version_id": {"type": "string", "format": "uuid", "x-label": {"english": "Form version", "russian": "Версия формы"}, "x-description": {"english": "Id of the stamped work-item form version.", "russian": "Идентификатор зафиксированной версии формы."}},
    "title": {"type": "string", "x-label": {"english": "Title", "russian": "Заголовок"}, "x-description": {"english": "Short title of the order, up to 500 characters.", "russian": "Краткий заголовок заказа, до 500 символов."}},
    "description": {"type": ["string", "null"], "x-label": {"english": "Description", "russian": "Описание"}, "x-description": {"english": "Plain-text description, up to 4000 characters; null when empty.", "russian": "Описание простым текстом, до 4000 символов; null, если пусто."}},
    "urgency": {"type": "string", "enum": ["low", "medium", "high", "critical"], "x-label": {"english": "Urgency", "russian": "Срочность"}},
    "impact": {"type": ["string", "null"], "enum": ["low", "medium", "high", "critical", null], "x-label": {"english": "Impact", "russian": "Влияние"}},
    "quantity": {"type": ["integer", "null"], "x-label": {"english": "Quantity", "russian": "Количество"}, "x-description": {"english": "Ordered quantity when collected on the form; null otherwise.", "russian": "Заказанное количество, если оно собирается на форме; иначе null."}},
    "watch_list": {"type": ["array", "null"], "items": {"type": "string", "format": "uuid"}, "x-label": {"english": "Watch list", "russian": "Список наблюдателей"}, "x-description": {"english": "Watcher user ids resolved from the form; null when none.", "russian": "Идентификаторы наблюдателей, разрешённые из формы; null, если нет."}},
    "requester_user_id": {"type": "string", "format": "uuid", "x-label": {"english": "Requester", "russian": "Заказчик"}, "x-description": {"english": "Account that placed the order.", "russian": "Учётная запись, оформившая заказ."}},
    "requested_for_user_id": {"type": ["string", "null"], "format": "uuid", "x-label": {"english": "Requested for", "russian": "Получатель"}, "x-description": {"english": "Beneficiary when different from the requester; null means the requester.", "russian": "Получатель, если он отличается от заказчика; null — сам заказчик."}}
  }
}$event_core_schema$::jsonb,
    '{"order_number": "so-00012k", "service_id": "4f6c2a1e-8b3d-4c9a-9e21-7d5b0c3a1f42", "form_id": "5a7b9c1d-3e5f-4a2b-8c4d-6e8f0a2b4c6d", "form_version_id": "6b8c0d2e-4f6a-4b3c-9d5e-7f9a1b3c5d7e", "title": "VPN access for a contractor", "description": "Access is needed until the end of the year.", "urgency": "high", "impact": null, "quantity": null, "watch_list": null, "requester_user_id": "9a1d7c3e-2b4f-4e8a-b6c5-1f0e3d2a7b98", "requested_for_user_id": null}'::jsonb,
    NULL,
    '0.24.4'
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
    'catalog.service_order.submitted',
    'catalog.service_order',
    'submitted',
    'active',
    false,
    false,
    '{"english":"Service order submitted","russian":"Заказ услуги оформлен"}'::jsonb,
    '{"english":"A user submitted an order for a catalog service.","russian":"Пользователь оформил заказ услуги из каталога."}'::jsonb,
    $event_type_description${"english":"Published by the catalog module in the same transaction that inserts the order into app.service_orders. object_id is the order id; object_version is 1.\n\ncore carries the full order snapshot: number, service, form, form version, title, description, urgency, impact, quantity, watch list, requester and beneficiary. custom carries the answers to the admin-defined fields of the stamped form version (form_version_id plus a {key, type, value} list; the list may be empty). Attachments are not part of the event.\n\nThere is no changes block: the order is created, not changed. initiator_user_id is the account that submitted the order.\n\nTypical subscribers: the process engine (start a fulfilment process), notifications, reporting replicas.","russian":"Публикуется модулем catalog в той же транзакции, которая вставляет заказ в app.service_orders. object_id — id заказа; object_version равен 1.\n\ncore содержит полный снимок заказа: номер, услугу, форму, версию формы, заголовок, описание, срочность, влияние, количество, список наблюдателей, заказчика и получателя. custom содержит ответы на поля формы, добавленные администратором, для зафиксированной версии формы (form_version_id и список {key, type, value}; список может быть пустым). Вложения в событие не входят.\n\nБлока changes нет: заказ создаётся, а не изменяется. initiator_user_id — учётная запись, оформившая заказ.\n\nТипичные подписчики: процессный движок (запуск процесса исполнения), уведомления, реплики для отчётов."}$event_type_description$::jsonb,
    '0.24.4'
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

-- app.service_requests.priority: enum labels become SMALLINT 1..5 (1 highest).
-- Re-running on a column that is already SMALLINT keeps 1..5 and nulls anything else.
ALTER TABLE app.service_requests
    ALTER COLUMN priority TYPE SMALLINT
    USING (
        CASE priority::text
            WHEN 'critical' THEN 1
            WHEN 'high' THEN 2
            WHEN 'medium' THEN 3
            WHEN 'low' THEN 4
            WHEN '1' THEN 1
            WHEN '2' THEN 2
            WHEN '3' THEN 3
            WHEN '4' THEN 4
            WHEN '5' THEN 5
            ELSE NULL
        END
    );

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_service_requests_priority_range'
          AND conrelid = 'app.service_requests'::regclass
    ) THEN
        ALTER TABLE app.service_requests
            ADD CONSTRAINT chk_service_requests_priority_range
            CHECK (priority IS NULL OR (priority >= 1 AND priority <= 5));
    END IF;
END $$;

COMMENT ON COLUMN app.service_requests.priority IS 'Priority level (1..5, 1 highest, calculated from impact and urgency via AdminApp.Practices/priority.matrix or set manually).';

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES
-- Practices Settings: 4x4 Impact x Urgency -> Priority (1..5, 1 highest) calculation matrix
('AdminApp.Practices', 'priority.matrix', 'all',
   '{"low":{"low":5,"medium":4,"high":4,"critical":3},"medium":{"low":4,"medium":3,"high":3,"critical":2},"high":{"low":4,"medium":3,"high":2,"critical":2},"critical":{"low":3,"medium":2,"high":2,"critical":1}}'::jsonb,
   '{"type":"object","additionalProperties":false,"required":["low","medium","high","critical"],"properties":{"low":{"type":"object","additionalProperties":false,"required":["low","medium","high","critical"],"properties":{"low":{"type":"integer","minimum":1,"maximum":5},"medium":{"type":"integer","minimum":1,"maximum":5},"high":{"type":"integer","minimum":1,"maximum":5},"critical":{"type":"integer","minimum":1,"maximum":5}}},"medium":{"type":"object","additionalProperties":false,"required":["low","medium","high","critical"],"properties":{"low":{"type":"integer","minimum":1,"maximum":5},"medium":{"type":"integer","minimum":1,"maximum":5},"high":{"type":"integer","minimum":1,"maximum":5},"critical":{"type":"integer","minimum":1,"maximum":5}}},"high":{"type":"object","additionalProperties":false,"required":["low","medium","high","critical"],"properties":{"low":{"type":"integer","minimum":1,"maximum":5},"medium":{"type":"integer","minimum":1,"maximum":5},"high":{"type":"integer","minimum":1,"maximum":5},"critical":{"type":"integer","minimum":1,"maximum":5}}},"critical":{"type":"object","additionalProperties":false,"required":["low","medium","high","critical"],"properties":{"low":{"type":"integer","minimum":1,"maximum":5},"medium":{"type":"integer","minimum":1,"maximum":5},"high":{"type":"integer","minimum":1,"maximum":5},"critical":{"type":"integer","minimum":1,"maximum":5}}}}}'::jsonb,
   '{"low":{"low":5,"medium":4,"high":4,"critical":3},"medium":{"low":4,"medium":3,"high":3,"critical":2},"high":{"low":4,"medium":3,"high":2,"critical":2},"critical":{"low":3,"medium":2,"high":2,"critical":1}}'::jsonb,
   'Priority calculation matrix (Impact x Urgency -> Priority 1..5, where 1 is highest priority). When impact or urgency is null, low is used.',
   false)
ON CONFLICT (section_path, setting_name, environment) DO UPDATE SET
    value = EXCLUDED.value,
    validation_schema = EXCLUDED.validation_schema,
    default_value = EXCLUDED.default_value,
    description = EXCLUDED.description,
    is_public = EXCLUDED.is_public,
    updated_at = CURRENT_TIMESTAMP;

UPDATE app.process_system_procedures
SET input_schema = $psp_in_create$
[
  {
    "key": "title",
    "type": "string",
    "required": true,
    "source": "both",
    "label": {
      "english": "Title",
      "russian": "Заголовок"
    },
    "description": {
      "english": "Short title of the service request.",
      "russian": "Краткий заголовок сервисного запроса."
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
      "english": "Detailed description of the request.",
      "russian": "Подробное описание запроса."
    }
  },
  {
    "key": "urgency",
    "type": "enum",
    "required": true,
    "source": "both",
    "enum": [
      "low",
      "medium",
      "high",
      "critical"
    ],
    "label": {
      "english": "Urgency",
      "russian": "Срочность"
    },
    "description": {
      "english": "Urgency level.",
      "russian": "Уровень срочности."
    }
  },
  {
    "key": "impact",
    "type": "enum",
    "required": false,
    "source": "both",
    "enum": [
      "low",
      "medium",
      "high",
      "critical"
    ],
    "label": {
      "english": "Impact",
      "russian": "Влияние"
    },
    "description": {
      "english": "Impact level.",
      "russian": "Уровень влияния."
    }
  },
  {
    "key": "priority",
    "type": "enum",
    "required": false,
    "source": "both",
    "enum": [
      "calculated",
      "1",
      "2",
      "3",
      "4",
      "5"
    ],
    "label": {
      "english": "Priority",
      "russian": "Приоритет"
    },
    "description": {
      "english": "Priority level.",
      "russian": "Уровень приоритета."
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
      "english": "Initial support group, account, or participant.",
      "russian": "Начальная группа поддержки, учётная запись или участник."
    }
  }
]
$psp_in_create$::jsonb
WHERE procedure_key = 'work.service_request.create';

UPDATE app.process_system_procedures
SET input_schema = $psp_in_update$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target service request ID",
      "russian": "ID целевого сервисного запроса"
    },
    "description": {
      "english": "UUID of the service request to update (from process context).",
      "russian": "UUID обновляемого сервисного запроса (из контекста процесса)."
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
      "resolved",
      "reopened",
      "closed",
      "cancelled",
      "failed"
    ],
    "label": {
      "english": "Status",
      "russian": "Статус"
    },
    "description": {
      "english": "New lifecycle status.",
      "russian": "Новый статус жизненного цикла."
    }
  },
  {
    "key": "approval_status",
    "type": "enum",
    "required": false,
    "source": "both",
    "enum": [
      "not_required",
      "pending",
      "approved",
      "auto_approved",
      "rejected",
      "auto_rejected",
      "cancelled"
    ],
    "label": {
      "english": "Approval status",
      "russian": "Статус согласования"
    },
    "description": {
      "english": "New approval outcome status.",
      "russian": "Новый статус согласования."
    }
  },
  {
    "key": "priority",
    "type": "enum",
    "required": false,
    "source": "both",
    "enum": [
      "1",
      "2",
      "3",
      "4",
      "5"
    ],
    "label": {
      "english": "Priority",
      "russian": "Приоритет"
    },
    "description": {
      "english": "Updated priority.",
      "russian": "Обновлённый приоритет."
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
    "key": "work_notes",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Work notes",
      "russian": "Рабочие заметки"
    },
    "description": {
      "english": "Internal support note to record.",
      "russian": "Внутренняя рабочая заметка поддержки."
    }
  }
]
$psp_in_update$::jsonb
WHERE procedure_key = 'work.service_request.update';

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.24.6',
        'Renamed pricing permission keys from adminPricing to referencePricing and role names from role.adminPricing.* to role.referencePricing.*. Membership stays on group_id. Renamed app_settings section_path prefix AdminPricing to ReferencePricing when present. Renamed AdminProducts / AdminCatalog app_settings.section_path prefixes to AdminApp.Products / AdminApp.Catalog. Renamed AdminServices / AdminForms app_settings.section_path prefixes to AdminApp.Services / AdminApp.Forms. Added work_item_kind organization and updated app.organizations to the regional core/custom schema (region_id, address, answers) with one organization form per region on app.work_item_forms. Updated catalog.service_order schema version 1 with form_id, form_version_id, quantity, and watch_list. Converted app.service_requests.priority to SMALLINT (1..5, 1 highest) with chk_service_requests_priority_range. Seeded AdminApp.Practices/priority.matrix. Updated the input_schema priority enum of work.service_request.create and work.service_request.update.'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.24.6', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

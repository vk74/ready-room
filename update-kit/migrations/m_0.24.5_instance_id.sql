-- Version: 0.24.5
-- Description: Rename app.instance.evi_instance_id to instance_id, rename app.process_instances.variables to context, rename the leftover NOT NULL constraints to the default names for the new columns, replace the protect trigger, drop the product name from the seed admin email, the updates permission description, and the email From display-name description, add 'paused' to app.process_version_status, update app.tgr_processes_validate_current_version, rewrite user agreement version EVI_ELv2 to pre-mvp-notice, and remove the license key from preferences.lastLocations.
-- Backend file: m_0.24.5_instance_id.sql
--
-- Changes in v0.24.5:
-- - Rename app.instance.evi_instance_id to instance_id when the old column exists and instance_id does not. The UUID value stays with the column.
-- - Replace function app.tgr_instance_protect_instance_id and trigger tgr_instance_protect_instance_id. The function body matches db/init/02_schema.sql.
-- - Set the seed admin email to admin@example.com only when it is still admin@evi.team.
-- - Set the system:updates:access description. The permission key is unchanged.
-- - Set the Application.Notifications.Email from.display.name description. Value and default_value are not written.
-- - Rename app.process_instances.variables to context and chk_process_instances_variables_object to chk_process_instances_context_object. The JSON object stays with the column. The column comment matches db/init/05_tables.sql.
-- - Rename leftover NOT NULL constraints that RENAME COLUMN does not rewrite: instance_evi_instance_id_not_null to instance_instance_id_not_null, and process_instances_variables_not_null to process_instances_context_not_null. Each rename runs only when the old name exists and the new name does not.
-- - Add 'paused' to app.process_version_status before 'retired'. Re-issue the type comment, the current_version_id comment, the process_versions table and status comments, and replace app.tgr_processes_validate_current_version so a current version may be active or paused. Those statements match db/init.
-- - Create app.participants, function app.prevent_system_participant_deletion, and trigger tgr_participants_prevent_system_delete, and seed the system participants. The table, comments, function, trigger, and rows match db/init.
-- - State the same three-paragraph english and russian description on each
--   seeded participant as db/init/08_system_entities.sql.
-- - Rewrite user_agreement_version from EVI_ELv2 to pre-mvp-notice and remove the license key from preferences.lastLocations. Leave user_agreement_accepted and user_agreement_acceptance_time unchanged.
-- - Create app.process_system_procedures, function app.prevent_process_system_procedure_deletion, and trigger tgr_process_system_procedures_prevent_system_delete, and seed the 20 system procedures. The table, comments, function, trigger, and rows match db/init.
-- - Create app.process_external_procedures, function app.prevent_process_external_procedure_deletion, and trigger tgr_process_external_procedures_prevent_system_delete, and seed the 5 external webhook procedures. The table, comments, function, trigger, and rows match db/init.
--
-- Destructive-affects: COLUMN app.instance.evi_instance_id, COLUMN app.process_instances.variables
-- Destructive-data-loss: none; the UUID moves with the rename to instance_id; the JSON object moves with the rename to context

BEGIN;

-- Rename only when the old column is still present and instance_id is not.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'instance'
          AND column_name = 'evi_instance_id'
    ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'instance'
          AND column_name = 'instance_id'
    ) THEN
        ALTER TABLE app.instance RENAME COLUMN evi_instance_id TO instance_id;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'instance_evi_instance_id_not_null'
          AND conrelid = 'app.instance'::regclass
    ) AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'instance_instance_id_not_null'
          AND conrelid = 'app.instance'::regclass
    ) THEN
        ALTER TABLE app.instance
            RENAME CONSTRAINT instance_evi_instance_id_not_null TO instance_instance_id_not_null;
    END IF;
END $$;

DROP TRIGGER IF EXISTS tgr_instance_protect_evi_instance_id ON app.instance;
DROP FUNCTION IF EXISTS app.tgr_instance_protect_evi_instance_id();

DROP TRIGGER IF EXISTS tgr_instance_protect_instance_id ON app.instance;

CREATE OR REPLACE FUNCTION app.tgr_instance_protect_instance_id()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.instance_id IS DISTINCT FROM NEW.instance_id THEN
    RAISE EXCEPTION 'instance_id must not be changed after installation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER tgr_instance_protect_instance_id
  BEFORE UPDATE ON app.instance
  FOR EACH ROW
  EXECUTE FUNCTION app.tgr_instance_protect_instance_id();

UPDATE app.users_standard_profiles SET email = 'admin@example.com' WHERE user_id = '550e8400-e29b-41d4-a716-446655440001' AND email = 'admin@evi.team';

UPDATE app.permissions
SET description = 'Access to check platform updates in navigation'
WHERE permission_key = 'system:updates:access';

UPDATE app.app_settings
SET description = 'Display name shown in the From header (e.g. "notifications")',
    updated_at = CURRENT_TIMESTAMP
WHERE section_path = 'Application.Notifications.Email'
  AND setting_name = 'from.display.name'
  AND environment = 'all';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'process_instances'
          AND column_name = 'variables'
    ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'app'
          AND table_name = 'process_instances'
          AND column_name = 'context'
    ) THEN
        ALTER TABLE app.process_instances RENAME COLUMN variables TO context;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_process_instances_variables_object'
          AND conrelid = 'app.process_instances'::regclass
    ) AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_process_instances_context_object'
          AND conrelid = 'app.process_instances'::regclass
    ) THEN
        ALTER TABLE app.process_instances
            RENAME CONSTRAINT chk_process_instances_variables_object TO chk_process_instances_context_object;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'process_instances_variables_not_null'
          AND conrelid = 'app.process_instances'::regclass
    ) AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'process_instances_context_not_null'
          AND conrelid = 'app.process_instances'::regclass
    ) THEN
        ALTER TABLE app.process_instances
            RENAME CONSTRAINT process_instances_variables_not_null TO process_instances_context_not_null;
    END IF;
END $$;

COMMENT ON COLUMN app.process_instances.context IS
    'Process context as a JSON object. Must be a JSON object.';

ALTER TYPE app.process_version_status ADD VALUE IF NOT EXISTS 'paused' BEFORE 'retired';

COMMENT ON TYPE app.process_version_status IS
    'Lifecycle of one process definition version: draft (editable), active (frozen; new instances start here), paused (frozen; current version is on hold and new instances cannot start), retired (frozen; keeps serving instances already stamped on it).';

COMMENT ON COLUMN app.processes.current_version_id IS
    'Current version (active or paused). New instances start from it only when its status is active. NULL while the process has only drafts.';

COMMENT ON TABLE app.process_versions IS
    'One version of a process definition. Draft is editable; active, paused, and retired are frozen by tgr_frozen_version_immutable. Retired versions keep serving instances already stamped on them.';

COMMENT ON COLUMN app.process_versions.status IS
    'Lifecycle: draft (editable), active (frozen; new instances start here), paused (frozen; current version is on hold), retired (frozen).';

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

    IF v_status::text NOT IN ('active', 'paused') THEN
        RAISE EXCEPTION 'process %: current version % must be active or paused (is %)', NEW.id, NEW.current_version_id, v_status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.tgr_processes_validate_current_version() IS
    'BEFORE INSERT OR UPDATE OF current_version_id on app.processes. NULL is allowed; otherwise the version must exist, belong to the same process, and have status active or paused.';

-- ===========================================================================
-- System participants catalog (activity and routing assignees)
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.participants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    participant_key VARCHAR(64) NOT NULL,
    entity_kind     VARCHAR(32) NOT NULL,
    resolution_kind VARCHAR(32) NOT NULL,
    name            JSONB NOT NULL,
    description     JSONB NOT NULL,
    is_system       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_participants_key
        UNIQUE (participant_key),
    CONSTRAINT chk_participants_key_format
        CHECK (participant_key ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_participants_entity_kind
        CHECK (entity_kind IN ('order', 'service', 'product', 'catalog', 'process')),
    CONSTRAINT chk_participants_resolution_kind
        CHECK (resolution_kind IN ('user', 'group', 'mixed')),
    CONSTRAINT chk_participants_name_localized
        CHECK (app.is_localized_text(name)),
    CONSTRAINT chk_participants_description_localized
        CHECK (app.is_localized_text(description))
);

COMMENT ON TABLE app.participants IS
    'Catalog of symbolic participants (owners, coordinators, support tiers, specialists, requester, recipient, initiator) used as dynamic assignees in process steps and work routing. System rows (is_system = true) are protected from deletion by tgr_participants_prevent_system_delete.';
COMMENT ON COLUMN app.participants.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT or seeded deterministically.';
COMMENT ON COLUMN app.participants.participant_key IS
    'Stable symbolic key in <entity_kind>.<name> format (e.g. service.owner, product.specialists, order.requester). Unique.';
COMMENT ON COLUMN app.participants.entity_kind IS
    'Subject category the participant belongs to: order, service, product, catalog, or process.';
COMMENT ON COLUMN app.participants.resolution_kind IS
    'What principal kind this participant resolves to at runtime: user (standard or bot account), group, or mixed (both groups and user/bot accounts, e.g. product.specialists).';
COMMENT ON COLUMN app.participants.name IS
    'Localized display name. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.participants.description IS
    'Localized description of how the participant is resolved and its fallback rule. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.participants.is_system IS
    'True for platform-seeded participants that cannot be deleted.';
COMMENT ON COLUMN app.participants.created_at IS
    'Row creation timestamp.';

CREATE OR REPLACE FUNCTION app.prevent_system_participant_deletion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_system = true THEN
        RAISE EXCEPTION 'system participant % cannot be deleted', OLD.participant_key
            USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION app.prevent_system_participant_deletion() IS
    'BEFORE DELETE row guard for app.participants. Raises object_not_in_prerequisite_state (55000) when is_system is true.';

DROP TRIGGER IF EXISTS tgr_participants_prevent_system_delete ON app.participants;

CREATE TRIGGER tgr_participants_prevent_system_delete
BEFORE DELETE ON app.participants
FOR EACH ROW EXECUTE FUNCTION app.prevent_system_participant_deletion();

-- System participants seed (24 rows across order, service, product, catalog, process).
INSERT INTO app.participants (
    id, participant_key, entity_kind, resolution_kind, name, description, is_system
) VALUES
(
    '880e8400-e29b-41d4-a716-446655440001',
    'order.requester',
    'order',
    'user',
    '{"english":"Order requester","russian":"Заказчик"}'::jsonb,
    $pdesc${"english":"The order requester is the account that submitted the service order or the service request. Assign a manual task, an approval, or an acceptance to this participant when the step must be done by the account that raised the work, for example to confirm the request details or to accept the result.\n\nThe engine resolves one user account (standard or bot). When the subject is a service order it reads app.service_orders.requester_user_id. When the subject is a service request it reads app.service_requests.requester_user_id. When the instance was started by catalog.service_order.submitted, that order's requester is the start-event context field core.requester_user_id.\n\nrequester_user_id is required on the order, on the request, and on the service-order start event, so a stored order or request always resolves to an account. When the running instance has neither a service order nor a service request, the participant does not resolve.","russian":"Заказчик — учётная запись, оформившая заказ услуги или заявку. Назначайте этому участнику ручную задачу, согласование или приёмку, когда шаг должна выполнить учётная запись, которая инициировала работу: например, подтвердить сведения обращения или принять результат.\n\nДвижок разрешает одну учётную запись (standard или bot). Если предмет — заказ услуги, он читает app.service_orders.requester_user_id. Если предмет — заявка, он читает app.service_requests.requester_user_id. Если экземпляр запущен событием catalog.service_order.submitted, заказчик этого заказа — поле контекста стартового события core.requester_user_id.\n\nrequester_user_id обязателен и в заказе, и в заявке, и в стартовом событии заказа, поэтому сохранённый заказ или заявка всегда разрешаются в учётную запись. Если у выполняемого экземпляра нет ни заказа услуги, ни заявки, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440002',
    'order.requester_manager',
    'order',
    'user',
    '{"english":"Order requester manager","russian":"Руководитель заказчика"}'::jsonb,
    $pdesc${"english":"The requester manager is the direct line manager of the account that submitted the order or the service request. Assign an approval to this participant when that manager must authorize the work before it proceeds. This is the usual line-manager approval.\n\nThe engine first resolves the requester: app.service_orders.requester_user_id, or app.service_requests.requester_user_id, or the start-event context field core.requester_user_id of catalog.service_order.submitted. It then reads app.users_standard_profiles.manager_user_id for that account and resolves that user account.\n\nWhen the requester has no row in app.users_standard_profiles, as a bot does, or when manager_user_id is null, the participant does not resolve. A requester whose standard profile has a manager resolves to that one account. There is no further fallback.","russian":"Руководитель заказчика — непосредственный руководитель учётной записи, оформившей заказ или заявку. Назначайте этому участнику согласование, когда этот руководитель должен разрешить работу, прежде чем она пойдёт дальше. Это обычное согласование линейным руководителем.\n\nДвижок сначала разрешает заказчика: app.service_orders.requester_user_id, либо app.service_requests.requester_user_id, либо поле контекста стартового события core.requester_user_id события catalog.service_order.submitted. Затем он читает app.users_standard_profiles.manager_user_id этой учётной записи и разрешает её.\n\nЕсли у заказчика нет строки в app.users_standard_profiles, как у бота, или manager_user_id равен null, участник не разрешается. Заказчик, в стандартном профиле которого указан руководитель, разрешается в эту одну учётную запись. Дальнейшего запасного разрешения нет."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440003',
    'order.requested_for',
    'order',
    'user',
    '{"english":"Order recipient","russian":"Получатель заказа"}'::jsonb,
    $pdesc${"english":"The order recipient is the beneficiary the order or the service request was placed for, when that account is different from the requester. Assign a manual task or an acceptance to this participant when the account that will receive the service must act, for example to confirm that the result was delivered.\n\nThe engine reads requested_for_user_id. On a service order that column is app.service_orders.requested_for_user_id, and on a service-order start it is also the start-event context field core.requested_for_user_id of catalog.service_order.submitted. On a service request the column is app.service_requests.requested_for_user_id. A non-null value resolves to that one user account (standard or bot).\n\nWhen requested_for_user_id is null, the beneficiary is the requester, and this participant falls back to order.requester. When the running instance has neither a service order nor a service request, the participant does not resolve.","russian":"Получатель заказа — учётная запись, для которой оформили заказ или заявку, если она отличается от заказчика. Назначайте этому участнику ручную задачу или приёмку, когда должна действовать учётная запись, которая получит услугу: например, подтвердить, что результат передан.\n\nДвижок читает requested_for_user_id. У заказа услуги это колонка app.service_orders.requested_for_user_id, а при старте по заказу — ещё и поле контекста стартового события core.requested_for_user_id события catalog.service_order.submitted. У заявки это колонка app.service_requests.requested_for_user_id. Непустое значение разрешается в одну учётную запись (standard или bot).\n\nКогда requested_for_user_id равен null, получатель совпадает с заказчиком, и этот участник переходит к order.requester. Если у выполняемого экземпляра нет ни заказа услуги, ни заявки, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440004',
    'order.requested_for_manager',
    'order',
    'user',
    '{"english":"Order recipient manager","russian":"Руководитель получателя"}'::jsonb,
    $pdesc${"english":"The recipient manager is the direct line manager of the beneficiary. Assign an approval to this participant when the manager of the account that will receive the service must authorize work done for that account.\n\nThe engine resolves the recipient from app.service_orders.requested_for_user_id, from the start-event context field core.requested_for_user_id of catalog.service_order.submitted, or from app.service_requests.requested_for_user_id. It then reads app.users_standard_profiles.manager_user_id for that account.\n\nWhen requested_for_user_id is null, the recipient is the requester, so this participant falls back to order.requester_manager. When the recipient is set and that account has no row in app.users_standard_profiles, or manager_user_id is null, the participant does not resolve.","russian":"Руководитель получателя — непосредственный руководитель учётной записи, для которой оформлена работа. Назначайте этому участнику согласование, когда руководитель получателя услуги должен разрешить работу, выполняемую для этой учётной записи.\n\nДвижок разрешает получателя по app.service_orders.requested_for_user_id, по полю контекста стартового события core.requested_for_user_id события catalog.service_order.submitted или по app.service_requests.requested_for_user_id. Затем он читает app.users_standard_profiles.manager_user_id этой учётной записи.\n\nКогда requested_for_user_id равен null, получатель совпадает с заказчиком, поэтому этот участник переходит к order.requester_manager. Если получатель указан, но у него нет строки в app.users_standard_profiles или manager_user_id равен null, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440005',
    'order.assigned_user',
    'order',
    'user',
    '{"english":"Assigned request specialist","russian":"Текущий исполнитель заявки"}'::jsonb,
    $pdesc${"english":"The assigned request specialist is the account currently responsible for the service request. Assign the next manual task, approval, or acceptance to this participant when the step must be done by the account that is already working the request.\n\nThe engine reads app.service_requests.assigned_user_id on the service request that is the subject of the running instance and resolves that user account (standard or bot). The column is not on app.service_orders and is not a field of the catalog.service_order.submitted start event.\n\nassigned_user_id is optional. When it is null, the participant does not resolve. When the running instance has no service request, the participant does not resolve.","russian":"Текущий исполнитель заявки — учётная запись, на которой сейчас лежит заявка. Назначайте этому участнику следующую ручную задачу, согласование или приёмку, когда шаг должна выполнить учётная запись, которая уже ведёт заявку.\n\nДвижок читает app.service_requests.assigned_user_id у заявки, которая является предметом выполняемого экземпляра, и разрешает эту учётную запись (standard или bot). Колонки нет в app.service_orders, и её нет среди полей стартового события catalog.service_order.submitted.\n\nassigned_user_id необязателен. Когда он равен null, участник не разрешается. Если у выполняемого экземпляра нет заявки, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440006',
    'order.assigned_group',
    'order',
    'group',
    '{"english":"Assigned request group","russian":"Текущая группа заявки"}'::jsonb,
    $pdesc${"english":"The assigned request group is the support group currently responsible for the service request. Assign a manual task to this participant when any member of the group that holds the request may take the step.\n\nThe engine reads app.service_requests.assigned_group_id on the service request that is the subject of the running instance and resolves that row in app.groups. The column is not on app.service_orders and is not a field of the catalog.service_order.submitted start event.\n\nassigned_group_id is optional. When it is null, the participant does not resolve. When the running instance has no service request, the participant does not resolve.","russian":"Текущая группа заявки — группа поддержки, за которой сейчас закреплена заявка. Назначайте этому участнику ручную задачу, когда шаг может взять любой член группы, которая ведёт заявку.\n\nДвижок читает app.service_requests.assigned_group_id у заявки, которая является предметом выполняемого экземпляра, и разрешает эту строку в app.groups. Колонки нет в app.service_orders, и её нет среди полей стартового события catalog.service_order.submitted.\n\nassigned_group_id необязателен. Когда он равен null, участник не разрешается. Если у выполняемого экземпляра нет заявки, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440007',
    'order.assigned_group_owner',
    'order',
    'user',
    '{"english":"Assigned request group owner","russian":"Руководитель текущей группы заявки"}'::jsonb,
    $pdesc${"english":"The assigned request group owner is the owner of the support group currently responsible for the service request. Assign an escalation or an approval to this participant when the owner of that group must act on the request.\n\nThe engine reads app.service_requests.assigned_group_id on the service request that is the subject of the running instance, then reads app.groups.group_owner for that group, and resolves that user account.\n\nWhen assigned_group_id is null, or the running instance has no service request, the participant does not resolve. When a group is set, app.groups.group_owner is required, so the owner account is present.","russian":"Руководитель текущей группы заявки — владелец группы поддержки, за которой сейчас закреплена заявка. Назначайте этому участнику эскалацию или согласование, когда по заявке должен действовать владелец этой группы.\n\nДвижок читает app.service_requests.assigned_group_id у заявки, которая является предметом выполняемого экземпляра, затем читает app.groups.group_owner этой группы и разрешает эту учётную запись.\n\nКогда assigned_group_id равен null или у выполняемого экземпляра нет заявки, участник не разрешается. Если группа указана, app.groups.group_owner обязателен, поэтому учётная запись владельца есть."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440008',
    'service.owner',
    'service',
    'user',
    '{"english":"Service owner","russian":"Владелец услуги"}'::jsonb,
    $pdesc${"english":"The service owner is the accountable owner of the catalog service that was ordered or requested. Assign an approval or an exception decision to this participant when the service owner must accept a change of scope, a cost, or a deviation from the usual fulfilment.\n\nThe engine takes the service id of the running instance from the start-event context field core.service_id of catalog.service_order.submitted, or app.service_orders.service_id, or app.service_requests.service_id. It then reads app.services.owner_user_id and resolves that user account (standard or bot).\n\nowner_user_id is required on app.services, so a stored service always resolves to one account. When the running instance has no service, the participant does not resolve.","russian":"Владелец услуги — ответственный владелец услуги каталога, которую заказали или по которой создали заявку. Назначайте этому участнику согласование или решение об исключении, когда владелец услуги должен принять изменение объёма, стоимость или отклонение от обычного исполнения.\n\nДвижок берёт идентификатор услуги выполняемого экземпляра: поле контекста стартового события core.service_id события catalog.service_order.submitted, либо app.service_orders.service_id, либо app.service_requests.service_id. Затем он читает app.services.owner_user_id и разрешает эту учётную запись (standard или bot).\n\nowner_user_id обязателен в app.services, поэтому сохранённая услуга всегда разрешается в одну учётную запись. Если у выполняемого экземпляра нет услуги, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440009',
    'service.technical_owner',
    'service',
    'user',
    '{"english":"Service technical owner","russian":"Технический владелец услуги"}'::jsonb,
    $pdesc${"english":"The service technical owner is the account accountable for how the ordered service is delivered technically. Assign a manual task or an approval to this participant when the step needs a technical decision or an implementation that the service owner does not perform.\n\nThe engine takes the service id of the running instance from the start-event context field core.service_id of catalog.service_order.submitted, or app.service_orders.service_id, or app.service_requests.service_id. It then reads app.service_users.user_id on rows with that service_id and role_type technical_owner. Each user_id is a standard or bot account.\n\nSeveral accounts may hold role_type technical_owner on one service, and every matching row is part of the resolution. When no such row exists, the participant does not resolve. When the running instance has no service, the participant does not resolve.","russian":"Технический владелец услуги — учётная запись, отвечающая за то, как заказанная услуга устроена и поставляется технически. Назначайте этому участнику ручную задачу или согласование, когда шагу нужно техническое решение или реализация, которую владелец услуги не выполняет.\n\nДвижок берёт идентификатор услуги выполняемого экземпляра: поле контекста стартового события core.service_id события catalog.service_order.submitted, либо app.service_orders.service_id, либо app.service_requests.service_id. Затем он читает app.service_users.user_id у строк с этим service_id и role_type technical_owner. Каждый user_id — учётная запись standard или bot.\n\nРоль technical_owner на одной услуге могут иметь несколько учётных записей, и каждая подходящая строка входит в разрешение. Если такой строки нет, участник не разрешается. Если у выполняемого экземпляра нет услуги, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440010',
    'service.dispatcher',
    'service',
    'user',
    '{"english":"Service dispatcher","russian":"Координатор услуги"}'::jsonb,
    $pdesc${"english":"The service dispatcher is the coordinator of the ordered service. Assign the first triage or routing task to this participant when an account must classify the request and send it to the right line of support.\n\nThe engine takes the service id of the running instance from the start-event context field core.service_id of catalog.service_order.submitted, or app.service_orders.service_id, or app.service_requests.service_id. It then reads app.service_users.user_id on rows with that service_id and role_type dispatcher. Each user_id is a standard or bot account.\n\nSeveral accounts may hold role_type dispatcher on one service, and every matching row is part of the resolution. When no such row exists, the participant does not resolve. When the running instance has no service, the participant does not resolve.","russian":"Координатор услуги — диспетчер заказанной услуги. Назначайте этому участнику первую задачу разбора или маршрутизации, когда учётная запись должна классифицировать обращение и направить его на нужную линию поддержки.\n\nДвижок берёт идентификатор услуги выполняемого экземпляра: поле контекста стартового события core.service_id события catalog.service_order.submitted, либо app.service_orders.service_id, либо app.service_requests.service_id. Затем он читает app.service_users.user_id у строк с этим service_id и role_type dispatcher. Каждый user_id — учётная запись standard или bot.\n\nРоль dispatcher на одной услуге могут иметь несколько учётных записей, и каждая подходящая строка входит в разрешение. Если такой строки нет, участник не разрешается. Если у выполняемого экземпляра нет услуги, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440011',
    'service.form_owner',
    'service',
    'user',
    '{"english":"Service form owner","russian":"Владелец формы обращения"}'::jsonb,
    $pdesc${"english":"The service form owner is the accountable owner of the work-item form used to submit the order or the service request. Assign a task to this participant when the step is about that form, such as a missing question or a clarification of what the form asked.\n\nThe engine reads form_version_id from app.service_orders or from app.service_requests, follows it to app.work_item_form_versions.form_id, and reads app.work_item_forms.owner_user_id. That value is one user account (standard or bot).\n\nform_version_id is required on the order and on the request, and owner_user_id is required on the form, so a stored order or request always resolves to the form owner. When the running instance has neither a service order nor a service request, the participant does not resolve.","russian":"Владелец формы обращения — ответственный владелец формы рабочего элемента, по которой оформили заказ или заявку. Назначайте этому участнику задачу, когда шаг касается этой формы: не хватает вопроса или нужно пояснить, что форма спрашивала.\n\nДвижок читает form_version_id из app.service_orders или из app.service_requests, переходит по нему к app.work_item_form_versions.form_id и читает app.work_item_forms.owner_user_id. Значение — одна учётная запись (standard или bot).\n\nform_version_id обязателен и в заказе, и в заявке, а owner_user_id обязателен у формы, поэтому сохранённый заказ или заявка всегда разрешаются во владельца формы. Если у выполняемого экземпляра нет ни заказа услуги, ни заявки, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440012',
    'service.support_tier1',
    'service',
    'group',
    '{"english":"Service support (tier 1)","russian":"Группа поддержки 1-й линии"}'::jsonb,
    $pdesc${"english":"The first-line support group is the support group of the ordered service that handles first-line fulfilment. Assign a manual task to this participant when that line of support for the service should do the work.\n\nThe engine takes the service id of the running instance from the start-event context field core.service_id of catalog.service_order.submitted, or app.service_orders.service_id, or app.service_requests.service_id. It then reads app.service_groups.group_id on rows with that service_id and role_type support_tier1, and resolves each group_id to a row in app.groups.\n\nSeveral groups may hold role_type support_tier1 on one service, and every matching row is part of the resolution. When no group is assigned to support_tier1, the participant does not resolve. The engine does not substitute another support tier. When the running instance has no service, the participant does not resolve.","russian":"Группа поддержки первой линии — группа поддержки заказанной услуги, которая выполняет работу первой линии. Назначайте этому участнику ручную задачу, когда работу должна сделать эта линия поддержки услуги.\n\nДвижок берёт идентификатор услуги выполняемого экземпляра: поле контекста стартового события core.service_id события catalog.service_order.submitted, либо app.service_orders.service_id, либо app.service_requests.service_id. Затем он читает app.service_groups.group_id у строк с этим service_id и role_type support_tier1 и разрешает каждый group_id в строку app.groups.\n\nРоль support_tier1 на одной услуге могут иметь несколько групп, и каждая подходящая строка входит в разрешение. Если ни одна группа не назначена на support_tier1, участник не разрешается. Движок не подставляет другую линию поддержки. Если у выполняемого экземпляра нет услуги, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440013',
    'service.support_tier2',
    'service',
    'group',
    '{"english":"Service support (tier 2)","russian":"Группа поддержки 2-й линии"}'::jsonb,
    $pdesc${"english":"The second-line support group is the support group of the ordered service that handles second-line fulfilment. Assign a manual task to this participant when that line of support for the service should do the work.\n\nThe engine takes the service id of the running instance from the start-event context field core.service_id of catalog.service_order.submitted, or app.service_orders.service_id, or app.service_requests.service_id. It then reads app.service_groups.group_id on rows with that service_id and role_type support_tier2, and resolves each group_id to a row in app.groups.\n\nSeveral groups may hold role_type support_tier2 on one service, and every matching row is part of the resolution. When no group is assigned to support_tier2, the participant does not resolve. The engine does not substitute another support tier. When the running instance has no service, the participant does not resolve.","russian":"Группа поддержки второй линии — группа поддержки заказанной услуги, которая выполняет работу второй линии. Назначайте этому участнику ручную задачу, когда работу должна сделать эта линия поддержки услуги.\n\nДвижок берёт идентификатор услуги выполняемого экземпляра: поле контекста стартового события core.service_id события catalog.service_order.submitted, либо app.service_orders.service_id, либо app.service_requests.service_id. Затем он читает app.service_groups.group_id у строк с этим service_id и role_type support_tier2 и разрешает каждый group_id в строку app.groups.\n\nРоль support_tier2 на одной услуге могут иметь несколько групп, и каждая подходящая строка входит в разрешение. Если ни одна группа не назначена на support_tier2, участник не разрешается. Движок не подставляет другую линию поддержки. Если у выполняемого экземпляра нет услуги, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440014',
    'service.support_tier3',
    'service',
    'group',
    '{"english":"Service support (tier 3)","russian":"Группа поддержки 3-й линии"}'::jsonb,
    $pdesc${"english":"The third-line support group is the support group of the ordered service that handles third-line fulfilment. Assign a manual task to this participant when that line of support for the service should do the work.\n\nThe engine takes the service id of the running instance from the start-event context field core.service_id of catalog.service_order.submitted, or app.service_orders.service_id, or app.service_requests.service_id. It then reads app.service_groups.group_id on rows with that service_id and role_type support_tier3, and resolves each group_id to a row in app.groups.\n\nSeveral groups may hold role_type support_tier3 on one service, and every matching row is part of the resolution. When no group is assigned to support_tier3, the participant does not resolve. The engine does not substitute another support tier. When the running instance has no service, the participant does not resolve.","russian":"Группа поддержки третьей линии — группа поддержки заказанной услуги, которая выполняет работу третьей линии. Назначайте этому участнику ручную задачу, когда работу должна сделать эта линия поддержки услуги.\n\nДвижок берёт идентификатор услуги выполняемого экземпляра: поле контекста стартового события core.service_id события catalog.service_order.submitted, либо app.service_orders.service_id, либо app.service_requests.service_id. Затем он читает app.service_groups.group_id у строк с этим service_id и role_type support_tier3 и разрешает каждый group_id в строку app.groups.\n\nРоль support_tier3 на одной услуге могут иметь несколько групп, и каждая подходящая строка входит в разрешение. Если ни одна группа не назначена на support_tier3, участник не разрешается. Движок не подставляет другую линию поддержки. Если у выполняемого экземпляра нет услуги, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440015',
    'product.owner',
    'product',
    'user',
    '{"english":"Product owner","russian":"Владелец продукта"}'::jsonb,
    $pdesc${"english":"The product owner is the accountable owner of the product. Assign an approval or a product decision to this participant when the step must be taken by the account that owns the product, so the same process can serve many products.\n\nThe engine takes the product that is the subject of the running instance, app.products.product_id. It then reads app.product_users.user_id on rows with that product_id and role_type owner. Each user_id is a standard or bot account. app.products has no owner column; the owner is stored only in app.product_users.\n\nSeveral accounts may hold role_type owner on one product, and every matching row is part of the resolution. When no owner row exists, the participant does not resolve. When the running instance has no product, the participant does not resolve.","russian":"Владелец продукта — ответственный владелец продукта. Назначайте этому участнику согласование или продуктовое решение, когда шаг должна выполнить учётная запись, которая владеет продуктом, чтобы один и тот же процесс обслуживал много продуктов.\n\nДвижок берёт продукт, который является предметом выполняемого экземпляра, app.products.product_id. Затем он читает app.product_users.user_id у строк с этим product_id и role_type owner. Каждый user_id — учётная запись standard или bot. В app.products нет колонки владельца; владелец хранится только в app.product_users.\n\nРоль owner на одном продукте могут иметь несколько учётных записей, и каждая подходящая строка входит в разрешение. Если строки владельца нет, участник не разрешается. Если у выполняемого экземпляра нет продукта, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440016',
    'product.line_owner',
    'product',
    'user',
    '{"english":"Product line owner","russian":"Владелец продуктовой линейки"}'::jsonb,
    $pdesc${"english":"The product line owner is the owner of the product line that contains the product. Assign an approval to this participant when the decision sits at line level, such as an exception that applies to the whole line.\n\nThe engine takes the subject product, app.products.product_id, reads app.product_line_products.line_id for that product, then reads app.product_line_users.user_id on rows with that line_id and role_type owner. Each user_id is a standard or bot account.\n\nA product belongs to at most one product line. When it has no row in app.product_line_products, the participant does not resolve. When the line has no owner row, the participant does not resolve. Several accounts may hold role_type owner on one line, and every matching row is part of the resolution.","russian":"Владелец продуктовой линейки — владелец линейки, в которую входит продукт. Назначайте этому участнику согласование, когда решение принимается на уровне линейки, например исключение, которое действует на всю линейку.\n\nДвижок берёт продукт-предмет, app.products.product_id, читает app.product_line_products.line_id этого продукта, затем читает app.product_line_users.user_id у строк с этим line_id и role_type owner. Каждый user_id — учётная запись standard или bot.\n\nПродукт входит не более чем в одну продуктовую линейку. Если у него нет строки в app.product_line_products, участник не разрешается. Если у линейки нет строки владельца, участник не разрешается. Роль owner на одной линейке могут иметь несколько учётных записей, и каждая подходящая строка входит в разрешение."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440017',
    'product.specialist_groups',
    'product',
    'group',
    '{"english":"Product specialist groups","russian":"Группы специалистов продукта"}'::jsonb,
    $pdesc${"english":"The product specialist groups are the groups assigned to deliver and support the product. Assign a manual task to this participant when any specialist group of the product may perform the work.\n\nThe engine takes the subject product, app.products.product_id, and reads app.product_groups.group_id on rows with that product_id and role_type product_specialists. Each group_id resolves to a row in app.groups.\n\nSeveral groups may hold the role, and every matching row is part of the resolution. When no specialist group is assigned, the participant does not resolve. When the running instance has no product, the participant does not resolve. This participant resolves groups. Individual specialist accounts are product.specialist_users.","russian":"Группы специалистов продукта — группы, назначенные поставлять и сопровождать продукт. Назначайте этому участнику ручную задачу, когда работу может выполнить любая группа специалистов этого продукта.\n\nДвижок берёт продукт-предмет, app.products.product_id, и читает app.product_groups.group_id у строк с этим product_id и role_type product_specialists. Каждый group_id разрешается в строку app.groups.\n\nРоль могут иметь несколько групп, и каждая подходящая строка входит в разрешение. Если группа специалистов не назначена, участник не разрешается. Если у выполняемого экземпляра нет продукта, участник не разрешается. Этот участник разрешается в группы. Персональные специалисты — это product.specialist_users."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440018',
    'product.specialist_users',
    'product',
    'user',
    '{"english":"Product specialist accounts","russian":"Персональные специалисты продукта"}'::jsonb,
    $pdesc${"english":"The product specialist accounts are the individual standard or bot accounts assigned as specialists of the product, beside the specialist groups. Assign a manual task to this participant when a named specialist account of the product should act.\n\nThe engine takes the subject product, app.products.product_id, and reads app.product_users.user_id on rows with that product_id and role_type specialist. Each user_id is a standard or bot account.\n\nSeveral accounts may hold role_type specialist, and every matching row is part of the resolution. When no specialist account is assigned, the participant does not resolve. When the running instance has no product, the participant does not resolve. Specialist groups are product.specialist_groups.","russian":"Персональные специалисты продукта — отдельные учётные записи standard или bot, назначенные специалистами продукта, рядом с группами специалистов. Назначайте этому участнику ручную задачу, когда должна действовать именная учётная запись специалиста этого продукта.\n\nДвижок берёт продукт-предмет, app.products.product_id, и читает app.product_users.user_id у строк с этим product_id и role_type specialist. Каждый user_id — учётная запись standard или bot.\n\nРоль specialist могут иметь несколько учётных записей, и каждая подходящая строка входит в разрешение. Если персональный специалист не назначен, участник не разрешается. Если у выполняемого экземпляра нет продукта, участник не разрешается. Группы специалистов — это product.specialist_groups."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440019',
    'product.specialists',
    'product',
    'mixed',
    '{"english":"All product specialists","russian":"Все специалисты продукта"}'::jsonb,
    $pdesc${"english":"All product specialists are every specialist group and every individual specialist account of the product. Assign a manual task to this participant when the work may be done by any product specialist, whether that specialist is attached as a group or as an account.\n\nThe engine takes the subject product, app.products.product_id, and reads both sets: app.product_groups.group_id where role_type is product_specialists, and app.product_users.user_id where role_type is specialist. resolution_kind is mixed, so the result may contain groups from app.groups and user accounts (standard or bot).\n\nWhen both sets are empty, the participant does not resolve. When the running instance has no product, the participant does not resolve. Rows with role_type owner on app.product_users stay out of this resolution.","russian":"Все специалисты продукта — это каждая группа специалистов и каждая персональная учётная запись специалиста продукта. Назначайте этому участнику ручную задачу, когда работу может выполнить любой специалист продукта, назначенный группой или учётной записью.\n\nДвижок берёт продукт-предмет, app.products.product_id, и читает оба набора: app.product_groups.group_id при role_type product_specialists и app.product_users.user_id при role_type specialist. resolution_kind равен mixed, поэтому результат может содержать группы из app.groups и учётные записи (standard или bot).\n\nЕсли оба набора пусты, участник не разрешается. Если у выполняемого экземпляра нет продукта, участник не разрешается. Строки app.product_users с role_type owner в это разрешение не входят."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440020',
    'catalog.section_owner',
    'catalog',
    'user',
    '{"english":"Catalog section owner","russian":"Владелец раздела каталога"}'::jsonb,
    $pdesc${"english":"The catalog section owner is the owner of the catalog section in which the service or the product is placed. Assign an approval to this participant when the section owner governs what is published in that part of the catalog, for example a decision to offer the item or to withdraw it.\n\nFor a service, the engine takes the service id from the start-event context field core.service_id of catalog.service_order.submitted, or app.service_orders.service_id, or app.service_requests.service_id, reads every app.section_services.section_id for that service, and reads app.catalog_sections.owner. For a product placed on its own, it reads app.section_products.section_id for app.products.product_id and then app.catalog_sections.owner. For a product that belongs to a line, it reads app.product_line_products.line_id, then app.section_product_lines.section_id, then app.catalog_sections.owner. The owner column is one user account and may be null.\n\nA service may be placed in several catalog sections, and the engine resolves the owner of each linked section. A product is placed in at most one section, either directly or through its product line. When no section is linked, or owner is null, that placement does not resolve. This participant reads owner. The deputy is catalog.section_backup_owner.","russian":"Владелец раздела каталога — владелец раздела, в котором размещена услуга или продукт. Назначайте этому участнику согласование, когда владелец раздела решает, что публикуется в этой части каталога: например, вывести позицию или снять её.\n\nДля услуги движок берёт идентификатор услуги: поле контекста стартового события core.service_id события catalog.service_order.submitted, либо app.service_orders.service_id, либо app.service_requests.service_id, читает каждый app.section_services.section_id этой услуги и читает app.catalog_sections.owner. Для продукта, размещённого отдельно, он читает app.section_products.section_id у app.products.product_id и затем app.catalog_sections.owner. Для продукта, который входит в линейку, он читает app.product_line_products.line_id, затем app.section_product_lines.section_id, затем app.catalog_sections.owner. Колонка owner — одна учётная запись, и она может быть null.\n\nУслуга может быть размещена в нескольких разделах каталога, и движок разрешает владельца каждого связанного раздела. Продукт размещён не более чем в одном разделе: напрямую или через продуктовую линейку. Если раздел не связан или owner равен null, это размещение не разрешается. Этот участник читает owner. Заместитель — это catalog.section_backup_owner."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440021',
    'catalog.section_backup_owner',
    'catalog',
    'user',
    '{"english":"Catalog section backup owner","russian":"Заместитель владельца раздела каталога"}'::jsonb,
    $pdesc${"english":"The catalog section backup owner is the deputy of the section owner. Assign the same kind of section-level approval to this participant when a named deputy should act, and the section owner should act when no deputy is named.\n\nThe engine finds the section or sections the same way as catalog.section_owner: app.section_services for a service, app.section_products for a product placed on its own, and app.product_line_products plus app.section_product_lines for a product in a line. It then reads app.catalog_sections.backup_owner.\n\nWhen backup_owner is null, this participant falls back to catalog.section_owner, which is app.catalog_sections.owner of the same section. When both backup_owner and owner are null, or no section is linked, the participant does not resolve.","russian":"Заместитель владельца раздела каталога — заместитель владельца раздела. Назначайте этому участнику то же согласование на уровне раздела, когда должен действовать назначенный заместитель, а при отсутствии заместителя — владелец раздела.\n\nДвижок находит раздел или разделы так же, как catalog.section_owner: app.section_services для услуги, app.section_products для продукта, размещённого отдельно, и app.product_line_products вместе с app.section_product_lines для продукта в линейке. Затем он читает app.catalog_sections.backup_owner.\n\nКогда backup_owner равен null, этот участник переходит к catalog.section_owner, то есть к app.catalog_sections.owner того же раздела. Когда и backup_owner, и owner равны null или раздел не связан, участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440022',
    'process.owner',
    'process',
    'user',
    '{"english":"Process owner","russian":"Владелец процесса"}'::jsonb,
    $pdesc${"english":"The process owner is the accountable owner of the process definition that the instance is running. Assign an exception or a stuck-process decision to this participant when the owner of the process must intervene, for any account that started this run.\n\nThe engine reads app.process_instances.process_id on the running instance, then app.processes.owner_user_id, and resolves that user account (standard or bot).\n\nowner_user_id is required on app.processes, so a stored process always resolves to one account. The value is the owner of the definition. It is independent of app.process_instances.started_by.","russian":"Владелец процесса — ответственный владелец определения процесса, по которому идёт экземпляр. Назначайте этому участнику решение об исключении или о застрявшем процессе, когда должен вмешаться владелец процесса, какая бы учётная запись ни запустила этот прогон.\n\nДвижок читает app.process_instances.process_id выполняемого экземпляра, затем app.processes.owner_user_id и разрешает эту учётную запись (standard или bot).\n\nowner_user_id обязателен в app.processes, поэтому сохранённый процесс всегда разрешается в одну учётную запись. Значение — владелец определения. Оно не зависит от app.process_instances.started_by."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440023',
    'process.initiator',
    'process',
    'user',
    '{"english":"Process initiator","russian":"Инициатор процесса"}'::jsonb,
    $pdesc${"english":"The process initiator is the account that started the running process instance. Assign a manual task, an approval, or an acceptance to this participant when the account that launched the process must supply something or confirm the outcome.\n\nThe engine reads app.process_instances.started_by on the running instance and resolves that user account. app.users.account_type for that account may be standard, bot, or system.\n\nstarted_by is optional. When it is null, which covers a system start and a start whose account was later deleted, the participant does not resolve.","russian":"Инициатор процесса — учётная запись, запустившая выполняемый экземпляр процесса. Назначайте этому участнику ручную задачу, согласование или приёмку, когда учётная запись, запустившая процесс, должна что-то сообщить или подтвердить результат.\n\nДвижок читает app.process_instances.started_by выполняемого экземпляра и разрешает эту учётную запись. app.users.account_type этой учётной записи может быть standard, bot или system.\n\nstarted_by необязателен. Когда он равен null — это системный старт или старт, учётную запись которого позже удалили, — участник не разрешается."}$pdesc$::jsonb,
    true
),
(
    '880e8400-e29b-41d4-a716-446655440024',
    'process.initiator_accountable',
    'process',
    'user',
    '{"english":"Accountable user for initiator","russian":"Ответственный за бота-инициатора"}'::jsonb,
    $pdesc${"english":"The accountable user for the initiator is the account that answers for the start of the process. Assign a manual task or an approval to this participant when the step must reach that account: the initiator itself when a standard account started the process, and the bot's accountable user when a bot started it.\n\nThe engine reads app.process_instances.started_by and app.users.account_type. When account_type is bot, it reads app.users_bot_profiles.accountable_user_id for that bot and resolves that user account. When account_type is standard, it resolves started_by itself.\n\nA bot profile always has accountable_user_id, so a bot initiator resolves to that account. A standard initiator resolves to itself. When started_by is null, or account_type is system, the participant does not resolve.","russian":"Ответственный за инициатора — учётная запись, которая отвечает за запуск процесса. Назначайте этому участнику ручную задачу или согласование, когда шаг должен дойти до этой учётной записи: до самого инициатора, если процесс запустила стандартная учётная запись, и до ответственного за бота, если процесс запустил бот.\n\nДвижок читает app.process_instances.started_by и app.users.account_type. Когда account_type равен bot, он читает app.users_bot_profiles.accountable_user_id этого бота и разрешает эту учётную запись. Когда account_type равен standard, он разрешает сам started_by.\n\nУ профиля бота accountable_user_id обязателен, поэтому инициатор-бот разрешается в эту учётную запись. Стандартный инициатор разрешается в самого себя. Когда started_by равен null или account_type равен system, участник не разрешается."}$pdesc$::jsonb,
    true
)
ON CONFLICT (participant_key) DO UPDATE SET
    entity_kind = EXCLUDED.entity_kind,
    resolution_kind = EXCLUDED.resolution_kind,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    is_system = EXCLUDED.is_system;

UPDATE app.users_standard_profiles
SET user_agreement_version = 'pre-mvp-notice'
WHERE user_agreement_version = 'EVI_ELv2';

UPDATE app.users_standard_profiles
SET preferences = preferences #- '{lastLocations,license}'
WHERE preferences #> '{lastLocations,license}' IS NOT NULL;

-- ===========================================================================
-- Process system procedures catalog (systemActivity actions)
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.process_system_procedures (
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
    CONSTRAINT uq_process_system_procedures_key
        UNIQUE (procedure_key),
    CONSTRAINT chk_process_system_procedures_module_format
        CHECK (module ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_system_procedures_entity_format
        CHECK (entity ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_system_procedures_action_format
        CHECK (action ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_system_procedures_key_match
        CHECK (procedure_key = module || '.' || entity || '.' || action),
    CONSTRAINT chk_process_system_procedures_module_name_localized
        CHECK (app.is_localized_text(module_name)),
    CONSTRAINT chk_process_system_procedures_entity_name_localized
        CHECK (app.is_localized_text(entity_name)),
    CONSTRAINT chk_process_system_procedures_name_localized
        CHECK (app.is_localized_text(name)),
    CONSTRAINT chk_process_system_procedures_description_localized
        CHECK (app.is_localized_text(description)),
    CONSTRAINT chk_process_system_procedures_input_schema_array
        CHECK (jsonb_typeof(input_schema) = 'array'),
    CONSTRAINT chk_process_system_procedures_output_schema_array
        CHECK (jsonb_typeof(output_schema) = 'array')
);

COMMENT ON TABLE app.process_system_procedures IS
    'Catalog of platform procedures available to systemActivity in the process engine, organized by module, entity, and action. System rows (is_system = true) are protected from deletion by tgr_process_system_procedures_prevent_system_delete.';
COMMENT ON COLUMN app.process_system_procedures.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT or seeded deterministically.';
COMMENT ON COLUMN app.process_system_procedures.procedure_key IS
    'Stable key in <module>.<entity>.<action> format (e.g. work.service_request.create). Unique.';
COMMENT ON COLUMN app.process_system_procedures.module IS
    'Owning application module key (e.g. work, catalog).';
COMMENT ON COLUMN app.process_system_procedures.entity IS
    'Entity key within the module (e.g. service_request, incident, problem, change, manual_task, approval, acceptance, service_order).';
COMMENT ON COLUMN app.process_system_procedures.action IS
    'Operation key on the entity (e.g. create, update, delete).';
COMMENT ON COLUMN app.process_system_procedures.module_name IS
    'Localized display name of the module. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_system_procedures.entity_name IS
    'Localized display name of the entity. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_system_procedures.name IS
    'Localized display name of the procedure action. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_system_procedures.description IS
    'Localized description of what the procedure does, its inputs, and its outputs. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_system_procedures.input_schema IS
    'JSON array of input attribute descriptors ({key, type, required, source, enum?, label, description}).';
COMMENT ON COLUMN app.process_system_procedures.output_schema IS
    'JSON array of output variable descriptors ({key, type, enum?, label, description, example}) written to context.activities.<elementId>.';
COMMENT ON COLUMN app.process_system_procedures.is_system IS
    'True for platform-seeded procedures that cannot be deleted.';
COMMENT ON COLUMN app.process_system_procedures.created_at IS
    'Row creation timestamp.';

CREATE OR REPLACE FUNCTION app.prevent_process_system_procedure_deletion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_system = true THEN
        RAISE EXCEPTION 'system procedure % cannot be deleted', OLD.procedure_key
            USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION app.prevent_process_system_procedure_deletion() IS
    'BEFORE DELETE row guard for app.process_system_procedures. Raises object_not_in_prerequisite_state (55000) when is_system is true.';

DROP TRIGGER IF EXISTS tgr_process_system_procedures_prevent_system_delete ON app.process_system_procedures;

CREATE TRIGGER tgr_process_system_procedures_prevent_system_delete
BEFORE DELETE ON app.process_system_procedures
FOR EACH ROW EXECUTE FUNCTION app.prevent_process_system_procedure_deletion();

-- System procedures catalog (20 rows across work and catalog).
-- created_at stays at the first insert: conflict updates do not touch it.
INSERT INTO app.process_system_procedures (
    id, procedure_key, module, entity, action,
    module_name, entity_name, name, description,
    input_schema, output_schema, is_system
) VALUES
(
    '990e8400-e29b-41d4-a716-446655440001',
    'work.service_request.create',
    'work',
    'service_request',
    'create',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Service request", "russian": "Сервисный запрос"}'::jsonb,
    '{"english": "Create", "russian": "Создать"}'::jsonb,
    '{"english": "Creates a service request from a title, urgency, and optional description, impact, priority, and assignee. Writes the new request id, its human-readable number, and the status after creation.", "russian": "Создаёт сервисный запрос по заголовку, срочности и необязательным описанию, влиянию, приоритету и исполнителю. Записывает id нового запроса, его читаемый номер и статус после создания."}'::jsonb,
    $psp_in_01$
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_01$::jsonb,
    $psp_out_01$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Service request ID",
      "russian": "ID сервисного запроса"
    },
    "description": {
      "english": "UUID of the created service request.",
      "russian": "UUID созданного сервисного запроса."
    },
    "example": "<uuid>"
  },
  {
    "key": "request_number",
    "type": "string",
    "label": {
      "english": "Request number",
      "russian": "Номер запроса"
    },
    "description": {
      "english": "Human-readable reference (sr-XXXXXX).",
      "russian": "Читаемый номер запроса (sr-XXXXXX)."
    },
    "example": "sr-000105"
  },
  {
    "key": "status",
    "type": "enum",
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
      "english": "Lifecycle status after creation.",
      "russian": "Статус после создания."
    },
    "example": "new"
  }
]
$psp_out_01$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440002',
    'work.service_request.update',
    'work',
    'service_request',
    'update',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Service request", "russian": "Сервисный запрос"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the service request identified by target_id from the process context. Optional inputs set status, approval status, priority, assignee, and a work note. Writes the request id and the status after the update.", "russian": "Обновляет сервисный запрос, id которого (target_id) берётся из контекста процесса. Необязательные входы задают статус, статус согласования, приоритет, исполнителя и рабочую заметку. Записывает id запроса и статус после обновления."}'::jsonb,
    $psp_in_02$
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_02$::jsonb,
    $psp_out_02$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Service request ID",
      "russian": "ID сервисного запроса"
    },
    "description": {
      "english": "UUID of the updated service request.",
      "russian": "UUID обновлённого сервисного запроса."
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
      "english": "Status after update.",
      "russian": "Статус после обновления."
    },
    "example": "in_progress"
  }
]
$psp_out_02$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440003',
    'work.service_request.delete',
    'work',
    'service_request',
    'delete',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Service request", "russian": "Сервисный запрос"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the service request identified by target_id from the process context. Writes the id of the deleted request.", "russian": "Удаляет сервисный запрос, id которого (target_id) берётся из контекста процесса. Записывает id удалённого запроса."}'::jsonb,
    $psp_in_03$
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
      "english": "UUID of the service request to delete (from process context).",
      "russian": "UUID удаляемого сервисного запроса (из контекста процесса)."
    }
  }
]
$psp_in_03$::jsonb,
    $psp_out_03$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted service request ID",
      "russian": "ID удалённого сервисного запроса"
    },
    "description": {
      "english": "UUID of the deleted service request.",
      "russian": "UUID удалённого сервисного запроса."
    },
    "example": "<uuid>"
  }
]
$psp_out_03$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440004',
    'work.incident.create',
    'work',
    'incident',
    'create',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Incident", "russian": "Инцидент"}'::jsonb,
    '{"english": "Create", "russian": "Создать"}'::jsonb,
    '{"english": "Creates an incident from a title, urgency, and optional description, impact, priority, and assignee. Writes the new incident id, its human-readable number, and the status after creation.", "russian": "Создаёт инцидент по заголовку, срочности и необязательным описанию, влиянию, приоритету и исполнителю. Записывает id нового инцидента, его читаемый номер и статус после создания."}'::jsonb,
    $psp_in_04$
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
      "english": "Short title of the incident.",
      "russian": "Краткий заголовок инцидента."
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
      "english": "Detailed description of the incident.",
      "russian": "Подробное описание инцидента."
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_04$::jsonb,
    $psp_out_04$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Incident ID",
      "russian": "ID инцидента"
    },
    "description": {
      "english": "UUID of the created incident.",
      "russian": "UUID созданного инцидента."
    },
    "example": "<uuid>"
  },
  {
    "key": "request_number",
    "type": "string",
    "label": {
      "english": "Incident number",
      "russian": "Номер инцидента"
    },
    "description": {
      "english": "Human-readable reference (ir-XXXXXX).",
      "russian": "Читаемый номер инцидента (ir-XXXXXX)."
    },
    "example": "ir-000012"
  },
  {
    "key": "status",
    "type": "enum",
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
      "english": "Lifecycle status after creation.",
      "russian": "Статус после создания."
    },
    "example": "new"
  }
]
$psp_out_04$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440005',
    'work.incident.update',
    'work',
    'incident',
    'update',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Incident", "russian": "Инцидент"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the incident identified by target_id from the process context. Optional inputs set status, approval status, priority, assignee, and a work note. Writes the incident id and the status after the update.", "russian": "Обновляет инцидент, id которого (target_id) берётся из контекста процесса. Необязательные входы задают статус, статус согласования, приоритет, исполнителя и рабочую заметку. Записывает id инцидента и статус после обновления."}'::jsonb,
    $psp_in_05$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target incident ID",
      "russian": "ID целевого инцидента"
    },
    "description": {
      "english": "UUID of the incident to update (from process context).",
      "russian": "UUID обновляемого инцидента (из контекста процесса)."
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_05$::jsonb,
    $psp_out_05$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Incident ID",
      "russian": "ID инцидента"
    },
    "description": {
      "english": "UUID of the updated incident.",
      "russian": "UUID обновлённого инцидента."
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
      "english": "Status after update.",
      "russian": "Статус после обновления."
    },
    "example": "in_progress"
  }
]
$psp_out_05$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440006',
    'work.incident.delete',
    'work',
    'incident',
    'delete',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Incident", "russian": "Инцидент"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the incident identified by target_id from the process context. Writes the id of the deleted incident.", "russian": "Удаляет инцидент, id которого (target_id) берётся из контекста процесса. Записывает id удалённого инцидента."}'::jsonb,
    $psp_in_06$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target incident ID",
      "russian": "ID целевого инцидента"
    },
    "description": {
      "english": "UUID of the incident to delete (from process context).",
      "russian": "UUID удаляемого инцидента (из контекста процесса)."
    }
  }
]
$psp_in_06$::jsonb,
    $psp_out_06$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted incident ID",
      "russian": "ID удалённого инцидента"
    },
    "description": {
      "english": "UUID of the deleted incident.",
      "russian": "UUID удалённого инцидента."
    },
    "example": "<uuid>"
  }
]
$psp_out_06$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440007',
    'work.problem.create',
    'work',
    'problem',
    'create',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Problem", "russian": "Проблема"}'::jsonb,
    '{"english": "Create", "russian": "Создать"}'::jsonb,
    '{"english": "Creates a problem from a title, urgency, and optional description, impact, priority, and assignee. Writes the new problem id, its human-readable number, and the status after creation.", "russian": "Создаёт проблему по заголовку, срочности и необязательным описанию, влиянию, приоритету и исполнителю. Записывает id новой проблемы, её читаемый номер и статус после создания."}'::jsonb,
    $psp_in_07$
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
      "english": "Short title of the problem.",
      "russian": "Краткий заголовок проблемы."
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
      "english": "Detailed description of the problem.",
      "russian": "Подробное описание проблемы."
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_07$::jsonb,
    $psp_out_07$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Problem ID",
      "russian": "ID проблемы"
    },
    "description": {
      "english": "UUID of the created problem.",
      "russian": "UUID созданной проблемы."
    },
    "example": "<uuid>"
  },
  {
    "key": "request_number",
    "type": "string",
    "label": {
      "english": "Problem number",
      "russian": "Номер проблемы"
    },
    "description": {
      "english": "Human-readable reference (pr-XXXXXX).",
      "russian": "Читаемый номер проблемы (pr-XXXXXX)."
    },
    "example": "pr-000004"
  },
  {
    "key": "status",
    "type": "enum",
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
      "english": "Lifecycle status after creation.",
      "russian": "Статус после создания."
    },
    "example": "new"
  }
]
$psp_out_07$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440008',
    'work.problem.update',
    'work',
    'problem',
    'update',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Problem", "russian": "Проблема"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the problem identified by target_id from the process context. Optional inputs set status, approval status, priority, assignee, and a work note. Writes the problem id and the status after the update.", "russian": "Обновляет проблему, id которой (target_id) берётся из контекста процесса. Необязательные входы задают статус, статус согласования, приоритет, исполнителя и рабочую заметку. Записывает id проблемы и статус после обновления."}'::jsonb,
    $psp_in_08$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target problem ID",
      "russian": "ID целевой проблемы"
    },
    "description": {
      "english": "UUID of the problem to update (from process context).",
      "russian": "UUID обновляемой проблемы (из контекста процесса)."
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_08$::jsonb,
    $psp_out_08$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Problem ID",
      "russian": "ID проблемы"
    },
    "description": {
      "english": "UUID of the updated problem.",
      "russian": "UUID обновлённой проблемы."
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
      "english": "Status after update.",
      "russian": "Статус после обновления."
    },
    "example": "in_progress"
  }
]
$psp_out_08$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440009',
    'work.problem.delete',
    'work',
    'problem',
    'delete',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Problem", "russian": "Проблема"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the problem identified by target_id from the process context. Writes the id of the deleted problem.", "russian": "Удаляет проблему, id которой (target_id) берётся из контекста процесса. Записывает id удалённой проблемы."}'::jsonb,
    $psp_in_09$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target problem ID",
      "russian": "ID целевой проблемы"
    },
    "description": {
      "english": "UUID of the problem to delete (from process context).",
      "russian": "UUID удаляемой проблемы (из контекста процесса)."
    }
  }
]
$psp_in_09$::jsonb,
    $psp_out_09$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted problem ID",
      "russian": "ID удалённой проблемы"
    },
    "description": {
      "english": "UUID of the deleted problem.",
      "russian": "UUID удалённой проблемы."
    },
    "example": "<uuid>"
  }
]
$psp_out_09$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440010',
    'work.change.create',
    'work',
    'change',
    'create',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Change", "russian": "Изменение"}'::jsonb,
    '{"english": "Create", "russian": "Создать"}'::jsonb,
    '{"english": "Creates a change from a title, urgency, and optional description, impact, priority, and assignee. Writes the new change id, its human-readable number, and the status after creation.", "russian": "Создаёт изменение по заголовку, срочности и необязательным описанию, влиянию, приоритету и исполнителю. Записывает id нового изменения, его читаемый номер и статус после создания."}'::jsonb,
    $psp_in_10$
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
      "english": "Short title of the change.",
      "russian": "Краткий заголовок изменения."
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
      "english": "Detailed description of the change.",
      "russian": "Подробное описание изменения."
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_10$::jsonb,
    $psp_out_10$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Change ID",
      "russian": "ID изменения"
    },
    "description": {
      "english": "UUID of the created change.",
      "russian": "UUID созданного изменения."
    },
    "example": "<uuid>"
  },
  {
    "key": "request_number",
    "type": "string",
    "label": {
      "english": "Change number",
      "russian": "Номер изменения"
    },
    "description": {
      "english": "Human-readable reference (cr-XXXXXX).",
      "russian": "Читаемый номер изменения (cr-XXXXXX)."
    },
    "example": "cr-000009"
  },
  {
    "key": "status",
    "type": "enum",
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
      "english": "Lifecycle status after creation.",
      "russian": "Статус после создания."
    },
    "example": "new"
  }
]
$psp_out_10$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440011',
    'work.change.update',
    'work',
    'change',
    'update',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Change", "russian": "Изменение"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the change identified by target_id from the process context. Optional inputs set status, approval status, priority, assignee, and a work note. Writes the change id and the status after the update.", "russian": "Обновляет изменение, id которого (target_id) берётся из контекста процесса. Необязательные входы задают статус, статус согласования, приоритет, исполнителя и рабочую заметку. Записывает id изменения и статус после обновления."}'::jsonb,
    $psp_in_11$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target change ID",
      "russian": "ID целевого изменения"
    },
    "description": {
      "english": "UUID of the change to update (from process context).",
      "russian": "UUID обновляемого изменения (из контекста процесса)."
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
      "low",
      "medium",
      "high",
      "critical"
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
$psp_in_11$::jsonb,
    $psp_out_11$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Change ID",
      "russian": "ID изменения"
    },
    "description": {
      "english": "UUID of the updated change.",
      "russian": "UUID обновлённого изменения."
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
      "english": "Status after update.",
      "russian": "Статус после обновления."
    },
    "example": "in_progress"
  }
]
$psp_out_11$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440012',
    'work.change.delete',
    'work',
    'change',
    'delete',
    '{"english": "Work", "russian": "Работа"}'::jsonb,
    '{"english": "Change", "russian": "Изменение"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the change identified by target_id from the process context. Writes the id of the deleted change.", "russian": "Удаляет изменение, id которого (target_id) берётся из контекста процесса. Записывает id удалённого изменения."}'::jsonb,
    $psp_in_12$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target change ID",
      "russian": "ID целевого изменения"
    },
    "description": {
      "english": "UUID of the change to delete (from process context).",
      "russian": "UUID удаляемого изменения (из контекста процесса)."
    }
  }
]
$psp_in_12$::jsonb,
    $psp_out_12$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted change ID",
      "russian": "ID удалённого изменения"
    },
    "description": {
      "english": "UUID of the deleted change.",
      "russian": "UUID удалённого изменения."
    },
    "example": "<uuid>"
  }
]
$psp_out_12$::jsonb,
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
    $psp_in_13$
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
$psp_in_13$::jsonb,
    $psp_out_13$
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
$psp_out_13$::jsonb,
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
    $psp_in_14$
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
$psp_in_14$::jsonb,
    $psp_out_14$
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
$psp_out_14$::jsonb,
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
    $psp_in_15$
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
$psp_in_15$::jsonb,
    $psp_out_15$
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
$psp_out_15$::jsonb,
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
    $psp_in_16$
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
$psp_in_16$::jsonb,
    $psp_out_16$
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
$psp_out_16$::jsonb,
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
    $psp_in_17$
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
$psp_in_17$::jsonb,
    $psp_out_17$
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
$psp_out_17$::jsonb,
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
    $psp_in_18$
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
$psp_in_18$::jsonb,
    $psp_out_18$
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
$psp_out_18$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440019',
    'catalog.service_order.update',
    'catalog',
    'service_order',
    'update',
    '{"english": "Catalog", "russian": "Каталог"}'::jsonb,
    '{"english": "Service order", "russian": "Заказ услуги"}'::jsonb,
    '{"english": "Update", "russian": "Обновить"}'::jsonb,
    '{"english": "Updates the catalog service order identified by target_id from the process context. Optional inputs set the title, the description, urgency, and impact. Writes the order id.", "russian": "Обновляет заказ услуги, id которого (target_id) берётся из контекста процесса. Необязательные входы задают заголовок, описание, срочность и влияние. Записывает id заказа."}'::jsonb,
    $psp_in_19$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target service order ID",
      "russian": "ID целевого заказа услуги"
    },
    "description": {
      "english": "UUID of the service order to update (from process context).",
      "russian": "UUID обновляемого заказа услуги (из контекста процесса)."
    }
  },
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
      "english": "Updated title of the service order.",
      "russian": "Обновлённый заголовок заказа услуги."
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
      "english": "Updated description of the service order.",
      "russian": "Обновлённое описание заказа услуги."
    }
  },
  {
    "key": "urgency",
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
      "english": "Urgency",
      "russian": "Срочность"
    },
    "description": {
      "english": "Updated urgency level.",
      "russian": "Обновлённый уровень срочности."
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
      "english": "Updated impact level.",
      "russian": "Обновлённый уровень влияния."
    }
  }
]
$psp_in_19$::jsonb,
    $psp_out_19$
[
  {
    "key": "id",
    "type": "uuid",
    "label": {
      "english": "Service order ID",
      "russian": "ID заказа услуги"
    },
    "description": {
      "english": "UUID of the updated service order.",
      "russian": "UUID обновлённого заказа услуги."
    },
    "example": "<uuid>"
  }
]
$psp_out_19$::jsonb,
    true
),
(
    '990e8400-e29b-41d4-a716-446655440020',
    'catalog.service_order.delete',
    'catalog',
    'service_order',
    'delete',
    '{"english": "Catalog", "russian": "Каталог"}'::jsonb,
    '{"english": "Service order", "russian": "Заказ услуги"}'::jsonb,
    '{"english": "Delete", "russian": "Удалить"}'::jsonb,
    '{"english": "Deletes the catalog service order identified by target_id from the process context. Writes the id of the deleted order.", "russian": "Удаляет заказ услуги, id которого (target_id) берётся из контекста процесса. Записывает id удалённого заказа."}'::jsonb,
    $psp_in_20$
[
  {
    "key": "target_id",
    "type": "uuid",
    "required": true,
    "source": "context_only",
    "label": {
      "english": "Target service order ID",
      "russian": "ID целевого заказа услуги"
    },
    "description": {
      "english": "UUID of the service order to delete (from process context).",
      "russian": "UUID удаляемого заказа услуги (из контекста процесса)."
    }
  }
]
$psp_in_20$::jsonb,
    $psp_out_20$
[
  {
    "key": "deleted_id",
    "type": "uuid",
    "label": {
      "english": "Deleted service order ID",
      "russian": "ID удалённого заказа услуги"
    },
    "description": {
      "english": "UUID of the deleted service order.",
      "russian": "UUID удалённого заказа услуги."
    },
    "example": "<uuid>"
  }
]
$psp_out_20$::jsonb,
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

-- ===========================================================================
-- Process external procedures catalog (externalActivity connector methods)
-- ===========================================================================

CREATE TABLE IF NOT EXISTS app.process_external_procedures (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    procedure_key   VARCHAR(120) NOT NULL,
    connector       VARCHAR(50) NOT NULL,
    resource        VARCHAR(50) NOT NULL,
    method          VARCHAR(50) NOT NULL,
    connector_name  JSONB NOT NULL,
    resource_name   JSONB NOT NULL,
    name            JSONB NOT NULL,
    description     JSONB NOT NULL,
    input_schema    JSONB NOT NULL DEFAULT '[]'::jsonb,
    output_schema   JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_system       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_process_external_procedures_key
        UNIQUE (procedure_key),
    CONSTRAINT chk_process_external_procedures_connector_format
        CHECK (connector ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_external_procedures_resource_format
        CHECK (resource ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_external_procedures_method_format
        CHECK (method ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT chk_process_external_procedures_key_match
        CHECK (procedure_key = connector || '.' || resource || '.' || method),
    CONSTRAINT chk_process_external_procedures_connector_name_localized
        CHECK (app.is_localized_text(connector_name)),
    CONSTRAINT chk_process_external_procedures_resource_name_localized
        CHECK (app.is_localized_text(resource_name)),
    CONSTRAINT chk_process_external_procedures_name_localized
        CHECK (app.is_localized_text(name)),
    CONSTRAINT chk_process_external_procedures_description_localized
        CHECK (app.is_localized_text(description)),
    CONSTRAINT chk_process_external_procedures_input_schema_array
        CHECK (jsonb_typeof(input_schema) = 'array'),
    CONSTRAINT chk_process_external_procedures_output_schema_array
        CHECK (jsonb_typeof(output_schema) = 'array')
);

COMMENT ON TABLE app.process_external_procedures IS
    'Catalog of external connector methods available to externalActivity in the process engine, organized by connector, resource, and method. System rows (is_system = true) are protected from deletion by tgr_process_external_procedures_prevent_system_delete.';
COMMENT ON COLUMN app.process_external_procedures.id IS
    'Row UUID. Assigned by gen_random_uuid() on INSERT or seeded deterministically.';
COMMENT ON COLUMN app.process_external_procedures.procedure_key IS
    'Stable key in <connector>.<resource>.<method> format (e.g. http.webhook.post). Unique.';
COMMENT ON COLUMN app.process_external_procedures.connector IS
    'External connector key (e.g. http).';
COMMENT ON COLUMN app.process_external_procedures.resource IS
    'Resource key within the connector (e.g. webhook).';
COMMENT ON COLUMN app.process_external_procedures.method IS
    'Operation method key on the resource (e.g. post, get, put, patch, delete).';
COMMENT ON COLUMN app.process_external_procedures.connector_name IS
    'Localized display name of the connector. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_external_procedures.resource_name IS
    'Localized display name of the resource. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_external_procedures.name IS
    'Localized display name of the method. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_external_procedures.description IS
    'Localized description of what the external method does, its inputs, and its outputs. english is required and non-empty; russian is optional.';
COMMENT ON COLUMN app.process_external_procedures.input_schema IS
    'JSON array of input attribute descriptors ({key, type, required, source, enum?, label, description}).';
COMMENT ON COLUMN app.process_external_procedures.output_schema IS
    'JSON array of output variable descriptors ({key, type, enum?, label, description, example}) written to context.activities.<elementId>.';
COMMENT ON COLUMN app.process_external_procedures.is_system IS
    'True for platform-seeded external procedures that cannot be deleted.';
COMMENT ON COLUMN app.process_external_procedures.created_at IS
    'Row creation timestamp.';

CREATE OR REPLACE FUNCTION app.prevent_process_external_procedure_deletion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_system = true THEN
        RAISE EXCEPTION 'external procedure % cannot be deleted', OLD.procedure_key
            USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION app.prevent_process_external_procedure_deletion() IS
    'BEFORE DELETE row guard for app.process_external_procedures. Raises object_not_in_prerequisite_state (55000) when is_system is true.';

DROP TRIGGER IF EXISTS tgr_process_external_procedures_prevent_system_delete ON app.process_external_procedures;

CREATE TRIGGER tgr_process_external_procedures_prevent_system_delete
BEFORE DELETE ON app.process_external_procedures
FOR EACH ROW EXECUTE FUNCTION app.prevent_process_external_procedure_deletion();

-- External procedures catalog (5 webhook rows for connector http, resource webhook).
-- created_at stays at the first insert: conflict updates do not touch it.
INSERT INTO app.process_external_procedures (
    id, procedure_key, connector, resource, method,
    connector_name, resource_name, name, description,
    input_schema, output_schema, is_system
) VALUES
(
    'aa0e8400-e29b-41d4-a716-446655440001',
    'http.webhook.post',
    'http',
    'webhook',
    'post',
    '{"english": "HTTP / Webhook", "russian": "HTTP / Вебхук"}'::jsonb,
    '{"english": "Webhook endpoint", "russian": "Точка вебхука"}'::jsonb,
    '{"english": "POST request", "russian": "POST-запрос"}'::jsonb,
    '{"english": "Sends an HTTP POST request to an external webhook URL with an optional payload, Authorization header, and timeout. Writes the HTTP status code, the response body, and the round-trip duration.", "russian": "Отправляет HTTP POST-запрос на внешний URL вебхука с необязательными телом, заголовком Authorization и таймаутом. Записывает HTTP-код ответа, тело ответа и длительность запроса."}'::jsonb,
    $pep_in_01$
[
  {
    "key": "url",
    "type": "string",
    "required": true,
    "source": "both",
    "label": {
      "english": "Endpoint URL",
      "russian": "URL вебхука"
    },
    "description": {
      "english": "Target HTTPS/HTTP URL of the external webhook endpoint.",
      "russian": "Целевой HTTPS/HTTP адрес внешней точки вебхука."
    }
  },
  {
    "key": "payload",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Request payload",
      "russian": "Тело запроса"
    },
    "description": {
      "english": "JSON body or value sent in the POST request.",
      "russian": "JSON-тело или значение, отправляемое в POST-запросе."
    }
  },
  {
    "key": "auth_header",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Authorization header",
      "russian": "Заголовок авторизации"
    },
    "description": {
      "english": "Optional Authorization header value or bearer token reference.",
      "russian": "Необязательное значение заголовка Authorization или ссылка на токен."
    }
  },
  {
    "key": "timeout_seconds",
    "type": "string",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Timeout (seconds)",
      "russian": "Таймаут (секунды)"
    },
    "description": {
      "english": "Request timeout in seconds (default 30).",
      "russian": "Таймаут ожидания ответа в секундах (по умолчанию 30)."
    }
  }
]
$pep_in_01$::jsonb,
    $pep_out_01$
[
  {
    "key": "status_code",
    "type": "string",
    "label": {
      "english": "HTTP status code",
      "russian": "HTTP-код ответа"
    },
    "description": {
      "english": "Numeric HTTP response status code returned by the endpoint.",
      "russian": "Числовой код ответа HTTP, возвращённый внешней системой."
    },
    "example": "200"
  },
  {
    "key": "response_body",
    "type": "string",
    "label": {
      "english": "Response body",
      "russian": "Тело ответа"
    },
    "description": {
      "english": "Response body returned by the webhook endpoint.",
      "russian": "Тело ответа, возвращённое точкой вебхука."
    },
    "example": "{\"status\":\"ok\"}"
  },
  {
    "key": "duration_ms",
    "type": "string",
    "label": {
      "english": "Duration (ms)",
      "russian": "Длительность (мс)"
    },
    "description": {
      "english": "Round-trip request duration in milliseconds.",
      "russian": "Время выполнения запроса в миллисекундах."
    },
    "example": "145"
  }
]
$pep_out_01$::jsonb,
    true
),
(
    'aa0e8400-e29b-41d4-a716-446655440002',
    'http.webhook.get',
    'http',
    'webhook',
    'get',
    '{"english": "HTTP / Webhook", "russian": "HTTP / Вебхук"}'::jsonb,
    '{"english": "Webhook endpoint", "russian": "Точка вебхука"}'::jsonb,
    '{"english": "GET request", "russian": "GET-запрос"}'::jsonb,
    '{"english": "Sends an HTTP GET request to an external webhook URL with an optional Authorization header and timeout. Writes the HTTP status code, the response body, and the round-trip duration.", "russian": "Отправляет HTTP GET-запрос на внешний URL вебхука с необязательными заголовком Authorization и таймаутом. Записывает HTTP-код ответа, тело ответа и длительность запроса."}'::jsonb,
    $pep_in_02$
[
  {
    "key": "url",
    "type": "string",
    "required": true,
    "source": "both",
    "label": {
      "english": "Endpoint URL",
      "russian": "URL вебхука"
    },
    "description": {
      "english": "Target HTTPS/HTTP URL of the external webhook endpoint.",
      "russian": "Целевой HTTPS/HTTP адрес внешней точки вебхука."
    }
  },
  {
    "key": "auth_header",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Authorization header",
      "russian": "Заголовок авторизации"
    },
    "description": {
      "english": "Optional Authorization header value or bearer token reference.",
      "russian": "Необязательное значение заголовка Authorization или ссылка на токен."
    }
  },
  {
    "key": "timeout_seconds",
    "type": "string",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Timeout (seconds)",
      "russian": "Таймаут (секунды)"
    },
    "description": {
      "english": "Request timeout in seconds (default 30).",
      "russian": "Таймаут ожидания ответа в секундах (по умолчанию 30)."
    }
  }
]
$pep_in_02$::jsonb,
    $pep_out_02$
[
  {
    "key": "status_code",
    "type": "string",
    "label": {
      "english": "HTTP status code",
      "russian": "HTTP-код ответа"
    },
    "description": {
      "english": "Numeric HTTP response status code returned by the endpoint.",
      "russian": "Числовой код ответа HTTP, возвращённый внешней системой."
    },
    "example": "200"
  },
  {
    "key": "response_body",
    "type": "string",
    "label": {
      "english": "Response body",
      "russian": "Тело ответа"
    },
    "description": {
      "english": "Response body returned by the webhook endpoint.",
      "russian": "Тело ответа, возвращённое точкой вебхука."
    },
    "example": "{\"status\":\"ok\"}"
  },
  {
    "key": "duration_ms",
    "type": "string",
    "label": {
      "english": "Duration (ms)",
      "russian": "Длительность (мс)"
    },
    "description": {
      "english": "Round-trip request duration in milliseconds.",
      "russian": "Время выполнения запроса в миллисекундах."
    },
    "example": "145"
  }
]
$pep_out_02$::jsonb,
    true
),
(
    'aa0e8400-e29b-41d4-a716-446655440003',
    'http.webhook.put',
    'http',
    'webhook',
    'put',
    '{"english": "HTTP / Webhook", "russian": "HTTP / Вебхук"}'::jsonb,
    '{"english": "Webhook endpoint", "russian": "Точка вебхука"}'::jsonb,
    '{"english": "PUT request", "russian": "PUT-запрос"}'::jsonb,
    '{"english": "Sends an HTTP PUT request to an external webhook URL with an optional payload, Authorization header, and timeout. Writes the HTTP status code, the response body, and the round-trip duration.", "russian": "Отправляет HTTP PUT-запрос на внешний URL вебхука с необязательными телом, заголовком Authorization и таймаутом. Записывает HTTP-код ответа, тело ответа и длительность запроса."}'::jsonb,
    $pep_in_03$
[
  {
    "key": "url",
    "type": "string",
    "required": true,
    "source": "both",
    "label": {
      "english": "Endpoint URL",
      "russian": "URL вебхука"
    },
    "description": {
      "english": "Target HTTPS/HTTP URL of the external webhook endpoint.",
      "russian": "Целевой HTTPS/HTTP адрес внешней точки вебхука."
    }
  },
  {
    "key": "payload",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Request payload",
      "russian": "Тело запроса"
    },
    "description": {
      "english": "JSON body or value sent in the PUT request.",
      "russian": "JSON-тело или значение, отправляемое в PUT-запросе."
    }
  },
  {
    "key": "auth_header",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Authorization header",
      "russian": "Заголовок авторизации"
    },
    "description": {
      "english": "Optional Authorization header value or bearer token reference.",
      "russian": "Необязательное значение заголовка Authorization или ссылка на токен."
    }
  },
  {
    "key": "timeout_seconds",
    "type": "string",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Timeout (seconds)",
      "russian": "Таймаут (секунды)"
    },
    "description": {
      "english": "Request timeout in seconds (default 30).",
      "russian": "Таймаут ожидания ответа в секундах (по умолчанию 30)."
    }
  }
]
$pep_in_03$::jsonb,
    $pep_out_03$
[
  {
    "key": "status_code",
    "type": "string",
    "label": {
      "english": "HTTP status code",
      "russian": "HTTP-код ответа"
    },
    "description": {
      "english": "Numeric HTTP response status code returned by the endpoint.",
      "russian": "Числовой код ответа HTTP, возвращённый внешней системой."
    },
    "example": "200"
  },
  {
    "key": "response_body",
    "type": "string",
    "label": {
      "english": "Response body",
      "russian": "Тело ответа"
    },
    "description": {
      "english": "Response body returned by the webhook endpoint.",
      "russian": "Тело ответа, возвращённое точкой вебхука."
    },
    "example": "{\"status\":\"ok\"}"
  },
  {
    "key": "duration_ms",
    "type": "string",
    "label": {
      "english": "Duration (ms)",
      "russian": "Длительность (мс)"
    },
    "description": {
      "english": "Round-trip request duration in milliseconds.",
      "russian": "Время выполнения запроса в миллисекундах."
    },
    "example": "145"
  }
]
$pep_out_03$::jsonb,
    true
),
(
    'aa0e8400-e29b-41d4-a716-446655440004',
    'http.webhook.patch',
    'http',
    'webhook',
    'patch',
    '{"english": "HTTP / Webhook", "russian": "HTTP / Вебхук"}'::jsonb,
    '{"english": "Webhook endpoint", "russian": "Точка вебхука"}'::jsonb,
    '{"english": "PATCH request", "russian": "PATCH-запрос"}'::jsonb,
    '{"english": "Sends an HTTP PATCH request to an external webhook URL with an optional payload, Authorization header, and timeout. Writes the HTTP status code, the response body, and the round-trip duration.", "russian": "Отправляет HTTP PATCH-запрос на внешний URL вебхука с необязательными телом, заголовком Authorization и таймаутом. Записывает HTTP-код ответа, тело ответа и длительность запроса."}'::jsonb,
    $pep_in_04$
[
  {
    "key": "url",
    "type": "string",
    "required": true,
    "source": "both",
    "label": {
      "english": "Endpoint URL",
      "russian": "URL вебхука"
    },
    "description": {
      "english": "Target HTTPS/HTTP URL of the external webhook endpoint.",
      "russian": "Целевой HTTPS/HTTP адрес внешней точки вебхука."
    }
  },
  {
    "key": "payload",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Request payload",
      "russian": "Тело запроса"
    },
    "description": {
      "english": "JSON body or value sent in the PATCH request.",
      "russian": "JSON-тело или значение, отправляемое в PATCH-запросе."
    }
  },
  {
    "key": "auth_header",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Authorization header",
      "russian": "Заголовок авторизации"
    },
    "description": {
      "english": "Optional Authorization header value or bearer token reference.",
      "russian": "Необязательное значение заголовка Authorization или ссылка на токен."
    }
  },
  {
    "key": "timeout_seconds",
    "type": "string",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Timeout (seconds)",
      "russian": "Таймаут (секунды)"
    },
    "description": {
      "english": "Request timeout in seconds (default 30).",
      "russian": "Таймаут ожидания ответа в секундах (по умолчанию 30)."
    }
  }
]
$pep_in_04$::jsonb,
    $pep_out_04$
[
  {
    "key": "status_code",
    "type": "string",
    "label": {
      "english": "HTTP status code",
      "russian": "HTTP-код ответа"
    },
    "description": {
      "english": "Numeric HTTP response status code returned by the endpoint.",
      "russian": "Числовой код ответа HTTP, возвращённый внешней системой."
    },
    "example": "200"
  },
  {
    "key": "response_body",
    "type": "string",
    "label": {
      "english": "Response body",
      "russian": "Тело ответа"
    },
    "description": {
      "english": "Response body returned by the webhook endpoint.",
      "russian": "Тело ответа, возвращённое точкой вебхука."
    },
    "example": "{\"status\":\"ok\"}"
  },
  {
    "key": "duration_ms",
    "type": "string",
    "label": {
      "english": "Duration (ms)",
      "russian": "Длительность (мс)"
    },
    "description": {
      "english": "Round-trip request duration in milliseconds.",
      "russian": "Время выполнения запроса в миллисекундах."
    },
    "example": "145"
  }
]
$pep_out_04$::jsonb,
    true
),
(
    'aa0e8400-e29b-41d4-a716-446655440005',
    'http.webhook.delete',
    'http',
    'webhook',
    'delete',
    '{"english": "HTTP / Webhook", "russian": "HTTP / Вебхук"}'::jsonb,
    '{"english": "Webhook endpoint", "russian": "Точка вебхука"}'::jsonb,
    '{"english": "DELETE request", "russian": "DELETE-запрос"}'::jsonb,
    '{"english": "Sends an HTTP DELETE request to an external webhook URL with an optional Authorization header and timeout. Writes the HTTP status code, the response body, and the round-trip duration.", "russian": "Отправляет HTTP DELETE-запрос на внешний URL вебхука с необязательными заголовком Authorization и таймаутом. Записывает HTTP-код ответа, тело ответа и длительность запроса."}'::jsonb,
    $pep_in_05$
[
  {
    "key": "url",
    "type": "string",
    "required": true,
    "source": "both",
    "label": {
      "english": "Endpoint URL",
      "russian": "URL вебхука"
    },
    "description": {
      "english": "Target HTTPS/HTTP URL of the external webhook endpoint.",
      "russian": "Целевой HTTPS/HTTP адрес внешней точки вебхука."
    }
  },
  {
    "key": "auth_header",
    "type": "string",
    "required": false,
    "source": "both",
    "label": {
      "english": "Authorization header",
      "russian": "Заголовок авторизации"
    },
    "description": {
      "english": "Optional Authorization header value or bearer token reference.",
      "russian": "Необязательное значение заголовка Authorization или ссылка на токен."
    }
  },
  {
    "key": "timeout_seconds",
    "type": "string",
    "required": false,
    "source": "literal_only",
    "label": {
      "english": "Timeout (seconds)",
      "russian": "Таймаут (секунды)"
    },
    "description": {
      "english": "Request timeout in seconds (default 30).",
      "russian": "Таймаут ожидания ответа в секундах (по умолчанию 30)."
    }
  }
]
$pep_in_05$::jsonb,
    $pep_out_05$
[
  {
    "key": "status_code",
    "type": "string",
    "label": {
      "english": "HTTP status code",
      "russian": "HTTP-код ответа"
    },
    "description": {
      "english": "Numeric HTTP response status code returned by the endpoint.",
      "russian": "Числовой код ответа HTTP, возвращённый внешней системой."
    },
    "example": "200"
  },
  {
    "key": "response_body",
    "type": "string",
    "label": {
      "english": "Response body",
      "russian": "Тело ответа"
    },
    "description": {
      "english": "Response body returned by the webhook endpoint.",
      "russian": "Тело ответа, возвращённое точкой вебхука."
    },
    "example": "{\"status\":\"ok\"}"
  },
  {
    "key": "duration_ms",
    "type": "string",
    "label": {
      "english": "Duration (ms)",
      "russian": "Длительность (мс)"
    },
    "description": {
      "english": "Round-trip request duration in milliseconds.",
      "russian": "Время выполнения запроса в миллисекундах."
    },
    "example": "145"
  }
]
$pep_out_05$::jsonb,
    true
)
ON CONFLICT (procedure_key) DO UPDATE SET
    connector = EXCLUDED.connector,
    resource = EXCLUDED.resource,
    method = EXCLUDED.method,
    connector_name = EXCLUDED.connector_name,
    resource_name = EXCLUDED.resource_name,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    input_schema = EXCLUDED.input_schema,
    output_schema = EXCLUDED.output_schema,
    is_system = EXCLUDED.is_system;

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.24.5',
        'Renamed app.instance.evi_instance_id to instance_id and kept the UUID. Renamed app.process_instances.variables to context and kept the JSON object. Renamed NOT NULL constraints instance_evi_instance_id_not_null to instance_instance_id_not_null and process_instances_variables_not_null to process_instances_context_not_null. Replaced the protect function and trigger with app.tgr_instance_protect_instance_id. Set the seed admin email to admin@example.com when it was still admin@evi.team. Set the system:updates:access description and the from.display.name description without the product name. Added paused to app.process_version_status and updated app.tgr_processes_validate_current_version so a current version may be active or paused. Created app.participants with app.prevent_system_participant_deletion and tgr_participants_prevent_system_delete, and seeded the system participants. Rewrote agreement version EVI_ELv2 to pre-mvp-notice and removed the license key from preferences.lastLocations. Created app.process_system_procedures with app.prevent_process_system_procedure_deletion and tgr_process_system_procedures_prevent_system_delete, and seeded 20 system procedures. Created app.process_external_procedures with app.prevent_process_external_procedure_deletion and tgr_process_external_procedures_prevent_system_delete, and seeded 5 external webhook procedures.'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.24.5', last_updated_at = NOW()
WHERE id = 1;

COMMIT;

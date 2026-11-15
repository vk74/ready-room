# API contract — service auditor

<!--
version: 0.28.3
Short description: Read-only endpoint contract for role-service-auditor.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract for catalog services, work-item forms, settings, Work runtime reads, and the requester channel.
-->

Reference for `role-service-auditor`.

All routes below are protected and require:

```http
Authorization: Bearer <JWT>
```

JWT is acquired via `POST /api/auth/bot/token` (see `role-auth`).

## Response envelope

Success:

```json
{
  "success": true,
  "code": "ADM_SVC-SUC-004",
  "data": {}
}
```

Failure:

```json
{
  "success": false,
  "code": "AZN-ERR-403"
}
```

## Field naming

- Query parameters are the names below. Several are camelCase (`itemsPerPage`, `searchQuery`, `sortBy`, `sortDesc`, `serviceId`, `statusFilter`, `kindFilter`, `catalogBinding`, `assignedUserId`, `assignedGroupId`, `requesterUserId`). Exceptions that stay a single lowercase word, or snake_case, are called out per endpoint (`status`, `search`, `q`, `language`, `scope`, `catalog_status`, `unbound`).
- Response entities are snake_case (`service_id`, `work_item_kind`, `request_number`).
- Pagination blocks use camelCase (`totalItems`, `totalPages`, `currentPage`, `itemsPerPage`).
- This skill sends no JSON bodies. Do not mirror response snake_case keys into write bodies in other skills.

## Scope behavior

`adminServices:items:read:all` reads every catalog service and work-item form. There is no own-row filter on those admin reads.

Work list and detail routes do not carry an RBAC permission middleware. They require an active user and the Work module. Rows are then filtered in the handler. A caller with `service:requests:read:all` skips that filter and sees every service request, manual task, approval, and acceptance. The same permission allows reading the `requester` channel. It does not allow posting to that channel and it does not allow the `internal` channel.

Catalog service and form routes also require the services module to be enabled. Work routes require the Work module.

## Design-time endpoints

### `GET /api/admin/app/services/fetchallservices`

- Script: `admin-services-list.sh`
- Permission: `adminServices:items:read` (`adminServices:items:read:all` satisfies it)
- Success code: `ADM_SVC-SUC-004`
- Query params (all optional):
  - `page` (default `1`)
  - `itemsPerPage` (default `25`, values outside `1..100` become `25`)
  - `searchQuery` — contains-match on the resolved name or `service_id`
  - `sortBy` — `service_id` | `name` | `status` | `owner` | `technical_owner` | `created_at` | `modified_at` (unknown falls back to `name`)
  - `sortDesc` — `true` sends descending; omitted is ascending
  - `status` — repeatable. Allow-list: `draft`, `active`, `planned_maintenance`, `emergency_maintenance`, `archived`. Unknown values are dropped. Empty means no status filter.
  - `language` — `english` or `russian` (default `english`), used to pick the display name
- `data` shape:

```json
{
  "services": [
    {
      "id": "uuid",
      "service_id": "svc-abc12",
      "translation_key": "service.svcabc12",
      "name": "Service title",
      "status": "active",
      "catalog_section_ids": ["section-uuid"],
      "icon_name": null,
      "owner_user_id": "uuid",
      "owner": "Display name",
      "technical_owner": "Display name",
      "created_at": "2026-01-01T00:00:00Z",
      "created_by": "uuid",
      "modified_at": null,
      "modified_by": null
    }
  ],
  "pagination": {
    "totalItems": 1,
    "totalPages": 1,
    "currentPage": 1,
    "itemsPerPage": 25
  }
}
```

`id` is the row UUID. `service_id` is the human-readable code.

### `GET /api/admin/app/services/fetchsingleservice`

- Script: `admin-services-get.sh <service_uuid>`
- Permission: `adminServices:items:read`
- Success code: `ADM_SVC-SUC-001`
- Query: `id` (required UUID)
- Missing `id`: `VAL-ERR-400`. Unknown id: `USR-ERR-404`.
- `data` is one service object: identity (`id`, `service_id`, `translation_key`, `status`, `catalog_section_ids`, `icon_name`, `comments`, audit columns), owner (`owner_user_id`, `owner` username), role labels (`technical_owner`, `dispatcher`, `support_tier1`, `support_tier2`, `support_tier3`), and `translations[]` (`translation_id`, `language_code`, `name`, `description_short`, `description_long`, `purpose`).

### `GET /api/admin/app/services/services/search`

- Script: `admin-services-search.sh <query>`
- Permission: `adminServices:items:read`
- Success code: `ADM_SVC-SUC-016`
- Query: `q` (contains-match on name, `service_id`, or `translation_key`), `limit` (default `20`, outside `1..100` becomes `20`), `language` (default `english`)
- `data`: `{ "items": [{ "uuid", "name", "service_id" }] }`

### `GET /api/admin/app/services/forms/search`

- Script: `admin-services-forms-search.sh`
- Permission: `adminServices:items:read`
- Success code: `ADM_SVC-SUC-015`
- Query: `q` (optional contains-match on form name or `form_id`), `limit` (default `20`, max `100`), `unbound=true` to keep only unbound `service_request` forms
- Only forms with a current version are returned.
- `data`: `{ "items": [{ "uuid", "name", "form_id", "current_version_number" }] }`

### `GET /api/admin/app/services/catalog-section-options`

- Script: `admin-services-catalog-section-options.sh`
- Permission: `adminServices:items:read`
- Success code: `ADM_SVC-SUC-006`
- `data` is an array of `{ "section_id", "name", "status" }`.

### `GET /api/admin/app/forms/fetch-all`

- Script: `admin-forms-list.sh`
- Permission: `adminServices:items:read`
- Success code: `ADM_FRM-SUC-001`
- Query params (all optional):
  - `page`, `itemsPerPage` — same bounds as the service list (`1..100`, default `25`)
  - `searchQuery` — contains-match on name or `form_id`
  - `statusFilter` — repeatable `draft` | `active`. This is the derived identity status (`draft` when there is no current version, otherwise `active`). Unknown values are dropped.
  - `kindFilter` — repeatable `service_request` | `incident` | `problem` | `change` | `organization`
  - `serviceId` — UUID; omit to list every service
  - `catalog_status` — repeatable `draft` | `active` | `on hold` | `discontinued`. The space in `on hold` is part of the value. This is `app.work_item_forms.catalog_status`, not the derived `status`.
  - `catalogBinding` — repeatable `bound` | `unbound`
  - `sortBy` — `form_id` | `name` | `work_item_kind` | `status` | `service_name` | `owner` | `created_at` | `updated_at` (unknown falls back to `name`)
  - `sortDesc` — `true` or omitted
- `data.forms[]` fields: `id` (UUID), `form_id` (human-readable code), `work_item_kind`, `name`, `status`, `current_version_id`, `current_version_number`, `draft_version_id`, `draft_version_number`, `service_id`, `service_name`, `catalog_order`, `catalog_status`, `region_id`, `region_name`, `owner_user_id`, `owner`, `created_at`, `updated_at`
- `data.pagination` matches the service list

### `GET /api/admin/app/forms/:id`

- Script: `admin-forms-get.sh <form_uuid>`
- Permission: `adminServices:items:read`
- Success code: `ADM_FRM-SUC-002`
- A non-UUID or unknown id is `404` `ADM_FRM-ERR-001`.
- `data` is the list row plus `versions[]` (each version has `id`, `version_number`, `status`, `definition`, `change_note`, publish and audit fields) and `catalog_translations[]` (`language_code`, `title`, `subject`). `definition` is the stored form definition JSON.

### `GET /api/admin/app/forms/regions`

- Script: `admin-forms-regions.sh`
- Permission: `adminServices:items:read`
- Success code: `ADM_FRM-SUC-011`
- `data`: `{ "regions": [{ "region_id", "region_name", "bound_form_id" }] }`
- `bound_form_id` is the organization form bound to that region, or null.

### `GET /api/core/settings`

- Script: `admin-services-settings-get.sh`
- Success code: `STG-SUC-002`
- `data`: `{ "settings": { "<section.path>": {} }, "defaults": {} }`
- The server drops sections the caller cannot read. This role receives `AdminApp.Services`, `AdminApp.Forms`, and `AdminApp.Practices` from `adminServices:settings:read:all`, plus `Application`, `Work`, `Reports`, and `Communications` from `settings:read:common`.
- Settings update (`POST /api/admin/settings/update`) is out of scope.

```bash
jq '.data.settings["AdminApp.Services"]'
```

## Runtime endpoints

Work list defaults when a query param is omitted: `scope=all`, `assignee=all`, and for requests `requester=all`. Page default `1`, `itemsPerPage` default `25` (max `100`). An invalid enum is `400` `VAL-ERR-001` (these routes validate; they do not drop unknown enum values). A malformed query bind is `REQ-ERR-001`.

A list `search` shorter than 2 characters is not applied. Assignee `user` filters only when `assignedUserId` is present. Requester `user` filters only when `requesterUserId` is present.

Sort keys that are not in the server switch fall back to `created_at`. `activities_estimated_minutes` and `activities_actual_minutes` are accepted by `work-requests-list.sh` and currently use that fallback. The response still includes those minute totals as fields. `total_estimated_minutes` and `total_actual_minutes` are real sort keys.

### `GET /api/work/requests`

- Script: `work-requests-list.sh`
- Success code: `WORK-SUC-001`
- Query: `scope` (`mine` | `assigned` | `team` | `unassigned` | `all`), `search`, repeatable `status` (`new` | `in_progress` | `paused` | `resolved` | `reopened` | `closed` | `cancelled` | `failed`), repeatable `urgency` (`low` | `medium` | `high` | `critical`), `serviceId`, `assignee` (`all` | `me` | `unassigned` | `user`), `assignedUserId`, `assignedGroupId`, `requester` (`all` | `me` | `user`), `requesterUserId`, `language` (`english` | `russian`, default `english`, picks the service name), `page`, `itemsPerPage`, `sortBy`, `sortDesc`
- `sortBy` values this skill sends: `created_at`, `request_number`, `status`, `urgency`, `title`, `priority`, `service`, `form`, `requester`, `requested_for`, `assignee`, `group`, `resolved_at`, `closed_at`, `estimated_minutes`, `actual_minutes`, `activities_estimated_minutes`, `activities_actual_minutes`, `total_estimated_minutes`, `total_actual_minutes`
- `data.requests[]` includes `id`, `request_number`, `title`, `description`, `impact`, `priority`, `watch_list`, `quantity`, `work_notes`, `form_id`, `form_name`, `service_id`, `service_name`, `urgency`, `status`, `pause_reason`, `channel`, requester and requested-for ids and names, `group_id`, `group_name`, `assigned_user_id`, `assigned_user`, `resolved_at`, `closed_at`, `created_at`, `updated_at`, `can_cancel`, and the minute fields (`estimated_minutes`, `actual_minutes`, `activities_estimated_minutes`, `activities_actual_minutes`, `total_estimated_minutes`, `total_actual_minutes`)
- `data.pagination` uses the camelCase pagination block. `totalPages` can be `0` when `totalItems` is `0`.

### `GET /api/work/requests/:id`

- Script: `work-requests-get.sh <request_uuid>`
- Success code: `WORK-SUC-002`
- Query: `language` (`english` | `russian`)
- Bad UUID: `VAL-ERR-001`. Missing row, including a row hidden by visibility: `WORK-ERR-001`.
- `data` is the list row plus `answers`, `definition`, `form_version_id`, `form_version_number`, `can_manage`, `process_instance`, `related_items`, `related_items_total`, `watch_list_users`, and `escalation_targets`.
- `can_manage` and `can_cancel` report what the caller may do. This skill does not call the update or cancel routes. `process_instance` is read-only context on the request.

### `GET /api/work/services/search`

- Script: `work-services-search.sh <query>`
- Success code: `WORK-SUC-004`
- Query: `q`, `limit` (default `20`, max `100`), `language` (default `english`)
- `data`: `{ "items": [{ "uuid", "name", "service_id" }] }`
- The script requires a non-empty query. The route itself treats an empty `q` as the first page of services.

### `GET /api/work/activities/manual-tasks`

- Script: `work-manual-tasks-list.sh`
- Success code: `WORK_MT-SUC-001`
- Query: `scope` (`assigned` | `team` | `unassigned` | `all`), `search`, repeatable `status` (`new` | `in_progress` | `paused` | `complete`), `assignee`, `assignedUserId`, `assignedGroupId`, `page`, `itemsPerPage`, `sortBy`, `sortDesc`
- `sortBy`: `created_at`, `task_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `estimated_minutes`, `actual_minutes`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`
- `data.manual_tasks[]`: `id`, `task_number`, `parent_kind`, `parent_id`, `title`, `description`, KB article fields, assignment, `status`, `outcome`, `pause_reason`, audit times, `process_token_id`, `completed_by`, minute fields, WBS/Gantt fields (`wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`, `predecessor_ids`), `can_manage`
- `data.pagination` as on the request list

### `GET /api/work/activities/manual-tasks/:id`

- Script: `work-manual-tasks-get.sh <task_uuid>`
- Success code: `WORK_MT-SUC-002`
- Bad UUID: `VAL-ERR-001`. Not visible: `WORK_MT-ERR-001`.
- `data` is the list row plus `related_items` and `related_items_total`.

### `GET /api/work/activities/approvals`

- Script: `work-approvals-list.sh`
- Success code: `WORK_AP-SUC-001`
- Query matches manual tasks, plus `language` (`english` | `russian`). The list query validates `language` and does not use it to translate list columns.
- Status values: `new`, `in_progress`, `paused`, `complete`
- `sortBy`: `created_at`, `approval_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`
- `data.approvals[]` matches the manual-task row shape with `approval_number`, `approval_notes`, and `rejection_notes` in place of the task number and KB fields. There are no estimated/actual minute columns on the approval row.

### `GET /api/work/activities/approvals/:id`

- Script: `work-approvals-get.sh <approval_uuid>`
- Success code: `WORK_AP-SUC-002`
- Query: `language`, used when the parent is a service order and the handler loads that order's stamp
- Bad UUID: `VAL-ERR-001`. Not visible: `WORK_AP-ERR-001`.
- `data` is the list row plus `service_order` (when the parent stamp loads), `related_items`, and `related_items_total`.

### `GET /api/work/activities/acceptances`

- Script: `work-acceptances-list.sh`
- Success code: `WORK_AC-SUC-001`
- Query matches manual tasks. Status values are `new`, `in_progress`, `complete` (`paused` is not valid).
- `sortBy`: `created_at`, `acceptance_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`
- `data.acceptances[]` matches the approval row shape with `acceptance_number` and `acceptance_notes`.

### `GET /api/work/activities/acceptances/:id`

- Script: `work-acceptances-get.sh <acceptance_uuid>`
- Success code: `WORK_AC-SUC-002`
- Bad UUID: `VAL-ERR-001`. Not visible: `WORK_AC-ERR-001`.
- `data` is the list row plus `related_items` and `related_items_total`.

### `GET /api/communications/entity/service_request/:id/channels/requester`

- Script: `work-request-chat-get.sh <request_uuid>`
- Success code: `COM-SUC-001`
- Query: `page` (default `1`), `itemsPerPage` (default `25`, values above `100` become `100`)
- `service:requests:read:all` may read this channel. `can_post` stays false unless the caller is involved in the request or can manage it. Read-all alone does not grant a post.
- Unknown request: `COM-ERR-001`. Channel the caller cannot read (including `internal`, which this skill does not call): `COM-ERR-002`.
- `data`: `conversation_id`, `entity_type`, `entity_id`, `channel_key`, `can_post`, `message_count`, `unread_count`, `last_read_message_id`, `last_read_at`, `pinned_messages`, `messages`, `participants`, `pagination`
- A message includes `id`, `author`, `kind`, `body`, reply and thread fields, `mentioned_user_ids`, `has_attachments`, `attachments`, `reactions`, pin and edit fields, and timestamps. Message file bytes are not downloaded here; list them with `role-attachments` only when that entity type is registered for the message.

## Common error codes

- `AUT-ERR-401`: missing, invalid, or expired JWT. `role-request.sh` retries once after re-auth.
- `AZN-ERR-403`: missing permission, or the account is disabled
- `ADM_SRV-ERR-403-MODULE-DISABLED`: services module is off (catalog service and form routes)
- `WORK-ERR-403-MODULE-DISABLED`: Work module is off
- `VAL-ERR-400`: service fetch called without `id`
- `VAL-ERR-001`: invalid Work or communications query, or a bad UUID on a Work path
- `REQ-ERR-001`: query bind failed
- `USR-ERR-404`: service UUID not found
- `ADM_FRM-ERR-001`: form UUID not found or not a UUID
- `WORK-ERR-001`, `WORK_MT-ERR-001`, `WORK_AP-ERR-001`, `WORK_AC-ERR-001`: runtime row not found or not visible
- `COM-ERR-001`: conversation entity not found
- `COM-ERR-002`: channel read refused
- `SYS-ERR-500`: internal error
- File list errors (`FILE-ERR-0xx`) belong to the `role-attachments` contract

## Non-goals

This skill does not call:

- `POST /api/admin/app/services/create`, `/update`, `/deleteservices`, `/assign-owner`
- `POST /api/admin/app/forms/create`, `PUT /api/admin/app/forms/:id`, `PUT /api/admin/app/forms/:id/catalog`, `DELETE /api/admin/app/forms/:id`, or any `/api/admin/app/forms/versions/*` or `/:id/draft` route
- `POST /api/admin/settings/update`
- `PATCH /api/work/requests/:id/work`, `POST /api/work/requests/:id/cancel`
- `PATCH /api/work/activities/manual-tasks/:id`, `.../approvals/:id`, `.../acceptances/:id`
- `POST` or `PATCH` under `/api/communications/`
- `GET /api/communications/entity/service_request/:id/channels/internal`
- Any `/api/admin/app/processes/*` route
- `PUT` or `DELETE` under `/api/fs`

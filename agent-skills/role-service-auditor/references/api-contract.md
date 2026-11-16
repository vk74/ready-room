# API contract — service auditor

<!--
version: 0.28.3
Short description: Design-time read contract for role-service-auditor.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract for the design-time reads: catalog services, work-item forms, and settings (`/api/admin/app/services/*`, `/api/admin/app/forms/*`, `GET /api/core/settings`).
- Runtime oversight is the read scripts of the work skills, `role-communications` (`chat-channel-get.sh` on channel `requester`), and `role-attachments` (`fs-files-list.sh`). `service:requests:read:all` is full read-only visibility across all rows.
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

- Query parameters are the names below. Several are camelCase (`itemsPerPage`, `searchQuery`, `sortBy`, `sortDesc`, `serviceId`, `statusFilter`, `kindFilter`, `catalogBinding`). Exceptions that stay a single lowercase word, or snake_case, are called out per endpoint (`status`, `search`, `q`, `language`, `catalog_status`, `unbound`).
- Response entities are snake_case (`service_id`, `work_item_kind`, `request_number`).
- Pagination blocks use camelCase (`totalItems`, `totalPages`, `currentPage`, `itemsPerPage`).
- This skill sends no JSON bodies. Do not mirror response snake_case keys into write bodies in other skills.

## Scope behavior

`adminServices:items:read:all` reads every catalog service and work-item form. There is no own-row filter on those admin reads.

`service:requests:read:all` grants full read-only visibility across all Work rows. List and detail routes in the work skills do not carry an RBAC permission middleware. They require an active user and the Work module, then filter rows in the handler. This permission skips that filter, so the read scripts of `role-work-service-requests`, `role-work-manual-activities`, `role-work-approvals`, and `role-work-acceptances` return every service request, manual task, approval, and acceptance. The same permission allows `role-communications` `chat-channel-get.sh` to read channel `requester`. It does not allow posting on that channel, and it does not allow the `internal` channel. It does not grant `service:requests:update:all`.

Catalog service and form routes also require the services module to be enabled. This skill does not call Work or communications routes.

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

## Runtime reads (other skills)

This skill does not wrap Work, communications, or file routes. An auditor bot composes the read scripts below. Payloads and error codes for those routes live in each skill's own contract. `service:requests:read:all` is what makes every row visible.

| Read | Skill and script |
|---|---|
| `GET /api/work/requests`, `GET /api/work/requests/:id`, `GET /api/work/services/search` | `role-work-service-requests`: `work-requests-list.sh`, `work-requests-get.sh`, `work-services-search.sh` |
| Practices slice of `GET /api/core/settings` | `role-work-service-requests`: `work-practices-settings-get.sh`. This skill's `admin-services-settings-get.sh` already returns `AdminApp.Practices` with the other readable sections. |
| `GET /api/work/activities/manual-tasks`, `GET /api/work/activities/manual-tasks/:id` | `role-work-manual-activities`: `work-manual-tasks-list.sh`, `work-manual-tasks-get.sh` |
| `GET /api/work/activities/approvals`, `GET /api/work/activities/approvals/:id` | `role-work-approvals`: `work-approvals-list.sh`, `work-approvals-get.sh` |
| `GET /api/work/activities/acceptances`, `GET /api/work/activities/acceptances/:id` | `role-work-acceptances`: `work-acceptances-list.sh`, `work-acceptances-get.sh` |
| `GET /api/communications/entity/service_request/:id/channels/requester` | `role-communications`: `chat-channel-get.sh service_request <request_uuid> requester` |
| `GET /api/fs` | `role-attachments`: `fs-files-list.sh` for `service_request`, `manual_task`, and `acceptance` |

Do not run the write scripts of those skills. Read-all does not set `can_post` on the requester channel and does not open `internal`.

## Common error codes

- `AUT-ERR-401`: missing, invalid, or expired JWT. `role-request.sh` retries once after re-auth.
- `AZN-ERR-403`: missing permission, or the account is disabled
- `ADM_SRV-ERR-403-MODULE-DISABLED`: services module is off (catalog service and form routes)
- `VAL-ERR-400`: service fetch called without `id`
- `USR-ERR-404`: service UUID not found
- `ADM_FRM-ERR-001`: form UUID not found or not a UUID
- `SYS-ERR-500`: internal error
- Work, communications, and file-list codes (`WORK-*`, `COM-*`, `FILE-ERR-0xx`) belong to the composed skills' contracts

## Non-goals

This skill does not call:

- `POST /api/admin/app/services/create`, `/update`, `/deleteservices`, `/assign-owner`
- `POST /api/admin/app/forms/create`, `PUT /api/admin/app/forms/:id`, `PUT /api/admin/app/forms/:id/catalog`, `DELETE /api/admin/app/forms/:id`, or any `/api/admin/app/forms/versions/*` or `/:id/draft` route
- `POST /api/admin/settings/update`
- Any `/api/work/*` route (read scripts live in `role-work-service-requests`, `role-work-manual-activities`, `role-work-approvals`, and `role-work-acceptances`)
- Any `/api/communications/*` route (`role-communications` `chat-channel-get.sh` on channel `requester` is the auditor read)
- Any `/api/admin/app/processes/*` route
- Any `/api/fs` route (`role-attachments` `fs-files-list.sh` is the auditor file list)

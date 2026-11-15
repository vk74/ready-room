# API contract — services admin

<!--
version: 0.28.3
Short description: Endpoint contract for role-service-admin (services, forms, settings, item selector).
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract for the role.adminServices.admin routes wrapped by this skill.
-->

Reference for `role-service-admin`.

All routes below are protected and require:

```http
Authorization: Bearer <JWT>
```

Services and forms routes also require the services module to be enabled.
When it is off they return `ADM_SRV-ERR-403-MODULE-DISABLED`.

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

Validation failures that carry a reason use `meta`:

```json
{
  "success": false,
  "code": "VAL-ERR-001",
  "meta": {
    "reason": "status_requires_section"
  }
}
```

## Permissions

This skill maps to `role.adminServices.admin`.

| Operation | Permission |
|---|---|
| Service and form reads | `adminServices:items:read:all` |
| Service and form create | `adminServices:items:create:all` |
| Service and form update, catalog, draft, save, publish, discard, assign-owner | `adminServices:items:update:all` |
| Service and form delete | `adminServices:items:delete:all` |
| `GET /api/core/settings` for `AdminApp.Services` and `AdminApp.Forms` | `adminServices:settings:read:all` |
| `GET /api/core/settings` for `AdminApp.Practices` and system sections | `adminServices:settings:read:all` or `settings:read:common` |
| `POST /api/admin/settings/update` for `AdminApp.Services`, `AdminApp.Forms`, `AdminApp.Practices` | `adminServices:settings:update:all` |
| User and group search | active authenticated user |

The route gate stores the permission without the `:all` suffix (`adminServices:items:read`, and so on). The role grant is the `:all` key. Both match.

## Field names

Service create and update bodies are **snake_case**. That is the contract for those two routes.

- Request `translations`: `{"english": {"name", "description_short", "description_long", "purpose"}, "russian": {...}}`.
- Single-service response `translations`: an array of rows (`language_code`, `name`, …). Do not POST that array back.
- Delete and assign-owner bodies are camelCase: `serviceIds`, `newOwnerUsername`.
- Form request bodies are camelCase.
- Form and service row fields in responses are snake_case.
- Pagination inside `data` is camelCase.

## Shared error codes

| Code | When | What to do |
|---|---|---|
| `AUT-ERR-401` | Missing or expired JWT | The auth wrapper re-authenticates and retries once |
| `AZN-ERR-403` | Caller lacks the route permission | Stop. Settings denial includes `meta.required` |
| `ADM_SRV-ERR-403-MODULE-DISABLED` | Services module is off | Services and forms routes only |
| `SYS-ERR-500` | Unexpected server failure | Retry once, then stop |
| `VAL-ERR-400` | Body could not be bound, or a required principal was missing or not assignable | Fix the payload |
| `VAL-ERR-001` | Field validation failed. `meta.reason` names the rule | Fix the named field |
| `VAL-ERR-409` | Unique value already taken (service `translation_key`, catalog order clash) | Choose another value |
| `REQ-ERR-001` | Body could not be read | Send `Content-Type: application/json` and a JSON object |
| `USR-ERR-404` | Service UUID was not found on get or update | Check `id` |
| `ADM_STG-ERR-001` | Setting value failed JSON Schema, or a locked boolean was turned off | Read `meta.reason` |
| `ADM_STG-ERR-002` | `sectionPath` + `settingName` does not exist | Check both fields |

Service translation and status reasons in `meta.reason`:

- `translation_required` — no language has a non-empty `name`
- `language_not_allowed` — a named language is outside `AdminApp.Services` `allowed.languages`
- `invalid_status`
- `status_requires_section` — `active`, `planned_maintenance`, or `emergency_maintenance` with no section
- `invalid_catalog_section_id`

A username or group that is missing, inactive, a system account, or (for groups) a system group is `VAL-ERR-400`, not a 404.

## Service endpoints

### `GET /api/admin/app/services/fetchallservices`

Query parameters:

| Param | Script flag | Notes |
|---|---|---|
| `page` | `--page` | Default 1 |
| `itemsPerPage` | `--items-per-page` | Default 25, clamped to 1–100 |
| `searchQuery` | `--search` | Matches display name and `service_id` |
| `sortBy` | `--sort-by` | `service_id`, `name`, `status`, `owner`, `technical_owner`, `created_at`, `modified_at`. Unknown falls back to `name` |
| `sortDesc` | `--sort-desc` | Sent as `true` |
| `status` | `--status` | Repeated. Allowed: `draft`, `active`, `planned_maintenance`, `emergency_maintenance`, `archived`. Unknown values are dropped |
| `language` | `--language` | `english` or `russian`. Default `english`. Chooses the display name |

Success `ADM_SVC-SUC-004`:

```json
{
  "success": true,
  "code": "ADM_SVC-SUC-004",
  "data": {
    "services": [],
    "pagination": {
      "totalItems": 0,
      "totalPages": 1,
      "currentPage": 1,
      "itemsPerPage": 25
    }
  }
}
```

Each list row includes `id` (UUID), `service_id` (`svc-{5hex}`), `name`, `status`, `catalog_section_ids`, `owner`, `technical_owner`, and timestamps. `name` is the resolved translation, not a column.

### `GET /api/admin/app/services/fetchsingleservice?id=<uuid>`

Success `ADM_SVC-SUC-001`. `data` is the service object.

Response roles are usernames (`owner`, `dispatcher`, `technical_owner`) or group names (`support_tier1`, `support_tier2`, `support_tier3`). `translations` is an array of stored rows. `catalog_section_ids` is a UUID array.

Missing id or a bad UUID: `VAL-ERR-400`. Unknown id: `USR-ERR-404`.

### `GET /api/admin/app/services/services/search`

Query: `q` (required by the script; the server treats an empty `q` as no text filter), `limit` (default 20, clamped to 1–100), `language` (default `english`).

Success `ADM_SVC-SUC-016`: `data.items[]` with `uuid`, `name`, `service_id`.

### `GET /api/admin/app/services/forms/search`

Query: `q`, `limit` (default 20, clamped to 1–100), `unbound=true` when `--unbound` is set.

Returns forms that have a current version. `unbound=true` keeps only unbound `service_request` forms.

Success `ADM_SVC-SUC-015`: `data.items[]` with `uuid`, `name`, `form_id`, `current_version_number`.

### `GET /api/admin/app/services/catalog-section-options`

Success `ADM_SVC-SUC-006`. `data` is an array of `{ "section_id", "name", "status" }`. `name` is the English catalog-section translation, or the section translation key when that translation is missing.

### `POST /api/admin/app/services/create`

Required: `owner`, `dispatcher`, `support_tier1`, `translations`.

Optional: `technical_owner`, `support_tier2`, `support_tier3`, `translation_key`, `status`, `catalog_section_ids`, `icon_name`, `comments`.

```json
{
  "owner": "bot_username",
  "dispatcher": "bot_username",
  "support_tier1": "support_group",
  "technical_owner": "bot_username",
  "status": "draft",
  "catalog_section_ids": ["section-uuid"],
  "icon_name": "plugs",
  "comments": "Internal note",
  "translations": {
    "english": {
      "name": "Network access",
      "description_short": "Request network access",
      "description_long": "Full description",
      "purpose": "Grant access"
    },
    "russian": {
      "name": "Сетевой доступ"
    }
  }
}
```

`owner`, `dispatcher`, and `technical_owner` are active standard or bot usernames. Support tiers are active non-system group names. `status` defaults to `draft`. `active` and both maintenance statuses need at least one catalog section. A client `service_id` is ignored.

Success `ADM_SVC-SUC-002`:

```json
{
  "success": true,
  "code": "ADM_SVC-SUC-002",
  "data": {
    "id": "service-uuid",
    "translation_key": "service-<generated>"
  }
}
```

Duplicate `translation_key`: `VAL-ERR-409`.

### `POST /api/admin/app/services/update`

Required: `id` (UUID).

```json
{
  "id": "service-uuid",
  "status": "active",
  "catalog_section_ids": ["section-uuid"]
}
```

- `status` omitted keeps the current status. The status column is still written.
- `catalog_section_ids` omitted, or JSON `null`, keeps placements. A present array replaces every `section_services` row. `[]` clears placements. Order in the array becomes the stored order.
- Including `translations` or any of `owner`, `technical_owner`, `dispatcher`, `support_tier1`, `support_tier2`, `support_tier3`, `translation_key`, `icon_name`, `comments` deletes junction user and group roles and writes them from this payload. `dispatcher` and `support_tier1` are then required. Optional roles that are omitted or blank are removed. `translations` upserts languages that have a non-empty `name` and leaves the other language in place.
- A status-only or placement-only body does not touch junction roles.

Success `ADM_SVC-SUC-003`: `data` is `{ "id": "<service-uuid>" }`.

Unknown id: `USR-ERR-404`.

### `POST /api/admin/app/services/deleteservices`

```json
{
  "serviceIds": ["service-uuid"]
}
```

`serviceIds` is a non-empty UUID array. The field name is camelCase.

Success `ADM_SVC-SUC-005` even when some ids fail. Read `data.totalErrors` and `data.errors`.

```json
{
  "success": true,
  "code": "ADM_SVC-SUC-005",
  "data": {
    "deletedServices": [{ "id": "service-uuid", "name": "translation_key" }],
    "errors": [{ "id": "missing-uuid", "error": "Service not found" }],
    "totalRequested": 2,
    "totalDeleted": 1,
    "totalErrors": 1
  }
}
```

`name` on a deleted row is the service `translation_key`. A service referenced by an order or request is listed in `errors` and is not deleted.

### `POST /api/admin/app/services/assign-owner`

```json
{
  "serviceIds": ["service-uuid"],
  "newOwnerUsername": "bot_username"
}
```

`newOwnerUsername` must be an active standard or bot account. One owner is applied to every id.

Success `ADM_SVC-SUC-017`. The HTTP call succeeds when some ids fail. Read `data.totalErrors`.

```json
{
  "success": true,
  "code": "ADM_SVC-SUC-017",
  "data": {
    "updatedServices": [{ "id": "service-uuid", "service_id": "svc-ab12c" }],
    "errors": [],
    "totalRequested": 1,
    "totalUpdated": 1,
    "totalErrors": 0
  }
}
```

Unknown username: `VAL-ERR-400`. A missing service id is an entry in `errors` (`"Service not found"`), not a top-level 404.

## Form endpoints

List `status` is derived: `draft` when the form has no current version, otherwise `active`. `catalog_status` is a different column: `draft`, `active`, `on hold`, `discontinued`.

### `GET /api/admin/app/forms/fetch-all`

| Param | Script flag | Notes |
|---|---|---|
| `page` | `--page` | Default 1 |
| `itemsPerPage` | `--items-per-page` | Default 25, clamped to 1–100 |
| `searchQuery` | `--search` | Matches `name` and `form_id` |
| `statusFilter` | `--status` | `draft` or `active` |
| `kindFilter` | `--kind` | `service_request`, `incident`, `problem`, `change`, `organization` |
| `serviceId` | `--service-id` | UUID. Limits the list to forms bound to that service |
| `catalog_status` | `--catalog-status` | `draft`, `active`, `on hold`, `discontinued`. The value `on hold` contains a space |
| `catalogBinding` | `--catalog-binding` | `bound` or `unbound` |
| `sortBy` | `--sort-by` | `form_id`, `name`, `work_item_kind`, `status`, `service_name`, `owner`, `created_at`, `updated_at`. Unknown falls back to `name` |
| `sortDesc` | `--sort-desc` | Sent as `true` |

The server accepts repeated values for the filter params. This skill's list script sends one value each.

Success `ADM_FRM-SUC-001`: `data.forms[]` plus `data.pagination` (`totalItems`, `totalPages`, `currentPage`, `itemsPerPage`).

A list row includes `id`, `form_id` (`form-{5hex}`), `work_item_kind`, `name`, derived `status`, version ids, `service_id`, `service_name`, `catalog_order`, `catalog_status`, `region_id`, `region_name`, and `owner`.

### `GET /api/admin/app/forms/<form_uuid>`

Success `ADM_FRM-SUC-002`. `data` is the list row plus `versions[]` and `catalog_translations[]`.

A version has `id`, `version_number`, `status` (`draft`, `active`, or `retired`), `definition`, `change_note`, and publish/audit timestamps. Catalog translations use `language_code`, `title`, `subject`.

Unknown id or a non-UUID: `ADM_FRM-ERR-001`.

### `GET /api/admin/app/forms/regions`

Success `ADM_FRM-SUC-011`: `data.regions[]` of `{ "region_id", "region_name", "bound_form_id" }`. `bound_form_id` is the organization form bound to that region, or null.

### `POST /api/admin/app/forms/create`

```json
{
  "workItemKind": "service_request",
  "name": "Network access request"
}
```

Organization form:

```json
{
  "workItemKind": "organization",
  "name": "Regional organization",
  "regionId": 1
}
```

The server creates the identity and the first draft from the kind skeleton. `form_id` is server-assigned.

`regionId` on any kind other than `organization` returns `VAL-ERR-001` with `meta.reason` `region_requires_organization_kind`. An organization form with no `regionId` takes the first free region. No free region: `ADM_FRM-ERR-007` with `meta.reason` `no_free_regions`. A region already bound to a form: `ADM_FRM-ERR-007` with `region_already_bound`. Unknown region: `VAL-ERR-001` `region_not_found`. A kind the server cannot seed: `ADM_FRM-ERR-004` `work_item_kind_not_implemented`.

Success `ADM_FRM-SUC-003`. `data` is the form detail.

`name` is 1–250 characters.

### `PUT /api/admin/app/forms/<form_uuid>`

```json
{
  "name": "Network access request",
  "regionId": 1
}
```

Omitted `name` or `regionId` is left unchanged (`COALESCE`). `regionId` is rejected on a non-organization form (`region_requires_organization_kind`). A region already bound to another form: `ADM_FRM-ERR-007` `region_already_bound`.

Identity `status` is not writable.

Success `ADM_FRM-SUC-004`. `data` is the list row.

### `PUT /api/admin/app/forms/<form_uuid>/catalog`

```json
{
  "serviceId": "service-uuid",
  "order": 1,
  "catalogStatus": "draft",
  "translations": [
    {
      "languageCode": "english",
      "title": "Network access",
      "subject": "Request access"
    }
  ]
}
```

This call replaces the binding and replaces every catalog translation.

- `serviceId` omitted, `null`, or blank unbinds the form. `catalog_order` is stored as 0 and `order` is ignored.
- A non-null `serviceId` must be an existing service UUID, and the form's kind must be `service_request` (`catalog_binding_requires_service_request` otherwise).
- When bound, `order` must be at least 1. The server clamps it to the sibling count plus one.
- `catalogStatus`: `draft` is always legal. `active` needs a bound service and a current version (`catalog_status_requires_bind`, `catalog_status_requires_active_version`). `on hold` and `discontinued` need a bound service. Anything else is `invalid_catalog_status`.
- `translations` is required, 1–20 items. Each needs `languageCode` and `title` (1–250). `subject` is optional, max 250. A language outside `AdminApp.Forms` `allowed.languages` is `language_not_allowed`. The previous catalog translations are deleted first.

Success `ADM_FRM-SUC-010`. `data` is the form detail.

To unbind, send `serviceId: null`, a legal unbound `catalogStatus` (`draft`), and the translations you want to keep. Omitting `translations` fails validation.

### `DELETE /api/admin/app/forms/<form_uuid>`

Success `ADM_FRM-SUC-005`: `data` is `{ "id", "name" }`.

A form bound to a service: `ADM_FRM-ERR-002` with `meta.reason` `bound_to_catalog_service`. A form whose version is still referenced by a request: `ADM_FRM-ERR-002` without that reason. Unbind, or wait until those requests are gone, before deleting.

### `POST /api/admin/app/forms/<form_uuid>/draft`

No body. Creates a draft when none exists, cloning the current definition, or the kind skeleton when the form has never been published. An existing draft is returned as-is.

Success `ADM_FRM-SUC-006`: `data.draft_version_id` and `data.versions`.

### `PUT /api/admin/app/forms/versions/<version_uuid>`

```json
{
  "definition": {},
  "changeNote": "Adjust the request fields"
}
```

`definition` must be a valid form definition for that form's `workItemKind`. Copy the definition from `GET /api/admin/app/forms/<form_uuid>` and edit it. An empty object is not a valid definition. `changeNote` is optional, max 500 characters.

Only a draft can be saved. A published version returns `ADM_FRM-ERR-003`. An invalid definition returns `ADM_FRM-ERR-004` with `meta.reason` and `meta.field`.

Success `ADM_FRM-SUC-007`: `data.versions`.

### `POST /api/admin/app/forms/versions/<version_uuid>/publish`

No body. The draft becomes the active version. Previous active versions of that form are retired. The definition is validated again.

Success `ADM_FRM-SUC-008`. `data` is the form detail.

Not a draft: `ADM_FRM-ERR-003`. Invalid definition: `ADM_FRM-ERR-004`. Publish does not require a related process.

### `DELETE /api/admin/app/forms/versions/<version_uuid>`

No body. Deletes a draft version.

Success `ADM_FRM-SUC-009`: `data.form_id` and `data.versions`.

A published version: `ADM_FRM-ERR-003`.

## Settings

### `GET /api/core/settings`

Success `STG-SUC-002`:

```json
{
  "success": true,
  "code": "STG-SUC-002",
  "data": {
    "settings": {
      "AdminApp.Practices": {
        "time_tracking.require_actual_on_close": false
      }
    },
    "defaults": {}
  }
}
```

`data.settings` is `sectionPath -> settingName -> value` for standard settings only: `is_public` false and `confidentiality` false, then limited to sections this caller may read. `data.defaults` has the same shape for default values. Public settings and confidential settings are not included.

For this role the standard rows are `AdminApp.Practices` and `AdminApp.Services.Fs.Quotas`.

These rows are public (`is_public` true), so this GET does not return them:

- `AdminApp.Services` `allowed.languages` and `service.card.visibility.*`
- `AdminApp.Forms` `allowed.languages`
- `Application.RegionalSettings` `languages.scope` and `allowed.languages`

This skill does not call `GET /api/public/settings`. `POST /api/admin/settings/update` can still write the public keys. A following settings-get will not echo them.

### `POST /api/admin/settings/update`

One setting per request.

```json
{
  "sectionPath": "AdminApp.Services",
  "settingName": "allowed.languages",
  "value": ["english", "russian"]
}
```

`sectionPath` for this role:

- `AdminApp.Services` — public card-visibility booleans (`service.card.visibility.owner`, `service.card.visibility.technical.owner`, `service.card.visibility.dispatcher`, `service.card.visibility.support.tier1`, `service.card.visibility.support.tier2`, `service.card.visibility.support.tier3`) and public `allowed.languages`
- `AdminApp.Services.Fs.Quotas` — standard quota integers, same permission prefix as `AdminApp.Services` (`entity.max.bytes`, `entity.max.count`, `user.per.day.max.bytes`, `module.total.storage.max.bytes`)
- `AdminApp.Forms` — public `allowed.languages`
- `AdminApp.Practices` — standard settings `priority.matrix`, `escalation.practice_manager.policy`, `escalation.company_head.policy`, `time_tracking.require_actual_on_close`

`allowed.languages` must stay a subset of the global allowed languages. When `Application.RegionalSettings` `languages.scope` is `"global"`, the UI ignores the module list. `languages.scope` is a public setting and is not in `GET /api/core/settings`.

Success `ADM_STG-SUC-001`. `data` is the updated setting (`section_path`, `setting_name`, `value`, `is_public`).

Another module's section returns `AZN-ERR-403`.

## Item selector

Both routes require an active user. The query must be at least 2 characters. `limit` defaults to 20 and is clamped to 1–100. Shorter queries return `VAL-ERR-400`.

### `GET /api/core/item-selector/search-users`

Query: `query`, `limit`, and, only when the flags are set, `include_bots=true` and `exclude_system=true`.

Without `--include-bots` the search omits bots. `--exclude-system` omits system principals. Use both when picking a service owner or dispatcher: those fields accept an active standard or bot username and reject system accounts.

Success `ISL-SUC-001`: `data.items[]` of `{ "uuid", "name", "username", "status" }` and `data.total`. For users, `name` is the profile display name, with username as fallback. `status` is `account_status`.

### `GET /api/core/item-selector/search-groups`

Query: `query`, `limit`, and `exclude_system=true` when `--exclude-system` is set.

Support tiers accept an active non-system group name. Pass `--exclude-system` for that picker.

Success `ISL-SUC-001`. Group items set `username` equal to `name`. `status` is empty.

## Non-goals

This skill does not call:

- `/api/admin/app/processes/*` (process library, editor, versions, instances, events, procedures)
- product, catalog, knowledge-base, or organization admin routes
- settings sections other than `AdminApp.Services`, `AdminApp.Services.Fs.Quotas`, `AdminApp.Forms`, and `AdminApp.Practices`
- `GET /api/public/settings` (public rows such as `allowed.languages` and card visibility are written through `POST /api/admin/settings/update` and are not returned by `GET /api/core/settings`)
- `GET /api/core/item-selector/search-organizations` and `search-participants`
- attachment upload (`role-attachments` owns `/api/fs`)

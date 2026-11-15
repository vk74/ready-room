---
name: role-service-admin
description: >
  Service administration skill for evi. Covers service and work-item form
  administration, owner assignment, catalog binding, and AdminApp.Services,
  AdminApp.Forms, and AdminApp.Practices settings for bots mapped to
  role.adminServices.admin.
last_release: "0.28.3"
compatibility: Requires curl, jq, and network access to the evi instance. Auth helper resolution is REQUEST_SCRIPT, then scripts/_lib/role-request.sh, then ../../role-auth/scripts/role-request.sh (set REQUEST_SCRIPT to override).
required_environment_variables:
  - name: BASE_URL
    prompt: evi instance base URL (e.g. https://evi.example.com or http://localhost:7070)
    help: No trailing slash.
    required_for: full functionality
  - name: API_KEY
    prompt: Bot API key in bkey_<key_id>_<secret> format
    help: Used by role-auth to exchange for JWT.
    required_for: full functionality
  - name: TLS_INSECURE
    prompt: Set to 1 for self-signed TLS in dev/test
    help: Optional. When 1/true/yes/on, scripts pass -k to curl.
    required_for: self-signed deployments
  - name: CA_CERT_FILE
    prompt: Path to a PEM CA certificate for the evi endpoint
    help: Optional. Preferred over TLS_INSECURE for trusted self-hosted certs.
    required_for: custom/private CA deployments
  - name: AGENT_HOME
    prompt: Base directory for local agent cache and state
    help: Optional. Defaults to ~/.agent-skills; used by role-auth cache files.
    required_for: custom local runtime layout
---

# role-service-admin

<!--
version: 0.28.3
Short description: Full-scope admin role skill for services and work item forms.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill for role.adminServices.admin: service CRUD, form lifecycle,
  catalog binding, owner assignment, item-selector search, and settings.
-->

Standalone services admin skill for bots assigned to `role.adminServices.admin`
(*Role Service Administrators*).

Run the scripts in `scripts/`. Do not retype them.

## Role mapping

This skill is the external-agent counterpart of system group `role.adminServices.admin`.

Permissions held by that group:

- `adminServices:module:access`
- `adminServices:settings:access`
- `adminServices:settings:read:all`
- `adminServices:settings:update:all`
- `adminServices:items:read:all`
- `adminServices:items:create:all`
- `adminServices:items:update:all`
- `adminServices:items:delete:all`

`settings:read:common` comes from `role.users.registered`. It can read
`AdminApp.Practices` and the system settings sections. Updating
`AdminApp.Practices` still requires `adminServices:settings:update:all`.

## Scope

Included methods:

- `adminServices.items.list` -> `GET /api/admin/app/services/fetchallservices`
- `adminServices.items.get` -> `GET /api/admin/app/services/fetchsingleservice`
- `adminServices.items.search` -> `GET /api/admin/app/services/services/search`
- `adminServices.forms.search` -> `GET /api/admin/app/services/forms/search`
- `adminServices.catalogSectionOptions.list` -> `GET /api/admin/app/services/catalog-section-options`
- `adminServices.items.create` -> `POST /api/admin/app/services/create`
- `adminServices.items.update` -> `POST /api/admin/app/services/update`
- `adminServices.items.delete` -> `POST /api/admin/app/services/deleteservices`
- `adminServices.items.assignOwner` -> `POST /api/admin/app/services/assign-owner`
- `adminServices.forms.list` -> `GET /api/admin/app/forms/fetch-all`
- `adminServices.forms.get` -> `GET /api/admin/app/forms/<form_uuid>`
- `adminServices.forms.regions` -> `GET /api/admin/app/forms/regions`
- `adminServices.forms.create` -> `POST /api/admin/app/forms/create`
- `adminServices.forms.update` -> `PUT /api/admin/app/forms/<form_uuid>`
- `adminServices.forms.catalog` -> `PUT /api/admin/app/forms/<form_uuid>/catalog`
- `adminServices.forms.delete` -> `DELETE /api/admin/app/forms/<form_uuid>`
- `adminServices.forms.draft` -> `POST /api/admin/app/forms/<form_uuid>/draft`
- `adminServices.forms.version.save` -> `PUT /api/admin/app/forms/versions/<version_uuid>`
- `adminServices.forms.version.publish` -> `POST /api/admin/app/forms/versions/<version_uuid>/publish`
- `adminServices.forms.version.discard` -> `DELETE /api/admin/app/forms/versions/<version_uuid>`
- `adminServices.settings.read` -> `GET /api/core/settings`
- `adminServices.settings.update` -> `POST /api/admin/settings/update`
- `core.itemSelector.searchUsers` -> `GET /api/core/item-selector/search-users`
- `core.itemSelector.searchGroups` -> `GET /api/core/item-selector/search-groups`

Explicitly excluded:

- Processes (`/api/admin/app/processes/*`) — library, editor, versions, instances, events, procedures
- Settings for other modules (`AdminApp.Products`, `AdminApp.Catalog`, `KnowledgeBase`, …)

`AdminApp.Services.Fs.Quotas` uses the same `adminServices:settings` permission as
`AdminApp.Services`. The settings update script can address it. This skill has no
separate quota workflow.

## Field names

Service create and update bodies are **snake_case**. Do not copy a GET response
back into those bodies.

- Request `translations` is an object keyed by `english` and `russian`.
- Response `translations` on a single service is an array of rows with `language_code`.
- Delete and assign-owner use camelCase: `serviceIds`, `newOwnerUsername`.
- Form bodies are camelCase (`workItemKind`, `regionId`, `serviceId`, `catalogStatus`, `languageCode`, `changeNote`).
- Form and service response rows are snake_case.
- List pagination keys are camelCase (`totalItems`, `totalPages`, `currentPage`, `itemsPerPage`).

## Service write rules

Create requires `owner`, `dispatcher`, `support_tier1`, and `translations`.

- `owner` and `dispatcher` are active standard or bot usernames. `technical_owner` is the same, and is optional.
- `support_tier1` is an active non-system group name. `support_tier2` and `support_tier3` are the same, and are optional.
- `translations` needs at least one allowed language with a non-empty `name`.
- `status` is `draft`, `active`, `planned_maintenance`, `emergency_maintenance`, or `archived`. Omitted status is `draft`.
- `active`, `planned_maintenance`, and `emergency_maintenance` require at least one id in `catalog_section_ids`.
- `translation_key` is optional. Empty or omitted generates a key. A client `service_id` is ignored; the server assigns `svc-{5hex}`.

Update requires `"id": "<service-uuid>"`.

- Omit `catalog_section_ids` to keep section placements. A present array, including `[]`, replaces them.
- Omit `translations` and the role/identity fields (`owner`, `technical_owner`, `dispatcher`, `support_tier1`, `support_tier2`, `support_tier3`, `translation_key`, `icon_name`, `comments`) to keep junction roles.
- When any of those fields is included, the backend deletes the service's junction roles and writes them again from the payload. `dispatcher` and `support_tier1` are required in that payload. `translations` upserts each language that has a non-empty `name`; it does not delete the other language.
- There is no separate "add a section" script. Read the service, then send the full `catalog_section_ids` array when placements must change.

`admin-services-update.sh` prints a warning when the payload contains those replacing fields.

## Form write rules

Create body: `{"workItemKind": "service_request", "name": "...", "regionId": 1}`.

- `workItemKind` is `service_request`, `incident`, `problem`, `change`, or `organization`.
- `regionId` is only for `organization`. Other kinds must omit it. An organization form with no `regionId` is bound to the first free region.
- Identity update omits a field to leave it unchanged. `name` and `regionId` use that rule. `regionId` on a non-organization form is rejected.

Catalog update is an authoritative write:

- omitted or `null` `serviceId` unbinds the form
- `translations` replaces every catalog translation
- `order` is the 1-based position when bound, and is ignored when unbound
- `catalogStatus` `active` requires a bound service and a current (published) version
- `on hold` and `discontinued` require a bound service
- only a `service_request` form can be bound

`admin-forms-catalog-update.sh` prints that warning on every call.

A form delete is refused while the form is bound to a service, or while a request still references one of its versions. Unbind first.

Publish and discard act on a draft version. A published version is frozen.

## Destructive operations

- `admin-services-delete.sh` deletes the listed services. The HTTP call can succeed while `data.errors` reports ids that were missing or still referenced. Read `totalErrors`.
- `admin-forms-delete.sh` deletes one form.
- `admin-forms-version-discard.sh` deletes a draft version.
- `admin-services-update.sh` replaces junction roles or placements when those fields are present.
- `admin-forms-catalog-update.sh` replaces catalog translations and unbinds when `serviceId` is omitted or null.

Settings update changes one key at a time. It is not a full-section replace. The value is checked against the setting's JSON Schema.

## Settings

Sections this role updates:

- `AdminApp.Services`
- `AdminApp.Forms`
- `AdminApp.Practices`

`GET /api/core/settings` returns the standard settings the caller may read, nested as `data.settings[sectionPath][settingName]`, plus `data.defaults`. It is not limited to the three sections above.

`GET /api/core/settings` returns standard settings only (`is_public` false and not confidential), limited to sections this caller may read. For this role that includes `AdminApp.Practices` and `AdminApp.Services.Fs.Quotas`.

`allowed.languages`, the service card-visibility flags, and `Application.RegionalSettings` `languages.scope` are public settings. They are not in this response. This skill does not call `GET /api/public/settings`. The update script can still write those public keys; a later settings-get will not show them.

`allowed.languages` on `AdminApp.Services` and `AdminApp.Forms` must stay a subset of the global allowed languages. When `languages.scope` is `"global"`, the UI ignores the module list.

## JWT contract

Every protected request uses:

```http
Authorization: Bearer <JWT>
```

JWT lifecycle is delegated to the shared auth scripts. Resolution order: `REQUEST_SCRIPT`, then `scripts/_lib/role-request.sh`, then `../../role-auth/scripts/role-request.sh`.

Environment variables (`BASE_URL`, `API_KEY`, TLS options) must be **exported**. Hosts that start a fresh shell for each command should rely on `${AGENT_HOME:-$HOME/.agent-skills}/role.env` written by `role-setup.sh`.

All JSON-body requests send `Content-Type: application/json` (scripts set this automatically).

## Script map

- `scripts/admin-services-list.sh [--page N] [--items-per-page N] [--search "<text>"] [--sort-by service_id|name|status|owner|technical_owner|created_at|modified_at] [--sort-desc] [--status draft|active|planned_maintenance|emergency_maintenance|archived] [--language english|russian]`
- `scripts/admin-services-get.sh <service_uuid>`
- `scripts/admin-services-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/admin-services-forms-search.sh [<query>] [--limit N] [--unbound]`
- `scripts/admin-services-catalog-section-options.sh`
- `scripts/admin-services-create.sh <payload.json>`
- `scripts/admin-services-update.sh <payload.json>`
- `scripts/admin-services-delete.sh <payload.json>`
- `scripts/admin-services-assign-owner.sh <payload.json>`
- `scripts/admin-forms-list.sh [--page N] [--items-per-page N] [--search "<text>"] [--status draft|active] [--kind service_request|incident|problem|change|organization] [--service-id <uuid>] [--catalog-status "draft|active|on hold|discontinued"] [--catalog-binding bound|unbound] [--sort-by form_id|name|work_item_kind|status|service_name|owner|created_at|updated_at] [--sort-desc]`
- `scripts/admin-forms-get.sh <form_uuid>`
- `scripts/admin-forms-regions.sh`
- `scripts/admin-forms-create.sh <payload.json>`
- `scripts/admin-forms-update.sh <form_uuid> <payload.json>`
- `scripts/admin-forms-catalog-update.sh <form_uuid> <payload.json>`
- `scripts/admin-forms-delete.sh <form_uuid>`
- `scripts/admin-forms-draft-ensure.sh <form_uuid>`
- `scripts/admin-forms-version-save.sh <version_uuid> <payload.json>`
- `scripts/admin-forms-version-publish.sh <version_uuid>`
- `scripts/admin-forms-version-discard.sh <version_uuid>`
- `scripts/admin-services-settings-get.sh`
- `scripts/admin-services-settings-update.sh <payload.json>`
- `scripts/core-search-users.sh <query> [--limit N] [--include-bots] [--exclude-system]`
- `scripts/core-search-groups.sh <query> [--limit N] [--exclude-system]`

`--status` on `admin-services-list.sh` may be repeated. Each value is sent as its own `status` query parameter.

User and group search queries must be at least 2 characters. `--include-bots` sends `include_bots=true`. `--exclude-system` sends `exclude_system=true`. Flags that are omitted are not sent.

## Usage examples

```bash
bash scripts/admin-services-list.sh --search "network" --status active --status planned_maintenance
bash scripts/admin-services-get.sh "service-uuid"
bash scripts/admin-services-search.sh "network" --limit 20 --language english
bash scripts/admin-services-forms-search.sh --unbound --limit 20
bash scripts/admin-services-catalog-section-options.sh
bash scripts/core-search-users.sh "ann" --limit 10 --include-bots --exclude-system
bash scripts/core-search-groups.sh "support" --exclude-system

bash scripts/admin-services-create.sh ./payloads/create-service.json
bash scripts/admin-services-update.sh ./payloads/update-service.json
bash scripts/admin-services-delete.sh ./payloads/delete-services.json
bash scripts/admin-services-assign-owner.sh ./payloads/assign-owner.json

bash scripts/admin-forms-list.sh --kind service_request --catalog-binding unbound
bash scripts/admin-forms-create.sh ./payloads/create-form.json
bash scripts/admin-forms-draft-ensure.sh "form-uuid"
bash scripts/admin-forms-version-save.sh "version-uuid" ./payloads/save-draft.json
bash scripts/admin-forms-version-publish.sh "version-uuid"
bash scripts/admin-forms-catalog-update.sh "form-uuid" ./payloads/catalog.json

bash scripts/admin-services-settings-get.sh \
  | jq '.data.settings["AdminApp.Practices"]["time_tracking.require_actual_on_close"]'
bash scripts/admin-services-settings-update.sh ./payloads/update-setting.json
```

Create-service payload (`create-service.json`):

```json
{
  "owner": "bot_username",
  "dispatcher": "bot_username",
  "support_tier1": "support_group",
  "status": "draft",
  "catalog_section_ids": ["section-uuid"],
  "translations": {
    "english": {
      "name": "Network access",
      "description_short": "Request network access",
      "description_long": "Full description",
      "purpose": "Grant access"
    }
  }
}
```

Update-service payload (`update-service.json`):

```json
{
  "id": "service-uuid",
  "status": "active",
  "catalog_section_ids": ["section-uuid"]
}
```

That payload changes status and replaces placements. It omits role fields, so junction roles stay as they are. `active` still requires at least one section.

Delete payload:

```json
{
  "serviceIds": ["service-uuid"]
}
```

Assign-owner payload:

```json
{
  "serviceIds": ["service-uuid"],
  "newOwnerUsername": "bot_username"
}
```

Catalog payload:

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

Settings payload (`update-setting.json`):

```json
{
  "sectionPath": "AdminApp.Services",
  "settingName": "allowed.languages",
  "value": ["english", "russian"]
}
```

`sectionPath` may also be `AdminApp.Forms` or `AdminApp.Practices`. `allowed.languages` is a public setting: the update is stored, and `admin-services-settings-get.sh` does not return it.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)

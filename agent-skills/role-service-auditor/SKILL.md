---
name: role-service-auditor
description: >
  Read-only design-time service auditor skill. Wraps catalog services,
  work-item forms, and service settings. Use with the read scripts of the
  work, communications, and attachments skills for bots mapped to
  role.service.auditor, where service:requests:read:all grants full
  read-only visibility across all rows.
last_release: "0.28.3"
compatibility: Requires curl, jq, and network access to the evi instance. Self-contained — auth helper scripts are vendored in scripts/_lib (set REQUEST_SCRIPT to override).
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

# role-service-auditor

<!--
version: 0.28.3
Short description: Design-time read methods for the service auditor, composed with work, chat, and file reads.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill for system group role.service.auditor.
- Design-time reads of catalog services, work-item forms, and service settings (`/api/admin/app/services/*`, `/api/admin/app/forms/*`, `GET /api/core/settings`).
- Runtime oversight composes the read scripts of the work skills, `role-communications` (`chat-channel-get.sh` on channel `requester`), and `role-attachments` (`fs-files-list.sh`). `service:requests:read:all` is full read-only visibility across all rows.
-->

Read-only design-time oversight for bots assigned to `role.service.auditor` (Role Service Auditors). Runtime rows, the requester channel, and file lists come from the composed skills below.

Run the scripts that ship in this skill directory. Do not recreate them by writing their source back out. Install the skill by direct download or, once the pack bundle exists, by `base64 -d | tar xz`.

## Role mapping

This skill is the external-agent counterpart of system group `role.service.auditor`.

Permissions the group holds:

- `adminServices:module:access`
- `adminServices:settings:access`
- `adminServices:settings:read:all`
- `adminServices:items:read:all`
- `service:requests:read:all`

`settings:read:common` is held through `role.users.registered` (every registered account, including bots). It is not a grant on `role.service.auditor` itself.

`adminServices:items:read:all` satisfies the admin route gate `adminServices:items:read`. `service:requests:read:all` removes the per-row visibility filter on Work service requests, manual tasks, approvals, and acceptances, and it allows reading the service-request `requester` discussion channel. Those runtime reads are the composed skills below. This permission does not grant `service:requests:update:all`.

## Role composition

`role.service.auditor` is `role-auth` plus this skill plus the read scripts of the work skills, `role-communications`, and `role-attachments`. `service:requests:read:all` grants full read-only visibility across all rows.

- `role-auth` obtains and refreshes the JWT. This skill never calls `/api/*` except through `role-request.sh`.
- This skill wraps the design-time reads: `/api/admin/app/services/*`, `/api/admin/app/forms/*`, and `GET /api/core/settings`.
- Service requests: the read scripts of `role-work-service-requests` — `work-requests-list.sh`, `work-requests-get.sh`, `work-services-search.sh`, and `work-practices-settings-get.sh`. Do not run the update, assign, status, watcher, or cancel scripts.
- Manual tasks: the read scripts of `role-work-manual-activities` — `work-manual-tasks-list.sh` and `work-manual-tasks-get.sh`. Do not run `work-manual-tasks-update.sh` or `work-manual-tasks-attachments-add.sh`.
- Approvals: the read scripts of `role-work-approvals` — `work-approvals-list.sh` and `work-approvals-get.sh`. Do not run `work-approvals-update.sh`.
- Acceptances: the read scripts of `role-work-acceptances` — `work-acceptances-list.sh` and `work-acceptances-get.sh`. Do not run `work-acceptances-update.sh` or `work-acceptances-attachments-add.sh`.
- Discussion: `role-communications` `chat-channel-get.sh` on channel `requester` (`chat-channel-get.sh service_request <request_uuid> requester`). Read-all can read that channel and cannot post. Do not post, edit, delete, react, pin, or mark the conversation read. The `internal` channel stays closed unless this bot also has `can_manage`.
- Files: `role-attachments` `fs-files-list.sh`. Do not upload or delete.

## Scope

Design-time reads wrapped by this skill:

- `adminServices.items.list` -> `GET /api/admin/app/services/fetchallservices`
- `adminServices.items.get` -> `GET /api/admin/app/services/fetchsingleservice`
- `adminServices.items.search` -> `GET /api/admin/app/services/services/search`
- `adminServices.forms.search` -> `GET /api/admin/app/services/forms/search`
- `adminServices.catalogSectionOptions.list` -> `GET /api/admin/app/services/catalog-section-options`
- `adminServices.forms.list` -> `GET /api/admin/app/forms/fetch-all`
- `adminServices.forms.get` -> `GET /api/admin/app/forms/:id`
- `adminServices.forms.regions` -> `GET /api/admin/app/forms/regions`
- `adminServices.settings.read` -> `GET /api/core/settings`

Runtime reads are the composed skills, not scripts in this directory:

- `GET /api/work/requests`, `GET /api/work/requests/:id`, `GET /api/work/services/search`, and the practices slice of `GET /api/core/settings` -> `role-work-service-requests`
- `GET /api/work/activities/manual-tasks` and `GET /api/work/activities/manual-tasks/:id` -> `role-work-manual-activities`
- `GET /api/work/activities/approvals` and `GET /api/work/activities/approvals/:id` -> `role-work-approvals`
- `GET /api/work/activities/acceptances` and `GET /api/work/activities/acceptances/:id` -> `role-work-acceptances`
- `GET /api/communications/entity/service_request/:id/channels/requester` -> `role-communications`
- `GET /api/fs` -> `role-attachments`

Explicitly excluded from this skill:

- Every write on services, forms, and settings (`POST`, `PUT`, `PATCH`, `DELETE`), including service create/update/delete/assign-owner and form create/update/delete/catalog/draft/publish
- Work writes (work-tab update, assign, status, watchers, cancel, activity updates) and communications writes (post, edit, delete, reaction, pin, read cursor)
- The service-request `internal` discussion channel
- All `/api/admin/app/processes/*` routes
- Upload and delete in `role-attachments` (listing only; this role has no `service:requests:update:all`)

A service-request detail from `role-work-service-requests` may include a linked `process_instance`. That is payload on the Work read. It is not a call to the processes API.

## Settings the bulk read returns

`GET /api/core/settings` is filtered to sections the caller may read.

With `adminServices:settings:read:all`:

- `AdminApp.Services`
- `AdminApp.Forms`
- `AdminApp.Practices`

With `settings:read:common`:

- `Application`, `Work`, `Reports`, `Communications`
- `AdminApp.Practices` is also on this common-read list; update of that section still requires `adminServices:settings:update:all`, which this role does not hold

Other sections are omitted.

## Attachments

List files with the installed `role-attachments` skill. Parent entity types this role can read:

- `service_request` — files on a service request (`service:requests:read:all` may read)
- `manual_task` — files on a manual task (same read-all visibility as the activity row)
- `acceptance` — files on an acceptance (same read-all visibility as the activity row)

Approvals have no file entity type. Example, from the installed attachments skill:

```bash
bash scripts/fs-files-list.sh service_request "<request_uuid>"
```

## JWT contract

All protected requests use:

```http
Authorization: Bearer <JWT>
```

JWT is obtained and refreshed by shared auth scripts (vendored at `scripts/_lib/` when the skill is packed; canonical copies in `role-auth`). Resolution order: `REQUEST_SCRIPT` override -> vendored `scripts/_lib` copy -> `../../role-auth/scripts/` (monorepo layout).

`BASE_URL` and `API_KEY` do not have to be exported in the calling shell. `role-request.sh` loads `${AGENT_HOME:-$HOME/.agent-skills}/role.env` when they are unset. Real environment variables win over that file. Never print `API_KEY` or a JWT.

## Script map

- `scripts/admin-services-list.sh [--page N] [--items-per-page N] [--search "<text>"] [--sort-by service_id|name|status|owner|technical_owner|created_at|modified_at] [--sort-desc] [--status draft|active|planned_maintenance|emergency_maintenance|archived] [--language english|russian]`
- `scripts/admin-services-get.sh <service_uuid>`
- `scripts/admin-services-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/admin-services-forms-search.sh [<query>] [--limit N] [--unbound]`
- `scripts/admin-services-catalog-section-options.sh`
- `scripts/admin-forms-list.sh [--page N] [--items-per-page N] [--search "<text>"] [--status draft|active] [--kind service_request|incident|problem|change|organization] [--service-id <uuid>] [--catalog-status "draft|active|on hold|discontinued"] [--catalog-binding bound|unbound] [--sort-by form_id|name|work_item_kind|status|service_name|owner|created_at|updated_at] [--sort-desc]`
- `scripts/admin-forms-get.sh <form_uuid>`
- `scripts/admin-forms-regions.sh`
- `scripts/admin-services-settings-get.sh`

`--status` on `admin-services-list.sh` may be repeated. Each value is sent as its own `status` query parameter. The same repeat rule applies to `--status`, `--kind`, `--catalog-status`, and `--catalog-binding` on the forms list.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Work service requests](../role-work-service-requests/SKILL.md)
- [Work manual activities](../role-work-manual-activities/SKILL.md)
- [Work approvals](../role-work-approvals/SKILL.md)
- [Work acceptances](../role-work-acceptances/SKILL.md)
- [Communications skill](../role-communications/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)

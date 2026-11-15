---
name: role-service-auditor
description: >
  Read-only service auditor skill for evi. Covers catalog services, work-item
  forms, service and practices settings, and runtime Work service requests,
  manual tasks, approvals, acceptances, and the requester discussion channel
  for bots mapped to role.service.auditor.
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
Short description: Read-only service auditor methods for external agents.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill for system group role.service.auditor.
- Read-only catalog service, work-item form, settings, Work runtime, and requester-channel scripts.
-->

Read-only oversight for bots assigned to `role.service.auditor` (Role Service Auditors).

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

`adminServices:items:read:all` satisfies the admin route gate `adminServices:items:read`. `service:requests:read:all` removes the per-row visibility filter on Work service requests, manual tasks, approvals, and acceptances, and it allows reading the service-request `requester` discussion channel. It does not grant `service:requests:update:all`.

## Role composition

- `role-auth` obtains and refreshes the JWT. This skill never calls `/api/*` except through `role-request.sh`.
- File listing stays in `role-attachments` (`GET /api/fs`). This skill does not duplicate those scripts.
- One skill per role: do not split these reads across another service skill.

## Scope

Design-time reads:

- `adminServices.items.list` -> `GET /api/admin/app/services/fetchallservices`
- `adminServices.items.get` -> `GET /api/admin/app/services/fetchsingleservice`
- `adminServices.items.search` -> `GET /api/admin/app/services/services/search`
- `adminServices.forms.search` -> `GET /api/admin/app/services/forms/search`
- `adminServices.catalogSectionOptions.list` -> `GET /api/admin/app/services/catalog-section-options`
- `adminServices.forms.list` -> `GET /api/admin/app/forms/fetch-all`
- `adminServices.forms.get` -> `GET /api/admin/app/forms/:id`
- `adminServices.forms.regions` -> `GET /api/admin/app/forms/regions`
- `adminServices.settings.read` -> `GET /api/core/settings`

Runtime reads:

- `work.requests.list` -> `GET /api/work/requests`
- `work.requests.get` -> `GET /api/work/requests/:id`
- `work.services.search` -> `GET /api/work/services/search`
- `work.manualTasks.list` -> `GET /api/work/activities/manual-tasks`
- `work.manualTasks.get` -> `GET /api/work/activities/manual-tasks/:id`
- `work.approvals.list` -> `GET /api/work/activities/approvals`
- `work.approvals.get` -> `GET /api/work/activities/approvals/:id`
- `work.acceptances.list` -> `GET /api/work/activities/acceptances`
- `work.acceptances.get` -> `GET /api/work/activities/acceptances/:id`
- `work.requests.requesterChannel.get` -> `GET /api/communications/entity/service_request/:id/channels/requester`

Explicitly excluded:

- Every write on services, forms, settings, Work, and communications (`POST`, `PUT`, `PATCH`, `DELETE`), including service create/update/delete/assign-owner, form create/update/delete/catalog/draft/publish, request work-tab update and cancel, activity updates, and posting or editing chat messages
- The service-request `internal` discussion channel
- All `/api/admin/app/processes/*` routes
- Upload and delete in `role-attachments` (listing only; this role has no `service:requests:update:all`)

A service-request detail may include a linked `process_instance`. That is payload on the Work read. It is not a call to the processes API.

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
- `scripts/work-requests-list.sh [--scope mine|assigned|team|unassigned|all] [--search "<text>"] [--status new|in_progress|paused|resolved|reopened|closed|cancelled|failed] [--urgency low|medium|high|critical] [--service-id <uuid>] [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--requester all|me|user] [--requester-user-id <uuid>] [--language english|russian] [--page N] [--items-per-page N] [--sort-by created_at|request_number|status|urgency|title|priority|service|form|requester|requested_for|assignee|group|resolved_at|closed_at|estimated_minutes|actual_minutes|activities_estimated_minutes|activities_actual_minutes|total_estimated_minutes|total_actual_minutes] [--sort-desc]`
- `scripts/work-requests-get.sh <request_uuid> [--language english|russian]`
- `scripts/work-services-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/work-manual-tasks-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status new|in_progress|paused|complete] [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--page N] [--items-per-page N] [--sort-by created_at|task_number|title|status|assignee|group|completed_at|parent|estimated_minutes|actual_minutes|wbs_code|phase|work_stream|planned_start_at|planned_end_at|started_at] [--sort-desc]`
- `scripts/work-manual-tasks-get.sh <task_uuid>`
- `scripts/work-approvals-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status new|in_progress|paused|complete] [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--language english|russian] [--page N] [--items-per-page N] [--sort-by created_at|approval_number|title|status|assignee|group|completed_at|parent|wbs_code|phase|work_stream|planned_start_at|planned_end_at|started_at] [--sort-desc]`
- `scripts/work-approvals-get.sh <approval_uuid> [--language english|russian]`
- `scripts/work-acceptances-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status new|in_progress|complete] [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--page N] [--items-per-page N] [--sort-by created_at|acceptance_number|title|status|assignee|group|completed_at|parent|wbs_code|phase|work_stream|planned_start_at|planned_end_at|started_at] [--sort-desc]`
- `scripts/work-acceptances-get.sh <acceptance_uuid>`
- `scripts/work-request-chat-get.sh <request_uuid> [--page N] [--items-per-page N]`

`--status` and `--urgency` on `work-requests-list.sh` may be repeated. Each value is sent as its own `status` or `urgency` query parameter. The same repeat rule applies to `--status` on the service list and the activity lists, and to `--status`, `--kind`, `--catalog-status`, and `--catalog-binding` on the forms list.

`--assignee user` does nothing unless `--assigned-user-id` is set. `--requester user` does nothing unless `--requester-user-id` is set. A Work list `--search` shorter than 2 characters is ignored by the server.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)

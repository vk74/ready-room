# Work service requests API contract

<!--
version: 0.28.3
Short description: Service-request endpoint contract for role-work-service-requests.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract: visibility, can_manage, can_cancel, work-tab PATCH, cancel, service search, and practices settings.
- Directory search and the notifications inbox point at role-auth. Discussion points at role-communications.
-->

Reference for `role-work-service-requests`.

The bot may be a requester, a beneficiary, a watcher, an assignee, a fulfillment-group member, a support-tier member, a service owner, a technical owner, a dispatcher, a practice manager, a coordinator, or an auditor. Read `can_manage` and `can_cancel` on the row. Do not assume a role string grants a write.

All routes below require:

```http
Authorization: Bearer <JWT>
```

The scripts obtain the JWT through `role-request.sh`. A `401` or `AUT-ERR-401` is retried once after re-auth. Do not call `curl` against `/api/*` yourself.

## Envelope

Success:

```json
{"success": true, "code": "WORK-SUC-001", "data": {}}
```

Failure:

```json
{"success": false, "code": "VAL-ERR-400"}
```

List payloads put rows under `data.requests` and paging under `data.pagination`. Pagination keys are camelCase: `totalItems`, `totalPages`, `currentPage`, `itemsPerPage`. Row fields are snake_case.

## Visibility, can_manage, can_cancel

Without `service:requests:read:all`, list and detail include a request when the caller is the requester, the beneficiary, a watcher, the assigned user, a member of the assigned group, the owner of that group, the service owner, the technical owner, the dispatcher, a member of any group linked to the service, or the company head.

`role.service.coordinator`, `role.service.practiceManager`, and `role.service.auditor` hold `service:requests:read:all` and see every request.

`can_manage` is true when the caller holds `service:requests:update:all`, or is the company head, the assigned user, a member of the assigned fulfillment group, the owner of that group, the service owner, the technical owner, the dispatcher, or a member of support tier 1, 2, or 3 on the service. Coordinator and practice manager hold `service:requests:update:all`, so `can_manage` is true on every request. An auditor does not hold that permission.

`can_cancel` is true only for the requester (`requester_user_id`) or the beneficiary (`requested_for_user_id`), and only while status is not `resolved`, `closed`, `cancelled`, or `failed`. No other role sets it.

`scope=mine` is the requester, beneficiary, and watcher queue. `scope=team` is requests whose assigned group is one of the caller's groups. A support-tier member who is not in that assigned group uses `scope=all` (still limited by visibility).

## Field naming

`PATCH /api/work/requests/:id/work` uses snake_case:

| Key | Rule |
| --- | --- |
| `priority` | Required integer 1..5. `1` is highest. |
| `status` | Required: `new`, `in_progress`, `paused`, `resolved`, `reopened`, `closed`. |
| `pause_reason` | Required when `status` is `paused`: `awaiting_requester`, `awaiting_third_party`, `scheduled`, `other`. Any other status stores null. |
| `assigned_group_id` | UUID or null. Omitted, null, and `""` all clear the group. |
| `assigned_user_id` | UUID or null. Omitted, null, and `""` all clear the user. |
| `work_notes` | String or null. Omitted clears the notes. |
| `watch_list` | UUID string array. Omitted keeps the current list. Present, including `[]`, replaces the list. |
| `estimated_minutes` | Integer >= 0, or null to clear. Omitted keeps the current value. |
| `actual_minutes` | Integer >= 0, or null to clear. Omitted keeps the current value. |

The GET object names the assigned group `group_id`. The scripts read `group_id` and send `assigned_group_id`.

A group must be an active non-system group. A user must be an active standard or bot account. Otherwise the server returns `VAL-ERR-400`.

When `AdminApp.Practices` / `time_tracking.require_actual_on_close` is true, resolving or closing a request with no actual minutes returns `VAL-ERR-400`.

Closed, cancelled, and failed requests are not updated (`VAL-ERR-400`). A missing id is `WORK-ERR-001`. A caller who cannot manage the request, or who adds a practice manager or the company head against the escalation policy, receives `WORK-ERR-002`.

## Destructive-safe scripts

`work-requests-update-work.sh` loads the current row and builds priority, status, pause_reason, assigned_group_id (from `group_id`), assigned_user_id, and work_notes, then merges the caller's snake_case patch on top. `watch_list`, `estimated_minutes`, and `actual_minutes` stay off the wire unless the patch contains them. An empty patch still rewrites the overwrite fields.

`work-requests-assign.sh` changes only the flags you pass. `--group-id none` and `--user-id none` send null. An omitted flag keeps the current id.

`work-requests-status.sh` sets `status`. For `paused` it sends `pause_reason` (the flag, or the current reason when the request is already paused). `--actual-minutes` and `--work-notes` are optional.

`work-requests-watchers-add.sh` unions `data.watch_list` with the new user ids, preserving order and dropping case-insensitive duplicates, and sends that array together with the current overwrite fields.

## Escalation targets

`GET /api/work/requests/:id` returns `data.escalation_targets`:

```json
{
  "support_tier2": {"group_id": "uuid", "group_name": "Tier 2", "allowed": true},
  "support_tier3": {"group_id": "uuid", "group_name": "Tier 3", "allowed": true},
  "practice_manager": {
    "user_id": "uuid-of-first-member",
    "users": [{"user_id": "uuid", "username": "a", "display_name": "A"}],
    "allowed": true
  },
  "company_head": {"user_id": "uuid", "username": "head", "display_name": "Head", "allowed": true}
}
```

Functional escalation assigns `support_tier2.group_id` or `support_tier3.group_id` with `work-requests-assign.sh --group-id` when `allowed` is true. Hierarchical escalation adds each `practice_manager.users[].user_id` and `company_head.user_id` with `work-requests-watchers-add.sh` when `allowed` is true. `practice_manager.user_id` is only the first member.

A caller with `service:requests:update:all` is treated as `coordinator` for both hierarchical checks. Read `allowed` before acting. Other new watchers are not gated by that policy.

Default policies, overridable in `AdminApp.Practices`:

- `escalation.practice_manager.policy`: `assignee`, `fulfillment_group`, `support_tier_group`, `assigned_group_owner`, `dispatcher`, `technical_owner`, `service_owner`, `coordinator`
- `escalation.company_head.policy`: `assigned_group_owner`, `dispatcher`, `technical_owner`, `service_owner`, `coordinator`, `practice_manager`

## Endpoints

### `GET /api/work/requests`

Script: `work-requests-list.sh`.

Query names: `scope` (`mine`, `assigned`, `team`, `unassigned`, `all`), `search` (the script rejects fewer than 2 characters), repeated `status`, repeated `urgency` (`low`, `medium`, `high`, `critical`), `serviceId`, `assignee` (`all`, `me`, `unassigned`, `user`), `assignedUserId`, `assignedGroupId`, `requester` (`all`, `me`, `user`), `requesterUserId`, `language` (`english`, `russian`), `page`, `itemsPerPage` (1..100, default 25), `sortBy`, `sortDesc`.

List status values include `cancelled` and `failed`. The work PATCH does not accept those two.

`sortBy` keys the server orders by: `created_at`, `request_number`, `status`, `urgency`, `title`, `service`, `requester`, `assignee`, `form`, `impact`, `priority`, `requested_for`, `group`, `quantity`, `pause_reason`, `updated_at`, `resolved_at`, `closed_at`, `estimated_minutes`, `actual_minutes`, `total_estimated_minutes`, `total_actual_minutes`. The script also accepts `activities_estimated_minutes` and `activities_actual_minutes`. Those two have no order expression and sort as `created_at`. The response still includes them as fields. `total_estimated_minutes` and `total_actual_minutes` are the keys that include activity minutes.

Success `WORK-SUC-001`. Rows are `data.requests`, including `can_cancel` and the minute fields.

### `GET /api/work/requests/:id`

Script: `work-requests-get.sh`. Optional `language`.

Success `WORK-SUC-002`. `data` adds `answers`, `definition`, `can_manage`, `can_cancel`, `process_instance`, `related_items`, `watch_list`, `watch_list_users`, and `escalation_targets`.

### `PATCH /api/work/requests/:id/work`

Scripts: `work-requests-update-work.sh`, `work-requests-assign.sh`, `work-requests-status.sh`, `work-requests-watchers-add.sh`.

Example that pauses a request and leaves assignment to the script:

```json
{"status": "paused", "pause_reason": "scheduled"}
```

Success `WORK-SUC-003`.

### `POST /api/work/requests/:id/cancel`

Script: `work-requests-cancel.sh`. No body.

Allowed only when `can_cancel` is true. A caller who is not the requester or the beneficiary receives `WORK-ERR-002`. A party whose status is `resolved`, `closed`, `cancelled`, or `failed` receives `VAL-ERR-400`. A missing id is `WORK-ERR-001`.

Success `WORK-SUC-003`. The response `data` is the work-tab shape.

### `GET /api/work/services/search`

Script: `work-services-search.sh <query>`. Query `q`, `limit` (1..100, server default 20), `language` (server default `english`).

Success `WORK-SUC-004`. `data.items[]` has `uuid`, `name`, `service_id`.

### `GET /api/core/settings`

Script: `work-practices-settings-get.sh`.

Success `STG-SUC-002`. With `settings:read:common` (held through `role.users.registered`), `AdminApp.Practices` includes:

- `escalation.practice_manager.policy`
- `escalation.company_head.policy`
- `priority.matrix`
- `time_tracking.require_actual_on_close`

This skill does not update settings.

## Discussion and files

Discussion is not called by this skill. `role-communications` owns channel keys `requester` and `internal` on entity type `service_request`.

- `chat-channel-get.sh service_request <request_uuid> requester`
- `chat-channel-get.sh service_request <request_uuid> internal`
- Post, edit, delete, react, pin, and mark read with the other `chat-*` scripts in that skill.

`requester` is readable by involved users (requester, beneficiary, watchers), request managers, and `service:requests:read:all`. Posting there requires an involved user or a request manager, and the status must not be `closed`, `cancelled`, or `failed`. Read-all alone does not grant posting.

`internal` requires `can_manage` (`canManageRequest`) to read and to post, including after the request is closed. A caller who cannot manage it receives `COM-ERR-002`.

Work-tab notes stay in `work_notes`.

Files use `role-attachments` with `entity_type=service_request`. This skill does not upload or replace them. List with `fs-files-list.sh service_request <request_uuid>`.

User and group search is `role-auth` `core-search-users.sh` and `core-search-groups.sh` (`GET /api/core/item-selector/search-users` and `search-groups`). The inbox is `role-auth` `notifications-inbox-list.sh` and the related inbox scripts (`GET /api/notifications/inbox`).

## Error handling

| Code | What to do |
| --- | --- |
| `AUT-ERR-401` | The wrapper re-authenticates once. If it persists, check `API_KEY` and `BASE_URL`. |
| `REQ-ERR-001` | The body or query could not be bound. Fix the JSON and send `Content-Type: application/json`. |
| `VAL-ERR-001` / `VAL-ERR-400` | A field is missing or not in the allowed set, or cancel was refused because the status is terminal. |
| `WORK-ERR-001` | Request id does not exist. |
| `WORK-ERR-002` | Manage check failed, the caller is not allowed to cancel, or the escalation policy refused a new practice-manager or company-head watcher. |
| `SYS-ERR-500` | Server failure. Retry once, then stop. |

## Non-goals

- Creating a service request
- Manual tasks, approvals, and acceptances
- Discussion messages, reactions, and pins
- Uploading or replacing `service_request` files
- `POST /api/admin/settings/update` and any settings write
- Admin service catalog routes

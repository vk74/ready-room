# Service coordinator API contract

<!--
version: 0.28.3
Short description: Coordinator endpoint contract for role-service-coordinator.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract for role.service.coordinator work, escalation, activity, chat, and practices-settings routes.
-->

Reference for `role-service-coordinator`.

The bot is a member of `role.service.coordinator` (**Role Service Coordinators**) and coordinates every service request and manual task.

Under the default `AdminApp.Practices` policies, both `escalation.practice_manager.policy` and `escalation.company_head.policy` include `coordinator`. Escalate by:

- adding each `data.escalation_targets.practice_manager.users[].user_id` that should watch the request (`user_id` alone is only the first member);
- adding `data.escalation_targets.company_head.user_id`;
- assigning `data.escalation_targets.support_tier2.group_id` or `support_tier3.group_id` when that target's `allowed` is true.

`allowed` is the server's decision for this caller. `WORK-ERR-002` refuses a hierarchical watcher the policy does not allow.

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

List payloads put rows under a named array and paging under `data.pagination`. Pagination keys are camelCase: `totalItems`, `totalPages`, `currentPage`, `itemsPerPage`. Row fields are snake_case.

## Field naming

Activity and chat request bodies are camelCase. Responses are snake_case. Do not copy response keys back into those request bodies.

`PATCH /api/work/requests/:id/work` is the exception. Its JSON tags are snake_case:

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

The GET request object names the assigned group `group_id` and the assignee `assigned_user_id`. The PATCH response also returns `group_id`. The scripts read `group_id` and send `assigned_group_id`.

A group must be an active non-system group. A user must be an active standard or bot account. Otherwise the server returns `VAL-ERR-400`.

When `AdminApp.Practices` / `time_tracking.require_actual_on_close` is true, resolving or closing a request with no actual minutes returns `VAL-ERR-400`. The same rule applies when a manual task is completed as `succeeded`.

Closed, cancelled, and failed requests are not updated (`VAL-ERR-400`). A missing id is `WORK-ERR-001`. A caller who cannot manage the request, or who adds a practice manager or the company head against the escalation policy, receives `WORK-ERR-002`.

## Destructive-safe scripts

`work-requests-update-work.sh <request_uuid> <patch.json>` loads the current row and builds:

```json
{
  "priority": "<data.priority, or 3 when null>",
  "status": "<data.status>",
  "pause_reason": "<data.pause_reason>",
  "assigned_group_id": "<data.group_id>",
  "assigned_user_id": "<data.assigned_user_id>",
  "work_notes": "<data.work_notes>"
}
```

The caller's object is merged on top with `jq` (`baseline * patch`). Keys absent from the patch stay at the baseline. `watch_list`, `estimated_minutes`, and `actual_minutes` stay off the wire unless the patch contains them. An empty patch still rewrites the overwrite fields and the server records an update.

`work-requests-assign.sh` only changes the flags you pass. `--group-id none` and `--user-id none` send null. An omitted flag keeps the current id.

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

`practice_manager.user_id` is the first active member. Add every id in `practice_manager.users` that should watch the request.

Hierarchical escalation is adding those user ids to `watch_list`. Functional escalation to a support tier is setting `assigned_group_id` to that `group_id`.

Default `AdminApp.Practices` values:

- `escalation.practice_manager.policy`: `assignee`, `fulfillment_group`, `support_tier_group`, `assigned_group_owner`, `dispatcher`, `technical_owner`, `service_owner`, `coordinator`
- `escalation.company_head.policy`: `assigned_group_owner`, `dispatcher`, `technical_owner`, `service_owner`, `coordinator`, `practice_manager`

A caller with `service:requests:update:all` is treated as `coordinator` for both checks. Read `allowed` before acting. `WORK-ERR-002` refuses a practice-manager or company-head addition the policy does not allow. Other new watchers are not gated by that policy.

`support_tier2.allowed` and `support_tier3.allowed` are true when the service has that group and the request is not already assigned to it.

## Service requests

### `GET /api/work/requests`

Script: `work-requests-list.sh`.

Query names: `scope` (`mine`, `assigned`, `team`, `unassigned`, `all`), `search` (ignored by the server below 2 characters; the script rejects that), repeated `status`, repeated `urgency` (`low`, `medium`, `high`, `critical`), `serviceId`, `assignee` (`all`, `me`, `unassigned`, `user`), `assignedUserId`, `assignedGroupId`, `requester` (`all`, `me`, `user`), `requesterUserId`, `language` (`english`, `russian`), `page`, `itemsPerPage` (1..100, default 25), `sortBy`, `sortDesc`.

List status values include `cancelled` and `failed`. The work PATCH does not accept those two.

`sortBy` keys: `created_at`, `request_number`, `status`, `urgency`, `title`, `service`, `requester`, `assignee`, `form`, `impact`, `priority`, `requested_for`, `group`, `quantity`, `pause_reason`, `updated_at`, `resolved_at`, `closed_at`, `estimated_minutes`, `actual_minutes`, `total_estimated_minutes`, `total_actual_minutes`. An unknown key sorts by `created_at`.

Success `WORK-SUC-001`. Rows are `data.requests`.

### `GET /api/work/requests/:id`

Script: `work-requests-get.sh`. Optional `language`.

Success `WORK-SUC-002`. `data` is the request: list fields plus `answers`, `definition`, `can_manage`, `process_instance`, `related_items`, `watch_list`, `watch_list_users`, `escalation_targets`.

`can_manage` is true for this role because of `service:requests:update:all`.

### `PATCH /api/work/requests/:id/work`

Scripts: `work-requests-update-work.sh`, `work-requests-assign.sh`, `work-requests-status.sh`, `work-requests-watchers-add.sh`.

Example patch that pauses a request and leaves assignment to the script:

```json
{"status": "paused", "pause_reason": "scheduled"}
```

Example that records time without clearing notes:

```json
{"actual_minutes": 40, "estimated_minutes": 60}
```

Success `WORK-SUC-003`. The response `data` includes `group_id`, `assigned_user_id`, `work_notes`, `watch_list`, `watch_list_users`, minutes, and the child-task rollup.

### `GET /api/work/services/search`

Script: `work-services-search.sh <query>`. Query `q`, `limit` (1..100, server default 20), `language` (server default `english`).

Success `WORK-SUC-004`. `data.items[]` has `uuid`, `name`, `service_id`.

## Manual tasks

### `GET /api/work/activities/manual-tasks`

Script: `work-manual-tasks-list.sh`.

Query: `scope` (`assigned`, `team`, `unassigned`, `all`), `search`, repeated `status` (`new`, `in_progress`, `paused`, `complete`), `assignee`, `assignedUserId`, `assignedGroupId`, `page`, `itemsPerPage`, `sortBy`, `sortDesc`.

`sortBy`: `created_at`, `task_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `estimated_minutes`, `actual_minutes`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`.

Success `WORK_MT-SUC-001`. Rows are `data.manual_tasks`. `can_manage` is true for this role on every row.

### `GET /api/work/activities/manual-tasks/:id`

Script: `work-manual-tasks-get.sh`. Success `WORK_MT-SUC-002`.

### `PATCH /api/work/activities/manual-tasks/:id`

Script: `work-manual-tasks-update.sh`. CamelCase body. Omitted keys stay unchanged, except `attachmentFileIds`: omitted keeps current files, and a present array (including `[]`) replaces them. The script warns when that key is present.

```json
{
  "status": "complete",
  "outcome": "succeeded",
  "actualMinutes": 25,
  "kbArticleId": "uuid"
}
```

`status`: `new`, `in_progress`, `paused`, `complete`. `complete` requires `outcome`: `succeeded`, `cancelled`, `failed`, or `skipped`. `paused` requires `pauseReason`: `awaiting_requester`, `awaiting_third_party`, `awaiting_parts`, or `scheduled`.

Schedule keys: `wbsCode`, `phase`, `workStream`, `plannedStartAt`, `plannedEndAt`, `startedAt`, `predecessorIds`.

Success `WORK_MT-SUC-003`. Missing: `WORK_MT-ERR-001`. Forbidden: `WORK_MT-ERR-002`. Already complete: `WORK_MT-ERR-003` (409). Reload and do not retry a completed task.

## Approvals

### `GET /api/work/activities/approvals`

Script: `work-approvals-list.sh`. Same queue filters as manual tasks, plus `language`. Status values: `new`, `in_progress`, `paused`, `complete`.

`sortBy`: `created_at`, `approval_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`.

Success `WORK_AP-SUC-001`. Rows are `data.approvals`.

### `GET /api/work/activities/approvals/:id`

Script: `work-approvals-get.sh`. Optional `language`. Success `WORK_AP-SUC-002`. Detail adds `related_items` and, when the parent is a service order or service request, `service_order`.

### `PATCH /api/work/activities/approvals/:id`

Script: `work-approvals-update.sh`. Allowed only when `can_manage` is true (the caller is the assigned user or a member of the assigned group).

```json
{"status": "complete", "outcome": "approved", "approvalNotes": "Matches the request."}
```

`status`: `new`, `in_progress`, `paused`, `complete`. `complete` requires `outcome` `approved` or `rejected`. `rejected` requires `rejectionNotes` of at least 10 characters. `paused` requires `pauseReason`: `more_info_required`, `awaiting_additional_approver`, `awaiting_cab`, or `deferred`.

Success `WORK_AP-SUC-003`. Missing: `WORK_AP-ERR-001`. Forbidden: `WORK_AP-ERR-002`. Already complete: `WORK_AP-ERR-003` (409).

## Acceptances

### `GET /api/work/activities/acceptances`

Script: `work-acceptances-list.sh`. Queue filters match approvals except there is no `language` and status is `new`, `in_progress`, or `complete` (no `paused`).

`sortBy`: `created_at`, `acceptance_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`.

Success `WORK_AC-SUC-001`. Rows are `data.acceptances`.

### `GET /api/work/activities/acceptances/:id`

Script: `work-acceptances-get.sh`. Success `WORK_AC-SUC-002`.

### `PATCH /api/work/activities/acceptances/:id`

Script: `work-acceptances-update.sh`. Same `can_manage` rule as approvals. Omit `attachmentFileIds` to keep files. The script warns when the key is present.

```json
{"status": "complete", "outcome": "accepted", "acceptanceNotes": "Delivered as requested."}
```

`outcome`: `accepted` or `rejected`. `rejected` requires `rejectionNotes` of at least 10 characters.

Success `WORK_AC-SUC-003`. Missing: `WORK_AC-ERR-001`. Forbidden: `WORK_AC-ERR-002`. Already complete: `WORK_AC-ERR-003` (409).

## Requester discussion

Channel key `requester` on entity type `service_request`. This is the conversation between the requester and the support team. Put internal notes in request `work_notes`, not in this channel.

Request JSON is camelCase. Response JSON is snake_case.

### `GET /api/communications/entity/service_request/:id/channels/requester`

Script: `work-request-chat-get.sh`. Query `page`, `itemsPerPage`.

Success `COM-SUC-001`. `data` includes `conversation_id`, `channel_key`, `can_post`, `messages`, `participants`, `pagination`, `unread_count`, `last_read_message_id`.

### `POST .../channels/requester/messages`

Script: `work-request-chat-post.sh`.

```json
{"body": "We started the work.", "replyToMessageId": "uuid", "mentionedUserIds": ["uuid"]}
```

`body` is required. The other keys are optional. Success `COM-SUC-002` (HTTP 201).

### `PATCH /api/communications/messages/:id`

Script: `work-request-chat-update.sh`.

```json
{"body": "Corrected text."}
```

A missing field is left unchanged. Success `COM-SUC-003`.

### `DELETE /api/communications/messages/:id`

Script: `work-request-chat-delete.sh`. Success `COM-SUC-004`.

### `POST /api/communications/conversations/:id/read`

Script: `work-request-chat-read.sh`. The conversation id is `conversation_id` from the channel payload.

```json
{"lastReadMessageId": "uuid"}
```

An empty object marks the conversation read through the latest message. Success `COM-SUC-007`.

Chat errors: `COM-ERR-001` not found, `COM-ERR-002` forbidden, `COM-ERR-003` conflict. `VAL-ERR-001` is a bad id. `REQ-ERR-001` is a body the server could not bind.

## Practices settings

### `GET /api/core/settings`

Script: `work-practices-settings-get.sh`.

Success `STG-SUC-002`. `data.settings` and `data.defaults` are `section_path -> setting_name -> value`, limited to sections this account may read. With `settings:read:common`, `AdminApp.Practices` is included:

- `escalation.practice_manager.policy`
- `escalation.company_head.policy`
- `priority.matrix` (impact x urgency -> priority 1..5)
- `time_tracking.require_actual_on_close`

This skill does not update settings.

## Directory search

### `GET /api/core/item-selector/search-users`

Script: `core-search-users.sh`. Query `query` (minimum 2 characters), `limit` (1..100, default 20), `include_bots`, `exclude_system`.

Success `ISL-SUC-001`. `data.items[]` has `uuid`, `name`, `username`, `status`. `data.total` is the count returned.

### `GET /api/core/item-selector/search-groups`

Script: `core-search-groups.sh`. Query `query` (minimum 2 characters), `limit`, `exclude_system`.

Success `ISL-SUC-001`. The same item shape. A system group still cannot be stored as `assigned_group_id`.

A query shorter than 2 characters is `VAL-ERR-400`.

## Shared error handling

| Code | What to do |
| --- | --- |
| `AUT-ERR-401` | The wrapper re-authenticates once. If it persists, check `API_KEY` and `BASE_URL`. |
| `REQ-ERR-001` | The body or query could not be bound. Fix the JSON and send `Content-Type: application/json`. |
| `VAL-ERR-001` / `VAL-ERR-400` | A field is missing or not in the allowed set. Read the contract for that route. |
| `WORK-ERR-001` | Request id does not exist. |
| `WORK-ERR-002` | Manage check failed, or the escalation policy refused a new practice-manager or company-head watcher. |
| `WORK_MT-ERR-002` / `WORK_AP-ERR-002` / `WORK_AC-ERR-002` | `can_manage` is false. |
| `WORK_MT-ERR-003` / `WORK_AP-ERR-003` / `WORK_AC-ERR-003` | The activity is already complete. Reload. Do not retry the same completion. |
| `COM-ERR-002` | The caller cannot post, edit, or delete that message. |
| `SYS-ERR-500` | Server failure. Retry once, then stop. |

## Non-goals

- `POST /api/work/requests/:id/cancel`
- Creating a service request
- Admin service catalog routes
- `POST /api/admin/settings/update` and any settings write
- Message reactions and pins
- Channels other than `requester`
- Uploading file bytes (use `role-attachments`; this skill only forwards `attachmentFileIds` when the caller chooses to replace the set)

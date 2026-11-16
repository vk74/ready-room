# Work manual tasks API contract

<!--
version: 0.28.3
Short description: Manual-task endpoint contract for role-work-manual-activities.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract: visibility, can_manage, status transitions, time tracking, schedule fields, attachments, and the completion lock.
-->

Reference for `role-work-manual-activities`.

All routes below require:

```http
Authorization: Bearer <JWT>
```

The scripts obtain the JWT through `role-request.sh`. A `401` or `AUT-ERR-401` is retried once after re-auth. Do not call `curl` against `/api/*` yourself.

## Envelope

Success:

```json
{"success": true, "code": "WORK_MT-SUC-001", "data": {}}
```

Failure:

```json
{"success": false, "code": "WORK_MT-ERR-002"}
```

List rows are `data.manual_tasks`. Pagination keys are camelCase: `totalItems`, `totalPages`, `currentPage`, `itemsPerPage`. Row fields are snake_case. Request bodies are camelCase. Do not copy response keys into a PATCH.

## Visibility and can_manage

Without `service:requests:read:all`, a task is listed and readable when the caller is the assignee, a member of the assigned group, the owner of that group, the company head, or related to the parent service request or service order (requester, beneficiary, request watcher, parent assignee, parent fulfillment group or its owner, service owner, technical owner, dispatcher, or a member of a group linked to the parent service).

`can_manage` is `canManageManualTaskRow`. It is true when any of these hold:

- the caller is `assigned_user_id` or a member of `assigned_group_id`
- the caller holds `service:requests:update:all`
- the caller owns the assigned group
- the caller is the company head
- on the parent service request or service order, the caller is the service owner, technical owner, dispatcher, or a member of support tier 1, 2, or 3

`service:requests:read:all` does not by itself set `can_manage`. A PATCH with `can_manage` false returns `WORK_MT-ERR-002`.

## Endpoints

### `GET /api/work/activities/manual-tasks`

Script: `work-manual-tasks-list.sh`.

Query: `scope` (`assigned`, `team`, `unassigned`, `all`), `search` (script rejects fewer than 2 characters), repeated `status` (`new`, `in_progress`, `paused`, `complete`), `assignee` (`all`, `me`, `unassigned`, `user`), `assignedUserId`, `assignedGroupId`, `page`, `itemsPerPage` (1..100), `sortBy`, `sortDesc`.

`sortBy`: `created_at`, `task_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `estimated_minutes`, `actual_minutes`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`. An unknown key sorts by `created_at`.

Success `WORK_MT-SUC-001`.

### `GET /api/work/activities/manual-tasks/:id`

Script: `work-manual-tasks-get.sh`. Success `WORK_MT-SUC-002`. Missing id: `WORK_MT-ERR-001`.

The row includes `process_token_id`, `kb_article_id`, minutes, WBS and schedule fields, `outcome`, `pause_reason`, and `can_manage`.

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

`status`: `new`, `in_progress`, `paused`, `complete`.

`paused` requires `pauseReason`: `awaiting_requester`, `awaiting_third_party`, `awaiting_parts`, or `scheduled`.

`complete` requires `outcome`: `succeeded`, `cancelled`, `failed`, or `skipped`.

When `AdminApp.Practices` / `time_tracking.require_actual_on_close` is true, `complete` with `succeeded` requires `actualMinutes` or the server returns `VAL-ERR-400`. `estimatedMinutes` is optional. Read the flag from `GET /api/core/settings`. This skill does not wrap that call.

Schedule and link keys: `description`, `kbArticleId`, `wbsCode`, `phase`, `workStream`, `plannedStartAt`, `plannedEndAt`, `startedAt`, `predecessorIds`.

Success `WORK_MT-SUC-003`.

A task whose status is already `complete` rejects every later PATCH with `WORK_MT-ERR-003` (409). Do not retry. Completion publishes `work.manual_task.completed`. A non-empty `process_token_id` on that event resumes the waiting process token.

### Attachments

`work-manual-tasks-attachments-add.sh <task_uuid> <file_uuid> [...]`:

1. `GET /api/fs?entity_type=manual_task&entity_id=<task_uuid>` and collect active `data.items[].file_id`.
2. Append the new ids, keep order, drop case-insensitive duplicates.
3. `PATCH /api/work/activities/manual-tasks/:id` with `{"attachmentFileIds": [...]}` and `Content-Type: application/json`.

Each new id must already be uploaded and confirmed through `role-attachments` with `entity_type=manual_task` and the same `entity_id`. File errors (`FILE-ERR-0xx`) are documented in that skill.

## Error handling

| Code | What to do |
| --- | --- |
| `AUT-ERR-401` | The wrapper re-authenticates once. If it persists, check `API_KEY` and `BASE_URL`. |
| `REQ-ERR-001` | The body could not be bound. Send `Content-Type: application/json` and camelCase keys. |
| `VAL-ERR-001` / `VAL-ERR-400` | A field is missing or not in the allowed set, including actual minutes required on a succeeded close. |
| `WORK_MT-ERR-001` | Task id does not exist or is not visible. |
| `WORK_MT-ERR-002` | `can_manage` is false. |
| `WORK_MT-ERR-003` | The task is already complete. Reload. Do not retry. |
| `SYS-ERR-500` | Server failure. Retry once, then stop. |

## Non-goals

- Service-request work tab, cancel, and discussion
- Approvals and acceptances
- Uploading bytes (that is `role-attachments`)
- Creating a manual task

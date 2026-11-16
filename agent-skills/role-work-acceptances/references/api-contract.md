# Work acceptances API contract

<!--
version: 0.28.3
Short description: Acceptance endpoint contract for role-work-acceptances.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract: assignee-only decision gate, status transitions, attachments, and the completion lock.
-->

Reference for `role-work-acceptances`.

All routes below require:

```http
Authorization: Bearer <JWT>
```

The scripts obtain the JWT through `role-request.sh`. A `401` or `AUT-ERR-401` is retried once after re-auth. Do not call `curl` against `/api/*` yourself.

## Envelope

Success:

```json
{"success": true, "code": "WORK_AC-SUC-001", "data": {}}
```

Failure:

```json
{"success": false, "code": "WORK_AC-ERR-002"}
```

List rows are `data.acceptances`. Pagination keys are camelCase. Row fields are snake_case. Request bodies are camelCase. Send `acceptanceNotes` and `rejectionNotes`, not the response keys `acceptance_notes` and `rejection_notes`.

## Decision gate

`can_manage` is `canManageDecisionActivity`. It is true only when the caller is `assigned_user_id` or a member of `assigned_group_id`.

`service:requests:read:all` lets a coordinator, practice manager, or auditor list and read every acceptance. `service:requests:update:all` does not set `can_manage`. Deciding an acceptance assigned to someone else returns `WORK_AC-ERR-002`.

Visibility without `service:requests:read:all` matches the other activity lists: assignee, assigned-group member, assigned-group owner, company head, or a relationship to the parent service request or service order.

## Endpoints

### `GET /api/work/activities/acceptances`

Script: `work-acceptances-list.sh`.

Query: `scope` (`assigned`, `team`, `unassigned`, `all`), `search`, repeated `status` (`new`, `in_progress`, `complete`), `assignee`, `assignedUserId`, `assignedGroupId`, `page`, `itemsPerPage`, `sortBy`, `sortDesc`. There is no `language` query and no `paused` status.

`sortBy`: `created_at`, `acceptance_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`. An unknown key sorts by `created_at`.

Success `WORK_AC-SUC-001`.

### `GET /api/work/activities/acceptances/:id`

Script: `work-acceptances-get.sh`. Success `WORK_AC-SUC-002`. Missing id: `WORK_AC-ERR-001`.

The row includes `process_token_id`, `acceptance_notes`, `rejection_notes`, `outcome`, WBS and schedule fields, and `can_manage`.

### `PATCH /api/work/activities/acceptances/:id`

Script: `work-acceptances-update.sh`. Allowed only when `can_manage` is true.

```json
{"status": "complete", "outcome": "accepted", "acceptanceNotes": "Delivered as requested."}
```

`status`: `new`, `in_progress`, `complete`. `paused` is rejected.

`complete` requires `outcome` `accepted` or `rejected`. `rejected` requires `rejectionNotes` of at least 10 characters. Completing as `accepted` stores `rejection_notes` as null. Completing as `rejected` stores `acceptance_notes` as null.

Schedule keys: `description`, `wbsCode`, `phase`, `workStream`, `plannedStartAt`, `plannedEndAt`, `startedAt`, `predecessorIds`.

Omit `attachmentFileIds` to keep files. A present array, including `[]`, replaces the set. The script warns when that key is present.

Success `WORK_AC-SUC-003`.

A row whose status is already `complete` rejects every later PATCH with `WORK_AC-ERR-003` (409). Completion publishes `work.acceptance.completed`. A non-empty `process_token_id` on that event resumes the waiting process token.

### Attachments

`work-acceptances-attachments-add.sh <acceptance_uuid> <file_uuid> [...]`:

1. `GET /api/fs?entity_type=acceptance&entity_id=<acceptance_uuid>` and collect active `data.items[].file_id`.
2. Append the new ids, keep order, drop case-insensitive duplicates.
3. `PATCH /api/work/activities/acceptances/:id` with `{"attachmentFileIds": [...]}` and `Content-Type: application/json`.

Each new id must already be uploaded and confirmed through `role-attachments` with `entity_type=acceptance` and the same `entity_id`. File errors (`FILE-ERR-0xx`) are documented in that skill.

## Error handling

| Code | What to do |
| --- | --- |
| `AUT-ERR-401` | The wrapper re-authenticates once. If it persists, check `API_KEY` and `BASE_URL`. |
| `REQ-ERR-001` | The body could not be bound. Send `Content-Type: application/json` and camelCase keys. |
| `VAL-ERR-001` / `VAL-ERR-400` | A field is missing or not in the allowed set. `paused`, or a rejection note shorter than 10 characters, is this case. |
| `WORK_AC-ERR-001` | Acceptance id does not exist or is not visible. |
| `WORK_AC-ERR-002` | `can_manage` is false. Update-all does not override this. |
| `WORK_AC-ERR-003` | The acceptance is already complete. Reload. Do not retry. |
| `SYS-ERR-500` | Server failure. Retry once, then stop. |

## Non-goals

- Service-request work tab and discussion
- Manual tasks and approvals
- Uploading bytes (that is `role-attachments`)
- Creating an acceptance
- Deciding an acceptance assigned to another user or group
- A paused status

# Work approvals API contract

<!--
version: 0.28.3
Short description: Approval endpoint contract for role-work-approvals.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract: assignee-only decision gate, service_order snapshot, status transitions, and the completion lock.
-->

Reference for `role-work-approvals`.

All routes below require:

```http
Authorization: Bearer <JWT>
```

The scripts obtain the JWT through `role-request.sh`. A `401` or `AUT-ERR-401` is retried once after re-auth. Do not call `curl` against `/api/*` yourself.

## Envelope

Success:

```json
{"success": true, "code": "WORK_AP-SUC-001", "data": {}}
```

Failure:

```json
{"success": false, "code": "WORK_AP-ERR-002"}
```

List rows are `data.approvals`. Pagination keys are camelCase. Row fields are snake_case. Request bodies are camelCase. Do not copy `approval_notes` or `rejection_notes` back as those keys. Send `approvalNotes` and `rejectionNotes`.

## Decision gate

`can_manage` is `canManageDecisionActivity`. It is true only when the caller is `assigned_user_id` or a member of `assigned_group_id`.

`service:requests:read:all` lets a coordinator, practice manager, or auditor list and read every approval. `service:requests:update:all` does not set `can_manage`. Deciding an approval assigned to someone else returns `WORK_AP-ERR-002`.

Visibility without `service:requests:read:all` matches the other activity lists: assignee, assigned-group member, assigned-group owner, company head, or a relationship to the parent service request or service order.

Approvals have no `/api/fs` entity type. There is no attachment script.

## Endpoints

### `GET /api/work/activities/approvals`

Script: `work-approvals-list.sh`.

Query: `scope` (`assigned`, `team`, `unassigned`, `all`), `search`, repeated `status` (`new`, `in_progress`, `paused`, `complete`), `assignee`, `assignedUserId`, `assignedGroupId`, `language` (`english`, `russian`), `page`, `itemsPerPage`, `sortBy`, `sortDesc`.

`sortBy`: `created_at`, `approval_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`. An unknown key sorts by `created_at`.

Success `WORK_AP-SUC-001`.

### `GET /api/work/activities/approvals/:id`

Script: `work-approvals-get.sh`. Optional `language`. Success `WORK_AP-SUC-002`. Missing id: `WORK_AP-ERR-001`.

Detail adds `related_items`. When `parent_kind` is `service_order` or `service_request`, `service_order` is the stamped parent:

| Field | Meaning |
| --- | --- |
| `id`, `order_number`, `title`, `description` | The order or request being approved |
| `service_id`, `service_name` | Service |
| `form_id`, `form_name`, `form_version_id`, `form_version_number` | Form version |
| `urgency`, `impact`, `quantity` | Priority inputs |
| `watch_list` | Watcher user ids |
| `requester_user_id`, `requester` | Who asked |
| `requested_for_user_id`, `requested_for` | Beneficiary |
| `answers`, `definition` | Submitted answers and the form definition |
| `created_at` | When the parent was created |

Read `service_order` before deciding. This skill does not update it.

The approval row also includes `process_token_id`, `approval_notes`, `rejection_notes`, `outcome`, `pause_reason`, WBS and schedule fields, and `can_manage`.

### `PATCH /api/work/activities/approvals/:id`

Script: `work-approvals-update.sh`. Allowed only when `can_manage` is true.

```json
{"status": "complete", "outcome": "approved", "approvalNotes": "Matches the request."}
```

`status`: `new`, `in_progress`, `paused`, `complete`.

`paused` requires `pauseReason`: `more_info_required`, `awaiting_additional_approver`, `awaiting_cab`, or `deferred`.

`complete` requires `outcome` `approved` or `rejected`. `rejected` requires `rejectionNotes` of at least 10 characters. Completing as `approved` stores `rejection_notes` as null. Completing as `rejected` stores `approval_notes` as null.

Schedule keys: `description`, `wbsCode`, `phase`, `workStream`, `plannedStartAt`, `plannedEndAt`, `startedAt`, `predecessorIds`.

Success `WORK_AP-SUC-003`.

A row whose status is already `complete` rejects every later PATCH with `WORK_AP-ERR-003` (409). Completion publishes `work.approval.completed`. A non-empty `process_token_id` on that event resumes the waiting process token.

## Error handling

| Code | What to do |
| --- | --- |
| `AUT-ERR-401` | The wrapper re-authenticates once. If it persists, check `API_KEY` and `BASE_URL`. |
| `REQ-ERR-001` | The body could not be bound. Send `Content-Type: application/json` and camelCase keys. |
| `VAL-ERR-001` / `VAL-ERR-400` | A field is missing or not in the allowed set. A rejection note shorter than 10 characters is this case. |
| `WORK_AP-ERR-001` | Approval id does not exist or is not visible. |
| `WORK_AP-ERR-002` | `can_manage` is false. Update-all does not override this. |
| `WORK_AP-ERR-003` | The approval is already complete. Reload. Do not retry. |
| `SYS-ERR-500` | Server failure. Retry once, then stop. |

## Non-goals

- Service-request work tab and discussion
- Manual tasks and acceptances
- Any `/api/fs` call for an approval
- Creating an approval
- Deciding an approval assigned to another user or group

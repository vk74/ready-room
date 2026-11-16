---
name: role-work-manual-activities
description: >
  Lists, inspects, and executes Work manual tasks for any bot that can see
  them. Use when updating status, outcome, time, WBS or schedule fields, a
  knowledge-base article link, or attachments on a manual_task, including
  completion that resumes a waiting process token.
last_release: "0.28.3"
compatibility: Requires curl, jq, and network access to the running instance. Self-contained — auth helper scripts are vendored in scripts/_lib when the skill pack is built (set REQUEST_SCRIPT to override).
required_environment_variables:
  - name: BASE_URL
    prompt: Instance base URL (e.g. https://example.com or http://localhost:7070)
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
    prompt: Path to a PEM CA certificate for the endpoint
    help: Optional. Preferred over TLS_INSECURE for trusted self-hosted certs.
    required_for: custom/private CA deployments
  - name: AGENT_HOME
    prompt: Base directory for local agent cache and state
    help: Optional. Defaults to ~/.agent-skills; used by role-auth cache files.
    required_for: custom local runtime layout
---

# role-work-manual-activities

<!--
version: 0.28.3
Short description: Manual-task list, read, update, and preserve-and-add attachments.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill: list, get, update, and attachment preserve-and-add for manual tasks.
-->

Work manual tasks (`manual_task`) for any bot that can see the row. Read `can_manage` before a PATCH. A completed task is locked.

Run the scripts that ship in this skill directory. Do not recreate them by writing their source back out. Install the skill by direct download or, once the pack bundle exists, by `base64 -d | tar xz`.

## Role composition

- `role-auth` obtains and refreshes the JWT. Every script calls `/api/*` only through `role-request.sh`.
- Upload and confirm files with `role-attachments` (`entity_type=manual_task`, `entity_id` the task uuid), then add them with `work-manual-tasks-attachments-add.sh`. Do not send `attachmentFileIds` on `work-manual-tasks-update.sh` unless the intent is to replace the set.
- Service-request discussion and the request work tab are `role-work-service-requests` and `role-communications`. This skill does not call them.

## Visibility

Without `service:requests:read:all`, a manual task is visible when the bot is the assignee, a member of the assigned group, the owner of that group, the company head, or related to the parent service request or service order (requester, beneficiary, watcher on a request, assignee of the parent request, parent fulfillment group or its owner, service owner, technical owner, dispatcher, or a member of a group linked to the parent service).

`service:requests:read:all` removes that filter. Coordinator, practice manager, and auditor hold it.

`scope=team` means the task's assigned group is one of the bot's groups. It does not mean every task on services the bot supports. Use `scope=all` for that wider set, still limited by the visibility predicate above.

## can_manage

`can_manage` follows `canManageManualTaskRow`. It is true when any of these hold:

- the bot is `assigned_user_id` or a member of `assigned_group_id`
- the bot holds `service:requests:update:all` (coordinator and practice manager: true on every manual task)
- the bot owns the assigned group
- the bot is the company head
- on the parent service request or service order, the bot is the service owner, technical owner, dispatcher, or a member of support tier 1, 2, or 3

An auditor holds `service:requests:read:all` only. `can_manage` stays false unless one of the other facts is also true. A false `can_manage` PATCH returns `WORK_MT-ERR-002`.

## Status, time, and schedule

Request JSON is camelCase. Response JSON is snake_case. Do not copy response keys into the PATCH.

| status | Required companion |
| --- | --- |
| `new`, `in_progress` | none |
| `paused` | `pauseReason`: `awaiting_requester`, `awaiting_third_party`, `awaiting_parts`, `scheduled` |
| `complete` | `outcome`: `succeeded`, `cancelled`, `failed`, `skipped` |

When `time_tracking.require_actual_on_close` is true, `complete` with `outcome` `succeeded` requires `actualMinutes`. Read that flag from `GET /api/core/settings` (`AdminApp.Practices`). This skill does not wrap that settings call; `role-work-service-requests` script `work-practices-settings-get.sh` does.

Optional fields: `description`, `kbArticleId`, `estimatedMinutes`, `actualMinutes`, `wbsCode`, `phase`, `workStream`, `plannedStartAt`, `plannedEndAt`, `startedAt`, `predecessorIds`.

Omitted keys stay unchanged. `attachmentFileIds` is the exception: omitted keeps current files, and a present array, including `[]`, replaces them. `work-manual-tasks-update.sh` warns on stderr when that key is present. `work-manual-tasks-attachments-add.sh` loads `GET /api/fs?entity_type=manual_task&entity_id=`, unions the active `file_id`s with the new ids, and PATCHes the merged `attachmentFileIds`.

## Completion lock

`status: "complete"` locks the row. A later PATCH returns `WORK_MT-ERR-003` (409). Reload and stop. Completion publishes `work.manual_task.completed`. When `process_token_id` is set, that event resumes the waiting process token.

## Scope

| Script concern | Method and route |
| --- | --- |
| List tasks | `GET /api/work/activities/manual-tasks` |
| Read one task | `GET /api/work/activities/manual-tasks/:id` |
| Update a task | `PATCH /api/work/activities/manual-tasks/:id` |
| Add attachments | `GET /api/fs` then the same PATCH |

## JWT contract

Protected requests send `Authorization: Bearer <JWT>`. The wrapper in `role-auth` caches the token, refreshes it, and retries once on `401`. Resolution order:

1. `REQUEST_SCRIPT`
2. `scripts/_lib/role-request.sh` (vendored when the skill pack is built)
3. `../../role-auth/scripts/role-request.sh` (this repository layout)

Every JSON body script sends `Content-Type: application/json`. Credentials are read from the environment or from the `role.env` file written by `role-setup.sh` (default directory `~/.agent-skills`, override with `AGENT_HOME`). Do not print `API_KEY` or the JWT.

## Script map

- `scripts/work-manual-tasks-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-manual-tasks-get.sh <task_uuid>`
- `scripts/work-manual-tasks-update.sh <task_uuid> <payload.json>`
- `scripts/work-manual-tasks-attachments-add.sh <task_uuid> <file_uuid> [<file_uuid>...]`

`--sort-by` keys the server orders by: `created_at`, `task_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `estimated_minutes`, `actual_minutes`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`. An unknown key sorts by `created_at`.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)

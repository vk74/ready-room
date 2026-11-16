---
name: role-work-acceptances
description: >
  Lists, inspects, and decides Work acceptances for the bot that is the
  assigned accepter or a member of the assigned group. Use when recording
  accepted or rejected and when adding acceptance files without replacing
  the current set. Holding update-all does not grant the decision.
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

# role-work-acceptances

<!--
version: 0.28.3
Short description: Acceptance list, read, assignee-only decision, and preserve-and-add attachments.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill: list, get, update, and attachment preserve-and-add for acceptances.
-->

Work acceptances (`acceptance`) for any bot that can see the row. Decide only when `can_manage` is true. That flag is the assignee-or-group gate. A completed acceptance is locked. `paused` is not a status.

Run the scripts that ship in this skill directory. Do not recreate them by writing their source back out. Install the skill by direct download or, once the pack bundle exists, by `base64 -d | tar xz`.

## Role composition

- `role-auth` obtains and refreshes the JWT. Every script calls `/api/*` only through `role-request.sh`.
- Upload and confirm files with `role-attachments` (`entity_type=acceptance`, `entity_id` the acceptance uuid), then add them with `work-acceptances-attachments-add.sh`. Do not send `attachmentFileIds` on `work-acceptances-update.sh` unless the intent is to replace the set.
- The parent request's discussion and work tab are other skills. This skill does not call them.

## Visibility and the decision gate

Without `service:requests:read:all`, an acceptance is visible on the same parent-and-assignee predicate as other activities: assignee, assigned-group member, assigned-group owner, company head, or a relationship to the parent service request or service order.

`service:requests:read:all` (coordinator, practice manager, auditor) lists and reads every acceptance.

`can_manage` is `canManageDecisionActivity`. It is true only when the bot itself is `assigned_user_id` or a member of `assigned_group_id`. `service:requests:update:all` does not set it. A coordinator or practice manager can read an acceptance assigned to someone else and cannot decide it. That PATCH returns `WORK_AC-ERR-002`.

`scope=team` means the acceptance's assigned group is one of the bot's groups.

## Status

Request JSON is camelCase (`acceptanceNotes`, `rejectionNotes`). Response JSON is snake_case (`acceptance_notes`, `rejection_notes`).

| status | Required companion |
| --- | --- |
| `new`, `in_progress` | none |
| `complete` | `outcome`: `accepted` or `rejected` |

There is no `paused` status and no `pauseReason`.

`rejected` requires `rejectionNotes` of at least 10 characters. Completing as `accepted` clears `rejection_notes`. Completing as `rejected` clears `acceptance_notes`.

Schedule keys: `description`, `wbsCode`, `phase`, `workStream`, `plannedStartAt`, `plannedEndAt`, `startedAt`, `predecessorIds`.

Omitted keys stay unchanged. `attachmentFileIds` is the exception: omitted keeps current files, and a present array, including `[]`, replaces them. `work-acceptances-update.sh` warns on stderr when that key is present. `work-acceptances-attachments-add.sh` loads `GET /api/fs?entity_type=acceptance&entity_id=`, unions the active `file_id`s with the new ids, and PATCHes the merged `attachmentFileIds`.

## Completion lock

`status: "complete"` locks the row. A later PATCH returns `WORK_AC-ERR-003` (409). Completion publishes `work.acceptance.completed`. When `process_token_id` is set, that event resumes the waiting process token.

## Scope

| Script concern | Method and route |
| --- | --- |
| List acceptances | `GET /api/work/activities/acceptances` |
| Read one acceptance | `GET /api/work/activities/acceptances/:id` |
| Decide or update | `PATCH /api/work/activities/acceptances/:id` |
| Add attachments | `GET /api/fs` then the same PATCH |

## JWT contract

Protected requests send `Authorization: Bearer <JWT>`. The wrapper in `role-auth` caches the token, refreshes it, and retries once on `401`. Resolution order:

1. `REQUEST_SCRIPT`
2. `scripts/_lib/role-request.sh` (vendored when the skill pack is built)
3. `../../role-auth/scripts/role-request.sh` (this repository layout)

Every JSON body script sends `Content-Type: application/json`. Credentials are read from the environment or from the `role.env` file written by `role-setup.sh` (default directory `~/.agent-skills`, override with `AGENT_HOME`). Do not print `API_KEY` or the JWT.

## Script map

- `scripts/work-acceptances-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-acceptances-get.sh <acceptance_uuid>`
- `scripts/work-acceptances-update.sh <acceptance_uuid> <payload.json>`
- `scripts/work-acceptances-attachments-add.sh <acceptance_uuid> <file_uuid> [<file_uuid>...]`

`--sort-by` keys the server orders by: `created_at`, `acceptance_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`. An unknown key sorts by `created_at`. Status values are `new`, `in_progress`, and `complete`.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)

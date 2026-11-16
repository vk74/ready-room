---
name: role-work-approvals
description: >
  Lists, inspects, and decides Work approvals for the bot that is the assigned
  approver or a member of the assigned group. Use when reading the service-order
  snapshot and recording approved or rejected, including a pause for more
  information. Holding update-all does not grant the decision.
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

# role-work-approvals

<!--
version: 0.28.3
Short description: Approval list, detail with order snapshot, and assignee-only decision.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill: list, get, and update for approvals, with the assignee-only decision gate.
-->

Work approvals (`approval`) for any bot that can see the row. Decide only when `can_manage` is true. That flag is the assignee-or-group gate. A completed approval is locked.

Run the scripts that ship in this skill directory. Do not recreate them by writing their source back out. Install the skill by direct download or, once the pack bundle exists, by `base64 -d | tar xz`.

## Role composition

- `role-auth` obtains and refreshes the JWT. Every script calls `/api/*` only through `role-request.sh`.
- Approvals have no `/api/fs` entity type. Do not call `role-attachments` for an approval.
- The parent request's discussion and work tab are other skills. This skill does not call them.

## Visibility and the decision gate

Without `service:requests:read:all`, an approval is visible on the same parent-and-assignee predicate as other activities: assignee, assigned-group member, assigned-group owner, company head, or a relationship to the parent service request or service order.

`service:requests:read:all` (coordinator, practice manager, auditor) lists and reads every approval.

`can_manage` is `canManageDecisionActivity`. It is true only when the bot itself is `assigned_user_id` or a member of `assigned_group_id`. `service:requests:update:all` does not set it. A coordinator or practice manager can read an approval assigned to someone else and cannot decide it. That PATCH returns `WORK_AP-ERR-002`.

`scope=team` means the approval's assigned group is one of the bot's groups.

## What the detail contains

`GET /api/work/activities/approvals/:id` adds `related_items` and, when the parent is a service order or a service request, `service_order`. That stamp is the order or request the bot is approving: number, title, description, service, form and form version, urgency, impact, quantity, watch list, requester, beneficiary, `answers`, `definition`, and `created_at`. Read it before deciding. It is not writable from this skill.

## Status

Request JSON is camelCase (`approvalNotes`, `rejectionNotes`, `pauseReason`). Response JSON is snake_case (`approval_notes`, `rejection_notes`, `pause_reason`).

| status | Required companion |
| --- | --- |
| `new`, `in_progress` | none |
| `paused` | `pauseReason`: `more_info_required`, `awaiting_additional_approver`, `awaiting_cab`, `deferred` |
| `complete` | `outcome`: `approved` or `rejected` |

`rejected` requires `rejectionNotes` of at least 10 characters. Completing as `approved` clears `rejection_notes`. Completing as `rejected` clears `approval_notes`.

Schedule keys: `description`, `wbsCode`, `phase`, `workStream`, `plannedStartAt`, `plannedEndAt`, `startedAt`, `predecessorIds`.

## Completion lock

`status: "complete"` locks the row. A later PATCH returns `WORK_AP-ERR-003` (409). Completion publishes `work.approval.completed`. When `process_token_id` is set, that event resumes the waiting process token.

## Scope

| Script concern | Method and route |
| --- | --- |
| List approvals | `GET /api/work/activities/approvals` |
| Read one approval | `GET /api/work/activities/approvals/:id` |
| Decide or update | `PATCH /api/work/activities/approvals/:id` |

## JWT contract

Protected requests send `Authorization: Bearer <JWT>`. The wrapper in `role-auth` caches the token, refreshes it, and retries once on `401`. Resolution order:

1. `REQUEST_SCRIPT`
2. `scripts/_lib/role-request.sh` (vendored when the skill pack is built)
3. `../../role-auth/scripts/role-request.sh` (this repository layout)

Every JSON body script sends `Content-Type: application/json`. Credentials are read from the environment or from the `role.env` file written by `role-setup.sh` (default directory `~/.agent-skills`, override with `AGENT_HOME`). Do not print `API_KEY` or the JWT.

## Script map

- `scripts/work-approvals-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--language english|russian] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-approvals-get.sh <approval_uuid> [--language english|russian]`
- `scripts/work-approvals-update.sh <approval_uuid> <payload.json>`

`--sort-by` keys the server orders by: `created_at`, `approval_number`, `title`, `status`, `assignee`, `group`, `completed_at`, `parent`, `wbs_code`, `phase`, `work_stream`, `planned_start_at`, `planned_end_at`, `started_at`. An unknown key sorts by `created_at`.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)

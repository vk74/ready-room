---
name: role-service-practice-manager
description: >
  Operates service requests as the head of the service practice for a bot
  in role.service.practiceManager (Role Service Practice Managers, at most
  two active members). Use when listing or updating any service request,
  assigning work, changing status, adding watchers, escalating a request
  to the company head, updating manual tasks, deciding an approval or
  acceptance assigned to the bot, posting in the requester discussion
  channel, or reading AdminApp.Practices settings.
last_release: "0.28.3"
compatibility: Requires curl, jq, and network access to the running instance. Self-contained — auth helper scripts are vendored in scripts/_lib (set REQUEST_SCRIPT to override).
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

# role-service-practice-manager

<!--
version: 0.28.3
Short description: Practice-manager service-request operations for external agents.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill for role.service.practiceManager: work-tab updates, watchers, activities, requester chat, and practices settings.
-->

Head of the service practice. The bot is a member of `role.service.practiceManager` (display name **Role Service Practice Managers**, `max_members = 2`). In a process this participant is `service.practice_manager`.

## Role mapping

Permissions this skill calls:

- `service:requests:read:all` — every service request, manual task, approval, and acceptance
- `service:requests:update:all` — work tab on every service request, and `can_manage` on every manual task
- `settings:read:common` — read of `AdminApp.Practices` through `GET /api/core/settings`

The role group is granted the two `service:requests` permissions. `settings:read:common` is the baseline permission on `role.users.registered`, which every account joins. That permission is what includes `AdminApp.Practices` in the settings response.

## How this role differs from the coordinator

A practice manager is the escalation target and the head of the practice, not the day-to-day dispatcher.

Under the default `AdminApp.Practices` policies:

- `escalation.company_head.policy` includes `practice_manager` and `coordinator`. Add `data.escalation_targets.company_head.user_id` with `work-requests-watchers-add.sh` to escalate the request to the company head.
- `escalation.practice_manager.policy` includes `coordinator` (and the operational roles) and does not list `practice_manager`. A caller who holds `service:requests:update:all` is treated as a coordinator by that gate, so a practice-manager bot also passes the default practice-manager policy. Read `data.escalation_targets.practice_manager.allowed` before adding those users.

Support-tier moves are assignment changes. `data.escalation_targets.support_tier2.allowed` and `support_tier3.allowed` are true when that service has the tier group and the request is not already assigned to it. Set the group with `work-requests-assign.sh --group-id`. The work PATCH accepts any active non-system group.

Always read `allowed` on the detail payload. `WORK-ERR-002` means the server refused the manage check or the hierarchical watch-list addition.

## Scope

| Script concern | Method and route |
| --- | --- |
| List requests | `GET /api/work/requests` |
| Read one request | `GET /api/work/requests/:id` |
| Update work fields | `PATCH /api/work/requests/:id/work` |
| Search services | `GET /api/work/services/search` |
| Manual tasks | `GET` and `PATCH /api/work/activities/manual-tasks` |
| Approvals | `GET` and `PATCH /api/work/activities/approvals` |
| Acceptances | `GET` and `PATCH /api/work/activities/acceptances` |
| Requester discussion | `/api/communications/entity/service_request/:id/channels/requester` |
| Practices settings | `GET /api/core/settings` |
| Pick a user or group | `GET /api/core/item-selector/search-users` and `search-groups` |

Explicitly out of this skill: creating a request, cancelling a request, editing catalog services, updating settings, and message reactions or pins.

## Work-tab safety

`PATCH /api/work/requests/:id/work` overwrites `assigned_group_id`, `assigned_user_id`, and `work_notes` when those keys are omitted. `work-requests-update-work.sh`, `work-requests-assign.sh`, `work-requests-status.sh`, and `work-requests-watchers-add.sh` first `GET` the request and send the current values for every overwrite field the command does not change.

The GET body names the assigned group `group_id`. The PATCH body names it `assigned_group_id`. The scripts copy `group_id` into `assigned_group_id`.

`watch_list`, `estimated_minutes`, and `actual_minutes` are preserved by the server when omitted. `work-requests-watchers-add.sh` is the preserve-and-add path. A `watch_list` key inside `work-requests-update-work.sh` replaces the whole set.

Request `pause_reason` values the server accepts while `status` is `paused`: `awaiting_requester`, `awaiting_third_party`, `scheduled`, `other`.

## Approvals, acceptances, and manual tasks

Both this role and the coordinator can list and read every approval and acceptance. `PATCH` is allowed only when `can_manage` is true: the bot itself, or one of its groups, is the assigned approver or accepter. `service:requests:update:all` does not set `can_manage` on approvals or acceptances.

Manual tasks are different. `can_manage` is true on every manual task because of `service:requests:update:all`. Update status, outcome, `pauseReason`, description, `kbArticleId`, minutes, and WBS/schedule fields with camelCase keys. Omit `attachmentFileIds` so existing attachments stay. The same omit-to-keep rule applies to acceptances.

Approval and acceptance decision bodies use camelCase (`status`, `outcome`, `approvalNotes`, `rejectionNotes`, `acceptanceNotes`, `pauseReason`).

## Requester discussion

On a service request the discussion channel key is `requester`. That channel is the conversation between the requester and the support team. Internal support notes stay in `work_notes` on the request, not in that channel.

## JWT contract

Protected requests send `Authorization: Bearer <JWT>`. The wrapper in `role-auth` caches the token, refreshes it, and retries once on `401`. Resolution order:

1. `REQUEST_SCRIPT`
2. `scripts/_lib/role-request.sh` (vendored when the skill pack is built)
3. `../../role-auth/scripts/role-request.sh` (this repository layout)

Every JSON body script sends `Content-Type: application/json`. Credentials are read from the environment or from the `role.env` file written by `role-setup.sh` (default directory `~/.agent-skills`, override with `AGENT_HOME`). Do not print `API_KEY` or the JWT.

Install this skill by downloading the directory, or by decoding the packed bundle once `agent-skills/dist/` has been regenerated. Do not retype the scripts.

## Script map

- `scripts/work-requests-list.sh [--scope mine|assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--urgency low|medium|high|critical]... [--service-id <uuid>] [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--requester all|me|user] [--requester-user-id <uuid>] [--language english|russian] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-requests-get.sh <request_uuid> [--language english|russian]`
- `scripts/work-requests-update-work.sh <request_uuid> <patch.json>`
- `scripts/work-requests-assign.sh <request_uuid> [--group-id <uuid>|none] [--user-id <uuid>|none] [--priority 1..5]`
- `scripts/work-requests-status.sh <request_uuid> <status> [--pause-reason <reason>] [--actual-minutes <N>] [--work-notes "<text>"]`
- `scripts/work-requests-watchers-add.sh <request_uuid> <user_uuid> [<user_uuid>...]`
- `scripts/work-services-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/work-manual-tasks-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-manual-tasks-get.sh <task_uuid>`
- `scripts/work-manual-tasks-update.sh <task_uuid> <payload.json>`
- `scripts/work-approvals-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--language english|russian] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-approvals-get.sh <approval_uuid> [--language english|russian]`
- `scripts/work-approvals-update.sh <approval_uuid> <payload.json>`
- `scripts/work-acceptances-list.sh [--scope assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-acceptances-get.sh <acceptance_uuid>`
- `scripts/work-acceptances-update.sh <acceptance_uuid> <payload.json>`
- `scripts/work-request-chat-get.sh <request_uuid> [--page N] [--items-per-page N]`
- `scripts/work-request-chat-post.sh <request_uuid> <payload.json>`
- `scripts/work-request-chat-update.sh <message_uuid> <payload.json>`
- `scripts/work-request-chat-delete.sh <message_uuid>`
- `scripts/work-request-chat-read.sh <conversation_uuid> [<last_read_message_uuid>]`
- `scripts/work-practices-settings-get.sh`
- `scripts/core-search-users.sh <query> [--limit N] [--include-bots] [--exclude-system]`
- `scripts/core-search-groups.sh <query> [--limit N] [--exclude-system]`

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)

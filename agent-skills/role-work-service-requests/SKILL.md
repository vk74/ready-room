---
name: role-work-service-requests
description: >
  Lists, reads, updates, assigns, and cancels Work service requests for any
  bot that can see them: requester or beneficiary, watcher, assigned engineer,
  fulfillment group, support tier, service owner, technical owner, dispatcher,
  practice manager, coordinator, or auditor. Use when working the request
  queue, the work tab, watchers, escalation, or AdminApp.Practices settings.
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

# role-work-service-requests

<!--
version: 0.28.3
Short description: Service-request operations for any Work bot persona.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill: list, read, work-tab update, assign, status, watchers, cancel, service search, and practices settings.
- Directory search and the notifications inbox are role-auth scripts. Discussion is role-communications.
-->

Work service requests for any bot that can see a request. Read `can_manage` and `can_cancel` on the row before writing. This skill does not decide approvals or acceptances, and it does not execute manual tasks.

Run the scripts that ship in this skill directory. Do not recreate them by writing their source back out. Install the skill by direct download or, once the pack bundle exists, by `base64 -d | tar xz`.

## Role composition

- `role-auth` obtains and refreshes the JWT. Every script calls `/api/*` only through `role-request.sh`.
- Pick a user or a group with `role-auth` `scripts/core-search-users.sh` and `scripts/core-search-groups.sh`.
- The in-app inbox is `role-auth`: `notifications-inbox-list.sh`, `notifications-inbox-get.sh`, `notifications-inbox-read.sh`, `notifications-inbox-unread.sh`, `notifications-inbox-read-all.sh`, `notifications-inbox-read-by-subject.sh`, `notifications-inbox-delete.sh`, and the mute scripts.
- Discussion is `role-communications`. On a service request the channel keys are `requester` and `internal`. Read them with `chat-channel-get.sh service_request <request_uuid> requester` or `internal`.
- Files are `role-attachments` with `entity_type=service_request`. This skill does not upload or replace them. After the request exists, list files and leave the set unchanged.

## Who can see a request

Without `service:requests:read:all`, a request is visible when the bot is any of:

- the requester (`requester_user_id`) or the beneficiary (`requested_for_user_id`)
- a watcher (`watch_list`)
- the assigned user, a member of the assigned group, or the owner of that group
- the service owner, technical owner, or dispatcher
- a member of any group linked to the service
- the company head (staff standard account with no manager)

`service:requests:read:all` removes that filter. `role.service.coordinator`, `role.service.practiceManager`, and `role.service.auditor` hold it, so `scope=all` returns every request.

`scope` is a queue filter on top of visibility:

| scope | Rows |
| --- | --- |
| `mine` | Requester, beneficiary, or watcher. Use this for a requester or beneficiary bot. |
| `assigned` | `assigned_user_id` is the bot. |
| `team` | `assigned_group_id` is one of the bot's groups. This is the assigned fulfillment group, not "every request on services I support". |
| `unassigned` | No assigned user. |
| `all` | No extra queue filter. Default on the server. A support-tier member who is not in the assigned group still sees the service's requests here. |

## Who can manage and who can cancel

`can_manage` is true when any of these hold:

- `service:requests:update:all` (coordinator and practice manager: true on every request)
- the bot is the company head
- the bot is the assigned user, a member of the assigned fulfillment group, or the owner of that group
- the bot is the service owner, technical owner, or dispatcher
- the bot is in a support tier 1, 2, or 3 group on that service

A requester, beneficiary, or watcher who holds none of those has `can_manage` false. The work-tab scripts then receive `WORK-ERR-002`.

`can_cancel` is true only when the bot is the requester or the beneficiary, and status is not `resolved`, `closed`, `cancelled`, or `failed`. Coordinator, practice manager, assignee, and auditor do not gain cancel from their roles. `work-requests-cancel.sh` is that POST. A non-party receives `WORK-ERR-002`. A party on a terminal status receives `VAL-ERR-400`.

## Personas

**Requester or beneficiary.** List with `--scope mine`. Cancel only when `can_cancel` is true. Discussion is the `requester` channel in `role-communications`. `service:requests:read:all` alone does not grant posting there. Do not PATCH `/work`.

**Assigned engineer, fulfillment group, support tier 1..3, dispatcher, technical owner, or service owner.** `can_manage` is true on the matching requests. Discussion uses both `requester` and `internal`. `internal` requires `can_manage` (`canManageRequest`) to read or post. Update the work tab with the scripts below. They GET the row first so omitted assignment and notes are not cleared.

**Coordinator (`role.service.coordinator`) and practice manager (`role.service.practiceManager`).** Both hold `service:requests:read:all` and `service:requests:update:all`. They see every request and `can_manage` is true on every request. Functional escalation assigns `data.escalation_targets.support_tier2.group_id` or `support_tier3.group_id` with `work-requests-assign.sh --group-id` when that target's `allowed` is true. Hierarchical escalation adds every `practice_manager.users[].user_id` and `company_head.user_id` with `work-requests-watchers-add.sh` when `allowed` is true. `practice_manager.user_id` is only the first member. A caller with `service:requests:update:all` is treated as `coordinator` by the hierarchical policy. `WORK-ERR-002` refuses a watcher the policy does not allow.

**Auditor (`role.service.auditor`).** Holds `service:requests:read:all` and not `service:requests:update:all`. Read every request. Do not PATCH, assign, change status, add watchers, or cancel. The auditor can read the `requester` channel and cannot post there. `internal` stays closed unless that same bot also has `can_manage`.

## Work-tab safety

`PATCH /api/work/requests/:id/work` clears `assigned_group_id`, `assigned_user_id`, and `work_notes` when those keys are omitted. `work-requests-update-work.sh`, `work-requests-assign.sh`, `work-requests-status.sh`, and `work-requests-watchers-add.sh` GET the request and send the current values for every overwrite field the command does not change.

The GET body names the assigned group `group_id`. The PATCH body names it `assigned_group_id`. The scripts copy `group_id` into `assigned_group_id`.

`watch_list`, `estimated_minutes`, and `actual_minutes` stay when omitted. `work-requests-watchers-add.sh` is the preserve-and-add path. A `watch_list` key inside `work-requests-update-work.sh` replaces the whole set.

`pause_reason` while `status` is `paused`: `awaiting_requester`, `awaiting_third_party`, `scheduled`, `other`.

Read `AdminApp.Practices` with `work-practices-settings-get.sh` before escalating or closing: `escalation.practice_manager.policy`, `escalation.company_head.policy`, `priority.matrix`, `time_tracking.require_actual_on_close`.

## Scope

| Script concern | Method and route |
| --- | --- |
| List requests | `GET /api/work/requests` |
| Read one request | `GET /api/work/requests/:id` |
| Update work fields | `PATCH /api/work/requests/:id/work` |
| Cancel | `POST /api/work/requests/:id/cancel` |
| Search services | `GET /api/work/services/search` |
| Practices settings | `GET /api/core/settings` |

Explicitly out of this skill: creating a request, manual tasks, approvals, acceptances, discussion messages, attachment upload, and settings writes.

## JWT contract

Protected requests send `Authorization: Bearer <JWT>`. The wrapper in `role-auth` caches the token, refreshes it, and retries once on `401`. Resolution order:

1. `REQUEST_SCRIPT`
2. `scripts/_lib/role-request.sh` (vendored when the skill pack is built)
3. `../../role-auth/scripts/role-request.sh` (this repository layout)

Every JSON body script sends `Content-Type: application/json`. Credentials are read from the environment or from the `role.env` file written by `role-setup.sh` (default directory `~/.agent-skills`, override with `AGENT_HOME`). Do not print `API_KEY` or the JWT.

## Script map

- `scripts/work-requests-list.sh [--scope mine|assigned|team|unassigned|all] [--search "<text>"] [--status <status>]... [--urgency low|medium|high|critical]... [--service-id <uuid>] [--assignee all|me|unassigned|user] [--assigned-user-id <uuid>] [--assigned-group-id <uuid>] [--requester all|me|user] [--requester-user-id <uuid>] [--language english|russian] [--page N] [--items-per-page N] [--sort-by <key>] [--sort-desc [true|false]]`
- `scripts/work-requests-get.sh <request_uuid> [--language english|russian]`
- `scripts/work-requests-update-work.sh <request_uuid> <patch.json>`
- `scripts/work-requests-assign.sh <request_uuid> [--group-id <uuid>|none] [--user-id <uuid>|none] [--priority 1..5]`
- `scripts/work-requests-status.sh <request_uuid> <status> [--pause-reason <reason>] [--actual-minutes <N>] [--work-notes "<text>"]`
- `scripts/work-requests-watchers-add.sh <request_uuid> <user_uuid> [<user_uuid>...]`
- `scripts/work-requests-cancel.sh <request_uuid>`
- `scripts/work-services-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/work-practices-settings-get.sh`

`--sort-by` keys: `created_at`, `request_number`, `status`, `urgency`, `title`, `service`, `requester`, `assignee`, `form`, `impact`, `priority`, `requested_for`, `group`, `quantity`, `pause_reason`, `updated_at`, `resolved_at`, `closed_at`, `estimated_minutes`, `actual_minutes`, `total_estimated_minutes`, `total_actual_minutes`, `activities_estimated_minutes`, `activities_actual_minutes`. The last two are accepted by the script. The server sorts them as `created_at`. `total_estimated_minutes` and `total_actual_minutes` are the keys that include activity minutes.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)
- [Communications skill](../role-communications/SKILL.md)

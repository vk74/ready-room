---
name: role-communications
description: >
  Reads and writes entity discussion channels, including the requester and
  internal channels on service requests. Covers posting, editing, and
  deleting messages, replies, @username and UUID mentions, reactions, pins,
  message attachments through role-attachments, and marking conversations
  read. Use when an external agent needs the communications API for an
  entity chat without duplicating the parent module's own CRUD.
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

# role-communications

<!--
version: 0.28.3
Short description: Entity discussion channels for external agents.
File: SKILL.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial skill for entity chats: channel read, messages, reactions, pins, and the read cursor.
-->

Module-agnostic entity chat for external agents. The parent module still owns the entity. This skill only talks to `/api/communications`.

## Role composition

Compose `role-auth` with `role-communications`. Add `role-attachments` when a message carries files (`entity_type` `comm_message`). Compose that set with the module skill that owns the entity, such as `role-work-service-requests` for a service request.

This skill does not create, assign, or close the parent entity. Read `conversation_id` and `can_post` from the channel payload before posting or marking the conversation read. A channel that has never received a message returns `conversation_id: null`.

Install this skill by downloading the directory, or by decoding the packed bundle once `agent-skills/dist/` has been regenerated. Do not retype the scripts.

## Entity channels & access rules

`entity_type` and `channel_key` are path segments of 1..64 characters. They must not contain `/`. `entity_id` is a UUID.

For `entity_type = service_request` the channel keys are `requester` and `internal`.

`requester` is the conversation with the requester, `requested_for`, watchers, and request managers (`canManageRequest`). Involved users (requester, `requested_for`, watchers), request managers, and `service:requests:read:all` can read it. Posting is allowed for involved users and request managers while the request status is not `closed`, `cancelled`, or `failed`. `service:requests:read:all` alone does not grant posting. A write on a channel the caller can read but cannot post returns `COM-ERR-003`.

`internal` is the internal team discussion. Both reading and posting require `canManageRequest`: the assignee, a fulfillment group member, the assigned group's owner, the service owner, technical owner, or dispatcher, a support tier 1..3 member, the company head, or `service:requests:update:all`. Posting stays allowed after the request is closed. A caller who cannot manage the request receives `COM-ERR-002`.

`can_post` on the channel payload is the server's decision for this caller. When it is false, do not post, edit, delete, or pin.

An unknown `entity_type`, or a service request id that does not exist, is `COM-ERR-001`. An unknown channel key on a service request that does exist is `COM-ERR-002`.

## Mentions and Replies

An inline `@username` in `body` is resolved by the server to an active user and merged with `mentionedUserIds`. The username pattern is an `@` at the start of the text or after whitespace, then 2..64 characters from `A-Z`, `a-z`, `0-9`, `_`, `.`, and `-`. The match is case-sensitive and the account must be active. Unknown tokens stay in the text and are not added. Invalid UUID strings inside `mentionedUserIds` are skipped. The merged set is capped at 50. More than 50 mentions is `VAL-ERR-001`.

`replyToMessageId` quotes a non-deleted parent message in the same conversation. A missing parent is `COM-ERR-001`. A deleted parent is `COM-ERR-003`.

On update, an omitted key is left unchanged. Sending `body` re-resolves `@username` in the new text and merges those users into the mention list. Sending `mentionedUserIds` replaces the explicit id list. There is no request field for `mention_everyone` or `thread_root_id`. Messages posted here stay `mention_everyone: false` with `thread_root_id: null`.

## Message Attachments (`comm_message`)

Files are not part of the message JSON. Use two steps:

1. Post the message with `"hasAttachments": true` and a `body` string (text, or `""` when the message is only files). Read `data.id` (`<message_uuid>`).
2. Upload and confirm each file with `role-attachments`:

```bash
bash role-attachments/scripts/attachments-upload-flow.sh comm_message <message_uuid> <file_path>
```

Only the message author can upload, and only while the message is not deleted and the channel still accepts posts. A closed requester channel refuses the upload. Deleting the message deletes its stored files. Setting `hasAttachments` to false on update changes the flag and does not delete files. Omit `hasAttachments` to leave the flag unchanged.

Quotas and the MIME allowlist are in [the API contract](references/api-contract.md). Upload errors use `FILE-ERR-*` from `role-attachments`.

## Marking Read & Notifications

`chat-conversation-read.sh <conversation_uuid>` advances the caller read cursor. Omit the message id to mark the conversation read through its latest message. The same call marks unread notifications in module `comm` for that entity (`subject_type` is the entity type, `subject_id` is the entity id) as read. Those rows are the ones listed in `/api/notifications/inbox`. The call does not filter by channel: marking either channel of a service request read clears unread `comm` notifications for the whole request.

The read cursor requires a conversation id. Fetch the channel first. An empty channel has no conversation yet.

## Scope

| Script concern | Method and route |
| --- | --- |
| Read a channel page | `GET /api/communications/entity/:entityType/:entityId/channels/:channelKey` |
| Post a message | `POST /api/communications/entity/:entityType/:entityId/channels/:channelKey/messages` |
| Edit a message | `PATCH /api/communications/messages/:messageId` |
| Delete a message | `DELETE /api/communications/messages/:messageId` |
| Toggle a reaction | `POST /api/communications/messages/:messageId/reactions` |
| Pin a message | `POST /api/communications/messages/:messageId/pin` |
| Unpin a message | `DELETE /api/communications/messages/:messageId/pin` |
| Mark a conversation read | `POST /api/communications/conversations/:conversationId/read` |

Explicitly out of this skill: parent-entity CRUD, `/api/fs` (use `role-attachments`), calls, non-entity conversations, and listing or mutating `/api/notifications/inbox` except for the mark-read side effect above.

Edit and delete are limited to the author, and the channel must still accept posts. Pin and unpin require post access and are not limited to the author. A reaction requires read access, including on a requester channel that no longer accepts posts. A deleted message refuses update, delete, reaction, and pin with `COM-ERR-003`.

## JWT contract

Protected requests send `Authorization: Bearer <JWT>`. The wrapper in `role-auth` caches the token, refreshes it, and retries once on `401`. Resolution order:

1. `REQUEST_SCRIPT`
2. `scripts/_lib/role-request.sh` (vendored when the skill pack is built)
3. `../../role-auth/scripts/role-request.sh` (this repository layout)

Every JSON body script sends `Content-Type: application/json`. Credentials are read from the environment or from the `role.env` file written by `role-setup.sh` (default directory `~/.agent-skills`, override with `AGENT_HOME`). Do not print `API_KEY` or the JWT.

## Script map

- `scripts/chat-channel-get.sh <entity_type> <entity_id> <channel_key> [--page N] [--items-per-page N]`
- `scripts/chat-message-post.sh <entity_type> <entity_id> <channel_key> <payload.json>`
- `scripts/chat-message-update.sh <message_uuid> <payload.json>`
- `scripts/chat-message-delete.sh <message_uuid>`
- `scripts/chat-message-reaction-toggle.sh <message_uuid> <emoji>`
- `scripts/chat-message-pin.sh <message_uuid>`
- `scripts/chat-message-unpin.sh <message_uuid>`
- `scripts/chat-conversation-read.sh <conversation_uuid> [<last_read_message_uuid>]`

`--page` is an integer >= 1. `--items-per-page` is an integer from 1 to 100. Omitted, the server uses page 1 and 25 items. `data.messages` is oldest-first within the page. Page 1 is the newest page. `data.pagination` uses camelCase keys.

## Usage examples

Read the requester channel of a service request:

```bash
bash scripts/chat-channel-get.sh service_request \
  "11111111-1111-1111-1111-111111111111" requester --page 1 --items-per-page 25
```

Post a reply that mentions one user by id and one by username:

```bash
cat > /tmp/chat-message.json <<'EOF'
{
  "body": "Looking at this now, @alex.",
  "replyToMessageId": "22222222-2222-2222-2222-222222222222",
  "mentionedUserIds": ["33333333-3333-3333-3333-333333333333"]
}
EOF
bash scripts/chat-message-post.sh service_request \
  "11111111-1111-1111-1111-111111111111" requester /tmp/chat-message.json
```

Post a file-only message, then upload:

```bash
printf '%s' '{"body":"","hasAttachments":true}' > /tmp/chat-file.json
bash scripts/chat-message-post.sh service_request \
  "11111111-1111-1111-1111-111111111111" internal /tmp/chat-file.json
bash role-attachments/scripts/attachments-upload-flow.sh comm_message \
  "<message_uuid>" ./notes.pdf
```

Edit, react, pin, and mark the conversation read:

```bash
printf '%s' '{"body":"Updated text."}' > /tmp/chat-edit.json
bash scripts/chat-message-update.sh "<message_uuid>" /tmp/chat-edit.json
bash scripts/chat-message-reaction-toggle.sh "<message_uuid>" "👍"
bash scripts/chat-message-pin.sh "<message_uuid>"
bash scripts/chat-conversation-read.sh "<conversation_uuid>"
```

Request bodies are camelCase. Response fields are snake_case, except `data.pagination`. Do not copy response keys back into a request.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)

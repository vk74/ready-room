# Communications API contract

<!--
version: 0.28.3
Short description: Entity-chat endpoint contract for role-communications.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Initial contract for the eight /api/communications routes, message DTOs, and comm_message file rules.
-->

Reference for `role-communications`. The scripts call these routes through `role-request.sh`. Do not call `curl` against `/api/*` yourself.

All eight routes require an active authenticated user:

```http
Authorization: Bearer <JWT>
```

A `401` with `AUT-ERR-401` is retried once after re-auth. `SYS-ERR-500` is an unexpected server failure; retry only when the failure is clearly transient.

## Envelope

Success (`200`, or `201` for a newly posted message):

```json
{"success": true, "code": "COM-SUC-001", "data": {}}
```

Failure (no `data`):

```json
{"success": false, "code": "COM-ERR-002"}
```

## Field naming

Request JSON and the channel query string are camelCase: `body`, `replyToMessageId`, `mentionedUserIds`, `hasAttachments`, `emoji`, `lastReadMessageId`, `page`, `itemsPerPage`.

Response JSON is snake_case: `conversation_id`, `entity_type`, `channel_key`, `can_post`, `mentioned_user_ids`, `has_attachments`, `reply_to_message_id`. Do not copy those keys back into a request.

The exception inside a success payload is `data.pagination`. Its keys are camelCase: `totalItems`, `totalPages`, `currentPage`, `itemsPerPage`.

Timestamps are RFC3339. UUIDs are strings. Empty lists are `[]`, not null. Nullable fields (`conversation_id`, `reply_to_message_id`, `thread_root_id`, `pinned_at`, `pinned_by`, `edited_at`, `deleted_at`, `last_read_message_id`, `last_read_at`) are JSON `null` when unset. `author` and `reply_to` are omitted when absent.

## Codes

| Code | HTTP | When |
| --- | --- | --- |
| `COM-SUC-001` | 200 | Channel page fetched. An empty channel is still success. |
| `COM-SUC-002` | 201 | Message posted. `data` is one `ChatMessageDTO`. |
| `COM-SUC-003` | 200 | Message updated. `data` is one `ChatMessageDTO`. |
| `COM-SUC-004` | 200 | Message soft-deleted. `data` is `{"id":"<message_uuid>"}`. |
| `COM-SUC-005` | 200 | Reaction toggled. `data` is a `ChatReactionGroupDTO` array. |
| `COM-SUC-006` | 200 | Pin set or cleared. `data` is one `ChatMessageDTO`. |
| `COM-SUC-007` | 200 | Read cursor stored. `data` is `{"unread_count":0}`. |
| `COM-ERR-001` | 404 | Entity type is not registered, the entity or message or conversation is missing, `replyToMessageId` is not in this conversation, or `lastReadMessageId` is not in this conversation. |
| `COM-ERR-002` | 403 | The caller cannot read the channel, or the caller is not the author of a message being edited or deleted. An unknown channel key on a service request that exists is also 403. |
| `COM-ERR-003` | 409 | The caller can read but the channel does not accept posts (requester channel on a `closed`, `cancelled`, or `failed` request, or a read-only caller), the message is already deleted, or `replyToMessageId` quotes a deleted message. |
| `VAL-ERR-001` | 400 | Path id is not a UUID or is the nil UUID; `entity_type` or `channel_key` is empty or longer than 64 characters; `body` is empty when `hasAttachments` is false, or longer than 8000 characters; mentions exceed 50; `replyToMessageId` or `lastReadMessageId` is not a UUID; an update object sets none of `body`, `mentionedUserIds`, `hasAttachments`; `emoji` is empty or longer than 32 characters. |
| `REQ-ERR-001` | 400 | The query string or JSON body could not be bound. |
| `AUT-ERR-401` | 401 | Missing or invalid JWT, or the user is not active. |
| `SYS-ERR-500` | 500 | Unexpected server failure. |

`body` length is counted after trimming whitespace, in Unicode code points. The post script also rejects a present `body` whose raw length is above 8000.

## Service request channels

`entity_type` is `service_request`. `channel_key` is `requester` or `internal`.

`canManageRequest` is true when the caller is any of: the assignee, a fulfillment group member, the assigned group's owner, the service owner, the technical owner, the dispatcher, a support tier 1, 2, or 3 member, the company head, or holds `service:requests:update:all`.

| Channel | Read | Post |
| --- | --- | --- |
| `requester` | Involved users (requester, `requested_for`, watchers), request managers, and `service:requests:read:all`. | Involved users and request managers, and only while status is not `closed`, `cancelled`, or `failed`. |
| `internal` | `canManageRequest` only. | `canManageRequest`, including after the request is closed. |

The first post creates the conversation. A GET before that returns `conversation_id: null`, `message_count: 0`, and empty `messages`. `can_post` is still set.

Who is notified is separate from who can read. On `requester`, the participant set is the requester, `requested_for` when set, the watchers, and the assignee when set. On `internal`, the participant set is the assignee only. When no user is assigned, notifications go to the assigned group.

## GET channel

`GET /api/communications/entity/:entityType/:entityId/channels/:channelKey`

Query, both optional: `page` (default 1, values below 1 become 1) and `itemsPerPage` (default 25, values below 1 become 25, values above 100 become 100). The get script refuses to send a page below 1 or an `itemsPerPage` outside 1..100.

The page is selected newest-first (`created_at` descending, then `id` descending) and then reversed, so `messages` is oldest-first within that page. Page 1 is the newest page. Deleted messages stay in the page with `body: ""` and `deleted_at` set.

`pinned_messages` is a separate list of at most 20 non-deleted pinned messages, newest pin first. `unread_count` counts non-deleted messages by other authors created after `last_read_at`. When the caller has never read the conversation, every such message counts.

`ConversationViewDTO` (`COM-SUC-001`):

```json
{
  "conversation_id": "44444444-4444-4444-4444-444444444444",
  "entity_type": "service_request",
  "entity_id": "11111111-1111-1111-1111-111111111111",
  "channel_key": "requester",
  "can_post": true,
  "message_count": 2,
  "unread_count": 1,
  "last_read_message_id": null,
  "last_read_at": null,
  "pinned_messages": [],
  "messages": [],
  "participants": [],
  "pagination": {
    "totalItems": 2,
    "totalPages": 1,
    "currentPage": 1,
    "itemsPerPage": 25
  }
}
```

`participants` is a `ChatAuthorDTO` array for the channel's participant users. It does not include a recipient group.

## POST message

`POST /api/communications/entity/:entityType/:entityId/channels/:channelKey/messages`

`PostMessageRequest`:

| Field | Rule |
| --- | --- |
| `body` | String. Trimmed. Required as a non-empty string unless `hasAttachments` is true. At most 8000 characters. `""` is valid together with `hasAttachments: true`. |
| `replyToMessageId` | Optional UUID of a non-deleted message in this conversation. |
| `mentionedUserIds` | Optional UUID string array. Merged with `@username` matches from `body`. Cap 50. Invalid entries are ignored. |
| `hasAttachments` | Optional boolean, default false. `true` allows an empty body and tells the client that files will be uploaded to this message. |

`201` `COM-SUC-002` returns the created `ChatMessageDTO`. `kind` is `user`. `revision` starts at 1. The author's own read cursor moves to this message.

## PATCH message

`PATCH /api/communications/messages/:messageId`

`UpdateMessageRequest`. Every field is optional, and at least one must be present. A null or omitted field is unchanged.

| Field | Rule |
| --- | --- |
| `body` | Replacement text, same length rule as post. Sending `body` marks the message edited and re-resolves `@username`. |
| `mentionedUserIds` | Replaces the explicit id list. Combined with username matches when `body` is also sent. |
| `hasAttachments` | Replaces the flag. `false` does not delete stored files. |

Only the author can edit, and the channel must still accept posts. A non-author receives `COM-ERR-002`. A channel that is closed to posts, or a deleted message, returns `COM-ERR-003`. The result must still have a non-empty body or `hasAttachments: true`.

`200` `COM-SUC-003` returns the updated `ChatMessageDTO`. Sending `body` sets `edited_at` and increments `revision`, including when the trimmed text is unchanged. When `body` is omitted, `revision` increments if `has_attachments` or the mention list changes.

## DELETE message

`DELETE /api/communications/messages/:messageId`

No body. Author only, and the channel must still accept posts. The row is soft-deleted: `body` is cleared, `has_attachments` becomes false, the pin is cleared, reactions are removed, and stored `comm_message` files are deleted. `200` `COM-SUC-004` returns `{"id":"<message_uuid>"}`.

## Reactions

`POST /api/communications/messages/:messageId/reactions`

```json
{"emoji": "👍"}
```

`emoji` is required, trimmed, 1..32 characters. The call inserts the caller's reaction or removes it when that same emoji is already present. Any caller who can read the conversation may react, including on a requester channel that no longer accepts posts. A deleted message is `COM-ERR-003`.

`200` `COM-SUC-005` returns the message's reaction groups, or `[]` when the last reaction was removed.

## Pin and unpin

`POST /api/communications/messages/:messageId/pin` sets `pinned_at` and `pinned_by` to the caller.

`DELETE /api/communications/messages/:messageId/pin` clears both.

No body. Any caller who can post on the channel may pin or unpin. The author is not special here. A deleted message, or a channel that does not accept posts, is `COM-ERR-003`.

`200` `COM-SUC-006` returns the updated `ChatMessageDTO`. The channel GET shows at most 20 pinned messages.

## Mark read

`POST /api/communications/conversations/:conversationId/read`

```json
{}
```

or

```json
{"lastReadMessageId": "22222222-2222-2222-2222-222222222222"}
```

An empty object, or a missing `lastReadMessageId`, stores the conversation's latest message id (which may be null) and sets `last_read_at` to now. A provided id must belong to that conversation.

The caller must be able to read the conversation. For an entity conversation the same transaction marks unread rows in `app.notifications` as read when `user_id` is the caller, `module` is `comm`, `subject_type` is the entity type, and `subject_id` is the entity id. Both channels of one service request share that subject, so either read cursor clears the request's unread `comm` notifications.

`200` `COM-SUC-007` returns `{"unread_count": 0}`.

## Response shapes

`ChatAuthorDTO`:

| Field | JSON | Notes |
| --- | --- | --- |
| User id | `user_id` | UUID. |
| Username | `username` | String. |
| Display name | `display_name` | Standard account: first and last name, otherwise the username. Bot: bot display name, otherwise the username. |
| Account type | `account_type` | `standard`, `bot`, or `system`. |

`ChatReplyPreviewDTO` (omitted when there is no loaded parent):

| Field | JSON | Notes |
| --- | --- | --- |
| Id | `id` | Parent message UUID. |
| Author | `author` | `ChatAuthorDTO`, omitted when unknown. |
| Preview | `body_preview` | At most 240 characters. Empty when the parent is deleted. |
| Deleted | `deleted` | True when the parent is soft-deleted. |

`ChatReactionGroupDTO`:

| Field | JSON | Notes |
| --- | --- | --- |
| Emoji | `emoji` | String. |
| Count | `count` | Number of users. |
| Reacted by me | `reacted_by_me` | True when the caller is in `user_ids`. |
| Users | `user_ids` | UUID array. |

`ChatAttachmentDTO` (active files only; empty after delete):

| Field | JSON | Notes |
| --- | --- | --- |
| File id | `file_id` | UUID. |
| Name | `original_filename` | String. |
| Type | `content_type` | MIME type. |
| Size | `size_bytes` | Integer. |
| Created | `created_at` | Timestamp. |

`ChatMessageDTO`:

| Field | JSON | Notes |
| --- | --- | --- |
| Id | `id` | Message UUID. Use this as `<message_uuid>`. |
| Conversation | `conversation_id` | UUID. |
| Author | `author` | `ChatAuthorDTO`, omitted when the user row is gone. |
| Kind | `kind` | `user` for messages posted by this API. |
| Body | `body` | Empty when the message is deleted. |
| Reply id | `reply_to_message_id` | UUID or null. |
| Reply preview | `reply_to` | `ChatReplyPreviewDTO`, omitted when absent. |
| Thread root | `thread_root_id` | Null for messages posted here. |
| Thread replies | `thread_reply_count` | Integer. |
| Mentions | `mentioned_user_ids` | UUID array, at most 50. |
| Everyone | `mention_everyone` | False for messages posted here. |
| Attachment flag | `has_attachments` | False when the message is deleted. |
| Files | `attachments` | `ChatAttachmentDTO` array. |
| Reactions | `reactions` | `ChatReactionGroupDTO` array. |
| Pin | `pinned_at`, `pinned_by` | Null when not pinned or when deleted. |
| Revision | `revision` | Integer, starts at 1. |
| Edited | `edited_at` | Null until the body is edited. |
| Deleted | `deleted_at` | Null until soft-deleted. |
| Times | `created_at`, `updated_at` | Timestamps. |

Example message after a text post (`COM-SUC-002`):

```json
{
  "id": "22222222-2222-2222-2222-222222222222",
  "conversation_id": "44444444-4444-4444-4444-444444444444",
  "author": {
    "user_id": "55555555-5555-5555-5555-555555555555",
    "username": "alex",
    "display_name": "Alex Example",
    "account_type": "standard"
  },
  "kind": "user",
  "body": "Looking at this now.",
  "reply_to_message_id": null,
  "thread_root_id": null,
  "thread_reply_count": 0,
  "mentioned_user_ids": [],
  "mention_everyone": false,
  "has_attachments": false,
  "attachments": [],
  "reactions": [],
  "pinned_at": null,
  "pinned_by": null,
  "revision": 1,
  "edited_at": null,
  "deleted_at": null,
  "created_at": "2026-11-16T12:00:00Z",
  "updated_at": "2026-11-16T12:00:00Z"
}
```

## `comm_message` file storage

Message files use the shared file API (`role-attachments`), not a field on the message body.

| Rule | Value |
| --- | --- |
| `entity_type` | `comm_message` |
| `entity_id` | The message UUID from `data.id`. |
| Parent | The message row must exist and `deleted_at` must be null. |
| Read | Same as reading the parent conversation. |
| Write | The caller is the message author, the message is not deleted, and the conversation still accepts posts. |
| Quota module | `Communications` (`Communications.Fs.Quotas`). |
| Per message | `entity.max.bytes` 52428800 (50 MiB total) and `entity.max.count` 10. |
| Per user per day | `user.per.day.max.bytes` 1073741824 (1 GiB). `0` would mean unlimited. |
| Module ceiling | `module.total.storage.max.bytes` 0 (unlimited). |
| One file | `Application.System.Fs.Policies` `max.size.bytes` (default 2147483648) and `mime.allow`. The per-message sum is the tighter cap. |
| Listed files | `status = active` only, oldest first. |
| Delete | Deleting the message deletes its files. |

Upload sequence:

1. `POST` the message with `hasAttachments: true`. Keep `data.id`.
2. `role-attachments/scripts/attachments-upload-flow.sh comm_message <message_uuid> <file_path>`.

A refused upload is `FILE-ERR-018` when the author or post check fails, `FILE-ERR-002` when the message is missing or deleted, and `FILE-ERR-005`, `FILE-ERR-006`, `FILE-ERR-009`, `FILE-ERR-010`, or `FILE-ERR-021` for MIME, size, and quota failures. Those codes are documented in `role-attachments`.

## Explicitly not called

This skill does not call:

- service-request, catalog, or other parent-module routes
- `/api/fs` (that is `role-attachments`)
- `/api/notifications/inbox` (mark-read updates those rows on the server; this skill does not list or patch them)
- call routes, member-admin routes, or non-entity conversation routes (none of those are in the eight routes above)

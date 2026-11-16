# API contract — bot authentication, notifications inbox, and directory search

<!--
version: 0.28.3
Short description: Bot API-key exchange, JWT contract, notifications inbox, subject mutes, and directory search for role-auth.
File: api-contract.md
Last release: 0.28.3

Changes in v0.28.3:
- Documented the outbound webhook wake-up ping, the notifications inbox and mute routes, and directory user and group search.
- Header last-release label is "Last release:".

Changes in v0.23.12:
- Documented that GET /api/auth/permissions is the RBAC key list. KB access is GET /api/kb/access and the write response.
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.
- Introduced version header; renamed API key format prefix from evik_ to bkey_
  in format docs and examples.
-->

Reference for the `role-auth` skill. All evi JSON APIs use the same response envelope. Inbox, mute, and directory-search calls go through `scripts/role-request.sh`, which attaches the Bearer JWT and retries once on `AUT-ERR-401`.

## Response envelope

Every handler returns:

```json
{
  "success": true,
  "code": "BOT_AUTH-SUC-001",
  "data": { }
}
```

On failure:

```json
{
  "success": false,
  "code": "BOT_AUTH-ERR-401"
}
```

Optional `meta` may appear on list endpoints. Clients should branch on `success` and `code`, not HTTP status alone (though codes align with status).

## API key format

Plaintext keys are issued once at creation or rotation:

```
bkey_<key_id>_<secret>
```

- `key_id` — UUID stored in `app.api_keys.id` (indexed lookup)
- `secret` — 64 hex characters (256 bits of entropy)
- Only the SHA-256 hash of the full key is stored server-side

Example shape (not a real key):

```
bkey_a1b2c3d4-e5f6-7890-abcd-ef1234567890_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

## POST /api/auth/bot/token

Public endpoint. No JWT required. Protected by strict rate limit and security hardening middleware.

### Request

```http
POST /api/auth/bot/token HTTP/1.1
Host: your-evi-host
Content-Type: application/json

{
  "api_key": "bkey_<key_id>_<secret>"
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `api_key` | string | yes | Full plaintext key; whitespace trimmed server-side |

### Success response

HTTP 200

```json
{
  "success": true,
  "code": "BOT_AUTH-SUC-001",
  "data": {
    "accessToken": "<JWT>",
    "accessTokenExpires": 1710000000,
    "tokenType": "Bearer"
  }
}
```

| Field | Type | Notes |
|-------|------|-------|
| `accessToken` | string | RS256 JWT |
| `accessTokenExpires` | number | Unix seconds; effective `exp` claim |
| `tokenType` | string | Always `Bearer` |

JWT claims include `uid` (bot user UUID), `tv` (token_version for invalidation), and `akid` (API key id used to authenticate).

There is **no** refresh token. When `accessTokenExpires` passes (or `tv` is bumped on revoke/disable), exchange the same `api_key` again.

### Error responses

| HTTP | Code | When |
|------|------|------|
| 400 | `BOT_AUTH-ERR-400` | Missing or empty `api_key`, malformed JSON |
| 401 | `BOT_AUTH-ERR-401` | Invalid key, revoked key, expired key, or inactive bot (uniform message) |

## Authenticated requests

Attach the access token to all protected routes:

```http
GET /api/auth/permissions HTTP/1.1
Host: your-evi-host
Authorization: Bearer <accessToken>
```

Common auth errors on protected routes:

| HTTP | Code | When |
|------|------|------|
| 401 | `AUT-ERR-401` | Missing/invalid/expired JWT, or `tv` mismatch after revoke/logout-all |

On `AUT-ERR-401`, re-run `POST /api/auth/bot/token` with the API key (do not call `/api/auth/refresh` — bots have no refresh cookie).

## Verification endpoints

### GET /api/admin/org/bot/self/keys

Requires active bot principal (`RequireActiveUser`). Returns metadata only.

```bash
curl -sS \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${BASE_URL}/api/admin/org/bot/self/keys"
```

### GET /api/auth/permissions

Returns the RBAC permission keys granted to the JWT subject (for example `settings:read:common`).

This list does not include per-tree ACL. Knowledge Base visibility is `GET /api/kb/access` (`canViewModule`). Author access on a tree is the write call: `KB-ERR-403` means this principal cannot write that tree.

```bash
curl -sS \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${BASE_URL}/api/auth/permissions"
```

## curl example (full auth flow)

```bash
export BASE_URL="http://localhost:7070"
export API_KEY="bkey_<key_id>_<secret>"

RESP=$(curl -sS -w "\n%{http_code}" -X POST \
  "${BASE_URL}/api/auth/bot/token" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg k "$API_KEY" '{api_key: $k}')")

BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n 1)

echo "HTTP $CODE"
echo "$BODY" | jq .

TOKEN=$(echo "$BODY" | jq -r '.data.accessToken')
curl -sS -H "Authorization: Bearer $TOKEN" \
  "${BASE_URL}/api/auth/permissions" | jq .
```

Prefer the bundled `scripts/role-auth.sh` and `scripts/role-request.sh` — they handle validation, caching, and re-auth.

## Outbound webhook wake-up

The worker job `send_bot_webhook` posts a Strict Inbox Ping to the bot webhook channel. The body is a pointer. Fetch the inbox row before acting on it.

```json
{
  "notification_id": "<uuid>",
  "bot_user_id": "<uuid>",
  "occurred_at": "2026-11-16T12:00:00Z"
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `notification_id` | UUID string | Inbox row to load with `notifications-inbox-get.sh` |
| `bot_user_id` | UUID string | Bot principal the row belongs to |
| `occurred_at` | string | RFC3339 timestamp. The worker fills it when the job omitted it |

A diagnostic job (`send_test_bot_webhook`) posts a different body. It is not an inbox row and has no `notification_id`:

```json
{
  "test": true,
  "bot_user_id": "<uuid>",
  "occurred_at": "2026-11-16T12:00:00Z"
}
```

When `test` is true, do not call the inbox scripts.

Every delivery is `POST` with `Content-Type: application/json`, `User-Agent: Webhook-Transport/1.0`, and `X-Notification-Idempotency-Key`. Redirects are not followed. A repeated idempotency key that the worker already marked sent is not delivered again. The receiver should still treat a repeated key as already accepted.

The remaining headers depend on the channel preset:

| Preset | Headers |
| --- | --- |
| `grok` | `Authorization: Bearer <key>`. The channel must have a bearer key. This preset does not send an HMAC signature. |
| `hermes` | `X-Request-ID` (same value as the idempotency key). When a secret is set: `X-Webhook-Timestamp` (Unix seconds) and `X-Webhook-Signature-V2` (lowercase hex HMAC-SHA256 of `<timestamp>.<raw body>`, no `sha256=` prefix). |
| `custom` | `X-Notification-Timestamp` (Unix seconds). When a secret is set: `X-Webhook-Signature-256` (`sha256=` plus lowercase hex HMAC-SHA256 of `<timestamp>.<raw body>`). |

The signed message is the decimal timestamp, a dot, and the exact raw body. The MAC key is the raw secret bytes.

## Field naming for inbox and mutes

Request bodies and inbox query keys are camelCase: `subjectType`, `subjectId`, `subjectNumber`, `subjectTitle`, `page`, `itemsPerPage`, `unreadOnly`.

Response fields are snake_case: `subject_type`, `subject_id`, `unread_count`, `read_at`. Do not copy response keys back into request bodies.

The list payload's `data.pagination` object is the exception. Its keys are camelCase: `totalItems`, `totalPages`, `currentPage`, `itemsPerPage`.

Directory search query keys are snake_case: `query`, `limit`, `include_bots`, `exclude_system`.

## Notifications inbox

Every inbox route requires an active principal (standard account or bot) and `Authorization: Bearer <JWT>`. A missing or rejected token is `AUT-ERR-401`. The wrapper re-authenticates once. `SYS-ERR-500` is a server failure; report it and do not invent a second retry loop.

`notifications-inbox-list.sh` calls:

```http
GET /api/notifications/inbox?page=1&itemsPerPage=25&unreadOnly=true
```

| Query | Script flag | Rule |
| --- | --- | --- |
| `page` | `--page N` | Integer >= 1. Omitted uses server default 1. |
| `itemsPerPage` | `--items-per-page N` | Integer 1..100. Omitted uses server default 25. |
| `unreadOnly` | `--unread-only` | Sent as `true`. Omitted returns read and unread rows. |

Success `NTF-SUC-009`:

```json
{
  "success": true,
  "code": "NTF-SUC-009",
  "data": {
    "items": [],
    "unread_count": 0,
    "pagination": {
      "totalItems": 0,
      "totalPages": 0,
      "currentPage": 1,
      "itemsPerPage": 25
    }
  }
}
```

`unread_count` is the principal's unread total, not the size of this page. `pagination.totalItems` counts the filtered list. Rows are newest first.

Each item in `data.items[]`:

| Field | Notes |
| --- | --- |
| `id` | Notification UUID |
| `user_id` | Owner. Always the caller |
| `actor_user_id` | UUID or null |
| `category` | Inbox category string |
| `module` | `work`, `comm`, `kb`, or another module key |
| `event_type` | Domain event that produced the row, such as `work.service_request.created` |
| `subject_type` | `service_request`, `manual_task`, `approval`, `acceptance`, `kb_article`, `conversation`, or a communications entity type |
| `subject_id` | UUID of that subject |
| `subject_number` | Display number, or null |
| `title` | Short title |
| `meta` | Object. May include `status`, `priority`, `parent_kind`, `parent_id`, `conversation_id`, `channel_key` |
| `event_count` | Integer |
| `read_at` | Timestamp or null when unread |
| `created_at`, `updated_at` | Timestamps |

A query the server cannot bind is `VAL-ERR-001`.

### `GET /api/notifications/inbox/:id`

Script: `notifications-inbox-get.sh <notification_uuid>`.

Success `NTF-SUC-010`. The row is `data.notification` (same fields as a list item).

A malformed id is `VAL-ERR-001`. An id that is missing or owned by someone else is HTTP 404 `NTF-ERR-006`. Stop. Do not guess another id.

### `POST /api/notifications/inbox/:id/read`

Script: `notifications-inbox-read.sh <notification_uuid>`.

Success `NTF-SUC-011`:

```json
{
  "success": true,
  "code": "NTF-SUC-011",
  "data": {
    "notification": {},
    "unread_count": 0
  }
}
```

An already-read row stays read (`read_at` is left as it was) and still returns `NTF-SUC-011`. Missing row: HTTP 404 `NTF-ERR-006`. Malformed id: `VAL-ERR-001`.

### `POST /api/notifications/inbox/:id/unread`

Script: `notifications-inbox-unread.sh <notification_uuid>`.

Success `NTF-SUC-013` with `data.notification` (`read_at` null) and `data.unread_count`. Missing row: HTTP 404 `NTF-ERR-006`. Malformed id: `VAL-ERR-001`.

### `POST /api/notifications/inbox/read-all`

Script: `notifications-inbox-read-all.sh`. No body.

Success `NTF-SUC-012`:

```json
{
  "success": true,
  "code": "NTF-SUC-012",
  "data": {
    "updated_count": 0,
    "unread_count": 0
  }
}
```

`updated_count` is how many unread rows were marked. `unread_count` is 0.

### `POST /api/notifications/inbox/read-by-subject`

Script: `notifications-inbox-read-by-subject.sh <subject_type> <subject_uuid>`.

```json
{"subjectType": "service_request", "subjectId": "<uuid>"}
```

The script sends `Content-Type: application/json`. `subjectType` must be 1..64 characters. `subjectId` must be a UUID.

Success `NTF-SUC-014` with `data.updated_count` and `data.unread_count`. Zero matching unread rows is still success (`updated_count` 0). An empty `subjectType` or a bad `subjectId` is `VAL-ERR-001`.

### `DELETE /api/notifications/inbox/:id`

Script: `notifications-inbox-delete.sh <notification_uuid>`.

Success `NTF-SUC-015`:

```json
{
  "success": true,
  "code": "NTF-SUC-015",
  "data": {
    "deleted": true,
    "unread_count": 0
  }
}
```

Missing row: HTTP 404 `NTF-ERR-006`. Malformed id: `VAL-ERR-001`.

## Subject mutes

### `GET /api/notifications/mutes`

Script: `notifications-mutes-list.sh`.

Success `NTF-SUC-016`. `data.items[]` rows:

| Field | Notes |
| --- | --- |
| `id` | Mute row UUID |
| `user_id` | Caller |
| `subject_type` | String |
| `subject_id` | UUID |
| `subject_number` | String or null |
| `subject_title` | String |
| `created_at` | Timestamp |

The server returns at most 200 rows, newest first.

### `POST /api/notifications/mutes`

Script: `notifications-mutes-add.sh <payload.json>` with `Content-Type: application/json`.

```json
{
  "subjectType": "service_request",
  "subjectId": "<uuid>",
  "subjectNumber": "SR-1001",
  "subjectTitle": "VPN access"
}
```

`subjectType` (1..64 characters) and `subjectId` (UUID) are required. `subjectNumber` and `subjectTitle` are optional. The script rejects a payload that is not that object.

Success `NTF-SUC-017`:

```json
{
  "success": true,
  "code": "NTF-SUC-017",
  "data": {
    "mute": {},
    "unread_count": 0
  }
}
```

Muting the same subject again updates the stored number and title. An empty `subjectTitle` keeps the previous title. A missing `subjectNumber` keeps the previous number. The same call deletes unread inbox rows for that subject. Rows that were already read stay. A bad body is `VAL-ERR-001`.

### `DELETE /api/notifications/mutes/:subjectType/:subjectId`

Script: `notifications-mutes-remove.sh <subject_type> <subject_uuid>`.

`subject_type` is one path segment: 1..64 characters, letters, digits, `.`, `_`, `~`, or `-`, and no slash. `subject_uuid` is a UUID.

Success `NTF-SUC-018`:

```json
{
  "success": true,
  "code": "NTF-SUC-018",
  "data": {
    "unmuted": true
  }
}
```

Success is returned even when that subject was not muted. Removing a mute does not restore inbox rows the mute call deleted. A bad path value is `VAL-ERR-001`.

## Directory search

Both routes require an active principal. `%`, `_`, and `\` in `query` are matched literally. Omitted `limit` uses 20.

The scripts refuse a query shorter than 2 characters and a `limit` outside 1..100. On the server, a bind failure and a trimmed query shorter than 2 characters are HTTP 400 `VAL-ERR-400`.

### `GET /api/core/item-selector/search-users`

Script: `core-search-users.sh <query> [--limit N] [--include-bots] [--exclude-system]`.

| Query | Rule |
| --- | --- |
| `query` | Required. At least 2 characters. Substring match on username, user id, email, and display name. |
| `limit` | Optional integer 1..100. Default 20. |
| `include_bots` | `true` when `--include-bots` is set. Default omits bots. |
| `exclude_system` | `true` when `--exclude-system` is set. Default includes system accounts. |

With neither flag the result is standard and system accounts. `--include-bots` adds bots. `--exclude-system` drops system accounts. Both flags together return standard accounts and bots.

Success `ISL-SUC-001`:

```json
{
  "success": true,
  "code": "ISL-SUC-001",
  "data": {
    "items": [
      {"uuid": "<uuid>", "name": "Ada Lovelace", "username": "ada", "status": "active"}
    ],
    "total": 1
  }
}
```

`name` is the profile display name, with username as the fallback. `status` is `account_status`. `total` is the number of items returned, not a directory-wide count.

These scripts do not send `organization_id` or `in_system_organization`.

### `GET /api/core/item-selector/search-groups`

Script: `core-search-groups.sh <query> [--limit N] [--exclude-system]`.

| Query | Rule |
| --- | --- |
| `query` | Required. At least 2 characters. Substring match on the group name. |
| `limit` | Optional integer 1..100. Default 20. |
| `exclude_system` | `true` when `--exclude-system` is set. Default includes system groups. |

Only active groups are returned. Success `ISL-SUC-001` with the same envelope. Group items set `username` equal to `name` and omit `status`. A system group still cannot be stored as `assigned_group_id` on a work update.

## Not wrapped

This skill does not call:

- `POST /api/notifications/email/send-test`
- `GET /api/notifications/email/test-status`
- `GET /api/notifications/stream` (server-sent inbox events)
- `GET /api/core/item-selector/search-organizations`
- `GET /api/core/item-selector/search-participants`

## Inbox and search errors

| Code | When | What to do |
| --- | --- | --- |
| `AUT-ERR-401` | Missing, expired, or revoked JWT | The wrapper re-authenticates once. If it persists, check `API_KEY` and `BASE_URL`. |
| `NTF-ERR-006` | Inbox id is missing or belongs to another principal (HTTP 404) | Stop. Do not retry the same id. |
| `NTF-SUC-009` .. `NTF-SUC-018` | Inbox and mute success codes listed above | Read `data` for the payload. |
| `VAL-ERR-001` | Inbox or mute id, query, or JSON body failed validation | Fix the argument. Do not retry it unchanged. |
| `VAL-ERR-400` | Directory search bind failure, or trimmed `query` shorter than 2 characters (HTTP 400) | Lengthen the query. The scripts already reject that case locally. |
| `ISL-SUC-001` | Directory search success | Read `data.items` and `data.total`. |
| `SYS-ERR-500` | Server failure | Report it. Do not add another retry loop. |

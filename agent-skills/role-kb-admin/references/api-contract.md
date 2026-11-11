# evi API contract - KB admin

<!--
version: 0.24.4
Short description: KB admin endpoint contract for tree governance, ACL, settings, and .kbz export/import.
File: api-contract.md
Last evi release: 0.24.4

Changes in v0.24.4:
- Tree import has no package size cap. Begin success data is session_id and expires_in_seconds (no max_bytes).
- Chunk max stays 1.5 MiB. Clients send 1.4 MiB at 90 chunks per minute so they stay under the standard 120 requests/minute limiter. HTTP 429 is retried after Retry-After.
- Browser download uses POST /api/kb/trees/:id/export/ticket (KB-SUC-031) then GET ?ticket= with no Bearer. Bot export stays Bearer GET.

Changes in v0.23.12:
- ACL update uses audience instead of is_public. Fetch returns data.audience.
- Documented KB module settings read (quotas only on GET /api/core/settings) and POST /api/admin/settings/update.

Changes in v1.3.1:
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.

Changes in v1.3.0:
- Documented raw-zip tree export and the chunked import session
  (begin/chunk/inspect/commit/cancel), including format_version 1 package
  layout (snake_case zip payload) and import warning/error codes.
- `--inspect-only` helper output adds `data.session_id` (raw inspect route
  does not return it).
- Updated Last evi release marker to 0.23.11.

Changes in v1.2.1:
- Documented related-link cleanup on article delete (via author) and tree delete.
- Updated Last evi release marker to 0.21.2.

Changes in v1.2.0:
- Documented system KB tree delete protection: built-in users/admins trees
  always return 403 `KB-ERR-403` on delete.
- Updated Last evi release marker to 0.21.1.

Changes in v1.1.0:
- Removed PUT /api/kb/trees/reorder (personal shelf — documented in role-kb-reader contract).
- Added short_description to tree translation payloads; noted create auto-adds to creator shelf.

Changes in v1.0.0:
- Initial KB admin API contract reference.
- Added tree write route payloads and ACL fetch/update contracts.
- Declared non-overlap with reader and author skills.
-->

Reference for `role-kb-admin`.

All routes require:

```http
Authorization: Bearer <JWT>
```

## Response envelope

Most routes use the standard envelope.

Success:

```json
{
  "success": true,
  "code": "KB-SUC-002",
  "data": {}
}
```

Failure:

```json
{
  "success": false,
  "code": "KB-ERR-403"
}
```

**Exception — tree export.** `GET /api/kb/trees/:id/export` is **not** an envelope on success. A successful export is a raw zip (`Content-Type: application/zip`, `Content-Disposition: attachment`). Failures that occur before the first zip byte use the JSON envelope above. `role-request.sh` with `-o` writes the body to a file and prints little or nothing on stdout; detect success by HTTP 2xx plus zip magic `PK`, and treat a leading `{` as a JSON error envelope.

## Field naming

**API request bodies stay camelCase** (same as the rest of evi), with the existing snake_case exceptions documented in `role-kb-author` (`attachment_file_ids`, `swa_steps`) — those fields are not used on admin routes.

**API responses use snake_case.**

**`.kbz` package files (`manifest.json`, `tree.json`) use snake_case.** That is the zip payload, not an API body. Do not camelCase package fields, and do not send package JSON as an HTTP body.

## Tree governance endpoints

### `POST /api/kb/trees`

Creates a new KB tree. The backend automatically adds the new tree to the creator's personal shelf.

Example payload:

```json
{
  "translations": {
    "english": {
      "name": "Operations KB",
      "description": "Runbooks and SOPs",
      "short_description": "Ops runbooks"
    }
  },
  "iconName": "books"
}
```

### `PUT /api/kb/trees/:id`

Example payload:

```json
{
  "translations": {
    "english": {
      "name": "Operations KB",
      "description": "Updated description",
      "short_description": "Card summary for KB Library"
    }
  },
  "status": "active",
  "iconName": "book-open"
}
```

Tree translation fields:

- `name` (required per language when translations are sent)
- `description` (optional)
- `short_description` (optional, max 255 chars — shown on KB Library cards)

### `DELETE /api/kb/trees/:id`

No request body.

System protection: the built-in system trees cannot be deleted even by owners
or callers with `kb:trees:delete:all`.

- HELP KB tree: `e1b10000-0000-4000-8000-000000000001`
- Failure: HTTP 403 with code `KB-ERR-403`

Side effect: deletes related-article links (`link_type = related`) involving
articles in the deleted tree.

### `POST /api/kb/trees/:id/change-owner`

Example payload:

```json
{
  "newOwnerId": "new-owner-user-uuid"
}
```

## Tree export

Builds a content-only `.kbz` zip in-process and streams it as a raw attachment. There is no package size cap.

Access: `kb:trees:update:all` **or** tree owner. System trees are not exportable. HELP KB `e1b10000-0000-4000-8000-000000000001` returns 403 `KB-ERR-403` (the tree exists but export is denied; a missing tree is `KB-ERR-001`).

### `POST /api/kb/trees/:id/export/ticket`

Browser download ticket. Bearer required. No request body. Success `KB-SUC-031`:

```json
{
  "success": true,
  "code": "KB-SUC-031",
  "data": {
    "ticket": "uuid",
    "expires_in_seconds": 120
  }
}
```

The ticket is single-use, lasts 120 seconds, and is bound to that tree and the caller. It is deleted when the download below starts. It identifies the caller; export access is checked again. A missing, expired, or mismatched ticket is 403 `KB-ERR-403`. Bot scripts do not call this route.

### `GET /api/kb/trees/:id/export`

Success: raw zip, not `{success,code,data}`.

**Bot / script:** `Authorization: Bearer <JWT>` and no `ticket` query. `kb-trees-export.sh` does this and passes curl `-o` so the zip streams to disk. There is no client time limit. Default output name is `kb-tree.kbz` because `role-request.sh` does not return `Content-Disposition`. On success the script prints `{"path":"...","bytes":N}` to stdout.

**Browser:** `GET /api/kb/trees/:id/export?ticket=<ticket>` with no Bearer. Same raw zip on success.

## Tree import session

Import always creates a **new** private tree owned by the caller, adds it to the importer's shelf, and copies **no ACL**. Configure visibility with the ACL routes below. Related-article rows are not imported; the table stays empty until an author reconcile.

All import routes require `kb:trees:update:all`. Sessions live in Valkey + a temp file. TTL is **1800 seconds (30 minutes)**. Chunks must be sequential: `offset` must equal the session `total_so_far`.

Limits:

- No package size cap
- Chunk max: **1.5 MiB** (1536 KiB). Scripts and the FE client send **1.4 MiB** (`1468006` bytes) at **90 chunks per minute** (60000/90 ms between chunk starts) so they stay under the standard limiter of **120 requests per minute per IP**. The chunk route uses that standard limiter.
- HTTP 429 (`RTE-ERR-429`) is not success. The response has header `Retry-After` and body `meta.retryAfter` (seconds, camelCase — the rate-limiter meta key is not snake_case). `kb-trees-import.sh` waits that many seconds and retries the same chunk up to 3 times, then fails. `role-request.sh` prints `role-request: HTTP <code>` on stderr and the body on stdout; it does not print response headers, so the helper reads the wait from `meta.retryAfter`.
- Session TTL: **1800s**

### `POST /api/kb/trees/import/begin`

Body: `{}`. Success `KB-SUC-026`:

```json
{
  "success": true,
  "code": "KB-SUC-026",
  "data": {
    "session_id": "uuid",
    "expires_in_seconds": 1800
  }
}
```

### `PUT /api/kb/trees/import/:sessionId/chunk?offset=`

Raw body (`Content-Type: application/octet-stream`). Must send that Content-Type so `role-request.sh` does **not** auto-add `application/json`. Success `KB-SUC-027`:

```json
{
  "success": true,
  "code": "KB-SUC-027",
  "data": {
    "received": 1468006,
    "total_so_far": 1468006
  }
}
```

`offset` must equal current `total_so_far` (start at `0`). Mismatched offset or an oversized chunk (over 1.5 MiB) returns `VAL-ERR-001`. Unknown/expired/foreign session: `KB-ERR-005`.

### `POST /api/kb/trees/import/:sessionId/inspect`

Body: `{}`. Parses the uploaded zip without writing a tree. Success `KB-SUC-028`:

```json
{
  "success": true,
  "code": "KB-SUC-028",
  "data": {
    "format_version": 1,
    "evi_version": "0.23.11",
    "tree_name": "Operations KB",
    "article_count": 12,
    "file_count": 3,
    "byte_size": 4096,
    "warnings": []
  }
}
```

Always inspect before commit. `kb-trees-import.sh` always inspects; `--inspect-only` stops here, leaves the session open, and adds `data.session_id` to the printed inspect envelope (the raw inspect route does not return it).

### `POST /api/kb/trees/import/:sessionId/commit`

Body: `{}`. Success `KB-SUC-029`:

```json
{
  "success": true,
  "code": "KB-SUC-029",
  "data": {
    "tree_id": "new-tree-uuid",
    "warnings": []
  }
}
```

If rewrite/reconcile fails after the tree was created, the backend deletes the tree best-effort and returns `KB-ERR-006`.

### `DELETE /api/kb/trees/import/:sessionId`

Cancels the session and removes the temp upload. Success `KB-SUC-030`. The import helper best-effort cancels (ignores cancel failure) after any failure that occurred after begin.

## `.kbz` package (`format_version` 1)

Zip entries:

- `manifest.json`
- `tree.json`
- `files/{file_id}` — raw file bytes keyed by the **source** file id

This build reads and writes `format_version` **1** only. A higher version is `KB-ERR-004`.

`manifest.json` (snake_case):

```json
{
  "format_version": 1,
  "evi_version": "0.23.11",
  "exported_at": "2026-09-17T20:00:00Z",
  "source_tree_id": "source-tree-uuid",
  "languages": ["english"],
  "article_types": ["wiki"],
  "article_count": 12,
  "file_count": 3,
  "byte_size": 4096
}
```

`tree.json` (snake_case) contains `tree` (icon + translations), `folders`, `articles`, and `files` metadata. Article rows include `article_type_code`, `type_schema_version`, `status`, `tags`, translations (`title` + TipTap `content`), optional `swa_steps`, and `placements`. File rows include `file_id`, `article_id`, `original_filename`, `content_type`, `size_bytes`, `sha256_hex`.

Unknown `article_type_code` on inspect/commit: `KB-ERR-007`. Invalid zip / missing `format_version` / malformed `tree.json` / no remaining tree translations: `KB-ERR-003`.

## Import warnings (non-fatal)

Warnings appear on inspect and commit. They do **not** fail the request.

- `KB-WARN-LANG` — translation skipped; language is not in KnowledgeBase allowed languages. `meta.language_code`. Handling: tree/article still imports in allowed languages.
- `KB-WARN-FILE` — file skipped (missing zip entry, MIME/quota/policy, ingest failure, unknown article). `meta.file_id`, `meta.reason`. Handling: article imports without that file; `fileImage` refs to it are cleared.
- `KB-WARN-LINK` — `entityLink` to a `kb_article` id that is not in this package (left as-is). `meta.entity_id`, `meta.entity_type`. Handling: chip stays pointing at the old id until an author remaps or reconciles.

## ACL management endpoints (KB trees)

### `GET /api/core/visibility/fetch`

Query params:

- `entity_id=<tree_uuid>`
- `entity_type=kb_tree`
- `action=read|update`

### `POST /api/core/visibility/update`

Example payload. `audience` is required. `is_public` is ignored by the API, so a success code does not mean the tree became public. Confirm with `GET /api/core/visibility/fetch` and `data.audience`.

Values: `custom` (allow lists only), `staff` (callers marked staff), `registered` (any authenticated active account), `public` (no login required).

```json
{
  "entity_id": "tree-uuid",
  "entity_type": "kb_tree",
  "action": "read",
  "audience": "custom",
  "allowed_groups": ["role.users.registered"],
  "allowed_users": ["alice"],
  "denied_groups": [],
  "denied_users": []
}
```

Invalid `audience` → `VIS-ERR-400-AUDIENCE`.

## KB module settings

### `GET /api/core/settings`

Success `STG-SUC-002`. File quotas are at `data.settings["KnowledgeBase.Fs.Quotas"]`:

- `entity.max.bytes` — sum of file bytes on one article; `0` means unlimited
- `entity.max.count` — file count cap per article (integer 1–500)
- `user.per.day.max.bytes` — per-user daily upload cap; `0` means unlimited
- `module.total.storage.max.bytes` — module-wide ceiling; `0` means unlimited

This response does not include public `KnowledgeBase` settings: `allow.all.registered.to.view.module`, `allow.all.registered.to.create.trees`, `allowed.languages`.

### `POST /api/admin/settings/update`

Body is camelCase. Requires `kb:settings:update:all`. Success `ADM_STG-SUC-001`; the stored value is `data.value`.

```json
{
  "sectionPath": "KnowledgeBase",
  "settingName": "allow.all.registered.to.create.trees",
  "value": false
}
```

`sectionPath` for this skill is `KnowledgeBase` or `KnowledgeBase.Fs.Quotas`. A `null` value fails schema validation with `ADM_STG-ERR-001`. Do not take the two public flags from `GET /api/core/settings` and write that result back.

`kb-settings-update.sh` rejects `null` and any other section path.

## Common error codes

- `AUT-ERR-401`: JWT missing/invalid/expired — re-auth (`role-request.sh` already retries once after re-auth)
- `KB-ERR-001`: tree/item not found
- `KB-ERR-003`: invalid import package (not a zip/.kbz, missing or invalid `format_version`, malformed `tree.json`)
- `KB-ERR-004`: package `format_version` is newer than this evi build
- `KB-ERR-005`: import session not found, expired, or not owned by the caller
- `KB-ERR-006`: import commit failed after it started (structural write rolled back, or half-created tree deleted best-effort)
- `KB-ERR-007`: package contains an unknown `article_type_code`
- `KB-ERR-403`: tree admin access denied (including system-tree export/delete)
- `AZN-ERR-403`: ACL management denied
- `VIS-ERR-400-AUDIENCE`: audience is missing or not one of custom, staff, registered, public
- `VIS-ERR-400-ENTITY-TYPE`: invalid entity type for visibility route
- `ADM_STG-ERR-001`: settings value failed JSON Schema validation (including `null`)
- `ADM_STG-ERR-002`: settings row not found
- `VAL-ERR-001` / `REQ-ERR-001`: validation/request shape errors (including bad chunk offset/size)
- `RTE-ERR-429`: too many requests. `meta.retryAfter` is the `Retry-After` hint in seconds. The import helper waits and retries that chunk; do not treat 429 as success
- `SYS-ERR-500`: internal error

## Non-overlap rules

`role-kb-admin` intentionally omits:

- reader routes (`role-kb-reader`), including KB Library and personal shelf reorder
- author routes (`role-kb-author`)
- history routes (`GET /api/kb/history`)
- favorites routes (`/api/kb/favorites`, article favorite add/remove)

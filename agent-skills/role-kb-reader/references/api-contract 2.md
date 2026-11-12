# evi API contract - KB reader

<!--
version: 0.27.3
Short description: Read-only Knowledge Base endpoint contract for role-kb-reader.
File: api-contract.md
Last evi release: 0.27.3

Changes in v0.27.3:
- Documented the shared object-container attributes (`layout`, `align`, `width`) on `mermaidDiagram` and `fileImage` in `GET /api/kb/articles/:id`.
- Documented collapsible `details` sections and the `textColor` mark in article rich text.

Changes in v0.23.12:
- Documented empty-shelf reseed of the system HELP KB tree after a successful shelf remove.
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.

Changes in v1.4.0:
- Documented GET /api/kb/history, POST|DELETE /api/kb/articles/:id/favorite,
  GET /api/kb/trees?scope=shelf|accessible, library canExport, tree
  capabilities, and content_version on tree/node/article.
- Updated Last evi release marker to 0.23.11.

Changes in v1.3.0:
- Added "Reading rich article content" section: entityLink, externalLink,
  mermaidDiagram; related vs inline chip semantics.
- Updated Last evi release marker to 0.21.2.

Changes in v1.2.0:
- Added GET /api/kb/articles/:id/related for read-only related-article lookup.
- Updated Last evi release marker to 0.21.1.

Changes in v1.1.0:
- Added GET /api/kb/library and POST/DELETE shelf routes (KB Library, evi 0.20.17).
- Documented GET /api/kb/trees as personal shelf projection only.
- Added PUT /api/kb/trees/reorder (personal shelf order, moved from admin contract).

Changes in v1.0.0:
- Initial KB reader API contract reference.
- Added endpoint list, query params, and auth/error notes.
-->

Reference for the `role-kb-reader` skill.

All routes below are protected and require:

```http
Authorization: Bearer <JWT>
```

JWT is acquired via `POST /api/auth/bot/token` (see `role-auth` skill).

## Response envelope

Success:

```json
{
  "success": true,
  "code": "KB-SUC-001",
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

## Reader endpoints

### `GET /api/kb/access`

- Purpose: effective module entry/access summary
- Success code: `KB-SUC-014`

### `GET /api/kb/library`

- Purpose: list all KB trees the caller can read (global KB Library catalog)
- Success code: `KB-SUC-023`
- Response: array of library items; each item includes tree metadata, owner fields,
  `translations` (with optional `short_description` per language),
  `on_shelf` (boolean — whether the tree is on the caller's personal shelf), and
  `canExport` (true when the caller is the owner or has `kb:trees:update:all`;
  always false for system trees)
- Example item shape:

```json
{
  "id": "tree-uuid",
  "status": "active",
  "ownerUserId": "user-uuid",
  "ownerUsername": "alice",
  "ownerAccountType": "standard",
  "createdAt": "2026-01-01T00:00:00Z",
  "icon_name": "books",
  "order": 0,
  "translations": {
    "english": {
      "name": "Operations KB",
      "description": "Long description",
      "short_description": "Card summary for KB Library"
    }
  },
  "on_shelf": false,
  "canExport": false
}
```

### `POST /api/kb/library/:treeId/shelf`

- Purpose: add a readable tree to the caller's personal shelf (appended at tail)
- Success code: `KB-SUC-024`
- Access: caller must have read access on the tree; otherwise `KB-ERR-001`
- Idempotent: duplicate add is a no-op (`ON CONFLICT DO NOTHING`)

### `DELETE /api/kb/library/:treeId/shelf`

- Purpose: remove a tree from the caller's personal shelf and compact shelf order
- Success code: `KB-SUC-025`
- Does not delete the KB tree itself
- If the shelf is empty afterwards, the next `GET /api/kb/library` or `GET /api/kb/trees` (shelf scope) puts the system HELP KB tree (`e1b10000-0000-4000-8000-000000000001`) back on the shelf when the caller can read it. A successful remove followed by that tree in the next shelf list is this reseed.

### `GET /api/kb/trees`

- Purpose: load full tree payloads (flat nodes + translations)
- Query: `scope=shelf|accessible` (default `shelf` when omitted)
  - `shelf`: trees on the caller's **personal shelf** only
  - `accessible`: all ACL-readable trees (global order, no shelf filter)
- Success code: `KB-SUC-001`
- Each tree includes `content_version` and backend-authoritative `capabilities`:
  `canUpdate`, `canDelete`, `canManageAccess`, `canChangeOwner`,
  `canViewNonPublished`, `canExport`
- Each node includes `content_version` (folder row or placed article)
- Access behavior: backend filters non-published article nodes for reader-only users
- Empty shelf: backend seeds the system HELP KB tree when the caller can read it (same reseed as after `DELETE .../shelf`)
- Invalid `scope` → `VAL-ERR-001`

### `PUT /api/kb/trees/reorder`

- Purpose: reorder the caller's **personal shelf** (`app.kb_user_tree_shelf`), not global `kb_trees.order`
- Success code: `KB-SUC-012`
- Payload (camelCase):

```json
{
  "treeIds": ["tree-uuid-1", "tree-uuid-2", "tree-uuid-3"]
}
```

- Validation: every id in `treeIds` must already be on the caller's shelf; count must match exactly — otherwise `KB-ERR-001`
- No tree-admin ACL required

### `GET /api/kb/article-types`

- Purpose: list active KB article type registry
- Success code: `KB-SUC-011`

### `GET /api/kb/articles`

- Purpose: list published articles for picker/search use
- Success code: `KB-SUC-019`
- Query params:
  - `q` (optional): title search
  - `tree_id` (optional): limit to one tree

### `GET /api/kb/articles/:id`

- Purpose: fetch one article body + metadata
- Success code: `KB-SUC-009`
- Response includes `content_version` (integer; bumps when the article content hash changes)
- Access behavior:
  - If the article/tree is not visible to caller, backend returns not found (`KB-ERR-001`) to avoid resource existence leaks.
- Rich content: `data.translations.<lang>.content.body` is ProseMirror JSON
  (wiki doc) or a type-specific wrapper (FAQ items, SWA steps, reference
  table columns/rows). Rich-text slots may contain:
  - `entityLink` — inline atom; KB articles use `attrs.entityType`:
    `"kb_article"` and `attrs.entityId` (target article uuid). `attrs.label`
    and `attrs.meta` are cached display snapshots.
  - `externalLink` — block atom with `attrs.url`, `attrs.linkOnly`, optional
    `attrs.preview` (`title`, `description`, `iconUrl`).
  - `mermaidDiagram` — block atom with `attrs.source` (Mermaid syntax;
    rendered SVG is not stored). Object-container attrs: `layout`
    (`"inline"` | `"block"`, default `"inline"`), `align`
    (`"left"` | `"center"` | `"right"`, default `"left"`), and `width`
    (px integer `>= 60` or `null`).
  - `fileImage` — block atom with `attrs.fileId` (see `role-attachments`)
    and the same object-container attrs `layout`, `align`, and `width`.
  - `details` — collapsible section. `content` is `detailsSummary` (the
    title, inline text) then `detailsContent` (the body blocks). `attrs.open`
    `false` means the UI shows only the title; the body is still in the JSON.
    `attrs.lineColor`, when set, is `success`, `warning`, `error`,
    `favorite`, `muted`, `blue`, `lightBlue`, `purple`, or `lightGrey`.
    Absent `lineColor` is the accent line. Sections are not nested.
  - Standard nodes: paragraph, heading, lists, tables, codeBlock, etc.
  - Marks: bold, italic, strike, code, `link` (inline hyperlink — distinct
    from `externalLink` block), `textColor` (`attrs.name`: `accent`,
    `success`, `warning`, `error`, `favorite`, `muted`, `blue`, `lightBlue`,
    `purple`, `lightGrey`).

### `GET /api/kb/articles/:id/related`

- Purpose: list articles linked as related from the source article (backing
  relation in `app.kb_article_links`, `link_type = related`)
- Success code: `KB-SUC-019`
- Since evi 0.21.2, related articles also appear as inline `entityLink` chips
  in the article body. This endpoint returns structured metadata for
  navigation; inline chips show in-context references inside
  `GET /api/kb/articles/:id` content. The two should match when content was
  saved through the evi UI or reconciled by an agent after API content PUT
  (see `role-kb-author` → `kb-articles-related-reconcile.sh`).
- Access behavior:
  - Caller must be able to read the source article; otherwise backend returns
    not found (`KB-ERR-001`).
  - Related target articles that the caller cannot read are omitted from the
    list.
- `data` shape:

```json
{
  "related_articles": [
    {
      "article_id": "uuid",
      "short_id": "abc12",
      "title": "Related article",
      "tree_id": "uuid",
      "tree_name": "Tree name",
      "status": "published",
      "article_type_code": "wiki"
    }
  ]
}
```

### `GET /api/kb/search`

- Purpose: access-aware KB search over trees/nodes/article content
- Success code: `KB-SUC-015`
- Query params:
  - `q` (required): search string (2..100 runes on backend validation)

### `GET /api/kb/favorites`

- Purpose: list caller's favorite articles filtered by current read permissions
- Success code: `KB-SUC-020`

### `POST /api/kb/articles/:id/favorite`

- Purpose: add an article to the caller's personal favorites (requires tree read access)
- Body: none (wrapper may send `Content-Type: application/json` with an empty POST)
- Success code: `KB-SUC-021`
- Idempotent: duplicate add is a no-op (`ON CONFLICT DO NOTHING`)
- No read access / unknown article: `KB-ERR-001` (existence hidden)

### `DELETE /api/kb/articles/:id/favorite`

- Purpose: remove an article from the caller's personal favorites
- Success code: `KB-SUC-022`
- Does not delete the article; missing favorite is a no-op

### `GET /api/kb/history`

- Purpose: paginated change-history feed (newest first) for one tree, folder subtree, or article
- Success code: `KB-SUC-019`
- Query params (exactly one scope):
  - `tree_id` — whole-tree scope
  - `folder_id` + `tree_id` — folder subtree (`folder_path_ids` containment)
  - `article_id` — article scope (tree is resolved server-side)
  - `limit` (optional): default 30, max 100
  - `before_at` + `before_id` (optional, together): keyset cursor from `next_cursor`
- Missing / empty scope tree id → `VAL-ERR-001`
- Invalid uuid query values → `VAL-ERR-001`
- Access (`CheckKbTreeHistoryReadAccess` in `kb_history.go`):
  - Allowed: `kb:trees:read:all` (auditor), owner, tree-local update ACL, or `kb:trees:update:all`
  - Denied: read-ACL-only readers. The handler maps denial to `KB-ERR-001` (404, existence hidden). `KB-ERR-403` is the module-level gate when the caller cannot view KB at all.
- `data` shape:

```json
{
  "events": [
    {
      "id": "event-uuid",
      "operation": "update",
      "subject_kind": "article",
      "subject_short_id": "abc12",
      "subject_title": "Runbook",
      "subject_article_id": "article-uuid",
      "occurred_at": "2026-01-01T00:00:00Z",
      "actor": {
        "user_id": "user-uuid",
        "username": "alice",
        "account_type": "standard"
      },
      "content_version_after": 4
    }
  ],
  "next_cursor": { "at": "2026-01-01T00:00:00Z", "id": "event-uuid" },
  "has_more": true
}
```

- `content_version_after` is present when the event meta recorded a content-version bump (create/update). Delete/move events often omit it.

## Common reader-relevant error codes

- `AUT-ERR-401`: missing/invalid/expired JWT (retry after re-auth)
- `KB-ERR-001`: KB item not found or hidden by access policy (including history denial)
- `KB-ERR-403`: caller has no KB module access (`RequireKbModuleAccess`)
- `VAL-ERR-001`: invalid query/params (bad uuid, missing history scope tree, invalid trees `scope`)
- `SYS-ERR-500`: internal error

## Non-goals for this skill

`role-kb-reader` does not create/import/export trees or manage tree ACL (`role-kb-admin`), and does not write article bodies (`role-kb-author`). Shelf add/remove/reorder and personal favorites are navigation only — they do not change KB content.

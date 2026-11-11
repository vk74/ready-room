# evi API contract - KB author

<!--
version: 0.27.3
Short description: Author-level KB write endpoint contract for role-kb-author.
File: api-contract.md
Last evi release: 0.27.3

Changes in v0.27.3:
- Documented the shared object-container contract (`layout`, `align`, `width`) on `mermaidDiagram` and `fileImage`, including block order in `doc.content`.
- Documented collapsible `details` sections (`open`, `lineColor`) and the `textColor` mark, including `lightBlue` and `lightGrey`.

Changes in v0.23.12:
- Documented that a successful article PUT does not echo attachment_file_ids; confirm via GET /api/fs data.items.
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.

Changes in v1.7.0:
- Documented content_version on article/node/tree write responses
  (snake_case; do not send in write payloads).
- Documented post-import related-reconcile (import does not write
  kb_article_links).
- Non-goals: export/import, history, favorites (other skills).
- Updated Last evi release marker to 0.23.11.

Changes in v1.6.0:
- Expanded article content model: entityLink, externalLink, mermaidDiagram nodes.
- Documented inline related-article workflow and kb-articles-related-reconcile.sh.
- Added POST /api/core/link-preview contract for external link preview enrichment.
- Updated Last evi release marker to 0.21.2.

Changes in v1.5.0:
- Added related-article add/remove contracts.
- Documented directional/additive link semantics and access checks.
- Updated Last evi release marker to 0.21.1.

Changes in v1.4.0:
- Updated article content contract: canonical payload is always
  translations.<lang>.content.body for all article types.
- Added validation diagnostics details for PUT /api/kb/articles/:id and
  POST /api/kb/nodes (VAL-ERR-001 with field-level meta).
- Updated "Last evi release" marker to 0.20.19 to match this skill update.

Changes in v1.3.1:
- Added tree discovery note: use role-kb-reader GET /api/kb/library; GET /api/kb/trees
  is personal shelf only (evi 0.20.17).

Changes in v1.3.0:
- Added "Field naming conventions" section: camelCase in request payloads
  (with snake_case exceptions attachment_file_ids and swa_steps), snake_case
  in responses.
- Added "Article content model" section: ProseMirror JSON, supported node and
  mark types, the fileImage recipe (NOT the standard image node), and the
  graceful-degradation behavior for unknown types.
- Preserve-and-add recipe now points to the dedicated
  kb-articles-attachments-add.sh helper script.

Changes in v1.2.0:
- Rewrote attachment_file_ids guidance: present = authoritative full replace,
  omitted = server preserves currently stored files. Added a
  "preserve-and-add" recipe based on fs-files-list.
- Documented the Content-Type: application/json requirement for all
  JSON-body requests (skill scripts send it automatically).

Changes in v1.1.0:
- Clarified attachment_file_ids usage contract for KB article updates.
- Added explicit reference to role-attachments for upload/list/delete lifecycle.

Changes in v1.0.0:
- Initial KB author API contract reference.
- Added request payload examples for node/article write routes.
- Documented strict-author exclusions.
-->

Reference for `role-kb-author`.

All routes below are protected and require:

```http
Authorization: Bearer <JWT>
```

Use `role-auth` for JWT acquisition and the shared `role-request.sh` wrapper (vendored at `scripts/_lib/role-request.sh` inside this skill) for authenticated HTTP calls.

**All requests with a JSON body MUST send `Content-Type: application/json`.** Without it the server may parse the body as form data: the response can still be a success code while `content`, `tags` and `attachment_file_ids` are silently dropped. The scripts in this skill set the header automatically; add it yourself when calling the API directly with curl.

## Field naming conventions

**Request payloads use camelCase** (`treeId`, `parentId`, `nodeType`,
`iconName`, `isPinned`, `parentNodeId`), with exactly two snake_case
exceptions in `kb.articles.update`: `attachment_file_ids` and `swa_steps`.

**Responses use snake_case** (`tree_id`, `node_id`, `article_type_code`,
`type_schema_version`, `content_version`, ...). Do NOT mirror a response
object back into a request payload without renaming the keys — a snake_case
key in a request (other than the two exceptions) is silently ignored and the
field keeps its previous value.

## `content_version` (read-only on writes)

Write responses that return a tree, node, or article DTO include
`content_version` (integer, snake_case):

- `POST /api/kb/nodes`, `PUT /api/kb/nodes/:id` — node `content_version`
  (folder row, or the placed article when `node_type` is article)
- `PUT /api/kb/articles/:id` — article `content_version`
- Tree create/update (`role-kb-admin`) — tree `content_version`

It is a monotonic per-entity stamp. The backend hashes a canonical JSON
snapshot of the entity and increments `content_version` only when that hash
changes. **Do not send `content_version` in write payloads** — it is
server-owned; a request key is ignored.

## Article content model

Canonical payload for every type:

- `translations.<language>.content.body` (object)

Type-specific body shapes:

- `wiki`: `body` is a ProseMirror JSON document (TipTap), rooted at
  `{ "type": "doc", "content": [...] }`.
- `faq`: `body.items[]` stores question/answer rows (`answer` can be
  ProseMirror JSON).
- `standard_manual_activity`: `body.steps[]` stores `step`, `title`, `body`;
  effort is sent separately in `swa_steps`.
- `reference_table`: `body.columns[]` + `body.rows[][]`.

For every rich-text slot (wiki body, FAQ answers, SWA step body), use the
node/mark schema below.

Node types supported by the evi editor schema:

- `paragraph`, `text`, `heading` (attrs `level`: 2, 3 or 4), `bulletList`,
  `orderedList`, `listItem`, `blockquote`, `horizontalRule`, `hardBreak`,
  `codeBlock`
- `table`, `tableRow`, `tableHeader`, `tableCell`
- `fileImage` — evi's ONLY image node (see below)
- `entityLink` — inline atom for internal entity references (see below)
- `externalLink` — block atom for external URL cards (see below)
- `mermaidDiagram` — block atom for Mermaid source diagrams (see below)
- `details` — collapsible section (see below). Do not nest one `details` inside another.

Mark types: `bold`, `italic`, `strike`, `code`, `link` (attrs `href`,
`target`), `textColor` (attr `name`, see below). The `link` mark is for
inline hyperlinks inside text; it is distinct from the `externalLink` block
node.

### Collapsible sections: `details`

A section is one block in `doc.content`. The body stays in the JSON when the
section is collapsed; `open` only controls what the reader sees first.

```json
{
  "type": "details",
  "attrs": { "open": false, "lineColor": "lightBlue" },
  "content": [
    {
      "type": "detailsSummary",
      "content": [{ "type": "text", "text": "Title" }]
    },
    {
      "type": "detailsContent",
      "content": [
        { "type": "paragraph", "content": [{ "type": "text", "text": "Body" }] }
      ]
    }
  ]
}
```

- `content` is exactly one `detailsSummary` followed by one `detailsContent`.
- `detailsSummary` holds inline text only (`text` and marks, including
  `textColor`). No paragraphs, images, or another section.
- `detailsContent` holds the same blocks as the rest of the document
  (`paragraph`, lists, `codeBlock`, `table`, `fileImage`, `mermaidDiagram`,
  `externalLink`, and so on). A `fileImage` inside a section is still a file
  reference and is reconciled like any other inline image.
- Do not put a `details` node inside `detailsContent`. The editor flattens a
  nested section on the next edit: the inner title becomes a paragraph and
  the inner blocks follow it. Write sections flat.
- `attrs.open`: `true` shows the body, `false` shows only the title. Include
  it. When it is omitted, the editor treats the section as open.
- `attrs.lineColor` paints the vertical line. Omit it, or send `null`, for
  the accent color. A stored name is one of `success`, `warning`, `error`,
  `favorite`, `muted`, `blue`, `lightBlue`, `purple`, `lightGrey`. Do not
  send `accent` or an unknown string; the editor drops those and uses accent.

### Text color: `textColor` mark

Color is a token name, never a hex value or a `style` attribute.

```json
{
  "type": "text",
  "text": "important",
  "marks": [{ "type": "textColor", "attrs": { "name": "error" } }]
}
```

Allowed `name` values: `accent`, `success`, `warning`, `error`, `favorite`,
`muted`, `blue`, `lightBlue`, `purple`, `lightGrey`. Clearing the color
means omitting the mark. `default` is not a stored name.

### Internal article links: use `entityLink`

KB articles reference other KB articles with an inline `entityLink` atom.
Always set `entityType` to `"kb_article"`:

```json
{
  "type": "entityLink",
  "attrs": {
    "entityType": "kb_article",
    "entityId": "target-article-uuid",
    "label": "abc12 — Article title",
    "meta": {
      "treeId": "tree-uuid",
      "treeName": "Operations KB",
      "shortId": "abc12",
      "status": "published",
      "articleTypeCode": "wiki"
    }
  }
}
```

- Required attrs: `entityType`, `entityId`.
- `label` and `meta` are display snapshots taken at insertion time; include
  them so readers see a sensible chip before live label resolution.
- Allowed in every rich-text slot: wiki `body`, FAQ `items[].answer`, SWA
  `steps[].body`. Not applicable to `reference_table` (no rich-text body).

Related-articles backing table: the UI stores related links in
`app.kb_article_links` (`link_type = related`). The evi web app reconciles
that table from `entityLink` chips on save. **The backend does NOT auto-sync
related links when you PUT article content via the API.** After updating
content with `entityLink` nodes, run
`kb-articles-related-reconcile.sh` (see below) so `GET /related` matches the
body.

After `role-kb-admin` tree import, `GET /related` may be empty even when
`entityLink` chips exist in imported bodies. Import does not write
`kb_article_links`. Run `kb-articles-related-reconcile.sh` for each imported
article that has `entityLink` chips.

Anti-pattern: calling `POST /related` without inserting `entityLink` nodes
does not add inline chips to the article body.

### External URL cards: use `externalLink`

External URLs are block-level cards, not the `link` mark:

```json
{
  "type": "externalLink",
  "attrs": {
    "url": "https://example.com/docs",
    "linkOnly": false,
    "altDescription": null,
    "preview": {
      "title": "Example Docs",
      "description": "Short summary",
      "iconUrl": "https://example.com/favicon.ico"
    }
  }
}
```

- `preview` is optional (`null` is valid — the card renders from `url` alone).
- `linkOnly: true` — compact URL link without a preview card.
- Optional enrichment: call `POST /api/core/link-preview` (see below) and map
  the response into `preview` (`icon_url` in the response becomes `iconUrl` in
  stored attrs).

### Mermaid diagrams: use `mermaidDiagram`

Only Mermaid source is persisted; rendered SVG is never stored.
`mermaidDiagram` is a block-level atom in `doc.content` and shares the
object-container attributes `layout`, `align`, and `width` (see below):

```json
{
  "type": "mermaidDiagram",
  "attrs": {
    "source": "flowchart TD\n  A --> B",
    "caption": null,
    "layout": "inline",
    "align": "left",
    "width": null
  }
}
```

### Images: use `fileImage`, never `image`

The standard TipTap/ProseMirror `image` node (with a `src` URL) is **not in
the evi schema**. Images reference uploaded files by id and use the same
object-container attributes as `mermaidDiagram`:

```json
{
  "type": "fileImage",
  "attrs": {
    "fileId": "3d9f2f61-c9af-4f91-8a6a-e38c5caefa13",
    "alt": "architecture diagram",
    "layout": "inline",
    "align": "left",
    "width": null
  }
}
```

Recipe:

1. Upload + confirm the image against the article
   (`entity_type=kb_article`, `entity_id=<article_uuid>`) via the
   `role-attachments` skill; keep the returned `file_id`.
2. Insert a `fileImage` node with `attrs.fileId` set to that id. It is a
   block-level atom in `doc.content`, never inside a `paragraph`. `alt` is
   optional. `layout`, `align`, and `width` follow the object-container
   contract below.
3. Save the article. The server walks the document, recognizes inline file
   references and keeps those files alive.

### Object container: `layout`, `align`, `width`

`fileImage` and `mermaidDiagram` share these attributes:

- `layout`: `"inline"` (default — floats left or right, and text from the
  following blocks wraps alongside the image or diagram) or `"block"`
  (occupies a separate horizontal row, `clear: both`, with no text wrapping
  beside it).
- `align`: `"left"` (default), `"center"` (valid in `"block"` mode only;
  normalized to `"left"` in `"inline"` mode), or `"right"`.
- `width`: `null` (default — the container auto-sizes to the image or SVG
  natural width, capped at 65% of the column width in `"inline"` mode and
  100% in `"block"` mode) or an integer `>= 60` (px). When set, the container
  is fixed to that width and the inner image or Mermaid SVG scales to `100%`
  of the container width while preserving aspect ratio.
- Vertical placement: `fileImage` and `mermaidDiagram` are block-level atoms
  in `doc.content` (never inside a `paragraph`'s `content`). To move an image
  or diagram higher or lower in the article, place or reorder its node
  earlier or later in the `content` array, between paragraphs and headings.
  In `"inline"` mode, text wrapping starts at the block immediately after
  the container node.

### Unknown node/mark types

Documents are sanitized on render: unknown node types are dropped (top-level
ones are replaced with a visible `[unsupported content: <type>]` placeholder)
and unknown marks are stripped, with a console warning. The article no longer
collapses to a blank body — but your content is still LOST for readers, so
always emit only the types listed above.

## Response envelope

Success:

```json
{
  "success": true,
  "code": "KB-SUC-005",
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

## Author endpoints

### `POST /api/kb/nodes` (`kb.nodes.create`)

Example payload:

```json
{
  "treeId": "tree-uuid",
  "parentId": "parent-node-uuid-or-null",
  "nodeType": "folder",
  "translations": {
    "english": { "title": "Runbooks" }
  },
  "iconName": "book-open"
}
```

### `PUT /api/kb/nodes/:id` (`kb.nodes.update`)

Example payload:

```json
{
  "translations": {
    "english": { "title": "Updated folder title" }
  },
  "iconName": "folder-open"
}
```

### `PUT /api/kb/nodes/:id/move` (`kb.nodes.move`)

Example payload:

```json
{
  "parentId": "target-parent-node-uuid-or-null",
  "order": 2
}
```

### `DELETE /api/kb/nodes/:id` (`kb.nodes.delete`)

No request body.

### `PUT /api/kb/articles/:id` (`kb.articles.update`)

Example payload:

```json
{
  "translations": {
    "english": {
      "content": {
        "body": {
          "type": "doc",
          "content": [
            { "type": "paragraph", "content": [{ "type": "text", "text": "Updated body" }] }
          ]
        }
      }
    }
  },
  "status": "published",
  "tags": ["incident", "runbook"],
  "isPinned": true
}
```

Optional advanced fields supported by backend:

- `attachment_file_ids`: authoritative file id set
- `swa_steps`: authoritative steps list for `standard_manual_activity`

Validation notes:

- Invalid article content shape returns `VAL-ERR-001` with
  `meta.field="translations.<lang>.content.body"` plus `meta.reason` and
  `meta.article_type_code`.
- For `POST /api/kb/nodes`, `nodeType="article"` without `articleTypeCode`
  returns `VAL-ERR-001` with `meta.field="articleTypeCode"`.

`attachment_file_ids` semantics:

- **Field present** (including `[]`): authoritative **full replace**. Every
  active file of the article NOT listed is scheduled for deletion. An empty
  array clears all attachments.
- **Field omitted**: the server preserves all currently stored files; the
  update does not touch attachments.
- The success body of `PUT /api/kb/articles/:id` does not include
  `attachment_file_ids`. Confirm the stored set with `GET /api/fs?entity_type=kb_article&entity_id=`
  (`data.items[].file_id`, `FILE-SUC-005`) from `role-attachments`.

Integration guidance:

1. Obtain/confirm file ids through `role-attachments` (`/api/fs` lifecycle).
2. Send only the final authoritative array in `kb.articles.update`.
3. Omit the field when you have no attachment opinion for this update —
   existing attachments survive.
4. Send an empty array only when your intent is to clear all attachments.

Preserve-and-add (add files without losing existing ones) — use the
dedicated helper, which lists the current set, unions in the new ids and
sends the merged authoritative array:

```bash
# new file(s) must already be uploaded + confirmed for this article
bash scripts/kb-articles-attachments-add.sh "<article_uuid>" "<new_file_uuid>" [more ids...]
```

Manual equivalent:

```bash
# 1. current attachment ids (role-attachments skill)
CURRENT=$(bash .../fs-files-list.sh kb_article "<article_uuid>" | jq -c '[.data.items[].file_id]')

# 2. upload + confirm the new file, keep its file_id (role-attachments flow)

# 3. union into the update payload
jq -n --argjson cur "$CURRENT" --arg new "<new_file_uuid>" \
  '{attachment_file_ids: ($cur + [$new])}' > payload.json

bash scripts/kb-articles-update.sh "<article_uuid>" payload.json
```

### `POST /api/kb/articles/:id/link` (`kb.articles.link`)

Example payload:

```json
{
  "parentNodeId": "target-folder-node-uuid-or-null"
}
```

`parentNodeId: null` means link to tree root.

### Related article links (inline `entityLink` + backing relation)

Since evi 0.21.2, related KB articles appear as `entityLink` chips inside the
article body. The backing relation (`GET/POST/DELETE /related`) must stay in
sync with those chips when authoring via the API.

**Recommended workflow after content edits:**

```bash
# 1. PUT the article body (include entityLink nodes in translations.*.content)
bash scripts/kb-articles-update.sh "<article_uuid>" ./payloads/update-article.json

# 2. Reconcile the backing relation to match entityLink chips in the payload
bash scripts/kb-articles-related-reconcile.sh "<article_uuid>" ./payloads/update-article.json
```

`kb-articles-related-reconcile.sh` extracts all `entityLink` nodes with
`entityType=kb_article` from the payload (all translations), diffs against
`GET /related`, then calls add/remove as needed. Idempotent; no-op when already
in sync. Skips `reference_table` articles (no rich-text body).

#### `POST /api/kb/articles/:id/related` (`kb.articles.related.add`)

Adds one or more directional related-article links from the source article to
target articles. Use for incremental updates without a full body rewrite, or
let `kb-articles-related-reconcile.sh` call this for you.

Payload:

```json
{
  "article_ids": ["target-article-uuid-1", "target-article-uuid-2"]
}
```

Success code: `KB-SUC-010`; success data:

```json
{
  "added": 2
}
```

Semantics:

- Links are directional. Adding A -> B does not create B -> A.
- The operation is additive, not an authoritative replace. Existing related
  links are preserved.
- Duplicate or already-linked target ids are ignored; `added` counts only newly
  inserted rows.
- Self-links are rejected with `VAL-ERR-001`.
- Caller needs write access on the source article tree and read access on every
  target article.
- Does **not** insert `entityLink` nodes into article content — use
  `kb.articles.update` for inline chips.

#### `DELETE /api/kb/articles/:id/related/:targetArticleId` (`kb.articles.related.remove`)

Removes one directional related-article link. Does **not** remove
`entityLink` nodes from article content.

Success code: `KB-SUC-010`; success data:

```json
{
  "removed": 1
}
```

Missing links return `KB-ERR-001`; invalid target UUID returns `VAL-ERR-001`.

### `POST /api/core/link-preview` (`core.linkPreview`)

Optional enrichment when building `externalLink` nodes. Not required to save
an external link (`preview: null` is valid).

Payload:

```json
{
  "url": "https://example.com/docs"
}
```

Success code: `LPV-SUC-001`; success data:

```json
{
  "title": "Example Docs",
  "description": "Short summary",
  "icon_url": "https://example.com/favicon.ico"
}
```

Map into `externalLink.attrs.preview`:

```json
{
  "title": "<title>",
  "description": "<description>",
  "iconUrl": "<icon_url or null>"
}
```

Helper script: `bash scripts/core-link-preview.sh "<url>"`.

Errors: invalid/blocked URLs return `VAL-ERR-400`. Fetch failures may return
success with empty fields.

### `DELETE /api/kb/articles/:id/placements/:placementId` (`kb.articles.unlinkPlacement`)

No request body.

### `DELETE /api/kb/articles/:id` (`kb.articles.deleteEverywhere`)

No request body.

## Common error codes

- `AUT-ERR-401`: JWT missing/invalid/expired
- `KB-ERR-001`: target entity not found (or hidden by policy)
- `KB-ERR-403`: write access denied on target tree
- `VAL-ERR-001`: payload/query validation failure
- `REQ-ERR-001`: malformed JSON body
- `SYS-ERR-500`: internal error

## Non-goals in strict-author scope

This skill does not call:

- `/api/kb/trees*` write routes
- Tree export/import (`GET /api/kb/trees/:id/export`, `/api/kb/trees/import/*`)
  — use `role-kb-admin`
- `/api/kb/history` — use `role-kb-reader`
- `/api/kb/library*` shelf navigation routes (use `role-kb-reader`)
- `/api/kb/articles/:id/favorite` and `GET /api/kb/favorites` — use `role-kb-reader`
- visibility ACL management routes
- generic `/api/fs` file lifecycle routes (use `role-attachments`)

Tree discovery (evi 0.20.17+; `scope=accessible` in evi 0.23.11): before
authoring in a tree, use `role-kb-reader` → `GET /api/kb/library` to find
readable trees (`on_shelf`, `canExport`). `GET /api/kb/trees` defaults to the
caller's personal shelf; pass `scope=accessible` for every readable tree
without a shelf add. Export/import stay in `role-kb-admin`.

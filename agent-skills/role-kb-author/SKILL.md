---
name: role-kb-author
description: >
  Knowledge Base author skill for evi. Covers node and article write operations
  for users/bots that already have author-level access on target KB trees.
last_release: "0.27.3"
compatibility: Requires curl, jq, and network access to the evi instance. Self-contained — auth helper scripts are vendored in scripts/_lib (set REQUEST_SCRIPT to override).
required_environment_variables:
  - name: BASE_URL
    prompt: evi instance base URL (e.g. https://evi.example.com or http://localhost:7070)
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
    prompt: Path to a PEM CA certificate for the evi endpoint
    help: Optional. Preferred over TLS_INSECURE for trusted self-hosted certs.
    required_for: custom/private CA deployments
  - name: AGENT_HOME
    prompt: Base directory for local agent cache and state
    help: Optional. Defaults to ~/.agent-skills; used by role-auth cache files.
    required_for: custom local runtime layout
---

# role-kb-author

<!--
version: 0.27.3
Short description: Author-level KB write operations for nodes and articles.
File: SKILL.md
Last release: 0.27.3

Changes in v0.27.3:
- Documented the shared object-container attributes (`layout`, `align`, `width`) on `fileImage` and `mermaidDiagram`, and that vertical order is the node's place in the parent `content` array.
- Documented collapsible `details` sections and the `textColor` mark (`lightBlue`, `lightGrey` included) for rich-text slots.

Changes in v0.26.2:
- Renamed frontmatter key `last_evi_release` to `last_release` and set it to 0.26.2.

Changes in v0.23.12:
- Documented that a successful article PUT does not return attachment_file_ids; confirm the set with role-attachments fs-files-list.sh (data.items).
- Renamed skill directory and shared scripts from evi-* to role-*; dropped EVI_ prefix from env vars (BASE_URL, API_KEY, …).
- Renamed API key format prefix from evik_ to bkey_ in API_KEY prompt.
- Updated last_evi_release marker to 0.23.12.

Changes in v1.7.0:
- Documented content_version on tree/node/article responses (monotonic
  per-entity stamp; do not send it in write payloads).
- Documented post-import related-reconcile: import does not write
  kb_article_links; run kb-articles-related-reconcile.sh per imported
  article that has entityLinks.
- Documented kb.trees.list accessible discovery (see role-kb-reader);
  export/import stay in role-kb-admin.
- Updated last_evi_release marker to 0.23.11.

Changes in v1.6.0:
- Expanded content model: entityLink (KB article chips), externalLink cards,
  mermaidDiagram blocks; link-preview helper for external URLs.
- Related articles are inline entityLink chips; added
  kb-articles-related-reconcile.sh to sync backing relation after content PUT.
- Documented that POST /related alone does not insert inline chips.
- Updated last_evi_release marker to 0.21.2.

Changes in v1.5.0:
- Added related-article add/remove operations:
  `POST /api/kb/articles/:id/related` and
  `DELETE /api/kb/articles/:id/related/:targetArticleId`.
- Documented that related links are directional and additive.
- Updated last_evi_release marker to 0.21.1.

Changes in v1.4.0:
- Updated article content contract: all article types use
  translations.<lang>.content.body as canonical shape (wiki doc, faq body.items,
  swa body.steps, reference_table body.columns/body.rows).
- Added validation diagnostics note: payload violations return VAL-ERR-001 with
  field-level meta (`field`, `reason`, `article_type_code`).
- Updated `last_evi_release` marker to 0.20.19 for this skill revision.

Changes in v1.3.1:
- Added KB Library workflow note: discover trees via role-kb-reader kb.library.list;
  kb.trees.list returns personal shelf only (evi 0.20.17).
- Added last_evi_release frontmatter marker.

Changes in v1.3.0:
- Added kb-articles-attachments-add.sh: safe preserve-and-add helper that
  unions current attachment ids with new ones before the PUT.
- Added content model warning: article content is ProseMirror JSON and
  images MUST use evi's fileImage node (never the standard image node);
  unknown node types are dropped by the renderer.
- Added field naming note: requests are camelCase except attachment_file_ids
  and swa_steps; responses are snake_case.

Changes in v1.2.0:
- Skill is now self-contained: auth helpers vendored in scripts/_lib with
  REQUEST_SCRIPT override support; role-auth co-location no longer required.
- Corrected attachment_file_ids semantics: present = authoritative full
  replace, omitted = server preserves currently stored files.
- Documented that environment variables must be exported.

Changes in v1.1.0:
- Added explicit composition guidance for KB author workflows with attachments.
- Clarified that generic file lifecycle is delegated to role-attachments skill.
- Added cross-reference to role-attachments in References.

Changes in v1.0.0:
- Initial KB author skill with strict-author scope.
- Added node/article write method map and script list.
- Added JWT contract and non-goals for tree-admin operations.
- Added role-composition guidance: author role loads reader + author skills.
-->

Author-focused Knowledge Base write skill for external agents and bots.

This skill is **strict-author scope**: it includes node/article mutations only and excludes tree admin actions.

## Role composition

- For **KB reader** role: load `role-kb-reader`.
- For **KB author** role: load `role-kb-reader` + `role-kb-author`.
- For **KB author with files**: load `role-kb-reader` + `role-kb-author` + `role-attachments`.
- For **KB admin** role: load `role-kb-reader` + `role-kb-author` + `role-kb-admin`.

## Scope

Included methods:

- `kb.nodes.create` -> `POST /api/kb/nodes`
- `kb.nodes.update` -> `PUT /api/kb/nodes/:id`
- `kb.nodes.move` -> `PUT /api/kb/nodes/:id/move`
- `kb.nodes.delete` -> `DELETE /api/kb/nodes/:id`
- `kb.articles.update` -> `PUT /api/kb/articles/:id`
- `kb.articles.link` -> `POST /api/kb/articles/:id/link`
- `kb.articles.related.add` -> `POST /api/kb/articles/:id/related`
- `kb.articles.related.remove` -> `DELETE /api/kb/articles/:id/related/:targetArticleId`
- `kb.articles.unlinkPlacement` -> `DELETE /api/kb/articles/:id/placements/:placementId`
- `kb.articles.deleteEverywhere` -> `DELETE /api/kb/articles/:id`

Content model note:

- Canonical payload for every article type is
  `translations.<lang>.content.body` (object).
- `wiki`: `body` is a ProseMirror JSON document.
- `faq`: `body.items[]` stores question/answer rows (`answer` may be ProseMirror JSON).
- `standard_manual_activity`: `body.steps[]` stores step/title/body;
  effort is sent separately in `swa_steps`.
- `reference_table`: `body.columns[]` + `body.rows[][]`.
- For rich text slots, images MUST be `fileImage` nodes referencing an uploaded
  `fileId` — the standard TipTap `image` node (with `src`) is not in the evi
  schema and is dropped by the renderer.
- Internal KB article links use inline `entityLink` atoms (`entityType`:
  `"kb_article"`). External URLs use block `externalLink` atoms. Mermaid
  diagrams use block `mermaidDiagram` atoms (source only, no stored SVG).
  Inline hyperlinks inside text use the `link` mark — distinct from
  `externalLink`.
- A collapsible section is a `details` block: `detailsSummary` (one line of
  text) then `detailsContent` (the same blocks as the rest of the document).
  Do not nest a section inside a section. `attrs.open` is `true` or `false`
  (`false` hides the body in the UI; the JSON still contains it). Omit
  `attrs.lineColor` for an accent line, or set `success`, `warning`,
  `error`, `favorite`, `muted`, `blue`, `lightBlue`, `purple`, or
  `lightGrey`.
- Font color is the `textColor` mark on a text node, `attrs.name` set to
  `accent`, `success`, `warning`, `error`, `favorite`, `muted`, `blue`,
  `lightBlue`, `purple`, or `lightGrey`. Do not send a hex color. Omitting
  the mark leaves the default text color.
- `fileImage` and `mermaidDiagram` share the object-container attributes
  `layout`, `align`, and `width`:
  - `layout`: `"inline"` | `"block"` (default `"inline"`). `"inline"` floats
    the container (`"left"` or `"right"`) so subsequent paragraphs and blocks
    wrap beside it. `"block"` places the container on its own row with no
    text wrapping (`"left"`, `"center"`, or `"right"`).
  - `align`: `"left"` | `"center"` | `"right"` (default `"left"`). In
    `"inline"` mode `"center"` normalizes to `"left"`.
  - `width`: integer `>= 60` (px) or `null` (default `null`, natural object
    width). When set, the image or Mermaid diagram SVG scales to fit the
    container width.
- Vertical placement is the node's position in the parent `content` array.
  In `"inline"` mode, text wrapping starts at the block immediately after
  the container node.
- Request payloads are **camelCase** (`treeId`, `isPinned`, ...) with two
  snake_case exceptions: `attachment_file_ids` and `swa_steps`. Responses are
  snake_case; never mirror response keys back into a request.
- Responses for trees, nodes, and articles include `content_version` (integer;
  monotonic per-entity stamp). It bumps only when the canonical content hash
  changes. **Do not send `content_version` in write payloads** — it is
  server-owned and a request key is ignored.

Attachment note:

- `kb.articles.update` accepts `attachment_file_ids` as an authoritative file-id set:
  **present** (including `[]`) = full replace (unlisted files are scheduled for
  deletion), **omitted** = the server preserves all currently stored files.
- To add files while keeping existing ones, use
  `scripts/kb-articles-attachments-add.sh <article_id> <file_id>...` — it
  lists the current ids, unions in the new ones and sends the merged set.
  Manual recipe in `references/api-contract.md`.
- A successful `PUT /api/kb/articles/:id` does not return `attachment_file_ids`.
  Confirm the stored set with `role-attachments` `fs-files-list.sh`: `data.items[].file_id`.
- Upload/list/delete lifecycle for those file ids is handled by `role-attachments`
  (this skill stays KB-domain only and does not duplicate `/api/fs` wrappers).

Related-articles note (evi 0.21.2+):

- Related KB articles appear as **`entityLink` chips** inside the article body
  (wiki body, FAQ answers, SWA step bodies). There is no separate related-articles
  panel in the UI anymore.
- The backing relation (`GET/POST/DELETE /related`) powers navigation and live
  label resolution. The web app reconciles it from body content on save; **the
  API does not auto-sync** when you PUT content.
- **After every content update that adds/removes `entityLink` chips**, run
  `scripts/kb-articles-related-reconcile.sh <article_id> <payload.json>` so
  the backing relation matches the saved body.
- `kb.articles.related.add` / `kb.articles.related.remove` remain for
  incremental relation changes without a full body rewrite, but they do **not**
  insert or remove inline chips. Anti-pattern: only POST /related without
  `entityLink` in content — no inline link appears for readers.
- Links are **directional** (A -> B does not create B -> A). Self-links are
  rejected. Caller needs write access on the source tree and read access on
  each target. `reference_table` articles have no rich-text body — reconcile
  is skipped for that type.
- After `role-kb-admin` import, `GET /related` may be empty even if `entityLink`
  chips exist in article bodies. Import does not write `kb_article_links`.
  Run `scripts/kb-articles-related-reconcile.sh` for each imported article
  that has `entityLink` chips.

External links note:

- Use `externalLink` block nodes for URL cards. Optional preview metadata from
  `scripts/core-link-preview.sh` (wraps `POST /api/core/link-preview`).

Mermaid note:

- Use `mermaidDiagram` block nodes with `attrs.source` (Mermaid syntax string).
  Only source is stored; SVG is rendered at display time.
- `mermaidDiagram` and `fileImage` share `{ layout, align, width }`:
  - `layout`: `"inline"` | `"block"` (default `"inline"`). `"inline"` floats
    the container (`"left"` or `"right"`) so subsequent paragraphs and blocks
    wrap beside it. `"block"` places the container on its own row with no
    text wrapping (`"left"`, `"center"`, or `"right"`).
  - `align`: `"left"` | `"center"` | `"right"` (default `"left"`). In
    `"inline"` mode `"center"` normalizes to `"left"`.
  - `width`: integer `>= 60` (px) or `null` (default `null`, natural object
    width). When set, the image or Mermaid diagram SVG scales to fit the
    container width.
- Vertical placement is the node's position in the parent `content` array.
  In `"inline"` mode, text wrapping starts at the block immediately after
  the container node.

Explicitly excluded:

- Tree admin routes (`POST/PUT/DELETE /api/kb/trees*`, change-owner, ACL) — use `role-kb-admin`
- Tree export/import routes (`GET /api/kb/trees/:id/export`, `/api/kb/trees/import/*`) — use `role-kb-admin`
- Personal shelf navigation (library list, shelf add/remove, shelf reorder) — use `role-kb-reader`
- Favorites mutation routes (`POST/DELETE /api/kb/articles/:id/favorite`) — use `role-kb-reader`
- Full read/navigation workflows (use `role-kb-reader`)

Tree discovery workflow (evi 0.20.17+; trees `accessible` in evi 0.23.11):

- Use `role-kb-reader` → `kb.library.list` to find readable KB trees, `on_shelf`, and `canExport`.
- `kb.trees.list` now accepts `scope=shelf|accessible` (see `role-kb-reader`). Pass
  `accessible` to load full payloads for every readable tree without adding them
  to the shelf first. Default `shelf` remains the personal shelf only.
- Use `kb.library.addToShelf` when the agent needs the tree on the personal shelf.
- Tree export/import stay in `role-kb-admin`.
- Author mutations (`kb.nodes.*`, `kb.articles.*`) still require update access on the target tree.

## JWT contract

Every protected backend request is executed with:

```http
Authorization: Bearer <JWT>
```

JWT lifecycle is delegated to the shared auth scripts (vendored at `scripts/_lib/`; canonical copies in the `role-auth` skill). Resolution order: `REQUEST_SCRIPT` env override → vendored `scripts/_lib/` copy → `../../role-auth/scripts/` (monorepo layout):

- missing/expired token -> re-auth
- `AUT-ERR-401` on request -> one re-auth + retry

Environment variables (`BASE_URL`, `API_KEY`, TLS options) must be **exported** — scripts spawn child processes that only inherit exported vars.

## Input contract for write scripts

Scripts that send payloads accept a JSON file path. JSON must follow backend field names (camelCase or snake_case exactly as documented in `references/api-contract.md`).

## Script map

- `scripts/kb-nodes-create.sh <payload.json>`
- `scripts/kb-nodes-update.sh <node_id> <payload.json>`
- `scripts/kb-nodes-move.sh <node_id> <payload.json>`
- `scripts/kb-nodes-delete.sh <node_id>`
- `scripts/kb-articles-update.sh <article_id> <payload.json>`
- `scripts/kb-articles-attachments-add.sh <article_id> <file_id> [<file_id>...]`
- `scripts/kb-articles-link.sh <article_id> [--parent-node-id "<uuid>" | --root]`
- `scripts/kb-articles-related-add.sh <article_id> <target_article_id> [<target_article_id>...]`
- `scripts/kb-articles-related-remove.sh <article_id> <target_article_id>`
- `scripts/kb-articles-related-reconcile.sh <article_id> <content_payload.json>`
- `scripts/core-link-preview.sh <url>`
- `scripts/kb-articles-unlink-placement.sh <article_id> <placement_id>`
- `scripts/kb-articles-delete.sh <article_id>`

## Usage examples

```bash
bash scripts/kb-nodes-create.sh ./payloads/create-folder.json
bash scripts/kb-articles-update.sh "article-uuid" ./payloads/update-article.json
bash scripts/kb-articles-related-reconcile.sh "article-uuid" ./payloads/update-article.json
bash scripts/kb-articles-link.sh "article-uuid" --parent-node-id "node-uuid"
bash scripts/kb-articles-related-add.sh "article-uuid" "related-article-uuid"
bash scripts/core-link-preview.sh "https://example.com/docs"
```

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Reader skill](../role-kb-reader/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)

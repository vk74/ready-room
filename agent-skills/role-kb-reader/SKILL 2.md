---
name: role-kb-reader
description: >
  Read-only Knowledge Base skill for evi. Uses JWT authentication from role-auth
  and lists/reads KB trees and articles, searches, lists change history, adds or
  removes personal article favorites, and navigates the personal shelf (library
  with canExport, shelf add/remove/reorder, trees list with scope shelf or
  accessible). Use when an agent needs KB read access or personal navigation
  without writing article bodies or administering trees.
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

# role-kb-reader

<!--
version: 0.27.3
Short description: Read-only Knowledge Base methods plus personal shelf and favorites navigation.
File: SKILL.md
Last release: 0.27.3

Changes in v0.27.3:
- Documented the shared object-container attributes (`layout`, `align`, `width`) on `mermaidDiagram` and `fileImage` in article content.
- Documented collapsible `details` sections and the `textColor` mark when reading article bodies.

Changes in v0.26.2:
- Renamed frontmatter key `last_evi_release` to `last_release` and set it to 0.26.2.

Changes in v0.23.12:
- Documented that an empty personal shelf is reseeded with the system HELP KB tree on the next library or shelf list, so a successful remove can still show that tree.
- Renamed skill directory and shared scripts from evi-* to role-*; dropped EVI_ prefix from env vars (BASE_URL, API_KEY, …).
- Renamed API key format prefix from evik_ to bkey_ in API_KEY prompt.
- Updated last_evi_release marker to 0.23.12.

Changes in v1.5.0:
- Added kb.history.list and personal favorite add/remove; documented
  kb.trees.list query scope=shelf|accessible and library canExport.
- Documented history access gate (CheckKbTreeHistoryReadAccess).
- Removed favorite mutate routes from Explicitly excluded.
- Updated last_evi_release marker for evi 0.23.11.

Changes in v1.4.0:
- Documented reading rich article content: entityLink, externalLink,
  mermaidDiagram nodes and related vs inline chip semantics.
- Updated last_evi_release marker for evi 0.21.2.

Changes in v1.3.0:
- Added read-only related-articles lookup:
  `GET /api/kb/articles/:id/related`.
- Updated last_evi_release marker for evi 0.21.1.

Changes in v1.2.0:
- Added KB Library: kb.library.list, kb.library.addToShelf, kb.library.removeFromShelf.
- Moved kb.trees.reorder from role-kb-admin (personal shelf order, evi 0.20.17).
- Documented kb.trees.list as shelf projection only; use library for full discovery.
- Added last_evi_release frontmatter marker.

Changes in v1.1.0:
- Skill is now self-contained: auth helpers vendored in scripts/_lib with
  REQUEST_SCRIPT override support; role-auth co-location no longer required.
- Documented that environment variables must be exported.

Changes in v1.0.0:
- Initial read-only KB reader skill.
- Added JWT contract and method list.
- Added script map for GET/search KB endpoints only.
- Added role-composition guidance for reader/author/admin bundles.
-->

Read-only Knowledge Base access for external agents and bots. This skill covers listing and reading KB content, listing change history, and **personal navigation** helpers (KB Library shelf add/remove, shelf reorder, and article favorite add/remove). Shelf and favorites adjust only the caller's own panel — they do not mutate KB tree content, nodes, or articles.

## Role composition

- For **KB reader** role: load `role-kb-reader`.
- For **KB author** role: load `role-kb-reader` + `role-kb-author`.
- For **KB admin** role: load `role-kb-reader` + `role-kb-author` + `role-kb-admin`.

## Scope

Included methods:

- `kb.access.getModuleAccess` -> `GET /api/kb/access`
- `kb.library.list` -> `GET /api/kb/library` (all readable trees + `on_shelf` + `canExport`)
- `kb.library.addToShelf` -> `POST /api/kb/library/:treeId/shelf`
- `kb.library.removeFromShelf` -> `DELETE /api/kb/library/:treeId/shelf`
- `kb.trees.list` -> `GET /api/kb/trees` query `scope=shelf|accessible` (default `shelf` = caller **personal shelf**; `accessible` = all readable trees, no shelf filter)
- `kb.trees.reorder` -> `PUT /api/kb/trees/reorder` (caller **personal shelf** order)
- `kb.history.list` -> `GET /api/kb/history` (tree / folder+tree / article scope; keyset pagination)
- `kb.articleTypes.list` -> `GET /api/kb/article-types`
- `kb.articles.listPublished` -> `GET /api/kb/articles` (`q`, `tree_id`)
- `kb.articles.get` -> `GET /api/kb/articles/:id`
- `kb.articles.related.get` -> `GET /api/kb/articles/:id/related`
- `kb.search.query` -> `GET /api/kb/search` (`q`)
- `kb.favorites.list` -> `GET /api/kb/favorites`
- `kb.favorites.add` -> `POST /api/kb/articles/:id/favorite`
- `kb.favorites.remove` -> `DELETE /api/kb/articles/:id/favorite`

Discovery workflow (evi 0.20.17+):

1. Call `kb.library.list` to see every KB tree the caller can read, whether each is on the personal shelf (`on_shelf`), and whether the caller may export it (`canExport`).
2. Call `kb.library.addToShelf` for trees the agent needs in the left panel — or skip the shelf and call `kb.trees.list` with `scope=accessible`.
3. Call `kb.trees.list` (default `shelf`) to load full tree payloads (nodes/articles) for shelf trees; pass `accessible` for every readable tree.

`kb.library.removeFromShelf` returns `KB-SUC-025` and does not delete the tree. If that call leaves the personal shelf empty, the next `kb.library.list` or `kb.trees.list` (shelf scope) puts the system HELP KB tree back on the shelf when the caller can read it. Seeing that tree again after a successful remove is this reseed.

History access (`CheckKbTreeHistoryReadAccess`):

- Allowed: `kb:trees:read:all` (auditor), tree owner, tree-local update ACL, or `kb:trees:update:all`.
- Denied: read-ACL-only readers. The handler maps that denial to `KB-ERR-001` (404, existence hidden). `KB-ERR-403` is the module-level gate when the caller cannot view KB at all.
- Success is typically `KB-SUC-019`. Response `{events, next_cursor, has_more}`; events may include `content_version_after`.

Reading rich article content (evi 0.21.2+):

- `kb.articles.get` returns ProseMirror JSON under
  `data.translations.<lang>.content.body`. Look for these node types:
  - `entityLink` — inline chip referencing another entity (`entityType`,
    `entityId`, cached `label`, optional `meta`). In KB, `entityType` is
    `"kb_article"`.
  - `externalLink` — block card for an external URL (`url`, `linkOnly`,
    optional `preview` with `title`, `description`, `iconUrl`).
  - `mermaidDiagram` — block with Mermaid `source` string (SVG not stored).
  - `fileImage` — image referencing a `/api/fs` file id (see
    `role-attachments`).
- A collapsible section is a `details` node. `attrs.open: false` means the
  UI shows only `detailsSummary`; `detailsContent` is still in the JSON.
  `attrs.lineColor` is omitted for the accent line, otherwise one of
  `success`, `warning`, `error`, `favorite`, `muted`, `blue`, `lightBlue`,
  `purple`, `lightGrey`.
- Colored text is a `textColor` mark. `attrs.name` is `accent`, `success`,
  `warning`, `error`, `favorite`, `muted`, `blue`, `lightBlue`, `purple`,
  or `lightGrey`.
- `mermaidDiagram` and `fileImage` carry the shared object-container
  attributes:
  - `layout`: `"inline"` | `"block"` (default `"inline"`).
  - `align`: `"left"` | `"center"` | `"right"` (default `"left"`).
  - `width`: px integer `>= 60`, or `null`.
- `kb.articles.related.get` returns the backing related-articles relation
  (metadata: title, tree, status). Use it for navigation graphs and when you
  need a full linked-article list without walking the body.
- Inline `entityLink` chips (what readers see in context) and `GET /related`
  (backing relation) should match when content was saved through the evi UI or
  when an agent ran `kb-articles-related-reconcile.sh` after a content PUT.
  They can diverge if content was updated via API without reconcile — prefer
  both sources: chips for in-context references, `GET /related` for structured
  metadata.

Explicitly excluded:

- KB content writes: tree/node/article create/update/delete (author/admin skills)
- Tree governance: create/import/export/delete/change-owner/ACL (`role-kb-admin`)

## JWT contract

This skill always calls protected backend endpoints with:

```http
Authorization: Bearer <JWT>
```

JWT is obtained and refreshed by the shared auth scripts (vendored at `scripts/_lib/`; canonical copies in the `role-auth` skill). Resolution order: `REQUEST_SCRIPT` env override → vendored `scripts/_lib/` copy → `../../role-auth/scripts/` (monorepo layout).

Environment variables (`BASE_URL`, `API_KEY`, TLS options) must be **exported** — scripts spawn child processes that only inherit exported vars.

If a protected call returns `AUT-ERR-401`, `role-request.sh` re-authenticates once and retries the request.

## Prerequisites

1. `role-auth` skill is available in the same `agent-skills/` directory.
2. `BASE_URL` and `API_KEY` are configured in local environment.
3. `curl` and `jq` are available.

## Script map

- `scripts/kb-access-get-module.sh`
- `scripts/kb-library-list.sh`
- `scripts/kb-library-shelf-add.sh <tree_id>`
- `scripts/kb-library-shelf-remove.sh <tree_id>`
- `scripts/kb-trees-list.sh [shelf|accessible]`
- `scripts/kb-history-list.sh --tree-id <uuid> [--folder-id <uuid>]`
- `scripts/kb-history-list.sh --article-id <uuid>`
- `scripts/kb-history-list.sh` also accepts `[--limit N] [--before-at ISO] [--before-id UUID]` on either form
- `scripts/kb-trees-reorder.sh <payload.json>`
- `scripts/kb-article-types-list.sh`
- `scripts/kb-articles-list-published.sh`
- `scripts/kb-articles-get.sh <article_id>`
- `scripts/kb-articles-related-get.sh <article_id>`
- `scripts/kb-search-query.sh <query>`
- `scripts/kb-favorites-list.sh`
- `scripts/kb-articles-favorite-add.sh <article_id>`
- `scripts/kb-articles-favorite-remove.sh <article_id>`

## Usage examples

```bash
bash scripts/kb-access-get-module.sh
bash scripts/kb-library-list.sh
bash scripts/kb-library-shelf-add.sh "e1b10000-0000-4000-8000-000000000001"
bash scripts/kb-trees-list.sh
bash scripts/kb-trees-list.sh accessible
bash scripts/kb-trees-reorder.sh ./payloads/reorder-shelf.json
bash scripts/kb-history-list.sh --tree-id "e1b10000-0000-4000-8000-000000000001"
bash scripts/kb-history-list.sh --tree-id "e1b10000-0000-4000-8000-000000000001" --folder-id "f0lder00-0000-4000-8000-000000000001"
bash scripts/kb-history-list.sh --article-id "b7de7d69-7e16-4f45-a389-8e7f45e4587e" --limit 30
bash scripts/kb-articles-list-published.sh --query "backup"
bash scripts/kb-articles-get.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e"
bash scripts/kb-articles-related-get.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e"
bash scripts/kb-articles-favorite-add.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e"
bash scripts/kb-articles-favorite-remove.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e"
bash scripts/kb-search-query.sh "incident runbook"
```

Shelf reorder payload example (`reorder-shelf.json`):

```json
{
  "treeIds": ["tree-uuid-1", "tree-uuid-2", "tree-uuid-3"]
}
```

Every id must already be on the caller's shelf; order in the array becomes the new shelf order.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)

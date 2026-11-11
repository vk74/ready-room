# evi Agent Skills

<!--
version: 0.27.4
Short description: Index of external vendor-neutral evi agent skills.
File: README.md
Last release: 0.27.4

Changes in v0.27.4:
- Sparse-checkout and raw-download examples use the public distribution repository vk74/ready-room.

Changes in v0.27.3:
- Marked role-kb-reader and role-kb-author last release 0.27.3 for the shared fileImage and mermaidDiagram object-container attributes (layout, align, width).
- Documented collapsible document sections and the text-color palette (including light blue and light grey) in role-kb-reader and role-kb-author.

Changes in v2.5.3:
- Skills table column is `last_release`; every listed skill is marked 0.26.2.

Changes in v2.5.2:
- Renamed all skill directories evi-* → role-*; shared scripts and env vars dropped the EVI_ prefix (BASE_URL, API_KEY, …).

Changes in v2.5.1:
- Renamed bot API key format prefix from evik_ to bkey_ in setup examples.

Changes in v2.5.0:
- Synced KB skills to evi 0.23.11: admin tree .kbz export/import, reader
  history and favorites, trees list scope shelf|accessible, library
  canExport, and content_version on tree/node/article responses.
- Updated KB skill table last_evi_release markers to 0.23.11.
- Expanded testing checklist with accessible trees, history, favorites,
  export, and inspect-then-commit import.

Changes in v2.4.0:
- Synced Admin Products role skills to evi 0.21.7: catalog visibility via
  statusCode=active plus placement, scalar memberLineId/catalogSectionId,
  catalog-section-options and bulk status/placement/card/regions/specialists.
- Updated products endpoint index and last_evi_release markers to 0.21.7.

Changes in v2.3.0:
- Updated KB skills for evi 0.21.2: entityLink/externalLink/mermaidDiagram
  content model, related-reconcile workflow, core-link-preview helper.
- Updated role-attachments last_evi_release and non-file node clarification.
- Expanded testing checklist with reconcile and link-preview smoke steps.

Changes in v2.2.0:
- Updated products role skills for product-line CRUD/membership operations and
  product `memberLineIds` membership updates.
- Updated KB reader/author/admin skills for related articles and protected
  system KB tree delete behavior.
- Marked updated product and KB skills as last evi release `0.21.1`.

Changes in v2.1.0:
- Updated Admin Products role skills (auditor/editor/specialist/admin) to the
  option-pairs contract with `relationKind` (`optional|required|incompatible`).
- Marked only updated Admin Products skills as last evi release `0.20.20`.

Changes in v2.0.0:
- KB Library support in role-kb-reader (library list, shelf add/remove, shelf reorder).
- Moved personal shelf reorder from role-kb-admin to role-kb-reader (evi 0.20.17).
- Added last_evi_release column to skills table; all skills marked 0.20.17.
- Expanded testing checklist with KB Library scripts.

Changes in v1.9.0:
- Added explicit host reload note: after adding/changing external skill dirs,
  restart skill resolution via /reset or by starting a new agent session.
- Added Admin Products endpoint index (route-to-skill matrix) so agents can
  discover the right skill without endpoint brute-force guessing.

Changes in v1.8.0:
- Reworked Admin Products external skills to strict 1:1 role mapping:
  role-admin-products-auditor, role-admin-products-editor,
  role-admin-products-specialist, role-admin-products-admin.
- Removed role-admin-products-reader naming and updated role composition,
  testing checklist, and directory layout for standalone role skills.

Changes in v1.7.0:
- Added role-admin-products-admin skill (clear-all and AdminProducts settings).
- Completed Admin Products role composition; updated testing checklist and layout.

Changes in v1.6.0:
- Added role-admin-products-editor skill (write Admin Products operations).
- Updated Admin Products role composition and testing checklist.

Changes in v1.5.0:
- Added role-admin-products-reader skill (read-only Admin Products access).
- Added Admin Products role composition guidance.

Changes in v1.4.0:
- Credentials section rewritten around role-setup.sh: one-time persisted
  configuration in ${AGENT_HOME:-$HOME/.agent-skills}/role.env with automatic
  fallback in the auth scripts (fresh shells no longer lose settings).
- Vendored _lib now also carries role-setup.sh.

Changes in v1.3.0:
- Skills are now self-contained: role-auth helper scripts are vendored into
  scripts/_lib of every dependent skill (resolution chain: REQUEST_SCRIPT
  env override -> vendored copy -> monorepo path).
- Added tools/ (sync-lib.sh, pack-skills.sh) and dist/ (base64 bundles +
  sha256 manifests) for content-filter-safe distribution to agents.
- Added "Installing via an agent" and integrity verification sections.
- Documented that BASE_URL / API_KEY must be exported.

Changes in v1.2.0:
- Added standalone role-attachments skill for reusable /api/fs file lifecycle.
- Added composition guidance for KB author workflows with attachments.
- Expanded smoke checklist and directory layout with role-attachments.

Changes in v1.1.0:
- Removed host-specific wording and configuration examples.
- Added the role-kb-reader skill to the public skills list.
- Added the role-kb-author skill (strict-author scope) to the public skills list.
- Added the role-kb-admin skill with admin-only KB governance methods.
- Added role composition guidance for reader/author/admin bundles.

Changes in v1.0.0:
- Initial agent-skills index and setup guide.
-->

Skills for external AI agents and bots that integrate with evi via the public API. They follow the [Agent Skills](https://agentskills.io/specification) open standard and work with compatible skill hosts.

This directory lives at the repository root (`agent-skills/`) so hosts can point external skill directories directly at a GitHub clone or sparse checkout.

## Available skills

| Skill | Last release | Description |
|-------|--------------|-------------|
| [role-auth](role-auth/SKILL.md) | 0.26.2 | Exchange a bot API key for a short-lived Bearer JWT (required before any other evi API call) |
| [role-attachments](role-attachments/SKILL.md) | 0.26.2 | Module-agnostic file lifecycle over `/api/fs`: upload-request, presigned PUT, confirm, list by entity, and delete |
| [role-kb-reader](role-kb-reader/SKILL.md) | 0.27.3 | KB read/search, personal shelf (`canExport`), trees scope shelf or accessible, history, favorites, related-article lookup, `content_version`, rich content (entityLink, externalLink, mermaid) |
| [role-kb-author](role-kb-author/SKILL.md) | 0.27.3 | Author-level KB write: nodes, articles, `content_version` on responses, inline article links, related reconcile (including after admin import), link preview |
| [role-kb-admin](role-kb-admin/SKILL.md) | 0.26.2 | Admin-only KB governance: tree lifecycle, .kbz export/import, owner changes, KB tree ACL management, protected system-tree delete behavior |
| [role-admin-products-auditor](role-admin-products-auditor/SKILL.md) | 0.26.2 | Auditor: read products/lines (status + placement fields), catalog-section-options, AdminProducts settings read |
| [role-admin-products-editor](role-admin-products-editor/SKILL.md) | 0.26.2 | Editor: read-all + update/import + placement/status/bulk helpers for products and lines |
| [role-admin-products-specialist](role-admin-products-specialist/SKILL.md) | 0.26.2 | Specialist: read-own + create/update/assign-owner-own + placement/status/bulk helpers |
| [role-admin-products-admin](role-admin-products-admin/SKILL.md) | 0.26.2 | Admin: full adminProducts scope including placement/status/bulk, clear-all, settings |

Each skill's `SKILL.md` frontmatter includes `last_release` — the evi app
release when that skill was last updated. Bump it whenever the skill changes
ship with an evi release. `role-kb-reader` and `role-kb-author` are marked
`0.27.3`. The other skills in this index are marked `0.26.2`.

More skills will be added here as separate directories.

## Role composition

- **Reader role**: `role-kb-reader`
- **Author role**: `role-kb-reader` + `role-kb-author`
- **Author with attachments**: `role-kb-reader` + `role-kb-author` + `role-attachments`
- **Admin role**: `role-kb-reader` + `role-kb-author` + `role-kb-admin`

This model keeps scopes unique and avoids method/script duplication across role skills.

### Admin Products role composition

- **Products auditor**: `role-admin-products-auditor`
- **Products editor**: `role-admin-products-editor`
- **Products specialist**: `role-admin-products-specialist`
- **Products specialist with images**: `role-admin-products-specialist` + `role-attachments`
- **Products admin**: `role-admin-products-admin`

### Admin Products endpoint index

Route-to-skill coverage matrix:

| Endpoint | Auditor | Editor | Specialist | Admin |
|---|---|---|---|---|
| `GET /api/admin/products/fetch-all-products` | yes | yes | yes | yes |
| `GET /api/admin/products/fetch` | yes | yes | yes | yes |
| `GET /api/admin/products/search` | yes | yes | yes | yes |
| `GET /api/admin/products/fetch-options` | yes | yes | yes | yes |
| `GET /api/admin/products/fetch-statuses` | yes | yes | yes | yes |
| `GET /api/admin/products/catalog-section-options` | yes | yes | yes | yes |
| `GET /api/admin/products/:productId/regions` | yes | yes | yes | yes |
| `PUT /api/admin/products/:productId/regions` | no | yes | yes | yes |
| `GET /api/admin/products/:productId/linked-kb-articles` | yes | yes | yes | yes |
| `PUT /api/admin/products/:productId/linked-kb-articles` | no | yes | yes | yes |
| `POST /api/admin/products/read-product-option-pairs` | yes | yes | yes | yes |
| `POST /api/admin/products/count-product-option-pairs` | yes | yes | yes | yes |
| `POST /api/admin/products/create-product-option-pairs` | no | yes | yes | yes |
| `POST /api/admin/products/update-product-option-pairs` | no | yes | yes | yes |
| `POST /api/admin/products/delete-product-option-pairs` | no | yes | yes | yes |
| `GET /api/admin/products/taxable-categories/by-region/:regionId` | yes | yes | yes | yes |
| `POST /api/admin/products/create` | no | no | yes | yes |
| `POST /api/admin/products/update` | no | yes | yes | yes |
| `POST /api/admin/products/import` | no | yes | no | yes |
| `POST /api/admin/products/delete` | no | no | no | yes |
| `POST /api/admin/products/assign-owner` | no | no | yes (own) | yes (all) |
| `POST /api/admin/products/bulk-status` | no | yes | yes (own) | yes |
| `POST /api/admin/products/bulk-placement` | no | yes | yes (own) | yes |
| `POST /api/admin/products/bulk-product-card` | no | yes | yes (own) | yes |
| `POST /api/admin/products/bulk-regions` | no | yes | yes (own) | yes |
| `POST /api/admin/products/bulk-specialists` | no | yes | yes (own) | yes |
| `GET /api/admin/product-lines/fetch-all` | yes | yes | yes (own) | yes |
| `GET /api/admin/product-lines/fetch` | yes | yes | yes (own) | yes |
| `GET /api/admin/product-lines/search` | yes | yes | yes | yes |
| `POST /api/admin/product-lines/create` | no | no | yes | yes |
| `POST /api/admin/product-lines/update` | no | yes | yes (own) | yes |
| `POST /api/admin/product-lines/delete` | no | no | no | yes |
| `POST /api/admin/product-lines/assign-owner` | no | no | yes (own) | yes (all) |
| `POST /api/admin/product-lines/bulk-status` | no | yes | yes (own) | yes |
| `POST /api/admin/product-lines/bulk-placement` | no | yes | yes (own) | yes |
| `POST /api/admin/products/clear-all/start` | no | no | no | yes |
| `GET /api/admin/products/clear-all/status/:operationId` | no | no | no | yes |
| `GET /api/core/settings` | yes (`adminProducts.*` read) | no | no | yes |
| `POST /api/admin/settings/update` (`AdminProducts` section) | no | no | no | yes |

## Connect skills to your host

### From a local clone

1. Clone the evi only this folder
2. In your agent host settings, add this directory as an external skills directory:

```yaml
skills:
  external_dirs:
    - /path/to/evi/agent-skills
```

### From GitHub (sparse checkout)

Minimal checkout of skills only:

```bash
git clone --filter=blob:none --sparse https://github.com/vk74/ready-room.git evi-skills
cd evi-skills
git sparse-checkout set agent-skills
```

Then configure your host to load:

```yaml
skills:
  external_dirs:
    - /path/to/evi-skills/agent-skills
```

Important: many hosts cache external skills for the current run. After adding
or changing `external_dirs`, force a skill reload with `/reset` or start a new
agent session, otherwise newly added skills may not resolve.

Paths can use `~` expansion and `${VAR}` substitution when supported by the host runtime.

### Installing via an agent (content-filter-safe)

Some agent runtimes filter or rewrite file contents written through their
file APIs: `$VAR`, `${...}` and `$(...)` patterns get masked, which silently
corrupts bash scripts. **Never let an agent retype or reconstruct these
scripts.** Install them so the bytes never pass through the agent's
file-write filter:

1. **Preferred — download directly** (bytes go disk-to-disk):

   ```bash
   # sparse checkout (see above), or per skill:
   curl -fsSL https://raw.githubusercontent.com/vk74/ready-room/main/agent-skills/role-kb-reader/scripts/kb-trees-list.sh -o kb-trees-list.sh
   ```

2. **Fallback — base64 bundle.** `dist/` contains one self-extracting bundle
   per skill. Fetch or paste the `.b64` text (it contains no `$` characters,
   so content filters leave it intact), then decode:

   ```bash
   base64 -d < role-kb-reader.tar.gz.b64 | tar xz
   ```

3. **Verify integrity after install** with the per-skill manifest from
   `dist/<skill>.sha256` (paths are relative to the skill directory):

   ```bash
   cd role-kb-reader && shasum -a 256 -c role-kb-reader.sha256
   ```

   If any file fails, the contents were mangled in transit — re-download.
   Do not hand-edit the scripts to "fix" them.

Each skill is self-contained: the shared auth helpers (`role-auth.sh`,
`role-request.sh`, `role-setup.sh`) are vendored into `scripts/_lib/` of every dependent skill,
so skills work in hosts that install each skill into its own directory
(no cross-skill relative paths required). Scripts resolve the auth wrapper
in this order:

1. `REQUEST_SCRIPT` environment variable (explicit override)
2. `scripts/_lib/role-request.sh` (vendored copy)
3. `../../role-auth/scripts/role-request.sh` (monorepo layout)

Maintainers: after changing any script under `role-auth/scripts/`, run
`tools/sync-lib.sh` to refresh vendored copies, then `tools/pack-skills.sh`
to regenerate `dist/`. `tools/sync-lib.sh --check` verifies sync status.

### Credentials

Issue the API key once in evi Admin → Org → Bot Editor → Credentials. Never paste it into chat.

**Recommended: persist the settings once** with the setup script. It writes
`${AGENT_HOME:-$HOME/.agent-skills}/role.env` (mode 600, path overridable via
`ENV_FILE`) and verifies the credentials. The auth scripts read this file
automatically whenever `BASE_URL` / `API_KEY` are missing from the
environment — so hosts that run every tool call in a fresh shell session keep
working with no re-exports:

```bash
bash role-auth/scripts/role-setup.sh --base-url https://your-evi-host --api-key bkey_<key_id>_<secret>
# optional: --tls-insecure | --ca-cert-file /path/ca.pem | --no-verify
```

Alternative: classic exports (current shell only). The skill scripts spawn
child processes (`bash script.sh`), which only inherit **exported** variables:

```bash
export BASE_URL=https://your-evi-host
export API_KEY=bkey_<key_id>_<secret>
```

Real environment variables always take precedence over `role.env` values.

## Testing checklist

1. Create a bot account in evi and issue an API key (copy plaintext once).
2. Run `role-auth/scripts/role-setup.sh --base-url ... --api-key ...` (or export `BASE_URL` / `API_KEY`).
3. Load this folder as an external skills directory in your host.
4. Run `role-auth/scripts/role-auth.sh` and confirm successful token exchange.
5. Verify auth with `role-auth/scripts/role-request.sh GET /api/auth/permissions`.
6. Verify reader skill with `role-kb-reader/scripts/kb-library-list.sh`.
7. Verify reader shelf with `role-kb-reader/scripts/kb-library-shelf-add.sh <tree_id>`.
8. Verify reader shelf reorder with `role-kb-reader/scripts/kb-trees-reorder.sh <payload.json>`.
9. Verify reader trees with `role-kb-reader/scripts/kb-trees-list.sh`.
10. Verify reader trees accessible with `role-kb-reader/scripts/kb-trees-list.sh accessible`.
11. Verify reader history with `role-kb-reader/scripts/kb-history-list.sh --tree-id <tree_id>`.
12. Verify reader related articles with `role-kb-reader/scripts/kb-articles-related-get.sh <article_id>`.
13. Verify reader favorites with `role-kb-reader/scripts/kb-articles-favorite-add.sh <article_id>` then `role-kb-reader/scripts/kb-articles-favorite-remove.sh <article_id>`.
14. Verify author skill with `role-kb-author/scripts/kb-nodes-create.sh <payload.json>`.
15. Verify author related links with `role-kb-author/scripts/kb-articles-related-add.sh <article_id> <target_article_id>`.
16. Verify author related reconcile with `role-kb-author/scripts/kb-articles-related-reconcile.sh <article_id> <content_payload.json>` after a content PUT that includes `entityLink` nodes.
17. Optional: verify link preview with `role-kb-author/scripts/core-link-preview.sh <url>`.
18. Verify attachments skill with `role-attachments/scripts/attachments-upload-flow.sh kb_article <entity_uuid> <file_path>`.
19. Verify admin skill with `role-kb-admin/scripts/kb-trees-create.sh <payload.json>`.
20. Verify admin export with `role-kb-admin/scripts/kb-trees-export.sh <tree_id>`.
21. Verify admin import inspect with `role-kb-admin/scripts/kb-trees-import.sh <file.kbz> --inspect-only`, then commit with `role-kb-admin/scripts/kb-trees-import-commit.sh <session_id>`.
22. Verify products auditor skill with `role-admin-products-auditor/scripts/admin-product-lines-list.sh`.
23. Verify products catalog-section-options with `role-admin-products-admin/scripts/admin-products-catalog-section-options.sh`.
24. Verify products specialist skill with `role-admin-products-specialist/scripts/admin-product-lines-create.sh <payload.json>`.
25. Verify products editor skill with `role-admin-products-editor/scripts/admin-product-lines-update.sh <payload.json>`.
26. Verify products bulk-status with `role-admin-products-editor/scripts/admin-products-bulk-status.sh <payload.json>`.
27. Verify products admin skill with `role-admin-products-admin/scripts/admin-products-settings-get.sh` (requires `adminProducts:settings:read:all` or update permission).
28. After skill changes: run `bash agent-skills/tools/sync-lib.sh --check` and verify `dist/*.sha256` manifests match regenerated bundles. Do not reconstruct scripts; install from download or `dist/`.
29. Optional: force an expired token and verify auto re-auth on next request.

## Directory layout

Each skill is a folder with a required `SKILL.md` plus optional `scripts/`, `references/`, and `assets/`. Dependent skills vendor the auth helpers in `scripts/_lib/`:

```text
agent-skills/
├── README.md
├── tools/
│   ├── sync-lib.sh        # refresh vendored _lib copies (--check to verify)
│   └── pack-skills.sh     # regenerate dist/ bundles + sha256 manifests
├── dist/
│   ├── <skill>.tar.gz.b64 # base64 bundle per skill (content-filter-safe)
│   └── <skill>.sha256     # per-skill integrity manifest
├── role-auth/
│   ├── SKILL.md
│   ├── scripts/           # canonical role-auth.sh + role-request.sh + role-setup.sh
│   └── references/
├── role-attachments/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── _lib/          # vendored auth helpers
│   └── references/
├── role-kb-reader/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── _lib/
│   └── references/
├── role-kb-author/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── _lib/
│   └── references/
├── role-kb-admin/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── _lib/
│   └── references/
├── role-admin-products-auditor/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── _lib/
│   └── references/
├── role-admin-products-editor/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── _lib/
│   └── references/
├── role-admin-products-specialist/
│   ├── SKILL.md
│   ├── scripts/
│   │   └── _lib/
│   └── references/
└── role-admin-products-admin/
    ├── SKILL.md
    ├── scripts/
    │   └── _lib/
    └── references/
```

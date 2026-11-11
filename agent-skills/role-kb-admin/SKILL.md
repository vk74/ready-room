---
name: role-kb-admin
description: >
  Knowledge Base admin skill for evi. Covers admin-only governance operations
  when a bot must manage tree lifecycle, ownership, per-tree ACL, or
  export/import a knowledge-base tree as a content-only .kbz package.
last_release: "0.27.2"
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

# role-kb-admin

<!--
version: 0.27.2
Short description: Admin-only KB governance methods with no overlap with reader/author.
File: SKILL.md
Last release: 0.27.2

Changes in v0.27.2:
- Export note names role-request for the wrapper that does not expose Content-Disposition.

Changes in v0.26.2:
- Renamed frontmatter key `last_evi_release` to `last_release` and set it to 0.26.2.

Changes in v0.24.4:
- No .kbz package size cap. The import helper sends 1.4 MiB chunks at 90 per minute and retries HTTP 429 after Retry-After.
- Browser download uses the export ticket (KB-SUC-031). Bot export stays Bearer GET with curl -o and no client time limit.
- last_evi_release is 0.24.4.

Changes in v0.23.12:
- ACL update payload uses audience (custom, staff, registered, public) instead of is_public.
- Added kb-settings-get.sh and kb-settings-update.sh for KB module settings and file quotas.
- Auditor role loads role-kb-reader only.

Changes in v1.4.2:
- Renamed skill directory and shared scripts from evi-* to role-*; dropped EVI_ prefix from env vars (BASE_URL, API_KEY, …).

Changes in v1.4.1:
- Renamed API key format prefix from evik_ to bkey_ in API_KEY prompt.
- Updated last_evi_release marker to 0.23.12.

Changes in v1.4.0:
- Added KB tree .kbz export (`kb.trees.export`) and chunked import
  (begin/chunk/inspect/commit/cancel plus `kb-trees-import.sh` helper).
- `--inspect-only` adds `data.session_id` to the printed inspect envelope.
- Updated last_evi_release marker for evi 0.23.11.

Changes in v1.3.1:
- Documented related-link cleanup on article/tree delete (unchanged backend
  behavior; relevant for agents using inline entityLink workflows).
- Updated last_evi_release marker for evi 0.21.2.

Changes in v1.3.0:
- Documented system KB tree delete protection for the built-in users/admins
  trees; protected deletes return 403 `KB-ERR-403`.
- Updated last_evi_release marker for evi 0.21.1.

Changes in v1.2.0:
- Removed kb.trees.reorder (personal shelf order — use role-kb-reader since evi 0.20.17).
- Documented short_description in tree translations and create auto-adds to creator shelf.
- Added last_evi_release frontmatter marker.

Changes in v1.1.0:
- Skill is now self-contained: auth helpers vendored in scripts/_lib with
  REQUEST_SCRIPT override support; role-auth co-location no longer required.
- Documented that environment variables must be exported.

Changes in v1.0.0:
- Initial KB admin skill with unique admin-only endpoints.
- Added tree governance and ACL management method map.
- Added role-composition guidance and explicit non-overlap rules.
-->

KB admin skill for governance operations that should stay separate from reader and author scopes.

## Role composition

- For **KB reader** role: load `role-kb-reader`.
- For **KB auditor** role: load `role-kb-reader` only. Auditor can read every tree, including history and unpublished articles. This skill's create, export, import, and ACL calls return `KB-ERR-403` or `AZN-ERR-403` for that role.
- For **KB author** role: load `role-kb-reader` + `role-kb-author`.
- For **KB admin** role: load `role-kb-reader` + `role-kb-author` + `role-kb-admin`.

This keeps each skill unique and prevents endpoint/script duplication across roles.

Personal shelf reorder (`kb.trees.reorder`) lives in `role-kb-reader`, not here.

System tree delete protection: `kb.trees.delete` cannot delete the built-in
system tree `e1b10000-0000-4000-8000-000000000001` ("HELP KB"). The backend
returns HTTP 403 with `KB-ERR-403` even for owners or callers with
`kb:trees:delete:all`.

Related-link cleanup: deleting an article (`role-kb-author` →
`kb.articles.deleteEverywhere`) removes related links where that article is
source or target. Deleting a KB tree (`kb.trees.delete`) removes related links
involving articles in that tree. No extra agent steps are required beyond the
delete call itself.

## Scope (admin-only)

Included methods:

- `kb.trees.create` -> `POST /api/kb/trees` (auto-adds new tree to creator's shelf)
- `kb.trees.update` -> `PUT /api/kb/trees/:id` (includes `short_description` in translations)
- `kb.trees.delete` -> `DELETE /api/kb/trees/:id`
- `kb.trees.changeOwner` -> `POST /api/kb/trees/:id/change-owner`
- `kb.trees.export` -> `GET /api/kb/trees/:id/export` (bot: Bearer, no ticket)
- `kb.trees.import.begin` -> `POST /api/kb/trees/import/begin`
- `kb.trees.import.chunk` -> `PUT /api/kb/trees/import/:sessionId/chunk`
- `kb.trees.import.inspect` -> `POST /api/kb/trees/import/:sessionId/inspect`
- `kb.trees.import.commit` -> `POST /api/kb/trees/import/:sessionId/commit`
- `kb.trees.import.cancel` -> `DELETE /api/kb/trees/import/:sessionId`
- `kb.acl.fetch` -> `GET /api/core/visibility/fetch` (entity_type=`kb_tree`, action=`read|update`)
- `kb.acl.update` -> `POST /api/core/visibility/update` (entity_type=`kb_tree`, action=`read|update`, body field `audience`)
- `kb.settings.get` -> `GET /api/core/settings` (returns `KnowledgeBase.Fs.Quotas` only)
- `kb.settings.update` -> `POST /api/admin/settings/update` (sections `KnowledgeBase` and `KnowledgeBase.Fs.Quotas`)

Explicitly excluded:

- Reader methods (`GET /api/kb/*` read/search/list flows, KB Library shelf navigation)
- Author methods (node/article write routes)
- Personal shelf reorder (`PUT /api/kb/trees/reorder` — see `role-kb-reader`)
- Generic non-KB module operations

## JWT contract

Every protected backend request is executed with:

```http
Authorization: Bearer <JWT>
```

JWT lifecycle is delegated to the shared auth scripts (vendored at `scripts/_lib/`; canonical copies in the `role-auth` skill). Resolution order: `REQUEST_SCRIPT` env override → vendored `scripts/_lib/` copy → `../../role-auth/scripts/` (monorepo layout).

Environment variables (`BASE_URL`, `API_KEY`, TLS options) must be **exported** — scripts spawn child processes that only inherit exported vars.

## Script map

- `scripts/kb-trees-create.sh <payload.json>`
- `scripts/kb-trees-update.sh <tree_id> <payload.json>`
- `scripts/kb-trees-delete.sh <tree_id>`
- `scripts/kb-trees-change-owner.sh <tree_id> <new_owner_user_id>`
- `scripts/kb-trees-export.sh <tree_id> [out.kbz]`
- `scripts/kb-trees-import-begin.sh`
- `scripts/kb-trees-import-chunk.sh <session_id> <offset> <chunk.bin>`
- `scripts/kb-trees-import-inspect.sh <session_id>`
- `scripts/kb-trees-import-commit.sh <session_id>`
- `scripts/kb-trees-import-cancel.sh <session_id>`
- `scripts/kb-trees-import.sh <file.kbz> [--inspect-only]`
- `scripts/kb-acl-fetch.sh <tree_id> [read|update]`
- `scripts/kb-acl-update.sh <tree_id> <read|update> <payload.json>`
- `scripts/kb-settings-get.sh`
- `scripts/kb-settings-update.sh <sectionPath> <settingName> <jsonValue>`

Export example (default output `kb-tree.kbz` in the current directory; role-request does not expose `Content-Disposition`, so the server-suggested filename is not used):

```bash
scripts/kb-trees-export.sh 11111111-1111-4111-8111-111111111111
scripts/kb-trees-export.sh 11111111-1111-4111-8111-111111111111 ops-runbooks.kbz
```

On success the export script prints `{"path":"...","bytes":N}` to stdout (never JWT or API keys). It passes curl `-o` and does not set a client time limit. It does not request a download ticket.

Browser download is separate: `POST /api/kb/trees/:id/export/ticket` returns `KB-SUC-031` with `{ticket, expires_in_seconds}` (120). The browser then calls `GET /api/kb/trees/:id/export?ticket=` with no Bearer. Bot export stays the Bearer GET above.

Import helper example (always inspects; omit `--inspect-only` to commit):

```bash
scripts/kb-trees-import.sh ./ops-runbooks.kbz --inspect-only
scripts/kb-trees-import.sh ./ops-runbooks.kbz
```

The helper only calls the primitive scripts in this directory. It does not reject a package for size. Chunks stay 1.4 MiB (`1468006` bytes), under the 1.5 MiB chunk max. It starts a chunk at most 90 times per minute (60000/90 ms between starts) so it stays under the standard 120 requests/minute limiter. HTTP 429 is not success: it waits `Retry-After` seconds and retries that chunk up to 3 times. `--inspect-only` prints the inspect envelope with `data.session_id` added so you can later run `kb-trees-import-commit.sh` or `kb-trees-import-cancel.sh`. Session TTL is 30 minutes.

## Export / import notes

- The `.kbz` package is **content-only**: tree copy, folders, articles, and files. It does not include ACL, history, favorites, or shelf state. There is no package size cap.
- Import always creates a **new private tree** owned by the caller and adds it to the importer's personal shelf. No ACL rows are copied — configure visibility afterwards with `kb-acl-fetch` / `kb-acl-update`.
- System trees are not exportable. Export of HELP KB `e1b10000-0000-4000-8000-000000000001` returns 403 `KB-ERR-403` even for owners or callers with `kb:trees:update:all`. Export otherwise requires `kb:trees:update:all` or tree ownership. Import routes require `kb:trees:update:all`.
- After import the related-article table is empty until an author runs related-link reconcile (`role-kb-author`).
- Always inspect before commit. The helper always inspects; `--inspect-only` stops after inspect and leaves the session open until TTL or cancel.

## ACL payload for `kb-acl-update.sh`

Payload file must contain `audience`. The API ignores `is_public`. After a successful update, run `kb-acl-fetch.sh` and read `data.audience`. `VIS-SUC-002` alone does not prove the mode changed.

`audience` values:

- `custom` — only the allow lists, minus the deny lists
- `staff` — callers marked staff
- `registered` — any authenticated active account
- `public` — no login required

```json
{
  "audience": "custom",
  "allowed_groups": [],
  "allowed_users": [],
  "denied_groups": [],
  "denied_users": []
}
```

## KB module settings

`kb-settings-get.sh` prints file quotas from `data.settings["KnowledgeBase.Fs.Quotas"]` (`entity.max.bytes`, `entity.max.count`, `user.per.day.max.bytes`, `module.total.storage.max.bytes`). `0` on a byte quota means unlimited.

`GET /api/core/settings` does not return the public module flags `KnowledgeBase` / `allow.all.registered.to.view.module`, `allow.all.registered.to.create.trees`, or `allowed.languages`. Do not read them from that response and write the result back: a `null` value is `ADM_STG-ERR-001`. The written value is `data.value` on `ADM_STG-SUC-001`.

```bash
bash scripts/kb-settings-update.sh KnowledgeBase allow.all.registered.to.create.trees false
bash scripts/kb-settings-update.sh KnowledgeBase.Fs.Quotas entity.max.count 250
```

`kb-settings-update.sh` accepts only those two section paths. `<jsonValue>` is raw JSON (`true`, `false`, `250`, `["english","russian"]`).

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Reader skill](../role-kb-reader/SKILL.md)
- [Author skill](../role-kb-author/SKILL.md)

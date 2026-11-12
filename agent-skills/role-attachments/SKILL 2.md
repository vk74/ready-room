---
name: role-attachments
description: >
  Universal evi attachments/file workflow skill. Covers /api/fs lifecycle:
  upload-request, direct PUT to presigned URL, confirm, list by entity, and
  delete by file id. Use when an external agent needs reusable file handling
  for KB or future modules without duplicating module-specific CRUD logic.
last_release: "0.26.2"
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

# role-attachments

<!--
version: 0.26.2
Short description: Reusable file lifecycle over /api/fs for external agents.
File: SKILL.md
Last release: 0.26.2

Changes in v0.26.2:
- Renamed frontmatter key `last_evi_release` to `last_release` and set it to 0.26.2.

Changes in v0.23.12:
- Added assets/test-attach.pdf, a one-page sample (text, table, image) for practicing the upload flow.
- Renamed skill directory and shared scripts from evi-* to role-*; dropped EVI_ prefix from env vars (BASE_URL, API_KEY, …).
- Renamed API key format prefix from evik_ to bkey_ in API_KEY prompt.
- Updated last_evi_release marker to 0.23.12.

Changes in v1.1.2:
- Clarified that entityLink, externalLink, and mermaidDiagram rich-editor nodes
  do not use /api/fs; only fileImage and attachment_file_ids do.
- Cross-reference to role-kb-author content model for KB inline links and diagrams.
- Updated last_evi_release marker for evi 0.21.2.

Changes in v1.1.1:
- Added last_evi_release frontmatter marker (skills pack sync at evi 0.20.17).

Changes in v1.1.0:
- Skill is now self-contained: auth helpers vendored in scripts/_lib with
  REQUEST_SCRIPT override support; role-auth co-location no longer required.
- Added content-type guidance for text-based files (.md/.csv/.json) and a
  pointer to the expanded FILE-ERR code list in the API contract.
- Documented that environment variables must be exported.

Changes in v1.0.0:
- Initial standalone attachments skill with universal /api/fs method map.
- Added script map for upload-request, presigned PUT, confirm, list, delete.
- Added KB recipe for authoritative attachment_file_ids update flow.
-->

Reusable file/attachments skill for external agents and bots.

This skill is module-agnostic: it handles the universal `/api/fs` lifecycle and
can be composed with KB or any future module skill.

## Role composition

- For KB read-only use: `role-kb-reader`
- For KB write use without files: `role-kb-reader` + `role-kb-author`
- For KB write with attachments: `role-kb-reader` + `role-kb-author` + `role-attachments`

## Scope

Included methods:

- `fs.uploadRequest` -> `POST /api/fs/upload-request`
- `fs.uploadPut` -> direct `PUT <presigned upload_url>` (storage URL, not `/api/*`)
- `fs.uploadConfirm` -> `POST /api/fs/:file_id/confirm`
- `fs.files.listByEntity` -> `GET /api/fs?entity_type=&entity_id=`
- `fs.files.deleteOne` -> `DELETE /api/fs/:file_id`
- `fs.uploadFlow` -> convenience composition of request + put + confirm

Important contract:

- `/api/fs` no longer accepts or returns a `purpose` filter.
- File ownership/read/write authorization is delegated to the module that
  registered `entity_type` in backend fs registry.

Explicitly excluded:

- KB tree/node/article CRUD routes
- Favorites or ACL routes
- Any module-specific business workflow beyond generic file lifecycle

Rich-editor note (KB and future modules):

- Only `fileImage` nodes and `attachment_file_ids` interact with `/api/fs`.
- `entityLink`, `externalLink`, and `mermaidDiagram` nodes are stored in
  ProseMirror JSON and do not create file records. See `role-kb-author`
  references/api-contract.md for those node shapes.

## JWT contract

All `/api/fs` calls require:

```http
Authorization: Bearer <JWT>
```

JWT lifecycle is delegated to the shared auth scripts (vendored at
`scripts/_lib/role-auth.sh` and `scripts/_lib/role-request.sh`; the canonical
copies live in the `role-auth` skill). Resolution order: `REQUEST_SCRIPT`
env override → vendored `scripts/_lib/` copy → `../../role-auth/scripts/`
(monorepo layout).

Environment variables (`BASE_URL`, `API_KEY`, TLS options) must be
**exported** — scripts spawn child processes that only inherit exported vars.

## Script map

- `scripts/fs-upload-request.sh <entity_type> <entity_id> <file_path> [--content-type "<mime>"]`
- `scripts/fs-upload-put.sh <upload_url> <file_path> [headers.json]`
- `scripts/fs-upload-confirm.sh <file_id>`
- `scripts/fs-files-list.sh <entity_type> <entity_id>`
- `scripts/fs-file-delete.sh <file_id>`
- `scripts/attachments-upload-flow.sh <entity_type> <entity_id> <file_path> [--content-type "<mime>"]`

## Sample file

`assets/test-attach.pdf` is a one-page PDF (text, a table, and an embedded image) kept in this skill so an agent does not have to hunt for a local file. Declare `application/pdf`:

```bash
bash scripts/attachments-upload-flow.sh kb_article "<article_uuid>" \
  assets/test-attach.pdf --content-type "application/pdf"
```

## Generic usage

```bash
bash scripts/fs-upload-request.sh kb_article "<article_uuid>" ./files/runbook.pdf
# -> keep file_id + upload_url + headers from response

bash scripts/fs-upload-put.sh "<upload_url>" ./files/runbook.pdf ./headers.json
bash scripts/fs-upload-confirm.sh "<file_id>"
bash scripts/fs-files-list.sh kb_article "<article_uuid>"
```

Content-type tips:

- Declare an explicit catalog MIME type for text-based files:
  `--content-type "text/markdown"` for `.md`, `"text/csv"` for `.csv`,
  `"application/json"` for `.json`. The confirm step validates stored bytes
  against the declared type (text-like types match as a family — see
  [API contract](references/api-contract.md) for details and the full
  `FILE-ERR-*` code list, including confirm-stage `013/014/015`).

## KB recipe: update attachment_file_ids

When updating a KB article, use this sequence:

1. Upload and confirm each local file through this skill.
2. Collect confirmed ids into `newIds[]`.
3. Load current files for `entity_type=kb_article` and compute final
   authoritative set required by your workflow.
4. Send `attachment_file_ids` in `PUT /api/kb/articles/:id` via `role-kb-author`.

Example payload fragment for KB article update:

```json
{
  "attachment_file_ids": [
    "9bf31c7f-91cb-4d9e-bf79-5f8bbec8ed6b",
    "2ab0ae9a-5c58-4cb4-9d70-5888f08f7f1e"
  ]
}
```

Consumer-side convention:

- Field present = authoritative full replace: files not listed are scheduled
  for deletion. Include existing ids (from `fs-files-list.sh`) to keep them.
- Omit the field when you have no authoritative opinion — the server
  preserves all currently stored files.
- Send an empty array only when you intentionally want zero attachments.

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [KB author skill](../role-kb-author/SKILL.md)

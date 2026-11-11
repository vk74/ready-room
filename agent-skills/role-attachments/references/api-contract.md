# evi API contract - attachments

<!--
version: 1.2.2
Short description: Universal /api/fs contract for external attachment workflows.
File: api-contract.md
Last evi release: 0.23.12

Changes in v1.2.2:
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.

Changes in v1.2.1:
- Noted that entityLink, externalLink, mermaidDiagram do not use /api/fs.
- Updated Last evi release marker to 0.21.2.

Changes in v1.2.0:
- KB integration recipe now points to the role-kb-author
  kb-articles-attachments-add.sh preserve-and-add helper.

Changes in v1.1.0:
- Documented previously missing error codes FILE-ERR-013/014/015/016/020 with
  their meta payloads and handling guidance.
- Added content-type validation notes: declared vs stored vs sniffed type,
  text-like family acceptance (markdown/csv/json/rtf), and the requirement to
  declare a catalog MIME type explicitly for extension-less detection cases.
- Clarified that the KB integration recipe array is a full replace and how to
  preserve existing attachments.

Changes in v1.0.0:
- Initial attachments API contract reference for upload, confirm, list, resolve, delete.
- Added envelope examples and common FILE-ERR codes with practical handling notes.
- Added KB integration recipe for attachment_file_ids updates.
-->

Reference for `role-attachments`.

All protected routes below require:

```http
Authorization: Bearer <JWT>
```

## Response envelope

Success:

```json
{
  "success": true,
  "code": "FILE-SUC-001",
  "data": {}
}
```

Failure:

```json
{
  "success": false,
  "code": "FILE-ERR-006",
  "meta": {}
}
```

## Endpoints

### `POST /api/fs/upload-request` (`fs.uploadRequest`)

Example payload:

```json
{
  "entity_type": "kb_article",
  "entity_id": "5a1f3c42-84ba-4a53-b70e-4e8768db8aa5",
  "original_filename": "runbook.pdf",
  "content_type": "application/pdf",
  "declared_size_bytes": 248773
}
```

Success data shape:

```json
{
  "file_id": "3d9f2f61-c9af-4f91-8a6a-e38c5caefa13",
  "upload_url": "https://host/objects/...",
  "method": "PUT",
  "headers": {
    "Content-Type": "application/pdf"
  },
  "expires_in_seconds": 300,
  "storage_key": "..."
}
```

### Direct `PUT <upload_url>` (`fs.uploadPut`)

- Use `upload_url` and `headers` returned by upload-request.
- This call goes to object storage, not to `/api/*`.
- Skip forbidden browser headers (`Host`, `Content-Length`) if present.

### `POST /api/fs/:file_id/confirm` (`fs.uploadConfirm`)

No request body.

Success data shape:

```json
{
  "file_id": "3d9f2f61-c9af-4f91-8a6a-e38c5caefa13",
  "url": "https://host/objects/...",
  "ttl_seconds": 300
}
```

### `GET /api/fs?entity_type=&entity_id=` (`fs.files.listByEntity`)

Example:

```http
GET /api/fs?entity_type=kb_article&entity_id=5a1f3c42-84ba-4a53-b70e-4e8768db8aa5
```

Success data shape:

```json
{
  "items": [
    {
      "file_id": "3d9f2f61-c9af-4f91-8a6a-e38c5caefa13",
      "content_type": "application/pdf",
      "size_bytes": 248773,
      "original_filename": "runbook.pdf",
      "sha256_hex": "..."
    }
  ],
  "count": 1
}
```

### `GET /api/fs/:file_id` (`fs.resolveUrl`, optional)

No request body. Returns presigned download URL + metadata.

### `DELETE /api/fs/:file_id` (`fs.files.deleteOne`)

No request body.

Success data shape:

```json
{
  "file_id": "3d9f2f61-c9af-4f91-8a6a-e38c5caefa13",
  "deleted": true
}
```

## Common success codes

- `FILE-SUC-001`: upload-request accepted
- `FILE-SUC-002`: file confirmed
- `FILE-SUC-003`: file deleted
- `FILE-SUC-004`: file resolved
- `FILE-SUC-005`: entity files listed

## Common error codes

- `AUT-ERR-401` or `AUTH-ERR-001`: missing/invalid/expired auth context
- `FILE-ERR-001`: file not found (or hidden by leak-safe policy)
- `FILE-ERR-002`: parent entity not found
- `FILE-ERR-003`: unknown `entity_type`
- `FILE-ERR-005`: MIME rejected (`meta.allowed[]`)
- `FILE-ERR-006`: size exceeded (`meta.policy_max_bytes`, `meta.declared_bytes`)
- `FILE-ERR-007`: content sniff mismatch (`meta.declared`, `meta.detected`)
- `FILE-ERR-009`: quota exceeded (`meta.current_bytes`, `meta.max_bytes`)
- `FILE-ERR-010`: user/day quota exceeded (`meta.current_bytes`, `meta.max_bytes`)
- `FILE-ERR-011`: missing list filters
- `FILE-ERR-013`: storage object missing on confirm (PUT never happened or failed)
- `FILE-ERR-014`: size mismatch on confirm (`meta.declared`, `meta.actual` bytes)
- `FILE-ERR-015`: content-type mismatch on confirm (`meta.declared`, `meta.actual`) — the stored bytes do not match the declared `content_type` (see validation notes below)
- `FILE-ERR-016`: reconcile saw a file id belonging to another entity (`meta.file_id`, `meta.expected`)
- `FILE-ERR-018`: write authz denied for operation
- `FILE-ERR-019`: storage backend unavailable
- `FILE-ERR-020`: database error
- `SYS-ERR-500`: internal error

## Content-type validation notes (confirm step)

Confirm validates the uploaded bytes against the `content_type` declared in
upload-request, in two layers:

1. The object's stored Content-Type (from the PUT) is compared to the
   declared type; on mismatch the server falls back to byte-level sniffing.
2. The first 512 bytes are sniffed and matched against the declared type.
   Images/audio/video match by family; `application/xml` accepts XML/drawio
   signatures; **text-like types match as a family**: content declared as
   `text/markdown`, `text/csv`, `text/plain`, `application/json` or
   `application/rtf` is accepted when the bytes sniff as any text-like type
   (sniffers report all of these as `text/plain`).

Practical rules:

- Always declare a specific catalog MIME type in upload-request
  (`text/markdown` for `.md`, `text/csv` for `.csv`, ...). The
  `fs-upload-request.sh` auto-detection via `file --mime-type` may return
  `text/plain` for these — acceptable, but explicit `--content-type` is better.
- `FILE-ERR-015` means the bytes genuinely do not look like the declared
  type (e.g. a PNG declared as `text/markdown`). Re-upload with the correct
  `content_type`; do not retry blindly.

## Retry guidance

- On `AUT-ERR-401`: re-auth once via `role-auth`, then retry request once.
- On `FILE-ERR-019`: retry with backoff; treat as infrastructure transient.
- On `FILE-ERR-013`: re-run the direct PUT, then confirm again.
- On `FILE-ERR-005/006/007/009/010/014/015`: do not blind-retry; adjust file/policy first.

## KB integration recipe

1. For each local file, run upload-request -> direct PUT -> confirm.
2. Keep confirmed `file_id`s.
3. Build authoritative `attachment_file_ids` list for the article.
4. Call `PUT /api/kb/articles/:id` (see `role-kb-author`) with:

```json
{
  "attachment_file_ids": ["<confirmed_file_uuid_1>", "<confirmed_file_uuid_2>"]
}
```

**Full-replace semantics**: when `attachment_file_ids` is present it is the
complete set the article keeps — files missing from it are scheduled for
deletion. To add files while preserving existing ones, prefer the
`role-kb-author` helper `scripts/kb-articles-attachments-add.sh <article_id>
<file_id>...` (it lists, unions and PUTs for you), or list the current set
manually and include those ids too:

```bash
bash scripts/fs-files-list.sh kb_article "<article_uuid>" \
  | jq -r '.data.items[].file_id'
```

Inline images in article body use `fileImage` nodes (not the standard `image`
node). The backend walks ProseMirror JSON and reconciles inline file refs
separately from `attachment_file_ids`. See `role-kb-author` content model.

Other rich-editor nodes (`entityLink`, `externalLink`, `mermaidDiagram`) are
stored in article content JSON and do **not** create `/api/fs` records.

Omitting `attachment_file_ids` from the article update preserves all
currently stored files (the server does not touch them).

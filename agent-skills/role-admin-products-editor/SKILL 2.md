---
name: role-admin-products-editor
description: >
  Admin Products editor skill for evi. Covers editor-scope read operations,
  update-family mutations, and import for bots mapped to role.adminProducts.editor.
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

# role-admin-products-editor

<!--
version: 1.7.3
Short description: Editor role skill with read-all + update/import Admin Products scope.
File: SKILL.md
Last release: 0.26.2

Changes in v1.7.3:
- Renamed frontmatter key `last_evi_release` to `last_release` and set it to 0.26.2.

Changes in v1.7.2:
- Renamed skill directory and shared scripts from evi-* to role-*; dropped EVI_ prefix from env vars (BASE_URL, API_KEY, …).

Changes in v1.7.1:
- Renamed API key format prefix from evik_ to bkey_ in API_KEY prompt.
- Updated last_evi_release marker to 0.23.12.

Changes in v1.7.0:
- Documented catalog visibility via statusCode=active plus placement fields.
- Added catalog-section-options and bulk status/placement/card/regions/specialists
  scripts for products and product lines.
- Switched product placement contract to scalar memberLineId/catalogSectionId.
- Updated `last_evi_release` marker to 0.21.7.

Changes in v1.6.0:
- Updated list-script contracts for statusFilter-only product/line lists.
- Updated `last_evi_release` marker to 0.21.5.

Changes in v1.5.0:
- Added editor-scope product-line list/get/search/update operations.
- Updated product import guidance: translation `shortDesc` is optional when
  `name` is present.
- Explicitly excluded product-line create/delete/assign-owner outside editor
  permissions.

Changes in v1.4.0:
- Updated option-pairs payload examples to `relationKind`
  (`optional | required | incompatible`) instead of `isRequired`.
- Added relation semantics note: `incompatible` is symmetric, and pair count
  endpoints report only `optional/required` relations.

Changes in v1.3.1:
- Added last_evi_release frontmatter marker (skills pack sync at evi 0.20.17).

Changes in v1.3.0:
- Added import success response summary (`imported_count`, `row_results`,
  `errors`) and option-pairs no-records caveat.
- Added explicit quick-start warning that `PUT /regions` and
  `PUT /linked-kb-articles` are authoritative full-replace operations.

Changes in v1.2.0:
- Added explicit write payload quick starts for update/import and option-pair mutations.
- Documented strict update id field name (`productId`) and translation update caveat
  (language entry applied only when both `name` and `shortDesc` are present).
- Clarified import translation minimum requirements to avoid NO_VALID_TRANSLATIONS rows.

Changes in v1.1.0:
- Realigned scope to role.adminProducts.editor in strict 1:1 role mapping.
- Added read routes directly into the editor skill for standalone role usage.
- Removed create/delete/assign-owner operations that are outside editor permissions.

Changes in v1.0.0:
- Initial Admin Products editor skill with CRUD, import, assign-owner, regions,
  KB links, and option-pair write routes.
- Added destructive-safety guidance and preserve-and-add helper scripts.
- Documented image file workflow via role-attachments and reader refetch after update.
-->

Standalone Admin Products skill for bots assigned to `role.adminProducts.editor`.

## Role mapping

This skill is the external-agent counterpart of evi role `role.adminProducts.editor`.
Allowed permissions in evi:

- `adminProducts:module:access`
- `adminProducts:items:read:all`
- `adminProducts:items:update:all`
- `adminProducts:items:import:all`

## Scope

Included methods:

- `adminProducts.items.list` -> `GET /api/admin/products/fetch-all-products`
- `adminProducts.items.get` -> `GET /api/admin/products/fetch` (`id`)
- `adminProducts.items.search` -> `GET /api/admin/products/search`
- `adminProducts.options.list` -> `GET /api/admin/products/fetch-options`
- `adminProducts.statuses.list` -> `GET /api/admin/products/fetch-statuses`
- `adminProducts.catalogSectionOptions.list` -> `GET /api/admin/products/catalog-section-options`
- `adminProducts.regions.get` -> `GET /api/admin/products/:productId/regions`
- `adminProducts.linkedKbArticles.get` -> `GET /api/admin/products/:productId/linked-kb-articles`
- `adminProducts.optionPairs.read` -> `POST /api/admin/products/read-product-option-pairs`
- `adminProducts.optionPairs.count` -> `POST /api/admin/products/count-product-option-pairs`
- `adminProducts.taxableCategories.byRegion` -> `GET /api/admin/products/taxable-categories/by-region/:regionId`
- `adminProducts.items.update` -> `POST /api/admin/products/update`
- `adminProducts.items.import` -> `POST /api/admin/products/import`
- `adminProducts.items.bulkStatus` -> `POST /api/admin/products/bulk-status`
- `adminProducts.items.bulkPlacement` -> `POST /api/admin/products/bulk-placement`
- `adminProducts.items.bulkProductCard` -> `POST /api/admin/products/bulk-product-card`
- `adminProducts.items.bulkRegions` -> `POST /api/admin/products/bulk-regions`
- `adminProducts.items.bulkSpecialists` -> `POST /api/admin/products/bulk-specialists`
- `adminProducts.productLines.list` -> `GET /api/admin/product-lines/fetch-all`
- `adminProducts.productLines.get` -> `GET /api/admin/product-lines/fetch`
- `adminProducts.productLines.search` -> `GET /api/admin/product-lines/search`
- `adminProducts.productLines.update` -> `POST /api/admin/product-lines/update`
- `adminProducts.productLines.bulkStatus` -> `POST /api/admin/product-lines/bulk-status`
- `adminProducts.productLines.bulkPlacement` -> `POST /api/admin/product-lines/bulk-placement`
- `adminProducts.regions.put` -> `PUT /api/admin/products/:productId/regions`
- `adminProducts.linkedKbArticles.put` -> `PUT /api/admin/products/:productId/linked-kb-articles`
- `adminProducts.optionPairs.create` -> `POST /api/admin/products/create-product-option-pairs`
- `adminProducts.optionPairs.update` -> `POST /api/admin/products/update-product-option-pairs`
- `adminProducts.optionPairs.delete` -> `POST /api/admin/products/delete-product-option-pairs`

Explicitly excluded:

- `POST /api/admin/products/create`
- `POST /api/admin/products/delete`
- `POST /api/admin/products/assign-owner`
- Product-line create/delete/assign-owner routes
- Clear-all routes (`POST /clear-all/start`, `GET /clear-all/status/:operationId`)
- Any settings routes (`GET /api/core/settings`, `POST /api/admin/settings/update`)


## Catalog visibility

A product appears in the public catalog when:

1. `statusCode` is `active`, and
2. it has placement: either `memberLineId` (line must also be `active` and placed in an active section) **or** `catalogSectionId` (standalone in an active section).

Placement fields on create/update/bulk-placement:

- UUID value = set that placement
- `""` = clear placement
- omit = leave placement unchanged
- set at most one of `memberLineId` / `catalogSectionId` (XOR)

`showAsProductCard` controls card vs option-only display. Use `admin-products-statuses-list.sh` for valid status codes and `admin-products-catalog-section-options.sh` for section IDs.

## Destructive-safety

Agents often send partial payloads. Know these semantics before calling write scripts:

| Field / route | Semantics |
|---|---|
| `POST /update` — most fields | **Partial merge**: omitted = preserve current value |
| `POST /update` — `translations` | Language entry is applied only when both `name` and `shortDesc` are provided. Sending only one translation field is ignored. |
| `POST /update` — `specialistsGroups` | **Present = authoritative replace**; `[]` clears all groups. Use `admin-products-specialists-add.sh` to add without dropping existing groups. |
| `POST /update` — `memberLineId` / `catalogSectionId` | UUID = set placement; `""` = clear; omit = unchanged. XOR: at most one placement. |
| `POST /product-lines/update` — `catalogSectionId` | Same scalar semantics for line section placement. |
| `POST /product-lines/update` — `memberProductIds` | **Present = authoritative replace** for line members; omitted preserves current line members. |
| `POST /update` — `detailImageFileId` / `thumbnailImageFileId` | Omitted = preserve; `""` = clear. When either field is sent, FS reconcile runs on both image slots. Upload files via `role-attachments` first (`entity_type=product`). |
| `PUT .../regions` | **Authoritative full replace** — deletes all bindings, then inserts from payload. Prefer `admin-products-regions-set-category.sh`. |
| `PUT .../linked-kb-articles` | **Authoritative full replace** — `[]` unlinks all. Prefer `admin-products-linked-kb-add.sh`. |
| `POST delete-product-option-pairs` — `all: true` | Deletes every option pair for the main product |

Request bodies use **camelCase** except `PUT regions` items (`region_id`, `category_id`). Responses use snake_case — do not mirror response keys into requests.

`POST /update` returns success with **empty `data`** — refetch via `scripts/admin-products-get.sh`.

## JWT contract

Every protected backend request uses:

```http
Authorization: Bearer <JWT>
```

JWT lifecycle is delegated to the shared auth scripts (vendored at `scripts/_lib/`). Resolution order: `REQUEST_SCRIPT` → vendored `scripts/_lib/` → `../../role-auth/scripts/`.

Environment variables (`BASE_URL`, `API_KEY`, TLS options) must be **exported**.

All JSON-body requests must send `Content-Type: application/json` (scripts set this automatically).

## Image workflow

1. Upload with `role-attachments/scripts/attachments-upload-flow.sh product <product_id> <file_path>`
2. Set `detailImageFileId` and/or `thumbnailImageFileId` in update payload
3. `entity_type=product` is registered in the backend FS registry

## Input contract for write scripts

Scripts accept JSON payload files (or product id + payload for PUT routes). See `references/api-contract.md` for field names and examples.

### Write payload quick start

`PUT /regions` and `PUT /linked-kb-articles` are **authoritative full replace** operations. Prefer helper scripts (`admin-products-regions-set-category.sh`, `admin-products-linked-kb-add.sh`) for additive changes.

`POST /update` minimal payload (note `productId`, not `id`):

```json
{
  "productId": "uuid",
  "productCode": "PRD-EDIT-001",
  "statusCode": "active",
  "catalogSectionId": "section-uuid",
  "showAsProductCard": true
}
```

`POST /update` translations payload (include both `name` and `shortDesc` in each updated language entry):

```json
{
  "productId": "uuid",
  "translations": {
    "english": {
      "name": "Updated name",
      "shortDesc": "Updated short description",
      "longDesc": "Updated long description"
    }
  }
}
```

`POST /import` payload shape:

```json
{
  "overwriteExisting": false,
  "items": [
    {
      "productCode": "PRD-IMPORT-001",
      "translationKey": "product.prd_import_001",
      "statusCode": "draft",
      "owner": "bot_username",
      "specialistsGroups": ["product_specialists"],
      "translations": {
        "english": {
          "name": "Imported product",
          "shortDesc": "Optional import short description"
        }
      }
    }
  ]
}
```

`POST /api/admin/product-lines/update` payload:

```json
{
  "lineId": "line-uuid",
  "statusCode": "active",
  "catalogSectionId": "section-uuid",
  "memberProductIds": ["product-uuid-1", "product-uuid-2"]
}
```

`memberProductIds` is authoritative when present. Omit it to preserve current
line membership.

`POST /import` success data summary:

```json
{
  "imported_count": 1,
  "updated_count": 0,
  "skipped_count": 0,
  "error_count": 0,
  "row_results": [],
  "errors": []
}
```

`POST /create-product-option-pairs` payload:

```json
{
  "mainProductId": "uuid",
  "pairs": [
    { "optionProductId": "uuid", "relationKind": "optional" },
    { "optionProductId": "uuid", "relationKind": "required", "unitsCount": 1 },
    { "optionProductId": "uuid", "relationKind": "incompatible" }
  ]
}
```

Practical read note: `POST /read-product-option-pairs` may return `VAL-ERR-001` when the main product has no option pairs in some deployments.

Pairing semantics note: create/update uses `relationKind` (`optional`, `required`, `incompatible`), `unitsCount` is meaningful only for `required`, and `count-product-option-pairs` excludes `incompatible`.

## Script map

- `scripts/admin-products-list.sh`
- `scripts/admin-products-get.sh <product_id>`
- `scripts/admin-products-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/admin-products-options-list.sh`
- `scripts/admin-products-statuses-list.sh`
- `scripts/admin-products-catalog-section-options.sh`
- `scripts/admin-products-regions-get.sh <product_id>`
- `scripts/admin-products-linked-kb-get.sh <product_id>`
- `scripts/admin-products-option-pairs-read.sh <payload.json>`
- `scripts/admin-products-option-pairs-count.sh <payload.json>`
- `scripts/admin-products-taxable-categories-by-region.sh <region_id>`
- `scripts/admin-products-update.sh <payload.json>`
- `scripts/admin-products-import.sh <payload.json>`
- `scripts/admin-products-bulk-status.sh <payload.json>`
- `scripts/admin-products-bulk-placement.sh <payload.json>`
- `scripts/admin-products-bulk-product-card.sh <payload.json>`
- `scripts/admin-products-bulk-regions.sh <payload.json>`
- `scripts/admin-products-bulk-specialists.sh <payload.json>`
- `scripts/admin-product-lines-list.sh [--language english|russian] [--search "<text>"] [--status CODE]`
- `scripts/admin-product-lines-get.sh <line_id>`
- `scripts/admin-product-lines-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/admin-product-lines-update.sh <payload.json>`
- `scripts/admin-product-lines-bulk-status.sh <payload.json>`
- `scripts/admin-product-lines-bulk-placement.sh <payload.json>`
- `scripts/admin-products-regions-put.sh <product_id> <payload.json>`
- `scripts/admin-products-regions-set-category.sh <product_id> <region_id> <category_id|--clear>`
- `scripts/admin-products-linked-kb-put.sh <product_id> <payload.json>`
- `scripts/admin-products-linked-kb-add.sh <product_id> <article_id> [<article_id>...]`
- `scripts/admin-products-specialists-add.sh <product_id> <group_name> [<group_name>...]`
- `scripts/admin-products-option-pairs-create.sh <payload.json>`
- `scripts/admin-products-option-pairs-update.sh <payload.json>`
- `scripts/admin-products-option-pairs-delete.sh <payload.json>`

## Usage examples

```bash
bash scripts/admin-products-list.sh --search "widget"
bash scripts/admin-products-update.sh ./payloads/update-status.json
bash scripts/admin-products-get.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e"
bash scripts/admin-products-search.sh "widget"
bash scripts/admin-product-lines-list.sh --search "bundle"
bash scripts/admin-product-lines-update.sh ./payloads/update-product-line.json
bash scripts/admin-products-linked-kb-add.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e" "article-uuid"
bash scripts/admin-products-regions-set-category.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e" 1 2
bash scripts/admin-products-specialists-add.sh "b7de7d69-7e16-4f45-a389-8e7f45e4587e" "product_specialists"
bash scripts/admin-products-import.sh ./payloads/import-batch.json
bash scripts/admin-products-catalog-section-options.sh
bash scripts/admin-products-bulk-status.sh ./payloads/bulk-status.json
bash scripts/admin-products-bulk-placement.sh ./payloads/bulk-placement.json
```

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Attachments skill](../role-attachments/SKILL.md)

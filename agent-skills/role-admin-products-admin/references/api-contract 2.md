# evi API contract - Admin Products admin

<!--
version: 1.8.1
Short description: Full admin-role endpoint contract for role-admin-products-admin.
File: api-contract.md

Changes in v1.8.1:
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.

Changes in v1.8.0:
- Documented catalog visibility (statusCode=active + placement) and scalar
  memberLineId/catalogSectionId / showAsProductCard contracts.
- Added catalog-section-options and bulk status/placement/card/regions/specialists
  endpoint contracts for products and product lines.

Changes in v1.7.0:
- Documented optional `regions` and `articleIds` on POST create/update for unified
  product editor save; PUT sub-resources remain available for scripts.

Changes in v1.6.0:
- Updated products and product-lines list contracts for statusFilter-only listing.

Changes in v1.5.0:
- Added product-line CRUD/search/assign-owner endpoint contracts.
- Updated product import validation: translation `shortDesc` is optional when
  `name` is present.

Changes in v1.4.0:
- Updated option-pairs create/update payloads to use `relationKind`
  (`optional | required | incompatible`) instead of `isRequired`.
- Clarified read `records` shape (`relationKind`, `unitsCount`) and that
  `count-product-option-pairs` excludes `incompatible` relations.

Changes in v1.3.0:
- Added create/import success response data shapes (`data.id`, import counters,
  `row_results`, `errors`) used by tested clients.
- Added practical note about option-pairs read on products without pairs
  (`VAL-ERR-001` in some deployments).
- Added create caveat for `productType` validation and owner-null observation.

Changes in v1.2.0:
- Added explicit payload contracts for admin write endpoints that previously
  required guessing (`delete`, `assign-owner`, `update`, `import`, option pairs).
- Added create/update/import payload examples and translation behavior notes
  for parity with specialist/editor contracts.
- Added practical read-route parameter notes (`excludeProductId`,
  `optionProductIds` requirements by mode).

Changes in v1.1.0:
- Expanded contract from admin-only settings/clear-all to full role.adminProducts.admin scope.
- Added products read/write endpoint groups covered by this standalone skill.
- Kept clear-all and settings sections as privileged admin operations.

Changes in v1.0.0:
- Initial Admin Products admin API contract reference.
- Added clear-all start/status, settings read/update, permissions, and polling notes.
-->

Reference for `role-admin-products-admin`.

All routes below are protected and require:

```http
Authorization: Bearer <JWT>
```

## Response envelope

Success:

```json
{
  "success": true,
  "code": "ADM_PRD-SUC-019",
  "data": {}
}
```

Failure:

```json
{
  "success": false,
  "code": "AZN-ERR-403"
}
```

## Permissions

This skill maps to `role.adminProducts.admin`, which has all `adminProducts:*` permissions.

Effective scope includes:

- full product read (`items:read:all`)
- full product writes (`items:create/update/delete/import:all`)
- full owner changes (`items:change_owner:all`)
- settings read/update (`settings:read:all`, `settings:update:all`, `settings:access`)

## Product endpoints in this skill

Read endpoints:

- `GET /api/admin/products/fetch-all-products`
- `GET /api/admin/products/fetch`
- `GET /api/admin/products/fetch-options`
- `GET /api/admin/products/fetch-statuses`
- `GET /api/admin/products/catalog-section-options`
- `GET /api/admin/products/:productId/regions`
- `GET /api/admin/products/:productId/linked-kb-articles`
- `POST /api/admin/products/read-product-option-pairs`
- `POST /api/admin/products/count-product-option-pairs`
- `GET /api/admin/products/taxable-categories/by-region/:regionId`

Write endpoints:

- `POST /api/admin/products/create`
- `POST /api/admin/products/update`
- `POST /api/admin/products/delete`
- `POST /api/admin/products/assign-owner`
- `POST /api/admin/products/import`
- `POST /api/admin/products/bulk-status`
- `POST /api/admin/products/bulk-placement`
- `POST /api/admin/products/bulk-product-card`
- `POST /api/admin/products/bulk-regions`
- `POST /api/admin/products/bulk-specialists`
- `GET /api/admin/product-lines/fetch-all`
- `GET /api/admin/product-lines/fetch`
- `GET /api/admin/product-lines/search`
- `POST /api/admin/product-lines/create`
- `POST /api/admin/product-lines/update`
- `POST /api/admin/product-lines/delete`
- `POST /api/admin/product-lines/assign-owner`
- `POST /api/admin/product-lines/bulk-status`
- `POST /api/admin/product-lines/bulk-placement`
- `PUT /api/admin/products/:productId/regions`
- `PUT /api/admin/products/:productId/linked-kb-articles`
- `POST /api/admin/products/create-product-option-pairs`
- `POST /api/admin/products/update-product-option-pairs`
- `POST /api/admin/products/delete-product-option-pairs`

## Product payload contracts

### `POST /api/admin/products/create`

Required fields:

- `productCode`
- `productType` (required in tested deployments; keep for compatibility with stricter validators)
- `translationKey`
- `owner`
- `translations` (object keyed by language; at least one valid language with both `name` and `shortDesc`)
- Optional: `memberLineId` / `catalogSectionId` (scalar placement; UUID set / `""` clear / omit unchanged)
- Optional: `statusCode`, `showAsProductCard`
- Optional: `regions` (array of `{ region_id, category_id }`; authoritative full replace; rows with `category_id: null` are skipped)
- Optional: `articleIds` (array of KB article UUIDs; authoritative full replace)

Minimal payload:

```json
{
  "productCode": "PRD-NEW-001",
  "productType": "default",
  "translationKey": "product.prd_new_001",
  "owner": "bot_username",
  "translations": {
    "english": {
      "name": "New product",
      "shortDesc": "Short description"
    }
  },
  "catalogSectionId": "section-uuid",
  "showAsProductCard": true
}
```

Success response:

```json
{
  "success": true,
  "code": "ADM_PRD-SUC-002",
  "data": {
    "id": "uuid",
    "productCode": "PRD-NEW-001",
    "translationKey": "product.prd_new_001"
  }
}
```

Practical note: in some runs, follow-up reads still show `owner: null` right after create despite `owner` in payload.

### `POST /api/admin/products/update`

Required fields:

- `productId` (UUID, required; not `id`)
- Optional: `memberLineId` / `catalogSectionId` (scalar placement; UUID set / `""` clear / omit unchanged)
- Optional: `statusCode`, `showAsProductCard`
- Optional: `regions` (authoritative full replace when present; omit to preserve bindings)
- Optional: `articleIds` (authoritative full replace when present; `[]` unlinks all; omit to preserve links)

Minimal payload:

```json
{
  "productId": "uuid",
  "productCode": "PRD-NEW-001-UPDATED",
  "memberLineId": "line-uuid",
  "statusCode": "active"
}
```

`memberLineId` / `catalogSectionId` set placement when present (XOR). Omit both to leave placement unchanged.

Translation update payload:

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

Note: translation language entry is applied only when both `name` and `shortDesc` are present.

### `POST /api/admin/products/delete`

Required fields:

- `productIds` (array of UUIDs)

Payload:

```json
{
  "productIds": ["uuid1", "uuid2"]
}
```

Success response summary (`data`):

```json
{
  "imported_count": 1,
  "updated_count": 0,
  "skipped_count": 0,
  "error_count": 0,
  "row_results": [
    {
      "row": 1,
      "product_code": "PRD-IMPORT-001",
      "status": "created"
    }
  ],
  "errors": []
}
```

Success data includes `deletedProducts`, `errors`, `totalRequested`, `totalDeleted`, `totalErrors`.

### `POST /api/admin/products/assign-owner`

Required fields:

- `productIds` (array of UUIDs)
- `newOwnerUsername` (username)

Payload:

```json
{
  "productIds": ["uuid1", "uuid2"],
  "newOwnerUsername": "username"
}
```

Success data includes `updatedProducts`, `errors`, `totalRequested`, `totalUpdated`, `totalErrors`.

### `POST /api/admin/products/import`

Required fields:

- `items` (array, min 1)
- item requires `productCode` and `translations`

Validation note:

- each imported row must include at least one translation with `name`.
  `shortDesc` is optional for import rows; rows without any named translation
  are skipped with `reason_code=NO_VALID_TRANSLATIONS`.

Payload:

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
          "shortDesc": "Optional short description"
        }
      }
    }
  ]
}
```

## Product line payload contracts

Product-line CRUD routes require `adminProducts:items:*` permissions, not
`adminCatalog:*` permissions. Request payloads are camelCase; response entities
are mostly snake_case.

### `GET /api/admin/product-lines/fetch-all`

Query params:

- `language` (default `english`)
- `searchQuery`
- `statusFilter`

Success code: `ADM_PRD-SUC-021`.

`data` shape:

```json
{
  "productLines": [
    {
      "line_id": "uuid",
      "line_code": "LINE-001",
      "status_code": "active",
      "catalog_section_id": "section-uuid",
      "order": 0,
      "name": "Line name",
      "owner": "username",
      "members_count": 2
    }
  ]
}
```

### `GET /api/admin/product-lines/fetch`

Query param:

- `id` (required product-line UUID)

Success code: `ADM_PRD-SUC-027`.

`data` contains `productLine`, `translations`, `members`, and `statuses`.

### `GET /api/admin/product-lines/search`

Query params:

- `q`
- `limit` (default 20, max 100)
- `language` (default `english`)

Success code: `ADM_PRD-SUC-026`.

### `POST /api/admin/product-lines/create`

Payload:

```json
{
  "lineCode": "LINE-001",
  "statusCode": "draft",
  "catalogSectionId": "section-uuid",
  "order": 0,
  "translations": {
    "english": {
      "name": "Product line",
      "shortDesc": "Grouped products",
      "longDesc": "Optional long description"
    }
  },
  "memberProductIds": ["product-uuid-1", "product-uuid-2"]
}
```

Success code: `ADM_PRD-SUC-022`; success data contains `id` and optional
`lineCode`.

### `POST /api/admin/product-lines/update`

Payload:

```json
{
  "lineId": "line-uuid",
  "lineCode": "LINE-001",
  "statusCode": "active",
  "catalogSectionId": "section-uuid",
  "order": 1,
  "translations": {
    "english": {
      "name": "Updated line",
      "shortDesc": "Updated summary"
    }
  },
  "memberProductIds": ["product-uuid-1", "product-uuid-2"]
}
```

Success code: `ADM_PRD-SUC-023`.

`memberProductIds` is authoritative when present: products not listed are
removed from the line.
Omit the field to preserve line membership.

### `POST /api/admin/product-lines/delete`

Payload:

```json
{
  "lineIds": ["line-uuid-1", "line-uuid-2"]
}
```

Success code: `ADM_PRD-SUC-024`; success data includes `deletedLines`,
`errors`, `totalRequested`, `totalDeleted`, and `totalErrors`.

### `POST /api/admin/product-lines/assign-owner`

Payload:

```json
{
  "lineIds": ["line-uuid"],
  "newOwnerUsername": "username"
}
```

Success code: `ADM_PRD-SUC-013`; success data includes `updatedLines`,
`errors`, `totalRequested`, `totalUpdated`, and `totalErrors`.

### `PUT /api/admin/products/:productId/regions`

Alternative to `regions` on POST create/update (preferred for additive script updates).

```json
{
  "regions": [
    { "region_id": 1, "category_id": 2 },
    { "region_id": 2, "category_id": null }
  ]
}
```

### `PUT /api/admin/products/:productId/linked-kb-articles`

Alternative to `articleIds` on POST create/update (preferred for additive script updates).

```json
{
  "articleIds": ["uuid1", "uuid2"]
}
```

### `POST /api/admin/products/create-product-option-pairs`

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

### `POST /api/admin/products/update-product-option-pairs`

```json
{
  "mainProductId": "uuid",
  "pairs": [
    { "optionProductId": "uuid", "relationKind": "required", "unitsCount": 2 }
  ]
}
```

### `POST /api/admin/products/delete-product-option-pairs`

Delete all:

```json
{
  "mainProductId": "uuid",
  "all": true
}
```

Delete selected:

```json
{
  "mainProductId": "uuid",
  "all": false,
  "selectedOptionIds": ["uuid1", "uuid2"]
}
```

## Read endpoint notes (practical gotchas)

- `GET /api/admin/products/fetch-options`: provide `excludeProductId` in regular workflows.
- `POST /api/admin/products/read-product-option-pairs`: `optionProductIds` is required for `records` (default) and `exists`; not required for `ids`.
- `POST /api/admin/products/read-product-option-pairs`: if main product has no pairs, some deployments return `VAL-ERR-001`.
- `POST /api/admin/products/read-product-option-pairs` (`records` mode): each pair contains `optionProductId`, `relationKind`, `unitsCount`.
- `POST /api/admin/products/count-product-option-pairs`: counts only `relationKind IN (optional, required)`.

## Product semantics summary

- Request payloads are camelCase, except regions items (`region_id`, `category_id`).
- Response entities are snake_case (pagination blocks may remain camelCase).
- `POST /update` is partial for scalar fields.
- `POST /update` `specialistsGroups` is authoritative replace when present.
- `POST /update` `memberLineId` / `catalogSectionId` update placement when present.
- Regions/linked-kb `PUT` endpoints are authoritative full replace.


## Catalog visibility and placement

A product is catalog-visible when `statusCode`/`status_code` is `active` and it has reachable placement:

- standalone: `catalogSectionId` / `catalog_section_id` points at an active section, or
- line member: `memberLineId` / `member_line_id` points at an active line that is itself placed in an active section.

Placement write semantics (create/update/bulk-placement): UUID = set, `""` = clear, omit = unchanged. Set at most one of `memberLineId` / `catalogSectionId`. `showAsProductCard` / `show_as_product_card` controls card vs option-only display.

### `GET /api/admin/products/catalog-section-options`

- Success code: `ADM_PRD-SUC-029`
- `data`: array of `{ "section_id", "name", "status" }`

### `POST /api/admin/products/bulk-status`

```json
{
  "productIds": ["uuid-1", "uuid-2"],
  "statusCode": "active"
}
```

Success code: `ADM_PRD-SUC-030`. `data` includes `updatedProducts`, `errors`, `totalRequested`, `totalUpdated`, `totalErrors`.

### `POST /api/admin/products/bulk-placement`

```json
{
  "productIds": ["uuid-1", "uuid-2"],
  "catalogSectionId": "section-uuid"
}
```

Or `"memberLineId": "line-uuid"`, or `""` on either field to clear. Requires a placement change (not both omitted).

### `POST /api/admin/products/bulk-product-card`

```json
{
  "productIds": ["uuid-1", "uuid-2"],
  "showAsProductCard": true
}
```

### `POST /api/admin/products/bulk-regions`

```json
{
  "productIds": ["uuid-1", "uuid-2"],
  "regions": [
    { "region_id": 1, "category_id": 2 }
  ]
}
```

### `POST /api/admin/products/bulk-specialists`

```json
{
  "productIds": ["uuid-1", "uuid-2"],
  "specialistsGroups": ["group_name"],
  "specialistsUsers": [],
  "mode": "replace"
}
```

`mode` is `replace` or `add`.

### `POST /api/admin/product-lines/bulk-status`

```json
{
  "lineIds": ["line-uuid"],
  "statusCode": "active"
}
```

### `POST /api/admin/product-lines/bulk-placement`

```json
{
  "lineIds": ["line-uuid"],
  "catalogSectionId": "section-uuid"
}
```

## Clear-all endpoints

### `POST /api/admin/products/clear-all/start`

- Purpose: enqueue async worker job to delete all products (snapshot-based batching)
- Permission: `adminProducts:settings:update:all`
- Success code: `ADM_PRD-SUC-019`
- Request body (JSON, camelCase):

```json
{
  "confirm": true,
  "batchSizeHint": 5000
}
```

- `confirm` must be `true` (required).
- `batchSizeHint` optional: integer 100–50000; server default 5000.
- `data` shape on success:

```json
{
  "operation_id": "uuid",
  "status": "pending",
  "snapshot_started_at": "2026-06-11T12:00:00Z",
  "batch_size": 5000
}
```

- Only one active operation allowed; concurrent start returns HTTP 409 with `ADM_PRD-ERR-409-CLEAR-IN-PROGRESS`.

Worker job type: `adminProducts.clear_all`. Deletes products in batches, schedules FS cleanup, removes KB article links.

### `GET /api/admin/products/clear-all/status/:operationId`

- Purpose: poll async clear-all progress.
- Permission: `adminProducts:settings:update:all`.
- Success code: `ADM_PRD-SUC-020`.
- Path param: `operationId` (UUID from start response).
- `data` shape:

```json
{
  "operation_id": "uuid",
  "status": "running",
  "snapshot_started_at": "2026-06-11T12:00:00Z",
  "batch_size": 5000,
  "total_candidates": 1200,
  "processed_count": 600,
  "deleted_count": 598,
  "failed_count": 2,
  "last_cursor_product_id": "uuid",
  "error_msg": null,
  "started_at": "2026-06-11T12:00:01Z",
  "finished_at": null,
  "created_at": "2026-06-11T12:00:00Z",
  "updated_at": "2026-06-11T12:00:05Z",
  "progress_percent": 50.0
}
```

- Status values: `pending` -> `running` -> `completed` or `failed`.
- Poll every approximately 3 seconds until terminal state.

### Clear-all error codes

- `ADM_PRD-ERR-409-CLEAR-IN-PROGRESS`: another operation is active.
- `ADM_PRD-ERR-404-CLEAR-OPERATION`: unknown `operationId`.
- `VAL-ERR-001`: invalid input (`confirm`, UUID, `batchSizeHint`).
- `REQ-ERR-001`: malformed JSON body.
- `AZN-ERR-403`: caller lacks `adminProducts:settings:update:all`.

## Settings endpoints

### `GET /api/core/settings`

- Purpose: fetch standard (non-confidential) app settings as nested map.
- Permission: section-based read via `RequireSettingsPermission("read")`.
- Success code: `STG-SUC-002`.
- Typical extraction:

```bash
jq '.data.settings.AdminProducts'
```

### `POST /api/admin/settings/update`

- Purpose: update one app setting by section path and name.
- Permission: `{sectionBase}:settings:update:all` (`AdminProducts` -> `adminProducts:settings:update:all`).
- Success code: `ADM_STG-SUC-001`.
- Payload:

```json
{
  "sectionPath": "AdminProducts",
  "settingName": "allowed.languages",
  "value": ["english", "russian"]
}
```

### Settings error codes

- `ADM_STG-ERR-001`: value failed JSON Schema validation.
- `ADM_STG-ERR-002`: setting not found.
- `VAL-ERR-400`: missing `sectionPath` or `settingName`.
- `AZN-ERR-403`: caller lacks update permission for the section.

## Non-goals for this skill

`role-admin-products-admin` is intentionally broad for the adminProducts role, but it still does not include routes from other modules (`adminCatalog`, `adminPricing`, `kb`, etc.).

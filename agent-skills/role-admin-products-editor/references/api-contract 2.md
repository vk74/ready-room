# evi API contract - Admin Products editor

<!--
version: 1.8.1
Short description: Editor-scope Admin Products endpoint contract for role-admin-products-editor.
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
- Added editor-scope product-line list/get/search/update endpoint contracts.
- Updated import validation: `shortDesc` is optional when `name` is present.
- Declared product-line create/delete/assign-owner out of scope for this role.

Changes in v1.4.0:
- Updated option-pairs create/update payloads from `isRequired` to
  `relationKind` (`optional | required | incompatible`).
- Clarified `read-product-option-pairs` `records` mode response shape
  (`relationKind`, `unitsCount`) and count behavior (excludes `incompatible`).

Changes in v1.3.0:
- Added import success response data summary (`imported_count`, `row_results`,
  `errors`) used by editor/admin import clients.
- Added practical note: read-product-option-pairs can return `VAL-ERR-001`
  when main product has no pairs in some deployments.

Changes in v1.2.0:
- Added explicit payload schemas and examples for update/import and option-pair
  write endpoints.
- Documented strict update id field name (`productId`) and translation update
  caveat (language entry applied only with both `name` and `shortDesc`).
- Added practical read-route parameter notes for fetch-options and
  read-product-option-pairs modes.
- Added explicit response envelope examples (`success`, `code`, `data`) to match
  skill authoring contract requirements.

Changes in v1.1.0:
- Realigned endpoint set to role.adminProducts.editor (read:all + update:all + import:all).
- Removed create/delete/assign-owner contracts from this role.
- Added reader endpoint group because the editor skill is now standalone.

Changes in v1.0.0:
- Initial Admin Products editor API contract reference.
- Documented write endpoints, authoritative-field semantics, helper recipes, and error codes.
-->

Reference for `role-admin-products-editor`.

All routes are protected and require:

```http
Authorization: Bearer <JWT>
```

## Response envelope

Success:

```json
{
  "success": true,
  "code": "ADM_PRD-SUC-003",
  "data": {}
}
```

Failure:

```json
{
  "success": false,
  "code": "VAL-ERR-001"
}
```

Use `role-auth` for JWT acquisition and the shared `role-request.sh` wrapper (vendored at `scripts/_lib/`).

## Role scope

This skill maps to `role.adminProducts.editor`:

- `adminProducts:module:access`
- `adminProducts:items:read:all`
- `adminProducts:items:update:all`
- `adminProducts:items:import:all`

## Endpoints in scope

Read endpoints (global scope):

- `GET /api/admin/products/fetch-all-products`
- `GET /api/admin/products/fetch`
- `GET /api/admin/products/search`
- `GET /api/admin/products/fetch-options`
- `GET /api/admin/products/fetch-statuses`
- `GET /api/admin/products/:productId/regions`
- `GET /api/admin/products/:productId/linked-kb-articles`
- `POST /api/admin/products/read-product-option-pairs`
- `POST /api/admin/products/count-product-option-pairs`
- `GET /api/admin/products/taxable-categories/by-region/:regionId`

Write endpoints:

- `POST /api/admin/products/update`
- `POST /api/admin/products/import`
- `GET /api/admin/product-lines/fetch-all`
- `GET /api/admin/product-lines/fetch`
- `GET /api/admin/product-lines/search`
- `POST /api/admin/product-lines/update`
- `PUT /api/admin/products/:productId/regions`
- `PUT /api/admin/products/:productId/linked-kb-articles`
- `POST /api/admin/products/create-product-option-pairs`
- `POST /api/admin/products/update-product-option-pairs`
- `POST /api/admin/products/delete-product-option-pairs`

## Read endpoint notes (practical gotchas)

### `GET /api/admin/products/fetch-options`

- Query params mirror list plus `excludeProductId`, `statusFilter`, `language`.
- In practical usage treat `excludeProductId` as required; omitting it can fail in some deployments.

### `POST /api/admin/products/read-product-option-pairs`

```json
{
  "mainProductId": "uuid",
  "optionProductIds": ["uuid1", "uuid2"],
  "mode": "records"
}
```

- `mainProductId` required.
- `optionProductIds` required for `records` (default) and `exists`.
- `ids` mode works without `optionProductIds`.
- In some deployments, products with no pairs return `VAL-ERR-001` instead of empty result sets.

## Write endpoint payloads

### `POST /api/admin/products/update`

Required fields:

- `productId` (UUID, required; field name must be `productId`).

Optional fields:

- Scalars: `productCode`, `translationKey`, `owner`, `statusCode`, `showAsProductCard`, `memberLineId`, `catalogSectionId`, `visibility.*`.
- Arrays/objects: `specialistsGroups`, `translations`.
- Images: `detailImageFileId`, `thumbnailImageFileId`.
- `regions` (authoritative full replace when present; omit to preserve bindings)
- `articleIds` (authoritative full replace when present; `[]` unlinks all; omit to preserve links)

Minimal payload:

```json
{
  "productId": "uuid",
  "productCode": "PRD-EDIT-001",
  "catalogSectionId": "section-uuid",
  "showAsProductCard": true
}
```

`memberLineId` / `catalogSectionId` set placement when present (XOR). Omit both to leave placement unchanged.

Translations payload (per-language entry needs both `name` and `shortDesc`):

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

### `POST /api/admin/products/import`

Required fields:

- `items` (array, min 1)
- each item requires `productCode` and `translations`

Important validation behavior:

- at least one translation row per item must have `name`; `shortDesc` is
  optional for import rows. Rows without any named translation are skipped with
  `reason_code=NO_VALID_TRANSLATIONS`.

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

## Product line endpoint contracts

Product-line routes in this skill require the same `adminProducts:items:*`
permissions as product routes. Editor scope includes read-all and update-all,
but not create, delete, or owner changes.

### `GET /api/admin/product-lines/fetch-all`

Query params: `language`, `searchQuery`, `statusFilter`.
Success code: `ADM_PRD-SUC-021`; data contains `{ "productLines": [...] }`.

### `GET /api/admin/product-lines/fetch`

Query param: `id` (required line UUID). Success code: `ADM_PRD-SUC-027`; data
contains `productLine`, `translations`, `members`, and `statuses`.

### `GET /api/admin/product-lines/search`

Query params: `q`, `limit`, `language`. Success code: `ADM_PRD-SUC-026`.

### `POST /api/admin/product-lines/update`

Payload:

```json
{
  "lineId": "line-uuid",
  "lineCode": "LINE-001",
  "statusCode": "active",
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

Success code: `ADM_PRD-SUC-023`. `memberProductIds` is authoritative when
present; omit it to preserve current line membership.

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

### `PUT /api/admin/products/:productId/regions`

Alternative to `regions` on POST create/update (preferred for additive script updates).

Payload (`region_id`, `category_id` are snake_case here):

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

Payload:

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

## Authoritative vs partial semantics

| Operation | Semantics |
|---|---|
| `POST /update` — scalar fields and visibility | Partial merge (omitted fields preserve values) |
| `POST /update` — `translations` | Language entry applied only when both `name` and `shortDesc` are present |
| `POST /update` — `specialistsGroups` | Present = authoritative replace; `[]` clears all groups |
| `POST /update` — `memberLineId` / `catalogSectionId` | UUID set / `""` clear / omit unchanged (XOR) |
| `POST /product-lines/update` — `memberProductIds` | Present = authoritative replace for line members |
| `POST /update` — image file ids | Omitted = preserve; empty string = clear |
| `PUT .../regions` | Authoritative full replace |
| `PUT .../linked-kb-articles` | Authoritative full replace (`[]` unlinks all) |
| `delete-product-option-pairs` with `all: true` | Deletes all pairs for `mainProductId` |

Additional pair semantics:

- `relationKind` values are `optional`, `required`, `incompatible`.
- `unitsCount` is persisted only for `required`.
- `read-product-option-pairs` `records` mode returns `relationKind` per pair.
- `count-product-option-pairs` counts only `optional/required` pairs.

Helper scripts for preserve-and-add flows:

- `admin-products-linked-kb-add.sh`
- `admin-products-regions-set-category.sh`
- `admin-products-specialists-add.sh`

## Field naming

- Request payloads: camelCase.
- Exception: `PUT /:productId/regions` items use `region_id`, `category_id`.
- Response entities: snake_case.

## Common error codes

- `AUT-ERR-401`: missing/invalid/expired JWT.
- `AZN-ERR-403`: permission denied.
- `USR-ERR-404`: product not found.
- `VAL-ERR-001`: validation failed (wrong body fields/types, bad UUID, missing required fields).
- `VAL-ERR-400`: missing required endpoint-specific value.
- `REQ-ERR-001`: malformed JSON body.
- `FILE-ERR-*`: FS reconcile/upload errors for image fields.
- `SYS-ERR-500`: internal error.


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

## Non-goals for this skill

`role-admin-products-editor` does not call create/delete/assign-owner, clear-all, or settings routes. It also does not call product-line create/delete/assign-owner routes.

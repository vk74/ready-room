# evi API contract - Admin Products specialist

<!--
version: 1.7.1
Short description: Specialist-scope Admin Products endpoint contract for role-admin-products-specialist.
File: api-contract.md

Changes in v1.7.1:
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.

Changes in v1.7.0:
- Documented catalog visibility (statusCode=active + placement) and scalar
  memberLineId/catalogSectionId / showAsProductCard contracts.
- Added catalog-section-options and bulk status/placement/card/regions/specialists
  endpoint contracts (backend enforces :own scope).

Changes in v1.6.0:
- Documented optional `regions` and `articleIds` on POST create/update for unified
  product editor save; PUT sub-resources remain available for scripts.

Changes in v1.5.0:
- Updated products and product-lines list contracts for statusFilter-only listing.

Changes in v1.4.0:
- Added specialist-scope product-line list/get/search/create/update/assign-owner
  contracts.
- Declared product-line delete out of scope for this role.

Changes in v1.3.0:
- Updated option-pairs create/update contracts from `isRequired` to
  `relationKind` (`optional | required | incompatible`).
- Clarified `read-product-option-pairs` `records` response shape and that
  `count-product-option-pairs` excludes `incompatible` relations.

Changes in v1.2.0:
- Added create contract caveats from retest: `productType` requirement in
  tested deployments, create success `data.id`, owner-null-after-create note.
- Added option-pairs read caveat for products without pairs (`VAL-ERR-001` on
  some deployments).

Changes in v1.1.0:
- Added explicit write payload contracts (required fields + minimal/full examples)
  for create, update, assign-owner, and option-pair operations.
- Added translation-format and update behavior notes to prevent partial payload
  mistakes (`translations` is object-shaped; update requires name+shortDesc per language entry).
- Added practical read-route parameter notes (`excludeProductId`, `optionProductIds`).
- Added explicit response envelope examples (`success`, `code`, `data`) for consistency
  with skill authoring requirements.

Changes in v1.0.0:
- Initial specialist contract aligned with role.adminProducts.specialist.
- Included read-own endpoints plus create/update/assign-owner own-scope mutations.
- Excluded import/delete/settings/clear-all endpoints.
-->

Reference for `role-admin-products-specialist`.

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

## Role scope

This skill maps to `role.adminProducts.specialist`:

- `adminProducts:module:access`
- `adminProducts:items:create:all`
- `adminProducts:items:read:own`
- `adminProducts:items:update:own`
- `adminProducts:items:change_owner:own`

## Endpoints in scope

Read endpoints (own-scope enforced by backend):

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

- `POST /api/admin/products/create`
- `POST /api/admin/products/update`
- `POST /api/admin/products/assign-owner`
- `GET /api/admin/product-lines/fetch-all`
- `GET /api/admin/product-lines/fetch`
- `GET /api/admin/product-lines/search`
- `POST /api/admin/product-lines/create`
- `POST /api/admin/product-lines/update`
- `POST /api/admin/product-lines/assign-owner`
- `PUT /api/admin/products/:productId/regions`
- `PUT /api/admin/products/:productId/linked-kb-articles`
- `POST /api/admin/products/create-product-option-pairs`
- `POST /api/admin/products/update-product-option-pairs`
- `POST /api/admin/products/delete-product-option-pairs`

## Scope behavior

- Product access checks use owner or `product_specialists` group membership.
- Calls against foreign products return `AZN-ERR-403`.
- `POST /assign-owner` runs in own-scope mode (`adminProducts:items:change_owner:own`).
- Product-line read/update/assign-owner routes use the same `:own` permission
  model for lines owned by the caller.

## Field naming and semantics

- Request payloads: camelCase.
- Exception: `PUT /:productId/regions` entries use `region_id`, `category_id`.
- Response entities: snake_case.
- `translations` in requests is an object keyed by language (`english`, `russian`), not an array.
- `POST /update` is partial for scalar fields, but translation language entry updates only when both `name` and `shortDesc` are present.
- `memberLineId` / `catalogSectionId` on product create/update set placement when present.
- `memberProductIds` on product-line update is authoritative when present.
- `PUT` regions/linked-kb endpoints are authoritative full-replace.

Helper scripts for preserve-and-add flows:

- `admin-products-linked-kb-add.sh`
- `admin-products-regions-set-category.sh`
- `admin-products-specialists-add.sh`

## Read endpoint notes (practical gotchas)

### `GET /api/admin/products/fetch-options`

- Query params: same paging/sort set as list + `excludeProductId`, `statusFilter`, `language`.
- In practical usage treat `excludeProductId` as required; omitting it can lead to request failure in some deployments.

### `POST /api/admin/products/read-product-option-pairs`

Request body:

```json
{
  "mainProductId": "uuid",
  "optionProductIds": ["uuid1", "uuid2"],
  "mode": "records"
}
```

- `mainProductId` required.
- `mode`:
  - `records` (default): requires `optionProductIds`.
  - `exists`: requires `optionProductIds`.
  - `ids`: does not require `optionProductIds`.
- In some deployments, calling this endpoint for products with no pairs returns `VAL-ERR-001`.
- In `records` mode each pair contains `optionProductId`, `relationKind`, `unitsCount`.

## Write endpoint payloads

### `POST /api/admin/products/create`

Required fields:

- `productCode` (string)
- `productType` (required in tested deployments with stricter create validation)
- `translationKey` (string)
- `owner` (username)
- `translations` (object; at least one valid language entry with both `name` and `shortDesc`)
- Optional: `memberLineId` / `catalogSectionId` (scalar placement; UUID set / `""` clear / omit unchanged)
- Optional: `statusCode`, `showAsProductCard`

Optional fields:

- `statusCode` (defaults to `draft`)
- `specialistsGroups` (array of group names)
- `detailImageFileId`, `thumbnailImageFileId` (UUID strings via FS flow)
- `regions` (array of `{ region_id, category_id }`; authoritative full replace)
- `articleIds` (array of KB article UUIDs; authoritative full replace)

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

Practical note: immediately after create, some runs still return `owner: null` on read endpoints.

Full payload:

```json
{
  "productCode": "PRD-NEW-001",
  "productType": "default",
  "translationKey": "product.prd_new_001",
  "owner": "bot_username",
  "statusCode": "active",
  "specialistsGroups": ["product_specialists"],
  "detailImageFileId": "uuid",
  "thumbnailImageFileId": "uuid",
  "translations": {
    "english": {
      "name": "New product",
      "shortDesc": "Short description",
      "longDesc": "Long description",
      "techSpecs": { "power": "220V" }
    },
    "russian": {
      "name": "New product RU",
      "shortDesc": "Short description RU",
      "longDesc": "Long description RU"
    }
  }
}
```

### `POST /api/admin/products/update`

Required fields:

- `productId` (UUID, required; not `id`).

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
  "productCode": "PRD-NEW-001-UPDATED",
  "catalogSectionId": "section-uuid",
  "showAsProductCard": true
}
```

`memberLineId` / `catalogSectionId` set placement when present (XOR). Omit both to leave placement unchanged.

Translations update payload (language entry must include both `name` and `shortDesc`):

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

### `POST /api/admin/products/assign-owner`

Required fields:

- `productIds` (array of UUIDs, min 1)
- `newOwnerUsername` (string username)

Payload:

```json
{
  "productIds": ["uuid"],
  "newOwnerUsername": "username"
}
```

## Product line endpoint contracts

### `GET /api/admin/product-lines/fetch-all`

Query params: `language`, `searchQuery`, `statusFilter`.
Success code: `ADM_PRD-SUC-021`; own-scope callers see lines they own.

### `GET /api/admin/product-lines/fetch`

Query param: `id` (required line UUID). Success code: `ADM_PRD-SUC-027`.

### `GET /api/admin/product-lines/search`

Query params: `q`, `limit`, `language`. Success code: `ADM_PRD-SUC-026`.

### `POST /api/admin/product-lines/create`

Payload:

```json
{
  "lineCode": "LINE-001",
  "statusCode": "draft",
  "translations": {
    "english": {
      "name": "Product line",
      "shortDesc": "Grouped products"
    }
  },
  "memberProductIds": ["product-uuid"]
}
```

Success code: `ADM_PRD-SUC-022`; success data contains `id` and optional
`lineCode`.

### `POST /api/admin/product-lines/update`

Payload:

```json
{
  "lineId": "line-uuid",
  "statusCode": "active",
  "memberProductIds": ["product-uuid-1", "product-uuid-2"]
}
```

Success code: `ADM_PRD-SUC-023`. `memberProductIds` is authoritative when
present; omit it to preserve current line membership.

### `POST /api/admin/product-lines/assign-owner`

Payload:

```json
{
  "lineIds": ["line-uuid"],
  "newOwnerUsername": "username"
}
```

Success code: `ADM_PRD-SUC-013`; own-scope callers can only affect lines they
own.

### `POST /api/admin/products/create-product-option-pairs`

Required fields:

- `mainProductId` (UUID)
- `pairs` (array, min 1)
- each pair requires `optionProductId`; `relationKind` accepts `optional`, `required`, `incompatible`; `unitsCount` is meaningful for `required`

Payload:

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

Same payload schema as create:

```json
{
  "mainProductId": "uuid",
  "pairs": [
    { "optionProductId": "uuid", "relationKind": "required", "unitsCount": 2 }
  ]
}
```

### `POST /api/admin/products/delete-product-option-pairs`

`all=true` mode payload:

```json
{
  "mainProductId": "uuid",
  "all": true
}
```

Selected-delete mode payload:

```json
{
  "mainProductId": "uuid",
  "all": false,
  "selectedOptionIds": ["uuid1", "uuid2"]
}
```

### `POST /api/admin/products/count-product-option-pairs`

Counts only `relationKind` values `optional` and `required`; `incompatible` is excluded from this counter.

## Common error codes

- `AUT-ERR-401`: missing/invalid/expired JWT.
- `AZN-ERR-403`: permission denied or product outside own scope.
- `USR-ERR-404`: product not found.
- `VAL-ERR-001`: validation failed (wrong body fields/types, bad UUID, missing required payload fields).
- `VAL-ERR-400`: missing required query/path/body input in endpoint-specific checks.
- `VAL-ERR-409`: duplicate product code or translation key on create.
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

`role-admin-products-specialist` does not call import, product delete, product-line delete, clear-all, or settings endpoints.

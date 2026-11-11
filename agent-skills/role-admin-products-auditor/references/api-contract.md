# evi API contract - Admin Products auditor

<!--
version: 1.8.1
Short description: Auditor-scope Admin Products endpoint contract for role-admin-products-auditor.
File: api-contract.md

Changes in v1.8.1:
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.

Changes in v1.8.0:
- Documented catalog visibility fields (status_code, placement, show_as_product_card).
- Added GET /api/admin/products/catalog-section-options read contract.

Changes in v1.7.0:
- Updated products and product-lines list contracts for statusFilter-only listing.

Changes in v1.6.0:
- Documented GET /api/admin/products/regions consumer list (module:access).

Changes in v1.5.0:
- Added read-only product-line list/get/search endpoint contracts.
- Declared product-line writes out of scope for auditor.

Changes in v1.4.0:
- Updated option-pairs `records` response contract from `isRequired` to
  `relationKind` (`optional | required | incompatible`).
- Clarified that `count-product-option-pairs` excludes `incompatible` relations.

Changes in v1.3.0:
- Added practical read caveat: `read-product-option-pairs` on products without
  pairs can return `VAL-ERR-001` in some deployments.

Changes in v1.2.0:
- Documented practical requirement to pass `excludeProductId` to
  `GET /fetch-options` in regular workflows.
- Clarified `read-product-option-pairs` parameter rules:
  `optionProductIds` required for `records` and `exists` modes.
- Added explicit payload examples per read-product-option-pairs mode.

Changes in v1.1.0:
- Renamed reference from reader to auditor and aligned role naming with evi RBAC.
- Added settings read endpoint to match adminProducts:settings:read:all scope.
- Updated non-goals for strict one-skill-per-role model.

Changes in v1.0.0:
- Initial Admin Products reader API contract reference.
- Added endpoint list, query/body params, response shapes, and scope notes.
-->

Reference for `role-admin-products-auditor`.

All routes below are protected and require:

```http
Authorization: Bearer <JWT>
```

JWT is acquired via `POST /api/auth/bot/token` (see `role-auth` skill).

## Response envelope

Success:

```json
{
  "success": true,
  "code": "ADM_PRD-SUC-011",
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

## Field naming

- **Request bodies** (POST read routes): camelCase (`mainProductId`, `optionProductIds`, `mode`).
- **Response `data`**: snake_case for product entities (`product_id`, `product_code`, `status_code`, …).
- Product list/fetch responses may include `productLines` / `product_lines`
  membership data depending on endpoint shape.
- **Pagination block** in list/options responses uses camelCase keys (`totalItems`, `currentPage`, …) — legacy contract from the Node.js API.
- Do not mirror response snake_case keys into request bodies when calling write endpoints in other skills.

## Scope behavior

Auditor bots use `adminProducts:items:read:all`, so product read routes are global (no own-scope filtering). Settings read is allowed via `adminProducts:settings:read:all`.

## Auditor endpoints

### `GET /api/admin/products/fetch-all-products`

- Purpose: paginated product list with search, sort, and filters
- Permission: `adminProducts:items:read` (`:all` or `:own`)
- Success code: `ADM_PRD-SUC-011`
- Query params (all optional):
  - `page` (default `1`)
  - `itemsPerPage` (default `25`, max `100`)
  - `searchQuery` — matches `product_code`, translation `name`, or `translation_key`
  - `sortBy` — `product_code` | `name` | `status_code` | `owner` (default `product_code`)
  - `sortDesc` — `true` | `false` (default `false`)
  - `statusFilter` — product status enum value
  - `language` — translation language for name column (default `english`)
- `data` shape:

```json
{
  "products": [
    {
      "product_id": "uuid",
      "product_code": "PRD-001",
      "translation_key": "product.prd001",
      "status_code": "active",
      "catalog_section_id": "section-uuid",
      "show_as_product_card": true,
      "owner": "username",
      "specialists_groups": ["group.name"],
      "name": "Product title",
      "product_lines": ["Line name"]
    }
  ],
  "pagination": {
    "totalItems": 42,
    "totalPages": 2,
    "currentPage": 1,
    "itemsPerPage": 25
  }
}
```

### `GET /api/admin/products/fetch`

- Purpose: fetch one product with translations, owner, specialists, and status reference list
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-001`
- Query params:
  - `id` (required): product UUID
- `data` shape:

```json
{
  "product": { "product_id": "uuid", "product_code": "PRD-001", "status_code": "active" },
  "translations": [
    {
      "translation_id": "uuid",
      "language_code": "english",
      "name": "Title",
      "short_desc": "Short",
      "long_desc": "Long",
      "tech_specs": {}
    }
  ],
  "owner": "username",
  "specialistsGroups": ["group.name"],
  "productLines": [
    {
      "line_id": "uuid",
      "line_code": "LINE-001",
      "name": "Line name"
    }
  ],
  "statuses": [{ "status_code": "active" }]
}
```

Note: `specialistsGroups` in this response uses camelCase (legacy shape).

### `GET /api/admin/products/fetch-options`

- Purpose: list candidate option products (all products except one excluded main product)
- Permission: `adminProducts:module:access`
- Success code: `ADM_PRD-SUC-014`
- Query params (all optional):
  - `page`, `itemsPerPage`, `searchQuery`, `sortBy`, `sortDesc` — same semantics as list
  - `excludeProductId` — UUID of the main product to omit from results
  - `statusFilter` — status enum filter
  - `language` — default `english`
- `data` shape: same as list (`products` + `pagination`)
- Practical note: in many real flows `excludeProductId` should be treated as required input.

### `GET /api/admin/products/fetch-statuses`

- Purpose: list valid `app.product_status` enum values
- Permission: `adminProducts:module:access`
- Success code: `ADM_PRD-SUC-015`
- `data` shape:

```json
{
  "statuses": [{ "status_code": "active" }, { "status_code": "draft" }]
}
```

### `GET /api/admin/products/:productId/regions`

- Purpose: all regions with optional per-product taxable category binding
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-004`
- `data`: array of region objects (not wrapped):

```json
[
  {
    "region_id": 1,
    "region_name": "Default",
    "category_id": 2,
    "category_name": "Standard VAT"
  }
]
```

### `GET /api/admin/products/:productId/linked-kb-articles`

- Purpose: KB articles linked to the product (preferences tab)
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-017`
- `data`: array of linked articles:

```json
[
  {
    "article_id": "uuid",
    "short_id": "abc12",
    "title": "Article title",
    "tree_id": "uuid",
    "tree_name": "Tree name",
    "status": "published"
  }
]
```

### `POST /api/admin/products/read-product-option-pairs`

- Purpose: read option-product pairs for a main product
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-006`
- Request body (JSON, camelCase):

```json
{
  "mainProductId": "uuid",
  "optionProductIds": ["uuid1", "uuid2"],
  "mode": "records"
}
```

- `mode` values:
  - `records` (default) — returns `pairs` array with `optionProductId`, `relationKind`, `unitsCount`; `optionProductIds` required
  - `ids` — returns `optionProductIds` array; `optionProductIds` not required
  - `exists` — returns `existsMap` object keyed by option product id; `optionProductIds` required
- Practical caveat: when the main product has no option pairs, some deployments return `VAL-ERR-001`.

Mode-specific payload examples:

`records`:

```json
{
  "mainProductId": "uuid",
  "optionProductIds": ["uuid1", "uuid2"]
}
```

`exists`:

```json
{
  "mainProductId": "uuid",
  "mode": "exists",
  "optionProductIds": ["uuid1", "uuid2"]
}
```

`ids`:

```json
{
  "mainProductId": "uuid",
  "mode": "ids"
}
```

### `POST /api/admin/products/count-product-option-pairs`

- Purpose: count option pairs for a main product
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-010`
- Request body:

```json
{
  "mainProductId": "uuid"
}
```

- `data` shape: `{ "count": 3 }`
- Count includes only `relationKind` values `optional` and `required`; `incompatible` is excluded.

### `GET /api/admin/products/regions`

- Purpose: master region list for the regions/VAT editor (consumer read of `app.regions`; does not require `adminReference:read`)
- Permission: `adminProducts:module:access`
- Success code: `ADM_PRD-SUC-028`
- `data`: array (not wrapped):

```json
[
  {
    "region_id": 1,
    "region_name": "EU",
    "created_at": "2024-01-01T00:00:00Z",
    "updated_at": null
  }
]
```

### `GET /api/admin/products/taxable-categories/by-region/:regionId`

- Purpose: taxable categories available for a region (regions/VAT editor reference data)
- Permission: `adminProducts:module:access`
- Success code: `ADM_PRD-SUC-016`
- Path param: `regionId` — integer region id
- `data`: array (not wrapped):

```json
[
  { "category_id": 1, "category_name": "Standard VAT" }
]
```

### `GET /api/admin/product-lines/fetch-all`

- Purpose: read product lines with owner/member counters and placement fields
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-021`
- Query params: `language`, `searchQuery`, `statusFilter`
- `data` shape: `{ "productLines": [...] }`

### `GET /api/admin/product-lines/fetch`

- Purpose: read one product line, translations, members, and statuses
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-027`
- Query params: `id` (required line UUID)

### `GET /api/admin/product-lines/search`

- Purpose: lightweight product-line picker lookup
- Permission: `adminProducts:items:read`
- Success code: `ADM_PRD-SUC-026`
- Query params: `q`, `limit`, `language`

### `GET /api/core/settings`

- Purpose: read app settings, including `AdminProducts.*` section values
- Permission: `adminProducts:settings:read:all` (or broader settings read role)
- Success code: `STG-SUC-002`
- Typical extraction:

```bash
jq '.data.settings.AdminProducts'
```

## Common auditor-relevant error codes

- `AUT-ERR-401`: missing/invalid/expired JWT (retry after re-auth)
- `AZN-ERR-403`: caller lacks permission or product is outside `:own` scope
- `USR-ERR-404`: product not found (`GET /fetch`)
- `VAL-ERR-400`: missing required query/path parameter
- `VAL-ERR-001`: invalid request body (pairs POST routes)
- `REQ-ERR-001`: malformed JSON body
- `SYS-ERR-500`: internal error


## Catalog visibility (read)

Product and list rows expose `status_code`, `member_line_id`, `catalog_section_id`, and `show_as_product_card`. Catalog-visible means `status_code` is `active` with reachable placement (section or active line in an active section).

### `GET /api/admin/products/catalog-section-options`

- Success code: `ADM_PRD-SUC-029`
- `data`: array of `{ "section_id", "name", "status" }`

## Non-goals for this skill

`role-admin-products-auditor` does not call any mutation endpoint: no product create/update/delete/import/assign-owner, no product-line create/update/delete/assign-owner, no product `PUT` writes, no clear-all, and no settings update.

---
name: role-admin-products-admin
description: >
  Admin Products admin skill for evi. Covers full admin scope: read, create,
  update, delete, assign-owner, import, clear-all, and AdminProducts settings
  governance for bots mapped to role.adminProducts.admin.
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

# role-admin-products-admin

<!--
version: 1.7.3
Short description: Full-scope admin role skill for Admin Products.
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
- Added product-line CRUD and membership operations for evi 0.21.1.
- Updated product import guidance: translation `shortDesc` is optional when
  `name` is present.

Changes in v1.4.0:
- Updated option-pairs payloads from `isRequired` to `relationKind`
  (`optional | required | incompatible`) to match current backend contracts.
- Documented that `incompatible` relations are symmetric and maintained as
  mirrored reverse rows by the service.
- Clarified that pair counts exclude `incompatible` and include only
  `optional/required` relations.

Changes in v1.3.1:
- Added last_evi_release frontmatter marker (skills pack sync at evi 0.20.17).

Changes in v1.3.0:
- Documented create/import success response shapes (`data.id`,
  `imported_count`, `row_results`, `errors`) and added quick-start caveats.
- Added destructive quick-start warning for `PUT /regions` and
  `PUT /linked-kb-articles` authoritative full-replace semantics.
- Added practical read caveat for option pairs on products without pairs
  (`VAL-ERR-001`) and owner-null-after-create observation.

Changes in v1.2.0:
- Added explicit payload quick starts for delete, assign-owner, create, update,
  import, and option-pair write operations.
- Documented strict field names that caused trial-and-error in testing:
  `productIds`, `newOwnerUsername`, and `productId` for update.
- Clarified translation update caveat and practical read-route parameter gotchas.

Changes in v1.1.0:
- Switched to standalone full-role model aligned with role.adminProducts.admin.
- Added full products read/write operation set to this skill.
- Kept clear-all and settings governance as admin-only flows.

Changes in v1.0.0:
- Initial Admin Products admin skill with clear-all start/status and module settings.
- Added destructive-safety guidance, polling flow, and languages.scope constraints.
- Added role-composition guidance for the full products admin bundle.
-->

Standalone Admin Products skill for bots assigned to `role.adminProducts.admin`.

## Role mapping

This skill is the external-agent counterpart of evi role `role.adminProducts.admin`.
Allowed permissions in evi: all `adminProducts:*`.

## Scope (full admin role)

Included methods:

- `adminProducts.items.list` -> `GET /api/admin/products/fetch-all-products`
- `adminProducts.items.get` -> `GET /api/admin/products/fetch`
- `adminProducts.items.search` -> `GET /api/admin/products/search`
- `adminProducts.options.list` -> `GET /api/admin/products/fetch-options`
- `adminProducts.statuses.list` -> `GET /api/admin/products/fetch-statuses`
- `adminProducts.catalogSectionOptions.list` -> `GET /api/admin/products/catalog-section-options`
- `adminProducts.regions.get` -> `GET /api/admin/products/:productId/regions`
- `adminProducts.linkedKbArticles.get` -> `GET /api/admin/products/:productId/linked-kb-articles`
- `adminProducts.optionPairs.read` -> `POST /api/admin/products/read-product-option-pairs`
- `adminProducts.optionPairs.count` -> `POST /api/admin/products/count-product-option-pairs`
- `adminProducts.taxableCategories.byRegion` -> `GET /api/admin/products/taxable-categories/by-region/:regionId`
- `adminProducts.items.create` -> `POST /api/admin/products/create`
- `adminProducts.items.update` -> `POST /api/admin/products/update`
- `adminProducts.items.delete` -> `POST /api/admin/products/delete`
- `adminProducts.items.assignOwner` -> `POST /api/admin/products/assign-owner`
- `adminProducts.items.import` -> `POST /api/admin/products/import`
- `adminProducts.items.bulkStatus` -> `POST /api/admin/products/bulk-status`
- `adminProducts.items.bulkPlacement` -> `POST /api/admin/products/bulk-placement`
- `adminProducts.items.bulkProductCard` -> `POST /api/admin/products/bulk-product-card`
- `adminProducts.items.bulkRegions` -> `POST /api/admin/products/bulk-regions`
- `adminProducts.items.bulkSpecialists` -> `POST /api/admin/products/bulk-specialists`
- `adminProducts.productLines.list` -> `GET /api/admin/product-lines/fetch-all`
- `adminProducts.productLines.get` -> `GET /api/admin/product-lines/fetch`
- `adminProducts.productLines.search` -> `GET /api/admin/product-lines/search`
- `adminProducts.productLines.create` -> `POST /api/admin/product-lines/create`
- `adminProducts.productLines.update` -> `POST /api/admin/product-lines/update`
- `adminProducts.productLines.delete` -> `POST /api/admin/product-lines/delete`
- `adminProducts.productLines.assignOwner` -> `POST /api/admin/product-lines/assign-owner`
- `adminProducts.productLines.bulkStatus` -> `POST /api/admin/product-lines/bulk-status`
- `adminProducts.productLines.bulkPlacement` -> `POST /api/admin/product-lines/bulk-placement`
- `adminProducts.regions.put` -> `PUT /api/admin/products/:productId/regions`
- `adminProducts.linkedKbArticles.put` -> `PUT /api/admin/products/:productId/linked-kb-articles`
- `adminProducts.optionPairs.create` -> `POST /api/admin/products/create-product-option-pairs`
- `adminProducts.optionPairs.update` -> `POST /api/admin/products/update-product-option-pairs`
- `adminProducts.optionPairs.delete` -> `POST /api/admin/products/delete-product-option-pairs`
- `adminProducts.settings.clearAll.start` -> `POST /api/admin/products/clear-all/start`
- `adminProducts.settings.clearAll.status` -> `GET /api/admin/products/clear-all/status/:operationId`
- `adminProducts.settings.read` -> `GET /api/core/settings`
- `adminProducts.settings.update` -> `POST /api/admin/settings/update` (section `AdminProducts`)

Explicitly excluded:

- Settings for other modules (`AdminCatalog`, `KnowledgeBase`, …)
- `AdminProducts.Fs.Quotas` and other system-level quota settings


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

## Permissions

| Operation | Permission |
|---|---|
| Clear-all start/status | `adminProducts:settings:update:all` (`role.adminProducts.admin`) |
| Settings update (`AdminProducts.*`) | `adminProducts:settings:update:all` |
| Settings read (`GET /api/core/settings`) | `adminProducts:settings:read:all` (auditor) or `adminProducts:settings:update:all` (admin) |

Editor and specialist roles do **not** have `adminProducts:settings:update:all`.

## Destructive operations

**Clear-all** permanently deletes all products (snapshot taken at start), cascades FS files and KB links, and runs asynchronously via worker job `adminProducts.clear_all`.

- Requires `--confirm` CLI flag **and** `"confirm": true` in the request body
- Only one active operation at a time (`ADM_PRD-ERR-409-CLEAR-IN-PROGRESS` if another is running)
- Optional `batchSizeHint`: integer 100–50000 (default 5000 on the server)

**Settings update** changes one key at a time — not an authoritative full-section replace. Values are validated against JSON Schema in the database.

For product writes:

- `POST /delete` requires payload field `productIds` (UUID array).
- `POST /assign-owner` requires `productIds` + `newOwnerUsername`.
- `POST /update` requires `productId` (not `id`).
- `POST /create` and `POST /update` accept scalar placement: `memberLineId` or
  `catalogSectionId` (UUID set / `""` clear / omit unchanged).
- `POST /api/admin/product-lines/create|update` accept `catalogSectionId` the same way.
- `POST /api/admin/product-lines/update` treats present `memberProductIds` as
  the authoritative member set. Omitted preserves existing line members.

## Settings constraints

The Products Settings UI manages `AdminProducts.allowed.languages` — an array of language codes that must be a subset of the global `Application.RegionalSettings.allowed.languages`.

Before updating module languages, check scope:

```bash
bash scripts/admin-products-settings-get.sh \
  | jq '.data.settings["Application.RegionalSettings"]["languages.scope"]'
```

When `languages.scope` is `"global"`, per-module `allowed.languages` is ignored by the UI — do not update it unless scope is `"per-module"`.

## Clear-all polling flow

The UI polls every 3 seconds. Typical agent flow:

1. `admin-products-clear-all-start.sh --confirm` — save `operation_id` from response `data`
2. Loop: `admin-products-clear-all-status.sh <operation_id>` while `status` is `pending` or `running`
3. Stop on `completed` or `failed`; on `failed`, inspect `error_msg` in the status payload

## Write payload quick start

`PUT /regions` and `PUT /linked-kb-articles` are **authoritative full replace** operations. Prefer helper scripts (`admin-products-regions-set-category.sh`, `admin-products-linked-kb-add.sh`) when you need additive updates.

`POST /create` minimum payload:

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
  }
}
```

`POST /create` success shape:

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

Practical note: in tested environments `productType` may be required by API validation. Also, `owner` in subsequent read payloads may remain `null` immediately after create.

`POST /update` minimum payload:

```json
{
  "productId": "uuid",
  "productCode": "PRD-NEW-001-UPDATED"
}
```

`POST /delete` payload:

```json
{
  "productIds": ["uuid"]
}
```

`POST /assign-owner` payload:

```json
{
  "productIds": ["uuid"],
  "newOwnerUsername": "username"
}
```

`POST /import` payload skeleton:

```json
{
  "overwriteExisting": false,
  "items": [
    {
      "productCode": "PRD-IMPORT-001",
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

`POST /import` success shape includes batch summary fields:

```json
{
  "success": true,
  "code": "ADM_PRD-SUC-010",
  "data": {
    "imported_count": 1,
    "updated_count": 0,
    "skipped_count": 0,
    "error_count": 0,
    "row_results": [],
    "errors": []
  }
}
```

`POST /api/admin/product-lines/create` minimum payload:

```json
{
  "lineCode": "LINE-001",
  "statusCode": "draft",
  "catalogSectionId": "section-uuid",
  "translations": {
    "english": {
      "name": "Product line",
      "shortDesc": "Grouped products"
    }
  },
  "memberProductIds": ["product-uuid"]
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

`memberProductIds` is authoritative when present. To leave membership untouched,
omit the field.

Make a product catalog-visible (status + standalone section placement):

```json
{
  "productId": "product-uuid",
  "statusCode": "active",
  "catalogSectionId": "section-uuid",
  "showAsProductCard": true
}
```

Or place it inside a product line:

```json
{
  "productId": "product-uuid",
  "statusCode": "active",
  "memberLineId": "line-uuid"
}
```

Bulk status example (`admin-products-bulk-status.sh`):

```json
{
  "productIds": ["uuid-1", "uuid-2"],
  "statusCode": "active"
}
```

Bulk placement example (`admin-products-bulk-placement.sh`):

```json
{
  "productIds": ["uuid-1", "uuid-2"],
  "catalogSectionId": "section-uuid"
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

Practical read notes:

- `GET /fetch-options`: provide `excludeProductId` in regular workflows.
- `POST /read-product-option-pairs`: `optionProductIds` is required for `records` (default) and `exists` modes.
- `POST /read-product-option-pairs`: when the main product has no option pairs, some deployments return `VAL-ERR-001` instead of an empty list.
- `relationKind` values for pair create/update are `optional`, `required`, `incompatible`; `unitsCount` is used only with `required`.
- `count-product-option-pairs` returns count for `optional/required` pairs only (excludes `incompatible`).

## JWT contract

Every protected backend request uses:

```http
Authorization: Bearer <JWT>
```

JWT lifecycle is delegated to the shared auth scripts (vendored at `scripts/_lib/`). Resolution order: `REQUEST_SCRIPT` → vendored `scripts/_lib/` → `../../role-auth/scripts/`.

Environment variables (`BASE_URL`, `API_KEY`, TLS options) must be **exported**.

All JSON-body requests send `Content-Type: application/json` (scripts set this automatically).

## Script map

- `scripts/admin-products-clear-all-start.sh --confirm [--batch-size-hint N]`
- `scripts/admin-products-clear-all-status.sh <operation_id>`
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
- `scripts/admin-products-create.sh <payload.json>`
- `scripts/admin-products-update.sh <payload.json>`
- `scripts/admin-products-delete.sh <payload.json>`
- `scripts/admin-products-assign-owner.sh <payload.json>`
- `scripts/admin-products-import.sh <payload.json>`
- `scripts/admin-products-bulk-status.sh <payload.json>`
- `scripts/admin-products-bulk-placement.sh <payload.json>`
- `scripts/admin-products-bulk-product-card.sh <payload.json>`
- `scripts/admin-products-bulk-regions.sh <payload.json>`
- `scripts/admin-products-bulk-specialists.sh <payload.json>`
- `scripts/admin-product-lines-list.sh [--language english|russian] [--search "<text>"] [--status CODE]`
- `scripts/admin-product-lines-get.sh <line_id>`
- `scripts/admin-product-lines-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/admin-product-lines-create.sh <payload.json>`
- `scripts/admin-product-lines-update.sh <payload.json>`
- `scripts/admin-product-lines-delete.sh <payload.json>`
- `scripts/admin-product-lines-assign-owner.sh <payload.json>`
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
- `scripts/admin-products-settings-get.sh`
- `scripts/admin-products-settings-update.sh <payload.json>`
- `scripts/admin-products-allowed-languages-set.sh <language> [<language>...]`

## Usage examples

```bash
bash scripts/admin-products-list.sh --search "widget"
bash scripts/admin-products-create.sh ./payloads/create-product.json
bash scripts/admin-products-delete.sh ./payloads/delete-products.json
bash scripts/admin-products-import.sh ./payloads/import-batch.json
bash scripts/admin-products-assign-owner.sh ./payloads/assign-owner.json
bash scripts/admin-product-lines-list.sh --search "bundle"
bash scripts/admin-product-lines-create.sh ./payloads/create-product-line.json
bash scripts/admin-product-lines-update.sh ./payloads/update-product-line-members.json
bash scripts/admin-products-catalog-section-options.sh
bash scripts/admin-products-bulk-status.sh ./payloads/bulk-status.json
bash scripts/admin-products-bulk-placement.sh ./payloads/bulk-placement.json

bash scripts/admin-products-settings-get.sh \
  | jq '.data.settings.AdminProducts["allowed.languages"]'

bash scripts/admin-products-allowed-languages-set.sh english russian

bash scripts/admin-products-settings-update.sh ./payloads/update-setting.json

bash scripts/admin-products-clear-all-start.sh --confirm
bash scripts/admin-products-clear-all-status.sh "operation-uuid-from-start-response"
```

Example settings update payload (`update-setting.json`):

```json
{
  "sectionPath": "AdminProducts",
  "settingName": "allowed.languages",
  "value": ["english", "russian"]
}
```

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)
- [Editor skill](../role-admin-products-editor/SKILL.md)

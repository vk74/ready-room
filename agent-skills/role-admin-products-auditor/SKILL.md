---
name: role-admin-products-auditor
description: >
  Admin Products auditor skill for evi. Covers read-only product routes and
  read-only AdminProducts settings access for bots mapped to
  role.adminProducts.auditor.
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

# role-admin-products-auditor

<!--
version: 1.7.3
Short description: Auditor-scope Admin Products methods for external agents.
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
- Documented catalog visibility fields on product reads (status + placement).
- Added catalog-section-options read script; restored admin-products-search.sh.
- Updated `last_evi_release` marker to 0.21.7.

Changes in v1.6.0:
- Updated list-script contracts for statusFilter-only product/line lists.
- Updated `last_evi_release` marker to 0.21.5.

Changes in v1.5.0:
- Added read-only product-line list/get/search operations for evi 0.21.1.
- Explicitly excluded product-line writes outside auditor permissions.

Changes in v1.4.0:
- Updated option-pairs read contract notes to `relationKind`
  (`optional | required | incompatible`) instead of `isRequired`.
- Clarified that pair counts exclude `incompatible` and include only
  `optional/required` relations.

Changes in v1.3.1:
- Added last_evi_release frontmatter marker (skills pack sync at evi 0.20.17).

Changes in v1.3.0:
- Added read caveat for `read-product-option-pairs` on products without pairs:
  some deployments return `VAL-ERR-001` instead of empty result payloads.

Changes in v1.2.0:
- Added read-route validation notes for frequently missed required params:
  `excludeProductId` in options list and `optionProductIds` in option-pairs
  records/exists modes.
- Added payload quick-start examples for read-product-option-pairs modes.

Changes in v1.1.0:
- Renamed skill from reader to auditor to match role.adminProducts.auditor.
- Added settings read operation to match adminProducts:settings:read:all scope.
- Reworked role mapping to strict one-skill-per-role model.

Changes in v1.0.0:
- Initial read-only Admin Products reader skill.
- Added JWT contract and method list for /api/admin/products GET/read routes.
- Added script map and role-composition guidance for reader/editor/admin bundles.
-->

Read-only Admin Products access for bots assigned to `role.adminProducts.auditor`.

## Role mapping

This skill is the external-agent counterpart of evi role `role.adminProducts.auditor`.
Allowed permissions in evi:

- `adminProducts:module:access`
- `adminProducts:items:read:all`
- `adminProducts:settings:read:all`
- `adminProducts:settings:access`

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
- `adminProducts.productLines.list` -> `GET /api/admin/product-lines/fetch-all`
- `adminProducts.productLines.get` -> `GET /api/admin/product-lines/fetch`
- `adminProducts.productLines.search` -> `GET /api/admin/product-lines/search`
- `adminProducts.settings.read` -> `GET /api/core/settings`

Explicitly excluded:

- Any product write route (`POST /create`, `/update`, `/delete`, `/assign-owner`, `/import`, bulk-*)
- Any product-line write route (`POST /create`, `/update`, `/delete`, `/assign-owner`, bulk-*)
- Any product `PUT` mutation route
- Option-pair write routes (`create-product-option-pairs`, `update-product-option-pairs`, `delete-product-option-pairs`)
- Clear-all routes (`POST /clear-all/start`, `GET /clear-all/status/:operationId`)
- Settings update (`POST /api/admin/settings/update`)


## Catalog visibility (read)

Product/list responses include `status_code`, `member_line_id`, `catalog_section_id`, and `show_as_product_card`. A product is catalog-visible when `status_code` is `active` and it has reachable placement (section or active line in an active section). Use `admin-products-catalog-section-options.sh` to list placement section options.

## JWT contract

All protected requests use:

```http
Authorization: Bearer <JWT>
```

JWT is obtained and refreshed by shared auth scripts (vendored at `scripts/_lib/`; canonical copies in `role-auth`). Resolution order: `REQUEST_SCRIPT` override -> vendored `scripts/_lib` copy -> `../../role-auth/scripts/` (monorepo layout).

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
- `scripts/admin-product-lines-list.sh [--language english|russian] [--search "<text>"] [--status CODE]`
- `scripts/admin-product-lines-get.sh <line_id>`
- `scripts/admin-product-lines-search.sh <query> [--limit N] [--language english|russian]`
- `scripts/admin-products-settings-get.sh`

## Read payload quick start

`POST /read-product-option-pairs` default (`records`) mode:

```json
{
  "mainProductId": "uuid",
  "optionProductIds": ["uuid1", "uuid2"]
}
```

`POST /read-product-option-pairs` exists mode:

```json
{
  "mainProductId": "uuid",
  "mode": "exists",
  "optionProductIds": ["uuid1", "uuid2"]
}
```

`POST /read-product-option-pairs` ids mode:

```json
{
  "mainProductId": "uuid",
  "mode": "ids"
}
```

Practical note: for `admin-products-options-list.sh`, provide `--exclude-product-id <uuid>` in normal workflows.

Additional caveat: `POST /read-product-option-pairs` may return `VAL-ERR-001` when the selected main product has no option pairs in some deployments.

In `records` mode, pair entries return `optionProductId`, `relationKind`, `unitsCount`.
`count-product-option-pairs` includes only `optional/required` pairs (excludes `incompatible`).

## References

- [API contract](references/api-contract.md)
- [Auth skill](../role-auth/SKILL.md)

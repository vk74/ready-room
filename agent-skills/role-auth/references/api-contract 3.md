# evi API contract — bot authentication

<!--
version: 0.23.12
Short description: Bot API-key exchange and JWT contract for role-auth.
File: api-contract.md
Last evi release: 0.23.12

Changes in v0.23.12:
- Documented that GET /api/auth/permissions is the RBAC key list. KB access is GET /api/kb/access and the write response.
- Renamed skill/script references evi-* → role-*; env var examples dropped the EVI_ prefix.
- Introduced version header; renamed API key format prefix from evik_ to bkey_
  in format docs and examples.
-->

Reference for the `role-auth` skill. All evi JSON APIs use the same response envelope.

## Response envelope

Every handler returns:

```json
{
  "success": true,
  "code": "BOT_AUTH-SUC-001",
  "data": { }
}
```

On failure:

```json
{
  "success": false,
  "code": "BOT_AUTH-ERR-401"
}
```

Optional `meta` may appear on list endpoints. Clients should branch on `success` and `code`, not HTTP status alone (though codes align with status).

## API key format

Plaintext keys are issued once at creation or rotation:

```
bkey_<key_id>_<secret>
```

- `key_id` — UUID stored in `app.api_keys.id` (indexed lookup)
- `secret` — 64 hex characters (256 bits of entropy)
- Only the SHA-256 hash of the full key is stored server-side

Example shape (not a real key):

```
bkey_a1b2c3d4-e5f6-7890-abcd-ef1234567890_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

## POST /api/auth/bot/token

Public endpoint. No JWT required. Protected by strict rate limit and security hardening middleware.

### Request

```http
POST /api/auth/bot/token HTTP/1.1
Host: your-evi-host
Content-Type: application/json

{
  "api_key": "bkey_<key_id>_<secret>"
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `api_key` | string | yes | Full plaintext key; whitespace trimmed server-side |

### Success response

HTTP 200

```json
{
  "success": true,
  "code": "BOT_AUTH-SUC-001",
  "data": {
    "accessToken": "<JWT>",
    "accessTokenExpires": 1710000000,
    "tokenType": "Bearer"
  }
}
```

| Field | Type | Notes |
|-------|------|-------|
| `accessToken` | string | RS256 JWT |
| `accessTokenExpires` | number | Unix seconds; effective `exp` claim |
| `tokenType` | string | Always `Bearer` |

JWT claims include `uid` (bot user UUID), `tv` (token_version for invalidation), and `akid` (API key id used to authenticate).

There is **no** refresh token. When `accessTokenExpires` passes (or `tv` is bumped on revoke/disable), exchange the same `api_key` again.

### Error responses

| HTTP | Code | When |
|------|------|------|
| 400 | `BOT_AUTH-ERR-400` | Missing or empty `api_key`, malformed JSON |
| 401 | `BOT_AUTH-ERR-401` | Invalid key, revoked key, expired key, or inactive bot (uniform message) |

## Authenticated requests

Attach the access token to all protected routes:

```http
GET /api/auth/permissions HTTP/1.1
Host: your-evi-host
Authorization: Bearer <accessToken>
```

Common auth errors on protected routes:

| HTTP | Code | When |
|------|------|------|
| 401 | `AUT-ERR-401` | Missing/invalid/expired JWT, or `tv` mismatch after revoke/logout-all |

On `AUT-ERR-401`, re-run `POST /api/auth/bot/token` with the API key (do not call `/api/auth/refresh` — bots have no refresh cookie).

## Verification endpoints

### GET /api/admin/org/bot/self/keys

Requires active bot principal (`RequireActiveUser`). Returns metadata only.

```bash
curl -sS \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${BASE_URL}/api/admin/org/bot/self/keys"
```

### GET /api/auth/permissions

Returns the RBAC permission keys granted to the JWT subject (for example `settings:read:common`).

This list does not include per-tree ACL. Knowledge Base visibility is `GET /api/kb/access` (`canViewModule`). Author access on a tree is the write call: `KB-ERR-403` means this principal cannot write that tree.

```bash
curl -sS \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${BASE_URL}/api/auth/permissions"
```

## curl example (full auth flow)

```bash
export BASE_URL="http://localhost:7070"
export API_KEY="bkey_<key_id>_<secret>"

RESP=$(curl -sS -w "\n%{http_code}" -X POST \
  "${BASE_URL}/api/auth/bot/token" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg k "$API_KEY" '{api_key: $k}')")

BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n 1)

echo "HTTP $CODE"
echo "$BODY" | jq .

TOKEN=$(echo "$BODY" | jq -r '.data.accessToken')
curl -sS -H "Authorization: Bearer $TOKEN" \
  "${BASE_URL}/api/auth/permissions" | jq .
```

Prefer the bundled `scripts/role-auth.sh` and `scripts/role-request.sh` — they handle validation, caching, and re-auth.

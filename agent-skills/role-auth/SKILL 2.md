---
name: role-auth
description: >
  Authenticate an evi bot agent with a bot API key and obtain a short-lived
  Bearer JWT for subsequent evi API calls. Use before any other evi skill,
  when starting a session, or after AUT-ERR-401 / BOT_AUTH-ERR-401.
last_release: "0.26.2"
compatibility: Requires curl, jq, network access to the evi instance.
required_environment_variables:
  - name: BASE_URL
    prompt: evi instance base URL (e.g. https://evi.example.com or http://localhost:7070)
    help: No trailing slash. Dev default is http://localhost:7070.
    required_for: full functionality
  - name: API_KEY
    prompt: Bot API key in bkey_<key_id>_<secret> format
    help: Issued once in Admin → Org → Bot Editor → Credentials. Never paste into chat.
    required_for: full functionality
  - name: TLS_INSECURE
    prompt: Set to 1 for self-signed TLS in dev/test
    help: Optional. When 1/true/yes/on, scripts pass -k to curl.
    required_for: self-signed deployments
  - name: CA_CERT_FILE
    prompt: Path to a PEM CA certificate for the evi endpoint
    help: Optional. Preferred over TLS_INSECURE for trusted self-hosted certs.
    required_for: custom/private CA deployments
---

# role-auth

<!--
version: 0.26.2
Short description: Bot API-key exchange into JWT and authenticated request flow.
File: SKILL.md
Last release: 0.26.2

Changes in v0.26.2:
- Renamed frontmatter key `last_evi_release` to `last_release` and set it to 0.26.2.

Changes in v0.23.12:
- Documented that GET /api/auth/permissions is the RBAC key list, not module or tree ACL. KB access is GET /api/kb/access plus the write response.
- Renamed skill directory and shared scripts from evi-* to role-*; dropped EVI_ prefix from env vars (BASE_URL, API_KEY, …).
- Renamed API key format prefix from evik_ to bkey_ in prompts and examples.
- Updated last_evi_release marker to 0.23.12.

Changes in v1.4.1:
- Added last_evi_release frontmatter marker (skills pack sync at evi 0.20.17).

Changes in v1.4.0:
- Added role-setup.sh: one-time persisted configuration. Writes
  ${AGENT_HOME:-$HOME/.agent-skills}/role.env (mode 600) and verifies
  credentials. role-auth.sh / role-request.sh now automatically fall back to
  that file when BASE_URL / API_KEY are not in the environment, so
  hosts that run every tool call in a fresh shell keep working without
  re-exports.

Changes in v1.3.0:
- Documented that BASE_URL / API_KEY must be exported (child
  processes only inherit exported variables; some hosts run each command in
  a fresh shell session).
- Added pitfall: never retype/reconstruct skill scripts through agent
  file-write APIs with content filters; install via download or base64
  bundles from dist/ and verify sha256 (see agent-skills README).
- Noted that dependent skills carry vendored copies of these scripts in
  scripts/_lib and honor the REQUEST_SCRIPT override.

Changes in v1.2.0:
- Removed host-specific wording and setup sections.
- Documented vendor-neutral host setup and local environment conventions.
- Clarified JWT contract for downstream skills.

Changes in v1.1.0:
- Added TLS and auth flow clarifications.
-->

Authenticate a bot principal against evi and cache a Bearer access token for later API calls. Bots do not use `/api/auth/login` or refresh tokens — they exchange the API key again when the JWT expires or is invalidated.

## When to Use

- Before any evi API call from an external agent runtime
- At the start of a new agent session that will touch evi
- After `AUT-ERR-401` (expired or revoked JWT, token_version mismatch)
- After `BOT_AUTH-ERR-401` (invalid, expired, or revoked API key)

Do **not** use `POST /api/auth/login` for bots — that endpoint rejects `account_type=bot`.

## Prerequisites (human setup)

1. In evi Admin, create a bot account (Org → Bot Editor).
2. Open **Credentials** and issue an API key. Copy the plaintext key **once** — it looks like `bkey_<uuid>_<64-hex-chars>`.
3. Persist the credentials once with the setup script (writes
   `${AGENT_HOME:-$HOME/.agent-skills}/role.env`, mode 600, and verifies them):

   ```bash
   bash scripts/role-setup.sh --base-url https://your-evi-host --api-key bkey_...
   ```

4. Add `agent-skills/` as an external skills directory in your host runtime:

   ```yaml
   skills:
     external_dirs:
       - /path/to/evi/agent-skills
   ```

   Or after a sparse GitHub checkout: `/path/to/evi-skills/agent-skills`.

5. Ensure `curl` and `jq` are available in the agent's terminal environment.

## Quick setup block (copy/paste, recommended)

Use this once when a human provides skill path + `base_url` + `api_key`. It
persists the settings to `${AGENT_HOME:-$HOME/.agent-skills}/role.env`
(mode 600) and verifies them — **every later tool call works even in a fresh
shell with no exported variables**, because the auth scripts fall back to
that file automatically.

```bash
bash /path/to/evi/agent-skills/role-auth/scripts/role-setup.sh \
  --base-url "<BASE_URL_FROM_USER>" \
  --api-key "<API_KEY_FROM_USER>"
# Optional flags: --tls-insecure | --ca-cert-file /path/ca.pem | --no-verify

bash /path/to/evi/agent-skills/role-auth/scripts/role-request.sh GET /api/auth/permissions
```

## Quick auth block (exports only, alternative)

Works for the current shell session only — variables are gone in the next
fresh shell unless your host persists them.

```bash
export BASE_URL="<BASE_URL_FROM_USER>"
export API_KEY="<API_KEY_FROM_USER>"

# Optional for self-signed dev/test certs:
# export TLS_INSECURE=1

bash /path/to/evi/agent-skills/role-auth/scripts/role-auth.sh
bash /path/to/evi/agent-skills/role-auth/scripts/role-request.sh GET /api/auth/permissions
```

If a CA file is available, prefer:

```bash
unset TLS_INSECURE
export CA_CERT_FILE="/absolute/path/to/ca.pem"
```

## Procedure

1. **Exchange the API key for a JWT** — run the helper script from this skill directory:

   ```bash
   bash scripts/role-auth.sh
   ```

   Or with an absolute path after loading the skill:

   ```bash
   bash /path/to/evi/agent-skills/role-auth/scripts/role-auth.sh
   ```

2. The script sends:

   ```http
   POST {BASE_URL}/api/auth/bot/token
   Content-Type: application/json

   {"api_key":"<API_KEY>"}
   ```

3. On success (`code: BOT_AUTH-SUC-001`), read from the response envelope:

   - `data.accessToken` — use as `Authorization: Bearer <token>`
   - `data.accessTokenExpires` — Unix timestamp (seconds)
   - `data.tokenType` — always `Bearer`

4. The script writes a cache file at `${AGENT_HOME:-$HOME/.agent-skills}/cache/role-auth.json` and exports `ACCESS_TOKEN` for the current shell.

5. For self-signed/custom CA instances, set `TLS_INSECURE=1` or `CA_CERT_FILE=/path/to/ca.pem` before running scripts.

6. For subsequent API calls, use `scripts/role-request.sh` or attach the Bearer header manually. Every protected endpoint must include:

   ```http
   Authorization: Bearer <JWT>
   ```

7. When the token expires or any protected call returns `AUT-ERR-401`, run `role-auth.sh` again. There is **no** refresh token for bots.

## Token lifetime

Effective JWT expiry is `min(access_token_lifetime_setting, api_key_expires_at)`. The auth script treats the token as expired 60 seconds before `accessTokenExpires` to avoid edge-case 401s.

Re-authenticate proactively before long-running tasks, or rely on `role-request.sh` to refresh on demand.

## Verification

After a successful login, confirm the session with one or both calls:

```bash
# Bot principal: metadata of own API keys (no secrets returned)
bash scripts/role-request.sh GET /api/admin/org/bot/self/keys

# RBAC permission keys for this bot (not module or tree ACL)
bash scripts/role-request.sh GET /api/auth/permissions
```

Expect `success: true` in the JSON envelope. The self-keys response lists `key_id`, `token_prefix`, status, and expiry — never the full API key.

`GET /api/auth/permissions` lists RBAC keys such as `settings:read:common`. A short list does not describe Knowledge Base access. Tree read and author rights come from the tree ACL: call `GET /api/kb/access` (`canViewModule`) and attempt the write. `KB-ERR-403` on that write is the author gate.

## Pitfalls

- **Fresh shells lose exports.** Many hosts run every tool call in a new shell session. Run `scripts/role-setup.sh` once — it persists settings to `${AGENT_HOME:-$HOME/.agent-skills}/role.env` (override path with `ENV_FILE`) and the auth scripts read it automatically whenever `BASE_URL` / `API_KEY` are absent. Real environment variables always take precedence over file values.
- If you rely on exports instead, **always `export`** `BASE_URL` and `API_KEY` (and the optional TLS variables). The skill scripts spawn child processes (`bash role-request.sh ...`), and child processes only see exported variables.
- **Never retype or reconstruct these scripts** through an agent file-write API: many hosts content-filter `$VAR` / `${...}` / `$(...)` patterns and silently corrupt the script. Install by direct download (git/curl) or from the base64 bundles in `agent-skills/dist/`, then verify with the matching `.sha256` manifest (see the agent-skills README).
- **Never** log, echo, or paste the full `API_KEY` into chat or agent transcripts.
- `BOT_AUTH-ERR-401` is uniform for all key failures (unknown, revoked, expired, inactive bot) — do not try to infer the reason from the status code alone.
- `/api/auth/bot/token` uses strict rate limiting — avoid calling it in a tight loop; cache the JWT instead.
- Do not collect secrets in chat interfaces — configure environment variables locally.
- Trim trailing slashes from `BASE_URL`; the scripts normalize this automatically.
- If `POST /api/auth/bot/token` returns `SYS-ERR-404`, stop brute-force probing ports and report probable backend/proxy misconfiguration for `/api/*`.

## Contract for downstream evi skills

Other evi skills (KB read, write, etc.) should:

1. Assume `role-auth` has been run, or call `scripts/role-auth.sh` if the cache is missing or stale.
2. Use `scripts/role-request.sh METHOD /api/...` for authenticated HTTP calls with automatic re-auth on 401. Dependent skills ship vendored copies of both scripts in their own `scripts/_lib/` directory and resolve the wrapper in this order: `REQUEST_SCRIPT` env override → local `scripts/_lib/role-request.sh` → `../../role-auth/scripts/role-request.sh` (monorepo layout). This keeps every skill self-contained in hosts that install skills into isolated directories.
3. Send `Authorization: Bearer <JWT>` on every protected backend request.
4. Read the cache at `${AGENT_HOME:-$HOME/.agent-skills}/cache/role-auth.json` if they need the token without shell export:

   ```json
   {
     "baseUrl": "https://evi.example.com",
     "accessToken": "...",
     "accessTokenExpires": 1710000000,
     "obtainedAt": 1709998000
   }
   ```

## References

- [API contract](references/api-contract.md) — request/response shapes, error codes, curl examples
- [Agent skills index](../README.md) — external skills directory setup

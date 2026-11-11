#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Set a new bcrypt password in the database for the seeded built-in admin user (fixed user_id from db/init)
#          and restart state so Valkey (tmpfs) clears refresh tokens. Invoked from Cockpit evi-admin via dispatch.
# Deployment file: admin-set-admin-password.sh
#
# Changes in v0.26.3:
# - DEPLOYMENT_DIR is the kit root, two levels above this script (scripts/admin/).
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Reads config/app.env and config/app.secrets.env.
# 
# Changes in v0.25.4:
# - Reads config/app.env and config/app.secrets.env, falling back to the legacy evi.* files.
#
# Changes in v1.0.6:
# - Removed evi- prefix from container name (evi-db -> db) in podman inspect/exec calls.
#   Updated exit code comments to use short names.
#
# Changes in v1.0.5:
# - Updated all container name references to short forms without evi- prefix.
#
# Changes in v1.0.4:
# - Add -q flag to psql to suppress command tags (UPDATE 1) so \echo :ROW_COUNT output is not concatenated with them
#
# Changes in v1.0.3:
# - Clearer hash-generation error: mention apache2-utils as evi prerequisite and apt fix for existing nodes
#
# Changes in v1.0.2:
# - Verify UPDATE with psql \\echo :ROW_COUNT instead of RETURNING + bash line count (avoids false \"got 2\" from psql \"(1 row)\" footer)
#
# Changes in v1.0.1:
# - UPDATE targets seed user_id (550e8400-e29b-41d4-a716-446655440001) instead of username/is_system to avoid duplicate-row failures
#
# Changes in v1.0.0:
# - Initial implementation: load_env, bcrypt via htpasswd or python3, single-row UPDATE, systemctl --user restart evi-state
#
# Exit codes:
#   0 - Success
#   1 - Missing env files or empty password
#   2 - podman / db not running
#   3 - Could not generate bcrypt hash (install apache2-utils / python3-bcrypt; see error text)
#   4 - Database update did not affect exactly one row
#   5 - Password updated but state restart failed

set -euo pipefail

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

log() { printf '%s\n' "$*"; }
warn() { printf '%sWARN:%s %s\n' "${YELLOW}" "${NC}" "$*" >&2; }
err() { printf '%sERROR:%s %s\n' "${RED}" "${NC}" "$*" >&2; }
ok() { printf '  %s[✓]%s %s\n' "${GREEN}" "${NC}" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_DIR="${DEPLOYMENT_DIR}/config"
APP_ENV_FILE="${CONFIG_DIR}/app.env"
APP_SECRETS_FILE="${CONFIG_DIR}/app.secrets.env"

load_env() {
  if [[ -f "${APP_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${APP_ENV_FILE}"
  else
    err "Missing config file: ${APP_ENV_FILE}"
    exit 1
  fi
  if [[ -f "${APP_SECRETS_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${APP_SECRETS_FILE}"
  else
    err "Missing secrets file: ${APP_SECRETS_FILE}"
    exit 1
  fi
  APP_POSTGRES_DB="${APP_POSTGRES_DB:-maindb}"
}

# Same UUID as db/init/07_system_users.sql (built-in system administrator).
APP_BUILTIN_ADMIN_USER_ID="550e8400-e29b-41d4-a716-446655440001"

# Produce bcrypt hash compatible with golang.org/x/crypto/bcrypt (cost 10).
generate_bcrypt_hash() {
  local plaintext="$1"
  local line

  if command -v htpasswd >/dev/null 2>&1; then
    line=$(htpasswd -nbBC 10 _ "${plaintext}") || return 1
    printf '%s' "${line#*:}"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    local pyhash
    pyhash="$(P="${plaintext}" python3 -c 'import bcrypt, os
h = os.environ["P"].encode("utf-8")
print(bcrypt.hashpw(h, bcrypt.gensalt(rounds=10)).decode("ascii"))
' 2>/dev/null)" || true
    if [[ -n "${pyhash}" ]]; then
      printf '%s' "${pyhash}"
      return 0
    fi
  fi

  return 1
}

require_podman_db() {
  command -v podman >/dev/null 2>&1 || {
    err "podman not found in PATH"
    exit 2
  }
  if ! podman container inspect db --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    err "Container db is not running"
    exit 2
  fi
}

main() {
  load_env

  local new_password="${APP_ADMIN_NEW_PASSWORD:-}"
  if [[ -z "${new_password}" ]]; then
    err "APP_ADMIN_NEW_PASSWORD is not set or empty"
    exit 1
  fi

  require_podman_db

  local hash
  if ! hash="$(generate_bcrypt_hash "${new_password}")" || [[ -z "${hash}" ]]; then
    err "Could not generate bcrypt hash. Install apache2-utils (provides htpasswd; listed in application prerequisites.conf) or python3 with the bcrypt package. On existing servers: sudo apt-get install -y apache2-utils"
    exit 3
  fi

  log "Setting new password hash for built-in admin (user_id=${APP_BUILTIN_ADMIN_USER_ID})..."

  local out
  if ! out="$(podman exec -i db psql -U postgres -d "${APP_POSTGRES_DB:-}" -q -t -A -v ON_ERROR_STOP=1 <<EOF
UPDATE app.users_standard_profiles SET hashed_password = \$HP\$$hash\$HP\$ WHERE user_id = '${APP_BUILTIN_ADMIN_USER_ID}'::uuid;
\\echo :ROW_COUNT
EOF
)"; then
    err "Database update failed"
    exit 4
  fi

  # psql :ROW_COUNT is the row count of the last SQL command (not the meta-command); avoids parsing RETURNING + \"(N rows)\" noise
  local rows
  rows="$(printf '%s' "${out}" | tr -d '[:space:]')"
  if [[ "${rows}" != "1" ]]; then
    err "Expected 1 updated row for built-in admin user_id ${APP_BUILTIN_ADMIN_USER_ID}, got: ${rows:-empty}"
    exit 4
  fi

  ok "Password updated for built-in admin."

  if systemctl --user restart state; then
    ok "Restarted state (sessions cleared)."
  else
    err "Password was updated in the database, but systemctl --user restart state failed."
    err "Run manually: systemctl --user restart state"
    exit 5
  fi

  log ""
  log "You can sign in again with the new password on all devices."
}

main "$@"

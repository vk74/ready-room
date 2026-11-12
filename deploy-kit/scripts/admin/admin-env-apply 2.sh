#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Apply Container Environment updates from Cockpit (base64 patch or stdin KEY=value lines),
#          then delegate render + systemctl restart to install.sh __cockpit_apply_restart.
# Deployment file: admin-env-apply.sh
#
# Changes in v0.26.3:
# - DEPLOYMENT_DIR is the kit root, two levels above this script (scripts/admin/).
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Cockpit env apply writes config/app.env and config/app.secrets.env.
# 
# Changes in v0.25.4:
# - Writes config/app.env and config/app.secrets.env, falling back to the legacy evi.* files when those are the ones on disk.
#
# Changes in v0.23.9:
# - Allowlist APP_LIMIT_MEM_STATE for the evi-state memory limit. Other EVI_LIMIT_MEM_* unchanged.
#
# Changes in v1.2.0:
# - Updated all container name references to short forms without evi- prefix.
#
# Changes in v1.1.0:
# - Removed UFW rules update (out of scope; requires sudo and is not managed here).
# - Removed EVI_CORS_ORIGINS from accepted key whitelist (read-only display field; synced automatically).
# - Replaced exec-into-install.sh with subprocess call to install.sh __cockpit_apply_restart,
#   which runs run_deploy_init + systemctl restart without interactive prompts.
#
# Changes in v1.0.1:
# - Read patch from EVI_COCKPIT_ENV_PATCH_B64 (base64 UTF-8) when set; else stdin for CLI tests.
#
# Changes in v1.0.0:
# - Initial implementation.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
TARGET_ENV="${CONFIG_DIR}/app.env"
TARGET_SECRETS="${CONFIG_DIR}/app.secrets.env"
INSTALL_SH="${DEPLOYMENT_DIR}/install.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

log()  { printf "${CYAN}[admin-env]${NC} %s\n" "$*"; }
ok()   { printf '  %s[✓]%s %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '  %s[!]%s %s\n' "${YELLOW}" "${NC}" "$*"; }
err()  { printf '%sERROR:%s %s\n' "${RED}" "${NC}" "$*" >&2; }

get_kv() {
  local file="$1" key="$2"
  grep "^${key}=" "${file}" 2>/dev/null | head -1 | cut -d= -f2- || true
}

sed_escape_repl() {
  printf '%s' "$1" | sed 's/[\/&|]/\\&/g'
}

set_env_line() {
  local file="$1" key="$2" value="$3"
  local esc
  esc=$(sed_escape_repl "${value}")
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

if [[ ! -f "${TARGET_ENV}" ]]; then
  err "Missing ${TARGET_ENV}"
  exit 1
fi
if [[ ! -f "${TARGET_SECRETS}" ]]; then
  err "Missing ${TARGET_SECRETS}"
  exit 1
fi
if [[ ! -f "${INSTALL_SH}" ]]; then
  err "Missing ${INSTALL_SH}"
  exit 1
fi

old_domain="$(get_kv "${TARGET_ENV}" APP_DOMAIN)"
old_cors="$(get_kv "${TARGET_ENV}" APP_CORS_ORIGINS)"
domain_changed=0

# Cockpit passes KEY=value lines base64-encoded in APP_COCKPIT_ENV_PATCH_B64.
# For CLI testing, falls back to stdin.
log "Reading updates..."
_patch_stream() {
  if [[ -n "${APP_COCKPIT_ENV_PATCH_B64:-}" ]]; then
    printf '%s' "${APP_COCKPIT_ENV_PATCH_B64:-}" | base64 -d 2>/dev/null || {
      err "Invalid base64 in APP_COCKPIT_ENV_PATCH_B64"
      exit 1
    }
  else
    cat
  fi
}

while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" ]] && continue
  [[ "${line}" =~ ^# ]] && continue
  key="${line%%=*}"
  value="${line#"${key}"=}"
  case "${key}" in
    APP_DOMAIN|APP_TLS_MODE|APP_ACME_EMAIL|APP_HTTP_PORT|APP_HTTPS_PORT|\
APP_FIREWALL_ADMIN_ACCESS|APP_FIREWALL_ADMIN_ALLOWED|\
APP_LIMIT_CPU_PROXY|APP_LIMIT_CPU_FE|APP_LIMIT_CPU_BE|APP_LIMIT_CPU_DB|APP_LIMIT_CPU_STATE|APP_LIMIT_CPU_WORKER|APP_LIMIT_CPU_FS|\
APP_LIMIT_MEM_PROXY|APP_LIMIT_MEM_FE|APP_LIMIT_MEM_BE|APP_LIMIT_MEM_DB|APP_LIMIT_MEM_STATE|APP_LIMIT_MEM_WORKER|APP_LIMIT_MEM_FS)
      set_env_line "${TARGET_ENV}" "${key}" "${value}"
      if [[ "${key}" == "APP_DOMAIN" && "${value}" != "${old_domain}" ]]; then
        domain_changed=1
      fi
      ok "set ${key}"
      ;;
    *)
      err "Rejected key (not managed here): ${key}"
      exit 1
      ;;
  esac
done < <(_patch_stream)

# Auto-sync APP_CORS_ORIGINS when domain changed and value still matches default pattern.
new_domain="$(get_kv "${TARGET_ENV}" APP_DOMAIN)"
if [[ "${domain_changed}" -eq 1 ]]; then
  if [[ "${old_cors}" == 'https://${APP_DOMAIN}' ]] || [[ "${old_cors}" == "https://${old_domain}" ]]; then
    set_env_line "${TARGET_ENV}" "APP_CORS_ORIGINS" "https://${new_domain}"
    ok "synced APP_CORS_ORIGINS → https://${new_domain}"
  fi
fi

# Delegate render + restart to install.sh __cockpit_apply_restart (non-interactive, no read prompts).
log "Applying configuration and restarting containers..."
exec bash "${INSTALL_SH}" __cockpit_apply_restart

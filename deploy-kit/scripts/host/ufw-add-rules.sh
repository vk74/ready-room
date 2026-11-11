#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Add UFW allow rules for cockpit (9090) and pgadmin (5445) from app.env. Does not remove any rules.
# Backend script, called from install.sh after ufw-delete-rules.sh (guided setup or restore).
# Logic: Read APP_FIREWALL_ADMIN_ACCESS and APP_FIREWALL_ADMIN_ALLOWED from app.env; if skip or ufw missing/inactive, exit; otherwise add allow rules only.
#
# Changes in v0.26.3:
# - DEPLOYMENT_DIR is the kit root, two levels above this script (scripts/host/).
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - UFW rules read config/app.env.
# 
# Changes in v0.25.4:
# - Default env file is config/app.env, falling back to legacy config/evi.env.
#
# Changes in v1.2.2:
# - Call ufw-ensure-active.sh before adding rules so inactive ufw is enabled first.
#
# Changes in v1.2.1:
# - Cleanup of obsolete change notes.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
if [[ -n "${1:-}" ]]; then
  TARGET_ENV="$1"
else
  TARGET_ENV="${CONFIG_DIR}/app.env"
fi

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() { printf "${CYAN}[app]${NC} %s\n" "$*"; }
info() { printf "info: %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }

validate_ip() {
  local ip="$1"
  [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_cidr() {
  local cidr="$1"
  [[ "${cidr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || return 1
  local mask="${cidr##*/}"
  [[ "${mask}" -ge 0 && "${mask}" -le 32 ]]
}

add_rules() {
  [[ -f "${TARGET_ENV}" ]] || return 0
  local access allowed
  access=$(grep "^APP_FIREWALL_ADMIN_ACCESS=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  if [[ -z "${access}" ]]; then
    access=$(grep "^APP_FIREWALL_ADMIN_ACCESS=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  fi
  [[ -z "${access}" ]] && access="skip"
  allowed=$(grep "^APP_FIREWALL_ADMIN_ALLOWED=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  if [[ -z "${allowed}" ]]; then
    allowed=$(grep "^APP_FIREWALL_ADMIN_ALLOWED=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  fi

  if [[ "${access}" == "skip" ]]; then
    info "firewall: no change (you will configure access yourself)."
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not found; skipping firewall rules for cockpit."
    return 0
  fi
  if ! "${SCRIPT_DIR}/ufw-ensure-active.sh"; then
    warn "ufw could not be enabled; skipping firewall rules for cockpit."
    return 0
  fi

  case "${access}" in
    localhost)
      sudo ufw allow from 127.0.0.1 to any port 9090 proto tcp 2>/dev/null || true
      sudo ufw allow from 127.0.0.1 to any port 5445 proto tcp 2>/dev/null || true
      info "firewall: cockpit/pgadmin allowed from this server only (127.0.0.1)."
      ;;
    allowed_ips)
      if [[ -z "${allowed}" ]]; then
        warn "firewall: no IPs in APP_FIREWALL_ADMIN_ALLOWED; skipping."
        return 0
      fi
      while IFS=',' read -r ip; do
        ip=$(echo "${ip}" | tr -d ' ')
        [[ -z "${ip}" ]] && continue
        if validate_ip "${ip}"; then
          sudo ufw allow from "${ip}" to any port 9090 proto tcp 2>/dev/null || true
          sudo ufw allow from "${ip}" to any port 5445 proto tcp 2>/dev/null || true
        fi
      done <<< "${allowed}"
      info "firewall: cockpit/pgadmin allowed from ${allowed}."
      ;;
    allowed_cidr)
      if [[ -z "${allowed}" ]]; then
        warn "firewall: no CIDR in APP_FIREWALL_ADMIN_ALLOWED; skipping."
        return 0
      fi
      if validate_cidr "${allowed}"; then
        sudo ufw allow from "${allowed}" to any port 9090 proto tcp 2>/dev/null || true
        sudo ufw allow from "${allowed}" to any port 5445 proto tcp 2>/dev/null || true
        info "firewall: cockpit/pgadmin allowed from ${allowed}."
      else
        warn "firewall: invalid CIDR ${allowed}; skipping."
      fi
      ;;
    any)
      sudo ufw allow 9090/tcp 2>/dev/null || true
      sudo ufw allow 5445/tcp 2>/dev/null || true
      info "firewall: cockpit/pgadmin allowed from any computer (not recommended)."
      ;;
    *)
      warn "firewall: unknown APP_FIREWALL_ADMIN_ACCESS=${access}; no rules applied."
      ;;
  esac
}

add_rules

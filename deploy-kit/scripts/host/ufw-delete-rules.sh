#!/usr/bin/env bash
#
# Version: 0.26.2
# Purpose: Remove all existing UFW rules for cockpit (9090) and pgadmin (5445). Does not add any rules.
# Backend script, called from install.sh before ufw-add-rules.sh (guided setup or restore). Same workflow for first run and reconfigure.
# Logic: Repeatedly find highest rule number for 9090/5445, delete it (print each removal), re-query until none left. Parse with line-start sed pattern.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
#
# Changes in v1.2.1:
# - Cleanup of obsolete change notes.
#
# Changes in v1.0.1:
# - Fixed pipeline: wrap "grep ... || true" in subshell so output is piped to sed; rules are now correctly found and removed on reconfigure.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() { printf "${CYAN}[app]${NC} %s\n" "$*"; }
info() { printf "info: %s\n" "$*"; }

# Delete existing rules for 9090 and 5445 by rule number. Re-query after each delete (numbers shift). Print each removal.
delete_app_admin_rules() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    return 0
  fi
  log "removing existing UFW rules for cockpit (9090) and pgadmin (5445)..."
  local max_n iter=0
  while [[ "${iter}" -lt 20 ]]; do
    max_n=$(sudo ufw status numbered 2>/dev/null | (grep -E '(9090|5445)/' || true) | sed -n 's/^[[:space:]]*\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | sort -rn | head -1)
    [[ -z "${max_n}" ]] || [[ ! "${max_n}" =~ ^[0-9]+$ ]] && break
    info "removing rule ${max_n}"
    sudo ufw --force delete "${max_n}" 2>/dev/null || true
    iter=$((iter + 1))
  done
  if [[ "${iter}" -eq 0 ]]; then
    info "no existing rules for 9090/5445 to remove."
  fi
}

delete_app_admin_rules

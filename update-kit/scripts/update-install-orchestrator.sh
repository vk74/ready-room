#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Run the five update phases in order. Removes a stale update-result.json
#          first. On a phase failure, deletes sudo.pass and writes update-result.json
#          status failed when phase 3 has not already written a rollback result.
#          Takes APP_HOME as $1.
# File: update-install-orchestrator.sh
#
# Changes in v0.26.3:
# - Install orchestrator for the five update-* phase scripts.
# - A non-zero phase exit writes status failed only when update-result.json is absent,
#   so a phase 3 rollback result is kept.
# - phase 2/5 remains a literal marker so an older dispatch still sees that this
#   script owns host prerequisites and the Cockpit panel.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
init_update_context "${1:?usage: update-install-orchestrator.sh <APP_HOME>}" "$SCRIPT_DIR"

if [[ -d "${UPDATES_DIR}" ]]; then
  rm -f "${UPDATES_DIR}/update-result.json"
fi

main() {
  echo ""
  log_tee "${BOLD}=== application update: installing v${VERSION_DIR_NAME} ===${NC}"
  echo ""

  phase "1/5" "pre-flight and compatibility checks"
  "${SCRIPT_DIR}/update-1-preflight.sh" "$APP_HOME" || return $?

  # Literal "phase 2/5" is how an older update dispatch detects that this script
  # owns host prerequisites and the Cockpit panel (it then only writes sudo.pass).
  phase "2/5" "updating host prerequisites and cockpit panel"
  "${SCRIPT_DIR}/update-2-host-and-cockpit.sh" "$APP_HOME" || return $?

  phase "3/5" "migrating database"
  "${SCRIPT_DIR}/update-3-migrate-db.sh" "$APP_HOME" || return $?

  phase "4/5" "updating application files and configuration"
  "${SCRIPT_DIR}/update-4-files-and-config.sh" "$APP_HOME" || return $?

  phase "5/5" "starting services and verifying health"
  "${SCRIPT_DIR}/update-5-start-and-verify.sh" "$APP_HOME" || return $?

  echo ""
  log_tee "${BOLD}=== Update to v${VERSION_DIR_NAME} completed successfully ===${NC}"
  info "log available at ${UPDATES_DIR}/update-output.log"
  echo ""
}

set +e
main
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]]; then
  rm -f "${UPDATES_DIR}/sudo.pass" || true
  if [[ ! -f "${UPDATES_DIR}/update-result.json" ]]; then
    cleanup_update_lock_and_write_result "failed" "$EXIT_CODE"
  fi
  err "update failed. Log: ${UPDATES_DIR}/update-output.log"
  exit "$EXIT_CODE"
fi
exit 0

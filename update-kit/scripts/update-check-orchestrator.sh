#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Check for newer releases. Creates a temporary workspace, fetches
#          candidate releases, then evaluates compatibility. Logs go to stderr.
#          The only stdout is one JSON object, which the Cockpit panel parses.
#          Usage: update-check-orchestrator.sh <APP_HOME> [--include-prerelease]
# File: update-check-orchestrator.sh
#
# Changes in v0.26.3:
# - Check orchestrator. Runs check-1-fetch-releases.sh, then check-2-evaluate-compatibility.sh.
# - A fetch failure prints {"error","currentVersion","releases"} on stdout and exits 1.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_HOME="${1:?usage: update-check-orchestrator.sh <APP_HOME> [--include-prerelease]}"
shift
INCLUDE_PRERELEASE=false
for arg in "$@"; do
  [[ "$arg" == "--include-prerelease" ]] && INCLUDE_PRERELEASE=true
done

emit_check_error() {
  local msg="$1" cur="$2"
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  msg="${msg//$'\n'/ }"
  cur="${cur//\\/\\\\}"
  cur="${cur//\"/\\\"}"
  cur="${cur//$'\n'/}"
  printf '{"error":"%s","currentVersion":"%s","releases":[]}\n' "$msg" "$cur"
}

read_work_file() {
  local path="$1"
  local value=""
  if [[ -f "$path" ]]; then
    IFS= read -r value < "$path" || true
  fi
  printf '%s' "$value"
}

CHECK_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/app-check-XXXXXX")
trap 'rm -rf "$CHECK_WORK_DIR"' EXIT

if ! "${SCRIPT_DIR}/check-1-fetch-releases.sh" "$APP_HOME" "$CHECK_WORK_DIR" "$INCLUDE_PRERELEASE" >&2; then
  err_msg=$(read_work_file "${CHECK_WORK_DIR}/error")
  cur=$(read_work_file "${CHECK_WORK_DIR}/current-version")
  [[ -z "$err_msg" ]] && err_msg="failed to fetch releases"
  [[ -z "$cur" ]] && cur="unknown"
  emit_check_error "$err_msg" "$cur"
  exit 1
fi

if ! "${SCRIPT_DIR}/check-2-evaluate-compatibility.sh" "$APP_HOME" "$CHECK_WORK_DIR" "$INCLUDE_PRERELEASE"; then
  cur=$(read_work_file "${CHECK_WORK_DIR}/current-version")
  [[ -z "$cur" ]] && cur="unknown"
  emit_check_error "failed to evaluate release compatibility" "$cur"
  exit 1
fi
exit 0

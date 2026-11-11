#!/usr/bin/env bash
#
# Version: 0.23.12
# Purpose: Ensure the host journald drop-in caps match prerequisites.conf.
#   Single source for /etc/systemd/journald.conf.d/app-logs.conf content and
#   write/compare/restart logic. Callers: install.sh (deploy/restore),
#   sync-host-prerequisites.sh, check-prerequisites.sh (--check / repair).
# File: journald-limits-ensure.sh
#
# Usage: journald-limits-ensure.sh <deploy-dir>
#          [--sudo-mode=nopasswd|password|interactive]
#          [--check]
#   Flags may appear before or after <deploy-dir>.
#   nopasswd (default): sudo -n — apply-update / sync.
#   interactive: sudo with a prompt — Deploy, restore, repair.
#   --check: no writes; exit 0 if drop-in matches, exit 1 otherwise.
#
# Changes in v0.23.12:
# - Initial helper: build desired drop-in from PREREQ_JOURNAL_*, compare
#   without relying on a trailing newline (printf '%s\n' on write; $(cat)
#   strips it), write via do_sudo tee, restart systemd-journald only when
#   content changes. --check reports a one-line reason on mismatch/missing.
#

set -euo pipefail

SUDO_MODE="nopasswd"
CHECK_ONLY=0
DEPLOY_DIR=""

DROP_IN_DIR="/etc/systemd/journald.conf.d"
DROP_IN_FILE="${DROP_IN_DIR}/app-logs.conf"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() { printf "${CYAN}[journald]${NC} %s\n" "$*"; }
info() { printf "${GREEN}info:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*" >&2; }

usage() {
  err "usage: journald-limits-ensure.sh <deploy-dir> [--sudo-mode=nopasswd|password|interactive] [--check]"
}

# --- sudo wrapper: same pattern as install-fail2ban.sh ---
do_sudo() {
  case "$SUDO_MODE" in
    password)
      if [[ -z "${SUDO_PASSWORD:-}" ]]; then
        err "SUDO_PASSWORD env var is empty but --sudo-mode=password was requested"
        return 1
      fi
      echo "${SUDO_PASSWORD}" | sudo -S "$@" 2>/dev/null
      ;;
    nopasswd)
      sudo -n "$@"
      ;;
    interactive)
      sudo "$@"
      ;;
    *)
      err "unknown sudo mode: ${SUDO_MODE}"
      return 1
      ;;
  esac
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --sudo-mode=*) SUDO_MODE="${arg#--sudo-mode=}" ;;
      --check) CHECK_ONLY=1 ;;
      --help|-h)
        usage
        return 1
        ;;
      -*)
        warn "unknown flag: ${arg}"
        ;;
      *)
        if [[ -z "${DEPLOY_DIR}" ]]; then
          DEPLOY_DIR="${arg}"
        fi
        ;;
    esac
  done
  if [[ -z "${DEPLOY_DIR}" ]]; then
    usage
    return 1
  fi
  case "${SUDO_MODE}" in
    nopasswd|password|interactive) ;;
    *)
      err "unknown sudo mode: ${SUDO_MODE}"
      return 1
      ;;
  esac
  return 0
}

load_manifest() {
  local prereq_conf="${DEPLOY_DIR}/prerequisites.conf"
  if [[ ! -f "${prereq_conf}" ]]; then
    err "prerequisites.conf not found: ${prereq_conf}"
    return 2
  fi
  # shellcheck source=/dev/null
  source "${prereq_conf}"

  if [[ -z "${PREREQ_JOURNAL_MAX_USE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_USE is empty (${prereq_conf})"
    return 2
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_FILE_SIZE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_FILE_SIZE is empty (${prereq_conf})"
    return 2
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_RETENTION// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_RETENTION is empty (${prereq_conf})"
    return 2
  fi
  return 0
}

# Desired content WITHOUT a trailing newline. Written with printf '%s\n' so the
# on-disk file has one; $(cat) strips it, so compare stays idempotent.
build_desired() {
  printf '%s' "[Journal]
Storage=persistent
SystemMaxUse=${PREREQ_JOURNAL_MAX_USE}
SystemMaxFileSize=${PREREQ_JOURNAL_MAX_FILE_SIZE}
MaxRetentionSec=${PREREQ_JOURNAL_MAX_RETENTION}"
}

# Read drop-in content (trailing newline stripped by command substitution).
# Uses sudo only when the file is not readable by the current user.
read_current() {
  if [[ -r "${DROP_IN_FILE}" ]]; then
    cat "${DROP_IN_FILE}" 2>/dev/null || true
    return 0
  fi
  if do_sudo test -f "${DROP_IN_FILE}" 2>/dev/null; then
    do_sudo cat "${DROP_IN_FILE}" 2>/dev/null || true
    return 0
  fi
  return 1
}

run_check() {
  local desired current
  desired="$(build_desired)"
  if ! current="$(read_current)"; then
    printf '%s\n' "journald drop-in missing (${DROP_IN_FILE})"
    return 1
  fi
  if [[ "${current}" == "${desired}" ]]; then
    return 0
  fi
  printf '%s\n' "journald drop-in content mismatch (${DROP_IN_FILE})"
  return 1
}

run_apply() {
  local desired current=""
  desired="$(build_desired)"

  if current="$(read_current)"; then
    if [[ "${current}" == "${desired}" ]]; then
      log "already ok (${DROP_IN_FILE})"
      return 0
    fi
  fi

  log "configuring journald limits (SystemMaxUse=${PREREQ_JOURNAL_MAX_USE}, MaxRetentionSec=${PREREQ_JOURNAL_MAX_RETENTION})..."
  if ! do_sudo mkdir -p "${DROP_IN_DIR}"; then
    err "failed to create ${DROP_IN_DIR}"
    return 1
  fi
  if ! printf '%s\n' "${desired}" | do_sudo tee "${DROP_IN_FILE}" >/dev/null; then
    err "failed to write ${DROP_IN_FILE}"
    return 1
  fi
  if ! do_sudo systemctl restart systemd-journald; then
    err "failed to restart systemd-journald"
    return 1
  fi
  log "journald configured (${DROP_IN_FILE})"
  return 0
}

main() {
  if ! parse_args "$@"; then
    return 1
  fi
  if ! load_manifest; then
    return 2
  fi
  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    run_check
    return $?
  fi
  run_apply
}

main "$@"

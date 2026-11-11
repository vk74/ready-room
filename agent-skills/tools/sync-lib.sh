#!/usr/bin/env bash
# version: 1.5.1
# Sync the canonical role-auth scripts into the vendored scripts/_lib copies
# of every dependent skill, or verify they are in sync with --check.
# File: sync-lib.sh
#
# Changes in v1.5.1:
# - Renamed skills evi-* → role-*; sync/pack targets and lib script names updated (role-auth.sh / role-request.sh / role-setup.sh).
#
# Changes in v1.5.0:
# - Replaced role-admin-products-reader with role-admin-products-auditor.
# - Added role-admin-products-specialist to dependent skills list.
#
# Changes in v1.4.0:
# - Added role-admin-products-admin to dependent skills list.
#
# Changes in v1.3.0:
# - Added role-admin-products-editor to dependent skills list.
#
# Changes in v1.2.0:
# - Added role-admin-products-reader to dependent skills list.
#
# Changes in v1.1.0:
# - Added role-setup.sh to the synced lib files (env-file setup entry point).
#
# Changes in v1.0.0:
# - Initial sync/check tool. Canonical source: role-auth/scripts/. Targets:
#   role-kb-reader, role-kb-author, role-kb-admin, role-attachments scripts/_lib.
#
# Usage:
#   tools/sync-lib.sh            # copy canonical scripts into all _lib dirs
#   tools/sync-lib.sh --check    # exit 1 if any vendored copy is out of sync

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CANONICAL_DIR="${SKILLS_ROOT}/role-auth/scripts"
LIB_FILES=(role-auth.sh role-request.sh role-setup.sh)
DEPENDENT_SKILLS=(role-kb-reader role-kb-author role-kb-admin role-attachments role-admin-products-auditor role-admin-products-editor role-admin-products-specialist role-admin-products-admin)

die() {
  echo "sync-lib: $*" >&2
  exit 1
}

MODE="sync"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ $# -gt 0 ]]; then
  die "unknown argument: $1 (expected --check or nothing)"
fi

for f in "${LIB_FILES[@]}"; do
  [[ -f "${CANONICAL_DIR}/${f}" ]] || die "canonical source missing: ${CANONICAL_DIR}/${f}"
done

STATUS=0
for skill in "${DEPENDENT_SKILLS[@]}"; do
  lib_dir="${SKILLS_ROOT}/${skill}/scripts/_lib"
  for f in "${LIB_FILES[@]}"; do
    src="${CANONICAL_DIR}/${f}"
    dst="${lib_dir}/${f}"
    if [[ "$MODE" == "check" ]]; then
      if [[ ! -f "$dst" ]]; then
        echo "sync-lib: MISSING ${skill}/scripts/_lib/${f}" >&2
        STATUS=1
      elif ! cmp -s "$src" "$dst"; then
        echo "sync-lib: OUT OF SYNC ${skill}/scripts/_lib/${f}" >&2
        STATUS=1
      fi
    else
      mkdir -p "$lib_dir"
      cp "$src" "$dst"
      echo "sync-lib: synced ${skill}/scripts/_lib/${f}"
    fi
  done
done

if [[ "$MODE" == "check" ]]; then
  if [[ $STATUS -eq 0 ]]; then
    echo "sync-lib: all vendored copies are in sync"
  else
    echo "sync-lib: run tools/sync-lib.sh to fix" >&2
  fi
fi
exit "$STATUS"

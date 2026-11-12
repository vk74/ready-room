#!/usr/bin/env bash
# version: 1.4.1
# Package every skill into a base64-encoded tarball plus a per-skill sha256
# manifest under agent-skills/dist/. These artifacts let agents with
# content-filtering file-write APIs install skills losslessly: download or
# paste the .b64 text, decode it, and verify integrity with the manifest
# instead of retyping scripts (which corrupts $-patterns).
# File: pack-skills.sh
#
# Changes in v1.4.1:
# - Renamed skills evi-* → role-*; sync/pack targets and lib script names updated (role-auth.sh / role-request.sh / role-setup.sh).
#
# Changes in v1.4.0:
# - Replaced role-admin-products-reader with role-admin-products-auditor.
# - Added role-admin-products-specialist to the skills packaging list.
#
# Changes in v1.3.0:
# - Added role-admin-products-admin to the skills packaging list.
#
# Changes in v1.2.0:
# - Added role-admin-products-editor to the skills packaging list.
#
# Changes in v1.1.0:
# - Added role-admin-products-reader to the skills packaging list.
#
# Changes in v1.0.0:
# - Initial packaging tool: dist/<skill>.tar.gz.b64 + dist/<skill>.sha256
#   for every skill directory; rerun after any change to skill contents.
#
# Usage:
#   tools/pack-skills.sh           # regenerate dist/ for all skills

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${SKILLS_ROOT}/dist"
SKILLS=(role-auth role-attachments role-kb-reader role-kb-author role-kb-admin role-admin-products-auditor role-admin-products-editor role-admin-products-specialist role-admin-products-admin)

die() {
  echo "pack-skills: $*" >&2
  exit 1
}

sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    die "neither sha256sum nor shasum found"
  fi
}

command -v tar >/dev/null 2>&1 || die "required command not found: tar"
command -v base64 >/dev/null 2>&1 || die "required command not found: base64"

mkdir -p "$DIST_DIR"

for skill in "${SKILLS[@]}"; do
  skill_dir="${SKILLS_ROOT}/${skill}"
  [[ -d "$skill_dir" ]] || die "skill directory not found: ${skill_dir}"

  # Per-skill manifest with paths relative to the skill directory, so it can
  # be verified after installation into any host layout:
  #   cd <installed-skill-dir> && shasum -a 256 -c <skill>.sha256
  (
    cd "$skill_dir"
    find . -type f ! -name '.DS_Store' | LC_ALL=C sort | sed 's|^\./||' \
      | while IFS= read -r f; do sha256_tool "$f"; done
  ) >"${DIST_DIR}/${skill}.sha256"

  # Base64-encoded tarball of the whole skill directory. Decode with:
  #   base64 -d <skill>.tar.gz.b64 | tar xz
  (
    cd "$SKILLS_ROOT"
    tar czf - --exclude='.DS_Store' "$skill" | base64 >"${DIST_DIR}/${skill}.tar.gz.b64"
  )

  echo "pack-skills: packed ${skill} -> dist/${skill}.tar.gz.b64 (+ ${skill}.sha256)"
done

echo "pack-skills: done. Commit dist/ together with skill changes."

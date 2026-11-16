#!/usr/bin/env bash
# version: 0.28.3
# Add files to a manual task without dropping the current attachment set.
# File: work-manual-tasks-attachments-add.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/fs for entity_type=manual_task, union file ids, then PATCH attachmentFileIds.

set -euo pipefail

die() {
  echo "work-manual-tasks-attachments-add: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-manual-tasks-attachments-add.sh <task_uuid> <file_uuid> [<file_uuid>...]

Each file_uuid must already be uploaded and confirmed via role-attachments
with entity_type=manual_task and entity_id=<task_uuid>. This script does not
upload. It loads the active file ids, appends the new ids, and PATCHes
attachmentFileIds with the merged set. Order is preserved. Duplicates are
dropped with a case-insensitive comparison.
A direct PATCH that includes attachmentFileIds replaces the set. Use this
script to add without dropping current files.
EOF
  exit 1
}

resolve_auth() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  AUTH_REQUEST_SCRIPT="${REQUEST_SCRIPT:-}"
  if [[ -z "$AUTH_REQUEST_SCRIPT" ]]; then
    for candidate in "${SCRIPT_DIR}/_lib/role-request.sh" "${SCRIPT_DIR}/../../role-auth/scripts/role-request.sh"; do
      if [[ -f "$candidate" ]]; then
        AUTH_REQUEST_SCRIPT="$candidate"
        break
      fi
    done
  fi
  [[ -n "$AUTH_REQUEST_SCRIPT" && -f "$AUTH_REQUEST_SCRIPT" ]] || die "cannot locate role-request.sh (set REQUEST_SCRIPT or restore scripts/_lib/)"
}

trim() {
  printf '%s' "$1" | xargs
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

[[ $# -ge 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
TASK_ID="$(trim "$1")"
shift
[[ -n "$TASK_ID" ]] || usage
is_uuid "$TASK_ID" || die "not a UUID: $TASK_ID"

NEW_IDS=()
for raw in "$@"; do
  item="$(trim "$raw")"
  [[ -n "$item" ]] || die "empty file uuid"
  is_uuid "$item" || die "not a UUID: $item"
  NEW_IDS+=("$item")
done

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
resolve_auth

LIST_BODY="$(bash "$AUTH_REQUEST_SCRIPT" GET "/api/fs?entity_type=manual_task&entity_id=${TASK_ID}")" \
  || { printf '%s\n' "$LIST_BODY"; die "failed to list current files for task ${TASK_ID}"; }

CURRENT_IDS_JSON="$(printf '%s' "$LIST_BODY" | jq -c '
  def uuid: test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
  if .success != true or (.data | type) != "object" then
    error("file list envelope is missing data")
  else
    [(.data.items // [])[]?.file_id | select(type == "string" and uuid)]
  end
')" || die "unexpected response shape from GET /api/fs"

NEW_IDS_JSON="$(printf '%s\n' "${NEW_IDS[@]}" | jq -R . | jq -cs .)" || die "could not encode the new file ids"
MERGED_JSON="$(jq -cn --argjson cur "$CURRENT_IDS_JSON" --argjson add "$NEW_IDS_JSON" '
  def dedupe:
    reduce .[] as $id ([];
      if any(.[]; ascii_downcase == ($id | ascii_downcase)) then . else . + [$id] end);
  ($cur + $add) | dedupe
')" || die "could not merge the file ids"

PAYLOAD="$(jq -cn --argjson ids "$MERGED_JSON" '{attachmentFileIds: $ids}')" || die "could not build the attachment payload"
current_count="$(printf '%s' "$CURRENT_IDS_JSON" | jq 'length')"
final_count="$(printf '%s' "$MERGED_JSON" | jq 'length')"
echo "work-manual-tasks-attachments-add: keeping ${current_count} existing file(s), adding ${#NEW_IDS[@]}, merged ${final_count}" >&2

printf '%s' "$PAYLOAD" | bash "$AUTH_REQUEST_SCRIPT" PATCH "/api/work/activities/manual-tasks/${TASK_ID}" \
  -H "Content-Type: application/json" \
  --data-binary @-

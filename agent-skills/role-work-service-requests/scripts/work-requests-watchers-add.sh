#!/usr/bin/env bash
# version: 0.28.3
# Add watchers to a service request without dropping the current watch list, and keep the other work fields.
# File: work-requests-watchers-add.sh
#
# Changes in v0.28.3:
# - Initial script: GET the request, union watch_list with the given user UUIDs, and PATCH /work.
# - Sends the current priority, status, pause reason, assignment, and work notes so those fields are not cleared.

set -euo pipefail

die() {
  echo "work-requests-watchers-add: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-requests-watchers-add.sh <request_uuid> <user_uuid> [<user_uuid>...]

Preserves the current watch_list order, appends new ids, and drops duplicates
(comparison is case-insensitive). Use this to escalate by adding user ids from
data.escalation_targets (practice_manager.users[].user_id or company_head.user_id).
The server returns WORK-ERR-002 when the escalation policy refuses the addition.
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

trim_text() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "required command not found: jq"
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

require_uuid() {
  is_uuid "$1" || die "not a UUID: $1"
}

cleanup() {
  if [[ -n "${TMP_BODY:-}" && -f "$TMP_BODY" ]]; then
    rm -f "$TMP_BODY"
  fi
}

fetch_request() {
  local id="$1" body
  body="$(bash "$AUTH_REQUEST_SCRIPT" GET "/api/work/requests/${id}")" || {
    printf '%s\n' "$body"
    die "failed to read request ${id}"
  }
  printf '%s' "$body"
}

# GET detail returns the assigned group as data.group_id. The PATCH key is
# assigned_group_id. Copy group_id into the baseline so an omitted group is kept.
request_work_baseline() {
  printf '%s' "$1" | jq -c '
    if .success != true or (.data | type) != "object" then
      error("request detail envelope is missing data")
    elif (.data.status | type) != "string" or .data.status == "" then
      error("request detail has no status")
    else
      {
        priority: (.data.priority // 3),
        status: .data.status,
        pause_reason: .data.pause_reason,
        assigned_group_id: (if .data.group_id != null then .data.group_id else .data.assigned_group_id end),
        assigned_user_id: .data.assigned_user_id,
        work_notes: .data.work_notes
      }
    end
  '
}

assert_work_payload() {
  printf '%s' "$1" | jq -e '
    def uuid: test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    (.priority | type) == "number" and .priority >= 1 and .priority <= 5 and .priority == (.priority | floor)
    and (.status == "new" or .status == "in_progress" or .status == "paused" or .status == "resolved" or .status == "reopened" or .status == "closed")
    and (if .status == "paused" then
          (.pause_reason == "awaiting_requester" or .pause_reason == "awaiting_third_party" or .pause_reason == "scheduled" or .pause_reason == "other")
        else true end)
    and ((.assigned_group_id == null) or ((.assigned_group_id | type) == "string" and (.assigned_group_id | uuid)))
    and ((.assigned_user_id == null) or ((.assigned_user_id | type) == "string" and (.assigned_user_id | uuid)))
    and ((.work_notes == null) or (.work_notes | type) == "string")
    and ((has("estimated_minutes") | not) or .estimated_minutes == null or ((.estimated_minutes | type) == "number" and .estimated_minutes >= 0 and .estimated_minutes == (.estimated_minutes | floor)))
    and ((has("actual_minutes") | not) or .actual_minutes == null or ((.actual_minutes | type) == "number" and .actual_minutes >= 0 and .actual_minutes == (.actual_minutes | floor)))
    and ((has("watch_list") | not) or ((.watch_list | type) == "array" and all(.watch_list[]; type == "string" and uuid)))
  ' >/dev/null || die "merged work payload is invalid (priority 1..5, status, pause_reason when paused, assignment, watch_list)"
}

send_work() {
  local id="$1" payload="$2"
  assert_work_payload "$payload"
  TMP_BODY="$(mktemp)"
  printf '%s' "$payload" > "$TMP_BODY"
  bash "$AUTH_REQUEST_SCRIPT" PATCH "/api/work/requests/${id}/work" \
    -H "Content-Type: application/json" \
    --data-binary "@${TMP_BODY}"
}

[[ $# -ge 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
REQUEST_ID="$(trim "$1")"
shift
is_uuid "$REQUEST_ID" || die "not a UUID: $REQUEST_ID"

NEW_IDS=()
for raw in "$@"; do
  item="$(trim "$raw")"
  [[ -n "$item" ]] || die "empty user uuid"
  is_uuid "$item" || die "not a UUID: $item"
  NEW_IDS+=("$item")
done

require_jq
resolve_auth
trap cleanup EXIT
BODY="$(fetch_request "$REQUEST_ID")" || die "failed to read request ${REQUEST_ID}"
NEW_JSON="$(printf '%s\n' "${NEW_IDS[@]}" | jq -R . | jq -cs .)" || die "could not encode the new watcher ids"
MERGED="$(printf '%s' "$BODY" | jq -c --argjson add "$NEW_JSON" '
  def uuid: test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
  def dedupe:
    reduce .[] as $id ([];
      if any(.[]; ascii_downcase == ($id | ascii_downcase)) then . else . + [$id] end);
  if .success != true or (.data | type) != "object" then
    error("request detail envelope is missing data")
  elif (.data.status | type) != "string" or .data.status == "" then
    error("request detail has no status")
  else
    ((.data.watch_list // []) | map(select(type == "string" and uuid))) as $cur
    | {
        priority: (.data.priority // 3),
        status: .data.status,
        pause_reason: .data.pause_reason,
        assigned_group_id: (if .data.group_id != null then .data.group_id else .data.assigned_group_id end),
        assigned_user_id: .data.assigned_user_id,
        work_notes: .data.work_notes,
        watch_list: (($cur + $add) | dedupe)
      }
  end
')" || die "could not merge the watch list"
current_count="$(printf '%s' "$BODY" | jq '((.data.watch_list // []) | length)')" || current_count="?"
final_count="$(printf '%s' "$MERGED" | jq '.watch_list | length')" || final_count="?"
echo "work-requests-watchers-add: current watchers ${current_count}, adding ${#NEW_IDS[@]}, merged ${final_count}" >&2
send_work "$REQUEST_ID" "$MERGED"

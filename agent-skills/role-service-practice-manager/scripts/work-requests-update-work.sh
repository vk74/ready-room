#!/usr/bin/env bash
# version: 0.28.3
# Destructive-safe PATCH of service-request work fields. Reads the current row, merges the caller's patch, and sends the full overwrite set.
# File: work-requests-update-work.sh
#
# Changes in v0.28.3:
# - Initial script: GET the request, merge patch.json over priority, status, pause_reason, assignment, and work_notes, then PATCH /work.
# - Maps response group_id onto request assigned_group_id so an omitted group is not cleared.

set -euo pipefail

die() {
  echo "work-requests-update-work: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-requests-update-work.sh <request_uuid> <patch.json>

patch.json is a JSON object of snake_case work fields merged over the current row:
  priority, status, pause_reason, assigned_group_id, assigned_user_id, work_notes,
  watch_list, estimated_minutes, actual_minutes.
Omitted assigned_group_id, assigned_user_id, and work_notes are filled from the current request.
Omitted watch_list, estimated_minutes, and actual_minutes stay omitted so the server keeps them.
watch_list, when present, replaces the whole watcher set.
status paused requires pause_reason: awaiting_requester, awaiting_third_party, scheduled, or other.
priority is 1..5. status: new, in_progress, paused, resolved, reopened, closed.
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

[[ $# -eq 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
REQUEST_ID="$(trim "$1")"
PATCH_FILE="$2"
[[ -n "$REQUEST_ID" ]] || usage
is_uuid "$REQUEST_ID" || die "not a UUID: $REQUEST_ID"
[[ -f "$PATCH_FILE" ]] || die "patch file not found: $PATCH_FILE"
require_jq
jq -e 'type == "object"' "$PATCH_FILE" >/dev/null || die "patch must be a JSON object"
if jq -e 'has("assignedGroupId") or has("assignedUserId") or has("workNotes") or has("pauseReason") or has("watchList") or has("estimatedMinutes") or has("actualMinutes")' "$PATCH_FILE" >/dev/null; then
  echo "work-requests-update-work: warning: work PATCH keys are snake_case. camelCase keys are ignored by the server." >&2
fi
if jq -e 'has("watch_list")' "$PATCH_FILE" >/dev/null; then
  echo "work-requests-update-work: warning: watch_list replaces the whole watcher set. Use work-requests-watchers-add.sh to add without dropping current watchers." >&2
fi
if jq -e 'length == 0' "$PATCH_FILE" >/dev/null; then
  echo "work-requests-update-work: warning: an empty patch still rewrites the current work fields and the server records an update." >&2
fi

resolve_auth
trap cleanup EXIT
BODY="$(fetch_request "$REQUEST_ID")" || die "failed to read request ${REQUEST_ID}"
BASELINE="$(request_work_baseline "$BODY")" || die "could not build the work baseline from GET /api/work/requests/${REQUEST_ID}"
MERGED="$(jq -nc --argjson base "$BASELINE" --slurpfile patch "$PATCH_FILE" '$base * $patch[0]')" || die "could not merge the patch"
send_work "$REQUEST_ID" "$MERGED"

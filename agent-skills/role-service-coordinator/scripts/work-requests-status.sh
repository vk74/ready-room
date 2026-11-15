#!/usr/bin/env bash
# version: 0.28.3
# Change a service request's status, preserving assignment and the work fields this command does not set.
# File: work-requests-status.sh
#
# Changes in v0.28.3:
# - Initial script: GET the request, set status and optional pause reason, actual minutes, and work notes, then PATCH /work.

set -euo pipefail

die() {
  echo "work-requests-status: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-requests-status.sh <request_uuid> <status> [--pause-reason <reason>]
       [--actual-minutes <N>] [--work-notes "<text>"]

status: new, in_progress, paused, resolved, reopened, closed.
When status is paused, pause_reason is required unless the request is already paused
and still has a reason. Allowed reasons: awaiting_requester, awaiting_third_party, scheduled, other.
--actual-minutes is an integer >= 0. --work-notes replaces work_notes. Omit it to keep the current notes.
Assignment is taken from the current row.
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
STATUS="$(trim "$2")"
shift 2
is_uuid "$REQUEST_ID" || die "not a UUID: $REQUEST_ID"
case "$STATUS" in
  new|in_progress|paused|resolved|reopened|closed) ;;
  *) die "status must be one of: new, in_progress, paused, resolved, reopened, closed" ;;
esac

PAUSE_REASON=""
ACTUAL=""
NOTES_SET="0"
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --pause-reason)
      shift
      [[ $# -gt 0 ]] || die "missing value after --pause-reason"
      PAUSE_REASON="$(trim "$1")"
      ;;
    --actual-minutes)
      shift
      [[ $# -gt 0 ]] || die "missing value after --actual-minutes"
      ACTUAL="$(trim "$1")"
      [[ "$ACTUAL" =~ ^[0-9]+$ ]] || die "actual-minutes must be an integer >= 0"
      ;;
    --work-notes)
      shift
      [[ $# -gt 0 ]] || die "missing value after --work-notes"
      NOTES="$(trim_text "$1")"
      NOTES_SET="1"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [[ -n "$PAUSE_REASON" ]]; then
  case "$PAUSE_REASON" in
    awaiting_requester|awaiting_third_party|scheduled|other) ;;
    *) die "pause-reason must be one of: awaiting_requester, awaiting_third_party, scheduled, other" ;;
  esac
fi

require_jq
resolve_auth
trap cleanup EXIT
BODY="$(fetch_request "$REQUEST_ID")" || die "failed to read request ${REQUEST_ID}"
BASELINE="$(request_work_baseline "$BODY")" || die "could not build the work baseline from GET /api/work/requests/${REQUEST_ID}"

if [[ "$STATUS" == "paused" && -z "$PAUSE_REASON" ]]; then
  current_reason="$(printf '%s' "$BASELINE" | jq -r '.pause_reason // empty')" || die "could not read the current pause_reason"
  case "$current_reason" in
    awaiting_requester|awaiting_third_party|scheduled|other) PAUSE_REASON="$current_reason" ;;
    *) die "status paused requires --pause-reason (awaiting_requester, awaiting_third_party, scheduled, other)" ;;
  esac
fi

OVERLAY="$(jq -n \
  --arg status "$STATUS" \
  --arg pause "$PAUSE_REASON" \
  --arg actual "$ACTUAL" \
  --arg notes_set "$NOTES_SET" \
  --arg notes "$NOTES" \
  '{status: $status}
   | if $status == "paused" then .pause_reason = $pause else . end
   | if $actual != "" then .actual_minutes = ($actual | tonumber) else . end
   | if $notes_set == "1" then .work_notes = $notes else . end')" || die "could not build the status overlay"
MERGED="$(jq -nc --argjson base "$BASELINE" --argjson overlay "$OVERLAY" '$base * $overlay')" || die "could not merge the status"
send_work "$REQUEST_ID" "$MERGED"

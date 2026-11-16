#!/usr/bin/env bash
# version: 0.28.3
# Update a manual task (PATCH /api/work/activities/manual-tasks/:id). Omit attachmentFileIds to keep current files.
# File: work-manual-tasks-update.sh
#
# Changes in v0.28.3:
# - Initial script: PATCH /api/work/activities/manual-tasks/:id with a JSON object.
# - Warns when attachmentFileIds is present because that key replaces attachments.

set -euo pipefail

die() {
  echo "work-manual-tasks-update: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: work-manual-tasks-update.sh <task_uuid> <payload.json>

JSON keys are camelCase: status, outcome, pauseReason, description, kbArticleId,
estimatedMinutes, actualMinutes, wbsCode, phase, workStream, plannedStartAt,
plannedEndAt, startedAt, predecessorIds.
Omit attachmentFileIds unless you intend to replace the attachment set.
An omitted attachmentFileIds key keeps the current files. A present key, including [], replaces them.
status: new, in_progress, paused, complete.
outcome: succeeded, cancelled, failed, skipped.
pauseReason when paused: awaiting_requester, awaiting_third_party, awaiting_parts, scheduled.
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

[[ $# -eq 2 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
ENTITY_ID="$(trim "$1")"
PAYLOAD_FILE="$2"
[[ -n "$ENTITY_ID" ]] || usage
[[ "$ENTITY_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a UUID: $ENTITY_ID"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: $PAYLOAD_FILE"
command -v jq >/dev/null 2>&1 || die "required command not found: jq"
jq -e 'type == "object"' "$PAYLOAD_FILE" >/dev/null || die "payload must be a JSON object"

if jq -e 'has("attachmentFileIds")' "$PAYLOAD_FILE" >/dev/null; then
  echo "work-manual-tasks-update: warning: attachmentFileIds replaces the attachment set. Omit attachmentFileIds to keep the current files." >&2
fi
resolve_auth
bash "$AUTH_REQUEST_SCRIPT" PATCH "/api/work/activities/manual-tasks/${ENTITY_ID}" \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"

#!/usr/bin/env bash
# version: 0.28.3
# Search admin services by name, service id, or translation key.
# File: admin-services-search.sh
#
# Changes in v0.28.3:
# - Initial script: GET /api/admin/app/services/services/search with q, limit, and language.

set -euo pipefail

die() {
  echo "admin-services-search: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: admin-services-search.sh <query> [--limit N] [--language english|russian]
EOF
  exit 1
}

require_positive_int() {
  local label="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      die "${label} must be a positive integer"
      ;;
  esac
  local stripped="$value"
  while [[ "$stripped" == 0* ]]; do
    stripped="${stripped#0}"
  done
  [[ -n "$stripped" ]] || die "${label} must be a positive integer"
}

[[ $# -ge 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
esac
QUERY="$(printf '%s' "$1" | xargs)"
shift
[[ -n "$QUERY" ]] || usage

LIMIT=""
LANGUAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      shift
      [[ $# -gt 0 ]] || die "missing value after --limit"
      LIMIT="$1"
      require_positive_int "--limit" "$LIMIT"
      ;;
    --language)
      shift
      [[ $# -gt 0 ]] || die "missing value after --language"
      LANGUAGE="$1"
      case "$LANGUAGE" in
        english|russian) ;;
        *) die "invalid --language: ${LANGUAGE}" ;;
      esac
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

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

CURL_ARGS=(--get --data-urlencode "q=${QUERY}")
if [[ -n "$LIMIT" ]]; then
  CURL_ARGS+=(--data-urlencode "limit=${LIMIT}")
fi
if [[ -n "$LANGUAGE" ]]; then
  CURL_ARGS+=(--data-urlencode "language=${LANGUAGE}")
fi

bash "$AUTH_REQUEST_SCRIPT" GET /api/admin/app/services/services/search ${CURL_ARGS[@]+"${CURL_ARGS[@]}"}

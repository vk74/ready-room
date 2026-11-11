#!/usr/bin/env bash
#
# Version: 0.26.2
# Purpose: Fetch list of container image tags from a registry (GHCR v2 API). Used by install.sh for manual EVI version selection.
# File: registry-tags.sh
# Deployment file: registry-tags.sh
# Logic:
# - Calls registry V2 API tags/list for the given image. Supports ghcr.io (public images; may use anonymous token).
# - For ghcr.io, always try the anonymous token exchange first. APP_GITHUB_TOKEN (or
#   ${APP_HOME}/.github-token) is used as Bearer only if that response is empty or lacks "tags".
# - Outputs one tag per line to stdout; exit 0 if success, non-zero on failure (network, auth, parse).
#
# Changes in v0.26.2:
# - Read and write APP_* configuration keys.
# 
# Changes in v0.23.9:
# - File renamed from evi-registry-tags.sh to registry-tags.sh.
#
# Changes in v0.23.6:
# - fetch_tags now tries the anonymous GHCR token exchange first, unconditionally.
#   EVI_GITHUB_TOKEN (PAT) is used as a Bearer fallback only when the anonymous
#   flow's response is empty or lacks "tags" (e.g. the package is private) — this
#   was previously the reverse priority (PAT first if set).
#
# Changes in v0.23.4:
# - Prefer EVI_GITHUB_TOKEN (or ${EVI_HOME}/.github-token when EVI_HOME is set) as Bearer for
#   GHCR tags/list; keep the anonymous token fallback when no PAT is present.
#
# Changes in v1.2.0:
# - Updated usage examples to use short image names (fe, be, db) without evi- prefix.
#
# Backend file: registry-tags.sh

set -euo pipefail

# --- Configuration ---
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"

usage() {
  echo "Usage: ${SCRIPT_NAME} <registry_base> <image_name>"
  echo "  registry_base  e.g. ghcr.io/vk74 (host/namespace)"
  echo "  image_name    e.g. fe, be, db"
  echo "Output: one tag per line; exit 0 on success, non-zero on failure."
  exit 1
}

# Build repo path for API: namespace/image (e.g. vk74/fe)
# registry_base may be ghcr.io/vk74 or vk74
get_repo_path() {
  local base="$1"
  local img="$2"
  local namespace
  if [[ "${base}" == *"/"* ]]; then
    namespace="${base##*/}"
  else
    namespace="${base}"
  fi
  echo "${namespace}/${img}"
}

# Fetch tags from registry. Uses anonymous token for GHCR when needed.
# Returns 0 and prints tags (one per line), or non-zero on failure.
fetch_tags() {
  local registry_base="$1"
  local image_name="$2"
  local host="${REGISTRY_HOST}"
  if [[ "${registry_base}" == *"/"* ]]; then
    host="${registry_base%%/*}"
  fi
  local repo_path
  repo_path=$(get_repo_path "${registry_base}" "${image_name}")
  local url="https://${host}/v2/${repo_path}/tags/list"

  local json=""
  local auth_token="${APP_GITHUB_TOKEN:-}"
  if [[ -z "${auth_token}" ]] && [[ -n "${APP_HOME:-}" ]]; then
    local token_file="${APP_HOME}/.github-token"
    if [[ -s "${token_file}" ]]; then
      auth_token=$(head -n 1 "${token_file}" || true)
      auth_token="${auth_token%$'\r'}"
    fi
  fi

  if [[ "${host}" == "ghcr.io" ]]; then
    # Anonymous token first (GHCR often requires this for tags/list)
    local token_resp
    token_resp=$(curl -sS --max-time 10 "https://${host}/token?scope=repository:${repo_path}:pull" 2>/dev/null || true)
    if [[ -n "${token_resp}" ]] && [[ "${token_resp}" == *'"token"'* ]]; then
      local token
      token=$(printf '%s' "${token_resp}" | tr -d '\n' | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      if [[ -n "${token}" ]]; then
        json=$(curl -sS --max-time 15 -H "Authorization: Bearer ${token}" -H "Accept: application/json" "${url}" 2>/dev/null || true)
      fi
    fi
  fi
  # PAT as Bearer only when anonymous did not yield a usable tag list (or host is not ghcr.io)
  if { [[ -z "${json}" ]] || [[ "${json}" != *'"tags"'* ]]; } && [[ -n "${auth_token}" ]]; then
    json=$(curl -sS --max-time 15 -H "Authorization: Bearer ${auth_token}" -H "Accept: application/json" "${url}" 2>/dev/null || true)
  fi
  if [[ -z "${json}" ]]; then
    json=$(curl -sS --max-time 15 -H "Accept: application/json" "${url}" 2>/dev/null || true)
  fi

  if [[ -z "${json}" ]] || [[ "${json}" != *'"tags"'* ]]; then
    return 1
  fi

  # Normalize to one line for sed; extract content inside "tags": [...]
  local json_line
  json_line=$(printf '%s' "${json}" | tr '\n' ' ')
  local raw
  raw=$(printf '%s' "${json_line}" | sed -n 's/.*"tags"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')
  if [[ -z "${raw}" ]]; then
    return 1
  fi

  # Split by comma and strip quotes/spaces; output one tag per line
  echo "${raw}" | tr ',' '\n' | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//;s/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
  return 0
}

# --- Main ---
if [[ $# -lt 2 ]]; then
  usage
fi
registry_base="$1"
image_name="$2"
if [[ -z "${registry_base}" ]] || [[ -z "${image_name}" ]]; then
  usage
fi

fetch_tags "${registry_base}" "${image_name}"

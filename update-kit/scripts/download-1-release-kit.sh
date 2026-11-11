#!/usr/bin/env bash
#
# Version: 0.27.2
# Purpose: Download the release tarball for one version, or reuse a kit already
#          staged at config/updates/<version>/ when its MANIFEST entries are present.
#          Extracts deploy/, update/, and package.json, checks them, and makes
#          the shell scripts executable. Writes KIT_BYTES and KIT_RETRIES.
#          Usage: download-1-release-kit.sh <APP_HOME> <version> <stats-file>
# File: download-1-release-kit.sh
#
# Changes in v0.27.2:
# - Read the distribution repository from APP_INSTALL_REPO (exported by lib/github-auth.sh) instead of local GITHUB_OWNER and GITHUB_REPO variables.
#
# Changes in v0.26.3:
# - Release-kit phase. Up to 3 attempts, backing off 3s then 6s.
#   A 401, 403, or 404 without a token is not retried.
# - A kit with no MANIFEST is accepted when deploy/install.sh exists and either
#   update/scripts/update-install-orchestrator.sh or update/scripts/apply-update.sh exists.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/update-common.sh
. "${SCRIPT_DIR}/lib/update-common.sh"
# shellcheck source=lib/github-auth.sh
. "${SCRIPT_DIR}/lib/github-auth.sh"

APP_HOME="${1:?usage: download-1-release-kit.sh <APP_HOME> <version> <stats-file>}"
VERSION="${2:?usage: download-1-release-kit.sh <APP_HOME> <version> <stats-file>}"
DL_STATS_FILE="${3:?usage: download-1-release-kit.sh <APP_HOME> <version> <stats-file>}"
export APP_HOME
load_github_token

CONFIG_DIR="${APP_HOME}/config"
UPDATES_DIR="${CONFIG_DIR}/updates"
UPDATES_JSON="${UPDATES_DIR}/updates.json"
MAX_DOWNLOAD_ATTEMPTS=3

github_token_required_err() {
  err "GitHub access key required. Set APP_GITHUB_TOKEN, or place it in ${APP_HOME}/.github-token or ${APP_HOME}/config/app.secrets.env"
}

format_bytes() {
  local bytes="${1:-0}"
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s' "$bytes"
    return 0
  fi
  if (( bytes >= 1048576 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }'
  elif (( bytes >= 1024 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.1f KB", b / 1024 }'
  else
    printf '%d B' "$bytes"
  fi
}

retry_backoff_for() {
  if [[ "$1" -le 1 ]]; then
    printf '3'
  else
    printf '6'
  fi
}

mark_download_incomplete() {
  [[ -f "$UPDATES_JSON" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/app-updates-XXXXXX")
    if jq '.downloaded = false | .downloadPath = ""' "$UPDATES_JSON" > "$tmp"; then
      mv "$tmp" "$UPDATES_JSON"
      return 0
    fi
    rm -f "$tmp"
  fi
  sed -i 's|"downloaded"[[:space:]]*:[[:space:]]*[^,}]*|"downloaded": false|' "$UPDATES_JSON" || true
  sed -i 's|"downloadPath"[[:space:]]*:[[:space:]]*"[^"]*"|"downloadPath": ""|' "$UPDATES_JSON" || true
}

write_kit_stats() {
  printf 'KIT_BYTES=%s\nKIT_RETRIES=%s\n' "$1" "$2" >> "$DL_STATS_FILE"
}

staging_path_from_manifest() {
  local dest="$1" rel="$2"
  case "${rel}" in
    update-kit/*) printf '%s/update/%s' "${dest}" "${rel#update-kit/}" ;;
    deploy-kit/*) printf '%s/deploy/%s' "${dest}" "${rel#deploy-kit/}" ;;
    *) printf '%s/%s' "${dest}" "${rel}" ;;
  esac
}

manifest_entries_present() {
  local dest="$1" manifest="$2" line="" staged=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    case "${line}" in
      ''|\#*) continue ;;
    esac
    staged="$(staging_path_from_manifest "${dest}" "${line}")"
    [[ -f "${staged}" ]] || return 1
  done < "${manifest}"
  return 0
}

validate_staging_against_manifest() {
  local dest="$1" manifest="$2" line="" rel="" staged="" missing=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    case "${line}" in
      ''|\#*) continue ;;
    esac
    rel="${line}"
    staged="$(staging_path_from_manifest "${dest}" "${rel}")"
    if [[ ! -f "${staged}" ]]; then
      err "new kit is missing ${rel} (expected ${staged#"${dest}"/}) — download may be corrupted"
      missing=1
    fi
  done < "${manifest}"
  return "${missing}"
}

# package.json plus both MANIFEST files, or the historical install/orchestrator files.
staged_kit_is_valid() {
  local dest="$1"
  [[ -f "${dest}/package.json" ]] || return 1
  if [[ -f "${dest}/deploy/MANIFEST" ]]; then
    manifest_entries_present "${dest}" "${dest}/deploy/MANIFEST" || return 1
  elif [[ ! -f "${dest}/deploy/install.sh" ]]; then
    return 1
  fi
  if [[ -f "${dest}/update/MANIFEST" ]]; then
    manifest_entries_present "${dest}" "${dest}/update/MANIFEST" || return 1
  elif [[ ! -f "${dest}/update/scripts/update-install-orchestrator.sh" && ! -f "${dest}/update/scripts/apply-update.sh" ]]; then
    return 1
  fi
  return 0
}

make_scripts_executable() {
  local download_dir="$1"
  if [[ -d "${download_dir}/deploy/scripts" ]]; then
    find "${download_dir}/deploy/scripts" -type f -name '*.sh' -exec chmod +x {} +
  fi
  if [[ -d "${download_dir}/update/scripts" ]]; then
    find "${download_dir}/update/scripts" -type f -name '*.sh' -exec chmod +x {} +
  fi
  if [[ -f "${download_dir}/deploy/install.sh" ]]; then
    chmod +x "${download_dir}/deploy/install.sh"
  fi
}

extract_and_validate_kit() {
  local download_dir="$1" tmp_tarball="$2" top_dir=""
  log "extracting deploy kit and update kit from tarball..."
  top_dir=$(tar -tzf "$tmp_tarball" 2>/dev/null | head -1 | cut -d'/' -f1 || true)
  if [[ -z "$top_dir" ]]; then
    err "could not determine tarball structure"
    rm -f "$tmp_tarball"
    return 1
  fi

  tar -xzf "$tmp_tarball" -C "$download_dir" --strip-components=1 "${top_dir}/deploy-kit" 2>/dev/null || {
    err "could not extract deploy-kit from tarball"
    err "expected structure: ${top_dir}/deploy-kit/"
    rm -f "$tmp_tarball"
    return 1
  }
  mv "${download_dir}/deploy-kit" "${download_dir}/deploy" || {
    err "could not stage deploy kit"
    rm -f "$tmp_tarball"
    return 1
  }

  tar -xzf "$tmp_tarball" -C "$download_dir" --strip-components=1 "${top_dir}/update-kit" 2>/dev/null || {
    err "could not extract update-kit from tarball"
    err "expected structure: ${top_dir}/update-kit/"
    rm -f "$tmp_tarball"
    return 1
  }
  mv "${download_dir}/update-kit" "${download_dir}/update" || {
    err "could not stage update kit"
    rm -f "$tmp_tarball"
    return 1
  }

  tar -xzf "$tmp_tarball" -C "$download_dir" --strip-components=1 "${top_dir}/package.json" 2>/dev/null || true
  rm -f "$tmp_tarball"
  printf " ${SYM_OK} tarball extracted to %s\n" "$download_dir"

  if [[ ! -f "${download_dir}/package.json" ]]; then
    err "package.json not found in tarball root — download may be incomplete or corrupted"
    rm -rf "$download_dir"
    return 1
  fi

  if [[ -f "${download_dir}/deploy/MANIFEST" ]]; then
    if ! validate_staging_against_manifest "${download_dir}" "${download_dir}/deploy/MANIFEST"; then
      rm -rf "$download_dir"
      return 1
    fi
    info "validated deploy kit against downloaded deploy-kit/MANIFEST"
  else
    warn "downloaded kit has no deploy-kit/MANIFEST; falling back to built-in file checks"
    if [[ ! -f "${download_dir}/deploy/install.sh" ]]; then
      if [[ -f "${download_dir}/install.sh" ]]; then
        local tmp_wrap
        tmp_wrap=$(mktemp -d "${UPDATES_DIR}/wrap-XXXXXX")
        mv "$download_dir" "$tmp_wrap/deploy" || return 1
        mv "$tmp_wrap" "$download_dir" || return 1
      else
        err "extracted kit is missing install.sh — download may be corrupted"
        rm -rf "$download_dir"
        return 1
      fi
    fi
  fi

  if [[ -f "${download_dir}/update/MANIFEST" ]]; then
    if ! validate_staging_against_manifest "${download_dir}" "${download_dir}/update/MANIFEST"; then
      rm -rf "$download_dir"
      return 1
    fi
    info "validated update kit against downloaded update-kit/MANIFEST"
  else
    warn "downloaded kit has no update-kit/MANIFEST; falling back to built-in file checks"
    if [[ ! -f "${download_dir}/update/scripts/update-install-orchestrator.sh" && ! -f "${download_dir}/update/scripts/apply-update.sh" ]]; then
      err "new kit does not contain update/scripts/update-install-orchestrator.sh — download may be corrupted"
      rm -rf "$download_dir"
      return 1
    fi
    if [[ ! -f "${download_dir}/update/scripts/run-migrations.sh" ]]; then
      warn "update/scripts/run-migrations.sh not found in kit (migrations may be skipped during apply)"
    fi
  fi

  make_scripts_executable "$download_dir"
  return 0
}

download_dir="${UPDATES_DIR}/${VERSION}"
tag="v${VERSION}"
tarball_url="https://api.github.com/repos/${APP_INSTALL_REPO}/tarball/${tag}"
log "download directory: ${download_dir}"

if [[ -d "$download_dir" ]] && staged_kit_is_valid "$download_dir"; then
  printf " ${SYM_OK} release kit v%s already staged at %s\n" "$VERSION" "$download_dir"
  make_scripts_executable "$download_dir"
  write_kit_stats 0 0
  exit 0
fi

if [[ -d "$download_dir" ]]; then
  log "removing previous partial download..."
  rm -rf "$download_dir"
fi
mkdir -p "$UPDATES_DIR" "$download_dir"
mark_download_incomplete

tmp_tarball=$(mktemp "${UPDATES_DIR}/app-update-XXXXXX.tar.gz")
trap 'rm -f "$tmp_tarball"' EXIT

kit_retries=0
download_ok=0
http_code=""
tarball_bytes=0
dl_sec=0
attempt=0
for (( attempt=1; attempt<=MAX_DOWNLOAD_ATTEMPTS; attempt++ )); do
  log "downloading release kit v${VERSION} (tag: ${tag}, attempt ${attempt}/${MAX_DOWNLOAD_ATTEMPTS})..."
  t0=$SECONDS
  curl_rc=0
  http_code=$(github_curl -sS -L --connect-timeout 15 --max-time 120 -w "%{http_code}" -o "$tmp_tarball" \
    -H "Accept: application/vnd.github+json" \
    "$tarball_url" 2>/dev/null) || curl_rc=$?
  http_code="${http_code//$'\n'/}"
  if [[ ! "${http_code}" =~ ^[0-9]{3}$ ]]; then
    http_code=""
  fi
  if [[ "$curl_rc" -eq 0 && "$http_code" == "200" ]]; then
    download_ok=1
    break
  fi
  if [[ -z "${APP_GITHUB_TOKEN:-}" && ( "$http_code" == "401" || "$http_code" == "403" || "$http_code" == "404" ) ]]; then
    github_token_required_err
    rm -f "$tmp_tarball"
    rm -rf "$download_dir"
    mark_download_incomplete
    exit 1
  fi
  if [[ "$attempt" -lt "$MAX_DOWNLOAD_ATTEMPTS" ]]; then
    kit_retries=$((kit_retries + 1))
    backoff=$(retry_backoff_for "$attempt")
    printf " ${SYM_WARN} download attempt %s/%s failed (HTTP %s); retrying in %ss...\n" \
      "$attempt" "$MAX_DOWNLOAD_ATTEMPTS" "${http_code:-error}" "$backoff"
    sleep "$backoff"
  fi
done

if [[ "$download_ok" -ne 1 ]]; then
  printf " ${SYM_FAIL} failed to download release kit after %s attempts\n" "$MAX_DOWNLOAD_ATTEMPTS"
  rm -f "$tmp_tarball"
  rm -rf "$download_dir"
  mark_download_incomplete
  exit 1
fi

tarball_bytes=$(stat -c%s "$tmp_tarball" 2>/dev/null || stat -f%z "$tmp_tarball" 2>/dev/null || echo 0)
if ! [[ "$tarball_bytes" =~ ^[0-9]+$ ]]; then
  tarball_bytes=0
fi
dl_sec=$((SECONDS - t0))
(( dl_sec < 1 )) && dl_sec=1
speed_bps=$((tarball_bytes / dl_sec))
printf " ${SYM_OK} downloaded release kit (%s in %ds, %s/s)\n" \
  "$(format_bytes "$tarball_bytes")" "$dl_sec" "$(format_bytes "$speed_bps")"

if ! extract_and_validate_kit "$download_dir" "$tmp_tarball"; then
  rm -f "$tmp_tarball"
  mark_download_incomplete
  exit 1
fi

write_kit_stats "$tarball_bytes" "$kit_retries"
exit 0

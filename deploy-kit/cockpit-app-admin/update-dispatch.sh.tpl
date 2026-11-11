#!/usr/bin/env bash
# Version: 0.27.1
# Purpose: Dispatcher for application update Cockpit package.
# Routes commands from the Cockpit UI to the appropriate update scripts.
# read-status reports the staged kit version and, when config/app.env exists,
# fills empty deployedAt and lastUpdatedAt from app.instance.
# start-update refuses a version mismatch and may store a sudo password from stdin.
# discard-download removes only that staged kit directory.
# The {{DEPLOYMENT_DIR}} placeholder is replaced during install.sh with the
# actual deployment directory path.
# Cockpit package. File: update-dispatch.sh
#
# Changes in v0.27.1:
# - Preserve trailing newlines when reading log chunks in update-progress so
#   consecutively polled lines are not concatenated in the UI Output block.
#
# Changes in v0.26.3:
# - list-releases runs update-check-orchestrator.sh. download-update runs
#   update-download-orchestrator.sh.
# - resolve_apply_script prefers update/scripts/update-install-orchestrator.sh
#   and falls back to update-orchestrator.sh, then apply-update.sh.
# - Removed check-updates, install-update, start-cockpit-install, and cockpit-install-progress.
# - set-github-token runs scripts/admin/set-github-token.sh.
# - read-status stores deployedAt and lastUpdatedAt from app.instance when either
#   value is empty and config/app.env exists.
# - start-update reads an optional sudo password from a non-terminal stdin and
#   writes config/updates/sudo.pass (mode 600) before launching the install script.
# - cleanup-update removes sudo.pass, install-cockpit-panels.run.sh, and leftover
#   cockpit install pid, result, and log files.
# - Installed version, downloadPath, includeBeta, and progress exitCode are
#   read or written with jq.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# 
# Changes in v0.25.5:
# - update-progress and cockpit-install-progress encode JSON with jq so ANSI
#   escape codes and control characters in logContent produce valid JSON.
# - Detach nohup background processes from stdin (< /dev/null) in start-update
#   and start-cockpit-install.
#
# Changes in v0.25.4:
# - github-token-status reads config/app.secrets.env, falling back to legacy config/evi.secrets.env.
#
# Changes in v0.24.5:
# - read-status writes currentVersion from the deployment package.json with jq
#   when the stored value differs, and adds stagedVersion only to the response.
# - read-status clears downloaded and downloadPath when the staged kit is
#   missing or its version cannot be read, without changing latestVersion or
#   the other check fields.
# - start-update requires its version argument to match the staged kit before
#   it creates a lock or pid or launches apply-update.sh.
# - discard-download removes only a direct child of config/updates and resets
#   downloaded, downloadPath, minVersion, and compatible.
#
# Changes in v0.23.5:
# - github-token-status: report whether a GitHub access key is configured
#   (.github-token first line or EVI_GITHUB_TOKEN in evi.secrets.env), without printing it.
# - set-github-token: exec set-github-token.sh; token arrives on stdin (not argv/env).
#
# Changes in v1.7.3:
# - read-status syncs currentVersion from deployment package.json when missing or unknown
# - set-include-beta seeds currentVersion from package.json instead of "unknown"
#
# Changes in v1.7.2:
# - set-include-beta creates full updates.json schema when file is missing (not includeBeta-only stub)
#
# Changes in v1.7.1:
# - Updated comments: evi-db → db to match current container naming (evi- prefix removed).
#
# Changes in v1.7.0:
# - verify-sudo: validate sudo password (reads from stdin, returns ok/fail JSON)
# - start-cockpit-install: write sudo.pass (chmod 600), launch install-cockpit-panels.sh detached
# - cockpit-install-progress: poll cockpit-install.pid + cockpit-install-result.json, return status/log
# - cleanup-update: also removes cockpit-install.pid, cockpit-install-result.json, cockpit-install-output.log, sudo.pass
#
# Changes in v1.6.0:
# - list-releases: new command to fetch list of available releases with minVersion/compatibility
# - download-update: forward $@ so UI can pass --version <ver> for targeted downloads
#
# Changes in v1.5.0:
# - check-updates: forward extra args ($@) to check-updates.sh so --include-prerelease passes through
# - set-include-beta: new command to persist includeBeta preference in updates.json
#
# Changes in v1.4.0:
# - start-update: set XDG_RUNTIME_DIR to deployment owner's /run/user/$uid so rootless podman in apply-update.sh (run-migrations) sees db; fixes "no container with name db found" when run from Cockpit.
#
# Changes in v1.3.0:
# - start-update passes DEPLOYMENT_DIR as first argument to apply-update.sh
# - install-update simplified to exec same script with start-update (no duplicate block)
#
# Changes in v1.2.0:
# - Update scripts moved from deploy/scripts/ to update/scripts/ (separate update kit)
# - Added UPDATE_SCRIPTS_DIR for check-updates, download-update, start-update commands
# - resolve_apply_script() now looks for update/scripts/apply-update.sh in downloaded kit
# - SCRIPTS_DIR kept for install/admin scripts only
#
# Changes in v1.1.1:
# - Fix: update-progress reads update-result.json for actual exit code when process finished
# - Fix: update-progress checks update-result.json when PID file missing (no false idle)
# - cleanup-update now removes update-result.json and update-output.log along with pid/lock
#
# Changes in v1.1.0:
# - Added start-update: launches apply-update.sh detached (nohup), lock/pid/log files
# - Added update-progress: returns status and log chunk for polling UI
# - Added cleanup-update: removes lock/pid after user dismisses result
# - install-update kept as deprecated alias that invokes start-update

set -euo pipefail

DEPLOYMENT_DIR="{{DEPLOYMENT_DIR}}"
SCRIPTS_DIR="${DEPLOYMENT_DIR}/scripts"
UPDATE_SCRIPTS_DIR="${DEPLOYMENT_DIR}/update/scripts"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
UPDATES_DIR="${CONFIG_DIR}/updates"
UPDATES_JSON="${UPDATES_DIR}/updates.json"

LOCK_FILE="${UPDATES_DIR}/update.lock"
PID_FILE="${UPDATES_DIR}/update.pid"
OUTPUT_LOG="${UPDATES_DIR}/update-output.log"
RESULT_JSON="${UPDATES_DIR}/update-result.json"

SUDO_PASS_FILE="${UPDATES_DIR}/sudo.pass"

CMD="${1:-}"
shift || true

# --- Installed version from deployment package.json ---
get_installed_version() {
  local ver
  ver=$(read_package_version "${DEPLOYMENT_DIR}/package.json")
  echo "${ver:-unknown}"
}

# Rewrite updates.json with a jq filter. Extra jq arguments (for example
# --arg) come after the filter. Writes a temp file, then mv.
rewrite_updates_json() {
  local filter="$1"
  shift
  local tmp
  tmp=$(mktemp "${UPDATES_DIR}/updates.json.XXXXXX") || return 1
  if ! /usr/bin/jq "$@" "$filter" "$UPDATES_JSON" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$UPDATES_JSON"
}

# One-line error object on stdout, then exit 1.
fail_json() {
  /usr/bin/jq -nc --arg error "$1" '{status:"error",error:$error}'
  exit 1
}

# Version string from a package.json, or empty when the file or field is missing.
read_package_version() {
  local pkg="$1"
  local ver
  if [[ ! -f "$pkg" ]]; then
    printf '\n'
    return 0
  fi
  ver=$(/usr/bin/jq -r 'if (.version | type) == "string" then .version else "" end' "$pkg" 2>/dev/null || true)
  printf '%s\n' "$ver"
}

# Version from <dir>/package.json. Empty when dir is missing or the version
# cannot be read.
read_package_version_from_dir() {
  local dir="$1"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    printf '\n'
    return 0
  fi
  read_package_version "${dir}/package.json"
}

# Staged kit version when updates.json says downloaded and the kit package.json
# is readable. Empty otherwise. Does not modify updates.json.
staged_version_if_downloaded() {
  local downloaded download_path
  if [[ ! -f "$UPDATES_JSON" ]]; then
    printf '\n'
    return 0
  fi
  downloaded=$(/usr/bin/jq -r 'if .downloaded == true then "true" else "false" end' "$UPDATES_JSON") || return 1
  if [[ "$downloaded" != "true" ]]; then
    printf '\n'
    return 0
  fi
  download_path=$(/usr/bin/jq -r 'if .downloadPath == null then "" else .downloadPath end' "$UPDATES_JSON") || return 1
  read_package_version_from_dir "$download_path"
}

# Write currentVersion from the deployment package.json when it is readable
# and differs from the stored value.
sync_current_version_with_jq() {
  local installed cur
  if [[ ! -f "$UPDATES_JSON" ]]; then
    return 0
  fi
  installed=$(get_installed_version)
  if [[ "$installed" == "unknown" ]]; then
    return 0
  fi
  cur=$(/usr/bin/jq -r 'if .currentVersion == null then "" else .currentVersion end' "$UPDATES_JSON") || return 1
  if [[ "$cur" == "$installed" ]]; then
    return 0
  fi
  rewrite_updates_json '.currentVersion = $currentVersion' --arg currentVersion "$installed"
}

# Fill empty deployedAt / lastUpdatedAt from app.instance. Skipped when
# config/app.env is absent so a status test that never creates that file
# leaves updates.json unchanged.
sync_instance_dates_with_jq() {
  [[ -f "${CONFIG_DIR}/app.env" ]] || return 0
  [[ -f "$UPDATES_JSON" ]] || return 0
  local deployed="" last_updated=""
  deployed=$(/usr/bin/jq -r 'if (.deployedAt | type) == "string" then .deployedAt else "" end' "$UPDATES_JSON" 2>/dev/null || true)
  last_updated=$(/usr/bin/jq -r 'if (.lastUpdatedAt | type) == "string" then .lastUpdatedAt else "" end' "$UPDATES_JSON" 2>/dev/null || true)
  if [[ -n "$deployed" && -n "$last_updated" ]]; then
    return 0
  fi
  export XDG_RUNTIME_DIR="/run/user/$(stat -c '%u' "$DEPLOYMENT_DIR" 2>/dev/null || id -u)"
  local db_name="maindb" env_db="" raw="" deployed_at="" last_updated_at=""
  env_db=$(grep '^APP_POSTGRES_DB=' "${CONFIG_DIR}/app.env" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'" || true)
  [[ -n "$env_db" ]] && db_name="$env_db"
  raw=$(podman exec db psql -U postgres -d "$db_name" -tAc "SELECT COALESCE(to_char(deployed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '') || '|' || COALESCE(to_char(last_updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '') FROM app.instance WHERE id = 1" 2>/dev/null || true)
  raw=$(printf '%s' "$raw" | tr -d '[:space:]')
  [[ -z "$raw" || "$raw" != *"|"* ]] && return 0
  deployed_at="${raw%%|*}"
  last_updated_at="${raw#*|}"
  [[ -z "$deployed_at" && -z "$last_updated_at" ]] && return 0
  local new_deployed="$deployed" new_updated="$last_updated"
  [[ -z "$deployed" && -n "$deployed_at" ]] && new_deployed="$deployed_at"
  [[ -z "$last_updated" && -n "$last_updated_at" ]] && new_updated="$last_updated_at"
  [[ -z "$new_deployed" && -z "$new_updated" ]] && return 0
  rewrite_updates_json \
    '.deployedAt = (if $deployedAt != "" then $deployedAt else (.deployedAt // "") end) | .lastUpdatedAt = (if $lastUpdatedAt != "" then $lastUpdatedAt else (.lastUpdatedAt // "") end)' \
    --arg deployedAt "$new_deployed" \
    --arg lastUpdatedAt "$new_updated" || return 0
}

cmd_read_status() {
  local installed downloaded download_path staged
  if [[ ! -f "$UPDATES_JSON" ]]; then
    installed=$(get_installed_version)
    /usr/bin/jq -nc \
      --arg currentVersion "$installed" \
      '{currentVersion:$currentVersion,latestVersion:"unknown",available:false,compatible:true,minVersion:"",downloaded:false,downloadPath:"",releaseNotes:"",lastCheck:"",stagedVersion:""}'
    return 0
  fi
  sync_current_version_with_jq
  sync_instance_dates_with_jq
  downloaded=$(/usr/bin/jq -r 'if .downloaded == true then "true" else "false" end' "$UPDATES_JSON") || return 1
  staged=""
  if [[ "$downloaded" == "true" ]]; then
    download_path=$(/usr/bin/jq -r 'if .downloadPath == null then "" else .downloadPath end' "$UPDATES_JSON") || return 1
    staged=$(read_package_version_from_dir "$download_path")
    if [[ -z "$staged" ]]; then
      rewrite_updates_json '.downloaded = false | .downloadPath = ""'
      staged=""
    fi
  fi
  /usr/bin/jq -c --arg stagedVersion "$staged" '. + {stagedVersion: $stagedVersion}' "$UPDATES_JSON"
}

# Refuse start-update unless the argument matches the staged kit version.
# Prints nothing when the versions match.
refuse_start_version() {
  local expected="$1"
  local staged err
  staged=$(staged_version_if_downloaded) || fail_json "staged update version could not be read"
  if [[ -z "$expected" ]]; then
    err="expected version is required"
  elif [[ -z "$staged" ]]; then
    err="staged update version could not be read"
  elif [[ "$expected" != "$staged" ]]; then
    err="staged version does not match the requested version"
  else
    return 0
  fi
  fail_json "$err"
}

# Canonical staged directory when it is a direct child of the updates
# directory. Prints nothing and returns 1 when the path is not safe to delete.
safe_staged_dir() {
  local download_path="$1"
  local updates_real staged_real parent
  updates_real=$(realpath "$UPDATES_DIR") || return 1
  staged_real=$(realpath "$download_path") || return 1
  parent=$(dirname "$staged_real")
  parent=$(realpath "$parent") || return 1
  if [[ "$parent" != "$updates_real" || "$staged_real" == "$updates_real" ]]; then
    return 1
  fi
  printf '%s\n' "$staged_real"
}

cmd_discard_download() {
  local old_pid download_path staged_real
  if [[ -f "$PID_FILE" ]]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    # A non-numeric pid is not a live update. kill -0 0 would signal this process group.
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && [[ "$old_pid" -gt 0 ]] && kill -0 "$old_pid" 2>/dev/null; then
      fail_json "an update is already running"
    fi
  fi
  if [[ ! -f "$UPDATES_JSON" ]]; then
    fail_json "updates.json not found"
  fi
  download_path=$(/usr/bin/jq -r 'if .downloadPath == null then "" else .downloadPath end' "$UPDATES_JSON") || fail_json "updates.json could not be read"
  if [[ -n "$download_path" && -d "$download_path" ]]; then
    staged_real=$(safe_staged_dir "$download_path") || fail_json "download path is not a direct child of the updates directory"
    rm -rf "$staged_real"
  fi
  rewrite_updates_json '.downloaded = false | .downloadPath = "" | .minVersion = "" | .compatible = true' || fail_json "updates.json could not be updated"
  echo '{"status":"ok"}'
}

# --- Resolve the update entrypoint from updates.json downloadPath ---
# Prefer the install orchestrator. Older kits and the panel status fixture
# still ship update-orchestrator.sh or apply-update.sh.
resolve_apply_script() {
  if [[ ! -f "$UPDATES_JSON" ]]; then
    echo "ERROR: updates.json not found. Run check and download first." >&2
    return 1
  fi
  local download_path
  download_path=$(/usr/bin/jq -r 'if (.downloadPath | type) == "string" then .downloadPath else "" end' "$UPDATES_JSON") || return 1
  if [[ -z "$download_path" ]] || [[ ! -d "$download_path" ]]; then
    echo "ERROR: Update not downloaded or download path invalid." >&2
    return 1
  fi
  local orchestrator="${download_path}/update/scripts/update-install-orchestrator.sh"
  local previous="${download_path}/update/scripts/update-orchestrator.sh"
  local apply_script="${download_path}/update/scripts/apply-update.sh"
  if [[ -f "$orchestrator" ]]; then
    echo "$orchestrator"
    return 0
  fi
  if [[ -f "$previous" ]]; then
    echo "$previous"
    return 0
  fi
  if [[ -f "$apply_script" ]]; then
    echo "$apply_script"
    return 0
  fi
  echo "ERROR: update-install-orchestrator.sh not found in downloaded kit at ${orchestrator}" >&2
  return 1
}

case "$CMD" in
  list-releases)
    exec "${UPDATE_SCRIPTS_DIR}/update-check-orchestrator.sh" "$DEPLOYMENT_DIR" "$@"
    ;;
  download-update)
    exec "${UPDATE_SCRIPTS_DIR}/update-download-orchestrator.sh" "$DEPLOYMENT_DIR" "$@"
    ;;
  discard-download)
    cmd_discard_download
    ;;
  set-include-beta)
    BETA_VAL="${1:-false}"
    INSTALLED_VERSION=$(get_installed_version)
    if [[ ! -f "$UPDATES_JSON" ]]; then
      mkdir -p "$UPDATES_DIR"
      tmp_updates=$(mktemp "${UPDATES_DIR}/updates.json.XXXXXX")
      if ! /usr/bin/jq -n \
        --arg currentVersion "$INSTALLED_VERSION" \
        --argjson includeBeta "$BETA_VAL" \
        '{currentVersion:$currentVersion,latestVersion:"",available:false,compatible:true,minVersion:"",downloaded:false,downloadPath:"",releaseNotes:"",lastCheck:"",includeBeta:$includeBeta}' \
        > "$tmp_updates"; then
        rm -f "$tmp_updates"
        exit 1
      fi
      mv "$tmp_updates" "$UPDATES_JSON"
    else
      rewrite_updates_json '.includeBeta = $beta' --argjson beta "$BETA_VAL"
    fi
    echo "{\"status\":\"ok\",\"includeBeta\":${BETA_VAL}}"
    ;;
  read-status)
    cmd_read_status
    ;;
  start-update)
    if [[ -f "$PID_FILE" ]]; then
      OLD_PID=$(cat "$PID_FILE")
      if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "{\"status\":\"already_running\",\"pid\":$OLD_PID}"
        exit 0
      fi
      rm -f "$PID_FILE" "$LOCK_FILE"
    fi

    refuse_start_version "${1:-}"

    APPLY_SCRIPT=$(resolve_apply_script) || exit 1
    chmod +x "$APPLY_SCRIPT"

    # Optional sudo password on a non-terminal stdin. A closed or empty stdin
    # (tests use /dev/null) returns immediately and leaves SUDO_PASSWORD empty.
    if [[ ! -t 0 ]]; then
      IFS= read -r -t 1 SUDO_PASSWORD 2>/dev/null || true
    fi

    # Run apply as deployment owner's runtime so podman sees db (rootless podman uses XDG_RUNTIME_DIR).
    OWNER_UID=$(stat -c '%u' "$DEPLOYMENT_DIR" 2>/dev/null || stat -f '%u' "$DEPLOYMENT_DIR" 2>/dev/null)
    if [[ -n "$OWNER_UID" ]] && [[ -d "/run/user/${OWNER_UID}" ]]; then
      export XDG_RUNTIME_DIR="/run/user/${OWNER_UID}"
    fi

    touch "$LOCK_FILE"
    if [[ -n "${SUDO_PASSWORD:-}" ]]; then
      printf '%s\n' "${SUDO_PASSWORD}" > "$SUDO_PASS_FILE"
      chmod 600 "$SUDO_PASS_FILE"
    fi
    nohup "$APPLY_SCRIPT" "$DEPLOYMENT_DIR" < /dev/null > "$OUTPUT_LOG" 2>&1 &
    CHILD_PID=$!
    echo "$CHILD_PID" > "$PID_FILE"
    echo "{\"status\":\"started\",\"pid\":$CHILD_PID}"
    ;;
  update-progress)
    OFFSET="${1:-0}"

    # Determine process state: running / finished / idle
    STATUS="idle"
    EXIT_CODE=""

    if [[ -f "$PID_FILE" ]]; then
      PID=$(cat "$PID_FILE")
      if kill -0 "$PID" 2>/dev/null; then
        STATUS="running"
      else
        STATUS="finished"
      fi
    fi

    # When finished (or PID file gone), read actual result from update-result.json
    if [[ "$STATUS" != "running" ]] && [[ -f "$RESULT_JSON" ]]; then
      STATUS="finished"
      EXIT_CODE=$(/usr/bin/jq -r 'if (.exitCode | type) == "number" then (.exitCode | tostring) else "1" end' "$RESULT_JSON" 2>/dev/null || echo "1")
    fi

    # No PID file and no result file means no update has run
    if [[ "$STATUS" == "idle" ]]; then
      echo '{"status":"idle"}'
      exit 0
    fi

    # Read log chunk (sentinel 'x' prevents bash $(...) from stripping trailing newlines)
    LOG_SIZE=0
    [[ -f "$OUTPUT_LOG" ]] && LOG_SIZE=$(stat -c%s "$OUTPUT_LOG" 2>/dev/null || stat -f%z "$OUTPUT_LOG" 2>/dev/null || echo "0")
    LOG_CONTENT=""
    if [[ -f "$OUTPUT_LOG" ]] && [[ "$OFFSET" -lt "$LOG_SIZE" ]]; then
      LOG_CONTENT=$(tail -c +"$((OFFSET + 1))" "$OUTPUT_LOG" 2>/dev/null | head -c 32768; printf x)
      LOG_CONTENT="${LOG_CONTENT%x}"
    fi

    if [[ -n "$EXIT_CODE" ]]; then
      /usr/bin/jq -nc \
        --arg status "$STATUS" \
        --argjson exitCode "$EXIT_CODE" \
        --arg logContent "$LOG_CONTENT" \
        --argjson logOffset "$LOG_SIZE" \
        '{status:$status,exitCode:$exitCode,logContent:$logContent,logOffset:$logOffset}'
    else
      /usr/bin/jq -nc \
        --arg status "$STATUS" \
        --arg logContent "$LOG_CONTENT" \
        --argjson logOffset "$LOG_SIZE" \
        '{status:$status,logContent:$logContent,logOffset:$logOffset}'
    fi
    ;;
  verify-sudo)
    read -r SUDO_PASSWORD 2>/dev/null || SUDO_PASSWORD=""
    if echo "${SUDO_PASSWORD}" | sudo -S true 2>/dev/null; then
      echo '{"status":"ok"}'
    else
      echo '{"status":"fail"}'
    fi
    ;;
  cleanup-update)
    rm -f "$PID_FILE" "$LOCK_FILE" "$RESULT_JSON" "$OUTPUT_LOG" "$SUDO_PASS_FILE"
    rm -f "${UPDATES_DIR}/cockpit-install.pid" "${UPDATES_DIR}/cockpit-install-result.json" "${UPDATES_DIR}/cockpit-install-output.log"
    rm -f "${UPDATES_DIR}/install-cockpit-panels.run.sh"
    echo '{"status":"cleaned"}'
    ;;
  get-defaults)
    echo "DEPLOYMENT_DIR=${DEPLOYMENT_DIR}"
    echo "CONFIG_DIR=${CONFIG_DIR}"
    echo "UPDATES_DIR=${UPDATES_DIR}"
    CURRENT_VERSION=$(sed -n '1,20p' "${DEPLOYMENT_DIR}/install.sh" 2>/dev/null | grep -m1 '^# Version: ' | sed 's/^# Version:[[:space:]]*//' || echo "?")
    echo "CURRENT_VERSION=${CURRENT_VERSION}"
    ;;
  github-token-status)
    configured=false
    token_file="${DEPLOYMENT_DIR}/.github-token"
    if [[ -s "${token_file}" ]]; then
      line=$(head -n 1 "${token_file}" || true)
      line="${line%$'\r'}"
      if [[ -n "${line}" ]]; then
        configured=true
      fi
      line=""
    fi
    if [[ "${configured}" != "true" ]]; then
      secrets_file="${CONFIG_DIR}/app.secrets.env"
      if [[ -f "${secrets_file}" ]]; then
        line=$(grep "^APP_GITHUB_TOKEN=" "${secrets_file}" 2>/dev/null | head -n 1 || true)
        val="${line#APP_GITHUB_TOKEN=}"
        if [[ "${val}" == \"*\" ]]; then
          val="${val#\"}"
          val="${val%\"}"
        elif [[ "${val}" == \'*\' ]]; then
          val="${val#\'}"
          val="${val%\'}"
        fi
        if [[ -n "${val}" ]]; then
          configured=true
        fi
        val=""
      fi
    fi
    printf '{"configured":%s}\n' "${configured}"
    ;;
  set-github-token)
    # inherits stdin from cockpit.spawn — do not put token in argv or env
    export APP_HOME="$DEPLOYMENT_DIR"
    exec "${SCRIPTS_DIR}/admin/set-github-token.sh" "$DEPLOYMENT_DIR"
    ;;
  *)
    echo "ERROR: Unknown command: ${CMD}" >&2
    echo "Available commands: list-releases, download-update, discard-download, read-status, start-update, update-progress, cleanup-update, set-include-beta, get-defaults, verify-sudo, github-token-status, set-github-token" >&2
    exit 1
    ;;
esac

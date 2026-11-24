#!/usr/bin/env bash
# Version: 0.28.9
# Purpose: Dispatcher for application admin tools Cockpit package.
# Routes commands from the Cockpit UI to the appropriate deployment scripts.
# The {{DEPLOYMENT_DIR}} placeholder is replaced during install.sh with the
# actual deployment directory path.
# Cockpit package; filename: admin-dispatch.sh
#
# Changes in v0.28.9:
# - disk-status, disk-cleanup, and disk-storage-apply run the admin disk scripts.
# - env-load emits APP_LIMIT_MEM_* only.
#
# Changes in v0.26.3:
# - backup-create, backup-estimate, and backup-verify run from scripts/backup/.
# - admin-set-password runs scripts/admin/admin-set-admin-password.sh.
# - env-apply runs scripts/admin/admin-env-apply.sh.
# - env-regen-cert runs scripts/tls/gen-self-signed-tls.sh.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# 
# Changes in v0.25.4:
# - env-load and env-regen-cert read config/app.env, falling back to legacy config/evi.env.
#
# Changes in v0.23.9:
# - env-load includes APP_LIMIT_MEM_STATE for the evi-state memory limit.
#
# Changes in v1.3.0:
# - disk-status: output JSON with disk usage for system and data disks, plus critical/warning state.
#
# Changes in v1.2.0:
# - env-load: print managed KEY=value lines from config/evi.env for Container Environment panel
# - env-apply: apply stdin KEY=value patches via admin-env-apply.sh then cockpit apply/restart
# - env-regen-cert: run gen-self-signed-tls.sh for current EVI_DOMAIN into config/tls
#
# Changes in v1.1.0:
# - Route admin-set-password to admin-set-admin-password.sh (system admin DB password + evi-state restart)
#
# Changes in v1.0.1:
# - DEFAULT_BACKUP_DIR changed to config/backup (deploy kit / runtime config split).

set -euo pipefail

DEPLOYMENT_DIR="{{DEPLOYMENT_DIR}}"
SCRIPTS_DIR="${DEPLOYMENT_DIR}/scripts"
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
TARGET_ENV="${CONFIG_DIR}/app.env"

CMD="${1:-}"
shift || true

case "$CMD" in
  backup-create)
    exec "${SCRIPTS_DIR}/backup/backup-create.sh" "$@"
    ;;
  backup-estimate)
    exec "${SCRIPTS_DIR}/backup/backup-estimate.sh" "$@"
    ;;
  backup-verify)
    exec "${SCRIPTS_DIR}/backup/backup-verify.sh" "$@"
    ;;
  get-defaults)
    echo "DEPLOYMENT_DIR=${DEPLOYMENT_DIR}"
    echo "DEFAULT_BACKUP_DIR=${DEPLOYMENT_DIR}/config/backup"
    ;;
  admin-set-password)
    exec "${SCRIPTS_DIR}/admin/admin-set-admin-password.sh" "$@"
    ;;
  env-load)
    if [[ ! -f "${TARGET_ENV}" ]]; then
      echo "ERROR: app.env not found at ${TARGET_ENV}" >&2
      exit 1
    fi
    _app_env_get() {
      local k="$1"
      local v
      v=$(grep "^${k}=" "${TARGET_ENV}" 2>/dev/null | head -1 | cut -d= -f2- || true)
      printf '%s' "${v}"
    }
    for k in \
      APP_DOMAIN APP_TLS_MODE APP_ACME_EMAIL APP_HTTP_PORT APP_HTTPS_PORT APP_CORS_ORIGINS \
      APP_FIREWALL_ADMIN_ACCESS APP_FIREWALL_ADMIN_ALLOWED \
      APP_LIMIT_MEM_PROXY APP_LIMIT_MEM_FE APP_LIMIT_MEM_BE APP_LIMIT_MEM_DB APP_LIMIT_MEM_STATE APP_LIMIT_MEM_WORKER APP_LIMIT_MEM_FS; do
      printf '%s=%s\n' "${k}" "$(_app_env_get "${k}")"
    done
    ;;
  env-apply)
    exec "${SCRIPTS_DIR}/admin/admin-env-apply.sh" "$@"
    ;;
  env-regen-cert)
    if [[ ! -f "${TARGET_ENV}" ]]; then
      echo "ERROR: app.env not found at ${TARGET_ENV}" >&2
      exit 1
    fi
    domain=$(grep '^APP_DOMAIN=' "${TARGET_ENV}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "${domain}" ]]; then
      echo "ERROR: APP_DOMAIN is empty in app.env" >&2
      exit 1
    fi
    tls_dir="${CONFIG_DIR}/tls"
    mkdir -p "${tls_dir}"
    exec "${SCRIPTS_DIR}/tls/gen-self-signed-tls.sh" "${domain}" "${tls_dir}" --force
    ;;
  disk-status)
    exec "${SCRIPTS_DIR}/admin/admin-disk-status.sh" "${DEPLOYMENT_DIR}" "$@"
    ;;
  disk-cleanup)
    exec "${SCRIPTS_DIR}/admin/admin-disk-cleanup.sh" "$@"
    ;;
  disk-storage-apply)
    exec "${SCRIPTS_DIR}/admin/admin-storage-apply.sh" "$@"
    ;;
  *)
    echo "ERROR: Unknown command: ${CMD}" >&2
    echo "Available commands: backup-create, backup-estimate, backup-verify, get-defaults, admin-set-password, env-load, env-apply, env-regen-cert, disk-status, disk-cleanup, disk-storage-apply" >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
#
# Version: 0.27.4
# Purpose: Persist a GitHub access key from stdin, login to GHCR, re-render only
#   the worker quadlet, and restart only worker. Invoked from Cockpit via
#   update-dispatch (set-github-token). Token is never printed or placed
#   in argv. Persist success is independent of GHCR login / worker restart.
# File: set-github-token.sh
#
# Changes in v0.27.4:
# - Normalize a legacy APP_INSTALL_REPO (owner vk74, repository evi) in config/app.env to the kit default (vk74/ready-room) before rendering worker.container.
#
# Changes in v0.27.2:
# - Ensure APP_INSTALL_REPO has a non-empty default before rendering worker.container.
#
# Changes in v0.26.3:
# - Sources scripts/lib/github-auth.sh and scripts/lib/render-templates.sh.
#
# Changes in v0.26.2:
# - Read and write APP_* configuration keys.
# - Sources config/app.env and config/app.secrets.env.
# 
# Changes in v0.25.4:
# - Worker re-render sources config/app.env and config/app.secrets.env, falling back to the legacy evi.* files.
#
# Changes in v0.23.5:
# - Initial script: read one stdin line, persist via github-auth.sh helpers,
#   optional GHCR login, worker-only quadlet re-render and restart.
#   Empty token is an error and writes nothing. GHCR / worker failures are
#   warnings; stdout is JSON only (Cockpit spawn uses err:out) and never
#   includes the token.
#
# Usage: set-github-token.sh <APP_HOME>
#
# Exit codes:
#   0 - token persisted (ghcr/worker failures are warnings)
#   1 - usage error or empty token
#

set -euo pipefail

export APP_HOME="${1:?usage: set-github-token.sh <APP_HOME>}"

# shellcheck disable=SC1091
source "${APP_HOME}/scripts/lib/github-auth.sh"

token=""
IFS= read -r token || true
token="${token%$'\r'}"

if [[ -z "${token}" ]]; then
  printf '%s\n' '{"status":"error","error":"empty"}'
  exit 1
fi

export APP_GITHUB_TOKEN="${token}"
token=""

persist_github_token

ghcr_ok=1
if ! podman_login_ghcr >/dev/null 2>&1; then
  ghcr_ok=0
fi

worker_ok=1
set +e
(
  set -euo pipefail
  default_install_repo="${APP_INSTALL_REPO}"
  set +u
  # shellcheck disable=SC1090
  if [[ -f "${APP_HOME}/config/app.env" ]]; then
    source "${APP_HOME}/config/app.env"
  fi
  if [[ -f "${APP_HOME}/config/app.secrets.env" ]]; then
    source "${APP_HOME}/config/app.secrets.env"
  fi
  set -u
  load_github_token
  _legacy_install_repo="vk74"
  _legacy_install_repo="${_legacy_install_repo}/evi"
  if [[ -z "${APP_INSTALL_REPO:-}" || "${APP_INSTALL_REPO}" == "${_legacy_install_repo}" ]]; then
    export APP_INSTALL_REPO="${default_install_repo}"
    if [[ -f "${APP_HOME}/config/app.env" ]] && grep -q "^APP_INSTALL_REPO=" "${APP_HOME}/config/app.env"; then
      sed -i "s|^APP_INSTALL_REPO=.*|APP_INSTALL_REPO=${default_install_repo}|" "${APP_HOME}/config/app.env"
    fi
  fi
  export APP_INSTALL_REPO="${APP_INSTALL_REPO:-${default_install_repo}}"

  CONFIG_DIR="${APP_HOME}/config"
  TPL_DIR="${APP_HOME}/quadlet-templates"
  PROXY_DIR="${APP_HOME}/reverse-proxy"
  DEPLOY_KIT_DIR="${APP_HOME}"
  TLS_DIR="${CONFIG_DIR}/tls"
  APP_STATE_DIR="${APP_STATE_DIR:-${CONFIG_DIR}/state}"
  APP_QUADLET_DIR="${APP_QUADLET_DIR:-${HOME}/.config/containers/systemd}"

  # shellcheck disable=SC1090
  source "${APP_HOME}/scripts/lib/render-templates.sh"

  APP_PODMANARGS_LIMITS_WORKER="$(deploy_compute_limits_block "${APP_LIMIT_CPU_WORKER-}" "${APP_LIMIT_MEM_WORKER-}")"
  deploy_render_template_file "${TPL_DIR}/worker.container" "${APP_QUADLET_DIR:-}/worker.container"
  systemctl --user daemon-reload >/dev/null 2>&1
  systemctl --user restart worker >/dev/null 2>&1
) >/dev/null 2>&1
worker_rc=$?
set -euo pipefail
if [[ "${worker_rc}" -ne 0 ]]; then
  worker_ok=0
fi

json='{"status":"ok","configured":true'
if [[ "${ghcr_ok}" -eq 0 ]]; then
  json+=',"ghcrLogin":"failed"'
fi
if [[ "${worker_ok}" -eq 0 ]]; then
  json+=',"workerRestart":"failed"'
fi
json+='}'
printf '%s\n' "${json}"

#!/usr/bin/env bash
#
# Version: 0.26.3
# Purpose: Create application app data and containers backup including container images, database, file storage volume, Valkey state store volume, and configuration.
# Deployment file: backup-create.sh
# Logic:
# - Creates backup directory with timestamp
# - Exports container images using podman save
# - Exports fs_data volume using podman volume export (when volume exists)
# - Exports state_data volume (Valkey state store) using podman volume export (when volume exists)
# - Dumps PostgreSQL database using pg_dump
# - Copies environment files, TLS certificates, JWT secrets, pgAdmin data, UFW status snapshot
# - Creates manifest.json with backup metadata (including architecture/platform)
# - Archives evi repository
# - Compresses and optionally encrypts the data archive
# - Generates README-RESTORE-STEP-BY-STEP.md with server info
# - EVI version for README and manifest: from deployment package.json, then repo package.json, fallback to FE image tag
#
# Changes in v0.26.3:
# - DEPLOYMENT_DIR is the kit root, two levels above this script (scripts/backup/).
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Backup reads config/app.env and config/app.secrets.env.
# 
# Changes in v0.25.4:
# - Reads and archives config/app.env and config/app.secrets.env, falling back to the legacy evi.* files.
#
# Changes in v0.25.2:
# - Export state_data volume (Valkey) alongside fs_data; manifest components.state_volume.
# - Release version is read from DEPLOYMENT_DIR/package.json first, then REPO_ROOT/package.json.
# - README mentions the Valkey state volume, states that an existing installation is wiped and replaced, uses config/evi.env, and shows journalctl plus podman logs.
# - archive_install_repo excludes temporary evi-kit-*.tar.gz and evi-staging-* files.
#
# Changes in v1.6.1:
# - Updated pgAdmin image fallback to docker.io/dpage/pgadmin4:9.15 for export
#   detection, manifest metadata, and
#   README included-components line.
#
# Changes in v1.6.0:
 to fs: APP_FS_IMAGE -> APP_FS_IMAGE; volume  -> fs_data;
#   backup path data/assets -> data/fs; manifest key "fs" -> "fs"; README text updated.
#
# Changes in v1.5.1:
# - Updated all container name references to short forms without evi- prefix.
#
# Changes in v1.4.0:
# - README intro reworded to be clearer; added Restore Scenarios section describing new server vs existing install.
# - Restore steps reduced from 5 to 4: prerequisites are now auto-installed during restore (step 3 merged into restore step).
# - Menu option name referenced in restore steps updated to "restore evi from full backup".
# - "What Is NOT Included" updated: host OS packages are auto-installed, no longer require manual action.
#
# Changes in v1.3.0:
# - Added evi-fs image to export_images and manifest components.images.
# - Added export_assets_volume(): podman volume export evi_fs_data to evi-data/fs/evi_fs_data.tar (skip with warn if volume missing).
# - manifest.json: components.assets_volume reflects presence of assets archive; README lists #
# Changes in v1.2.0:
# - Added evi-state and evi-worker container images to export and manifest.
# - Replaced EVI_PGADMIN_ENABLED with runtime checks: pgadmin image exported if podman image exists; pgadmin data copied if EVI_STATE_DIR/pgadmin exists.
# - Removed EVI_PGADMIN_ENABLED from load_env; added EVI_STATE_IMAGE and EVI_WORKER_IMAGE defaults.
#
# Changes in v1.1.1:
# - README restore steps: added Step 1 (copy backup to home, start terminal); renumbered steps 2–5; removed Prerequisites required bullet from Preparation notes; added Note in Step 3 (install prerequisites) about podman and other prerequisites.
#
# Changes in v1.1.0:
# - EVI version in README and manifest: use product release version from root package.json; fallback to EVI_FE_IMAGE tag when package.json is missing (e.g. deploy-only kit).
#
# Changes in v1.0.9:
# - Switched to CONFIG_DIR layout: env files read from config/, TLS from config/tls/, state from config/state/.
# - Archive repo exclusions updated: exclude entire config/ dir instead of env/evi.env, env/tls.
# - TLS check in manifest uses CONFIG_DIR/tls instead of ENV_DIR/tls.
#
# Changes in v1.0.8:
# - Save UFW status snapshot (ufw/ufw-status.txt) for documentation
# - Restore applies firewall rules from evi.env (install.sh); README: firewall no longer in "NOT Included"
# - manifest.json: added components.ufw flag
#
# Changes in v1.0.7:
# - README: Backup Information and Source Server Information as simple key-value lists (no tables)
# - README: wording fix — "the data restore does NOT require internet connection"
#
# Changes in v1.0.6:
# - Added architecture and platform fields to manifest.json (uname -m -> amd64/arm64)
# - Added Architecture row to README Source Server Information table
# - Updated README restore steps to use install.sh instead of evictl
# - Updated README notes: internet required for prerequisites, not for data restore
#
# Changes in v1.0.5:
# - Disable ANSI color codes when stdout is not a terminal (fixes garbled output in Cockpit console)
#
# Changes in v1.0.4:
# - Print script version at start of backup output
# - Fix copy_pgadmin_data: use podman unshare to read pgadmin4.db owned by remapped UID 5050
#
# Changes in v1.0.3:
# - Container running check: use podman container inspect instead of podman ps --filter (fixes "evi-db not running" on some podman versions)
#
# Changes in v1.0.2:
# - Archive and README use evi (evi-v*.tar.gz, cd evi)
#
# Changes in v1.0.1:
# - Added server IP addresses to README
# - Added OS version to README
# - Added certificate type detection (IP, intranet, public domain)
# - Added preparation notes section with restore guidance
#
# Exit codes:
#   0 - Success
#   1 - Database dump error
#   2 - Archive creation error
#   3 - Encryption error
#   4 - Insufficient space error

set -euo pipefail

# Colors (disabled when stdout is not a terminal, e.g. Cockpit output console)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  NC=''
fi

# Script version (printed at start of backup output)
BACKUP_SCRIPT_VERSION="0.25.2"

# Spinner characters
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

log() { printf "%s\n" "$*"; }
warn() { printf "${YELLOW}WARN:${NC} %s\n" "$*" >&2; }
err() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; }
ok() { printf "  ${GREEN}[✓]${NC} %s\n" "$*"; }
fail() { printf "  ${RED}[✗]${NC} %s\n" "$*"; }

# Spinner function for long operations
spinner_pid=""
start_spinner() {
  local msg="$1"
  (
    local i=0
    while true; do
      printf "\r  [%s] %s" "${SPINNER_CHARS:i++%${#SPINNER_CHARS}:1}" "${msg}"
      sleep 0.1
    done
  ) &
  spinner_pid=$!
}

stop_spinner() {
  if [[ -n "${spinner_pid}" ]]; then
    kill "${spinner_pid}" 2>/dev/null || true
    wait "${spinner_pid}" 2>/dev/null || true
    printf "\r"
    spinner_pid=""
  fi
}

cleanup() {
  stop_spinner
  # Clean up temporary files if backup failed
  if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${DEPLOYMENT_DIR}/.." && pwd)"

# Runtime config paths (config/ is preserved across updates)
CONFIG_DIR="${DEPLOYMENT_DIR}/config"
TLS_DIR="${CONFIG_DIR}/tls"
APP_STATE_DIR="${APP_STATE_DIR:-${CONFIG_DIR}/state}"
APP_ENV_FILE="${CONFIG_DIR}/app.env"
APP_SECRETS_FILE="${CONFIG_DIR}/app.secrets.env"

# Backup settings (can be overridden by environment)
BACKUP_DIR="${BACKUP_DIR:-}"
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-gzip-standard}"
BACKUP_ENCRYPT="${BACKUP_ENCRYPT:-true}"
BACKUP_PASSWORD="${BACKUP_PASSWORD:-}"
BACKUP_PASSWORD_FILE="${BACKUP_PASSWORD_FILE:-}"

# Load environment
load_env() {
  if [[ -f "${APP_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${APP_ENV_FILE}"
  else
    err "Missing config file: ${APP_ENV_FILE}"
    exit 1
  fi
  if [[ -f "${APP_SECRETS_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${APP_SECRETS_FILE}"
  else
    err "Missing secrets file: ${APP_SECRETS_FILE}"
    exit 1
  fi
  
  APP_STATE_IMAGE="${APP_STATE_IMAGE:-docker.io/valkey/valkey:8-alpine}"
  APP_WORKER_IMAGE="${APP_WORKER_IMAGE:-}"
  APP_FS_IMAGE="${APP_FS_IMAGE:-docker.io/chrislusf/seaweedfs:4.17}"
  APP_POSTGRES_DB="${APP_POSTGRES_DB:-maindb}"
}

# Get EVI version from image tag (fallback when package.json is not available)
get_app_version() {
  # Extract version from image tag (e.g., ghcr.io/vk74/evi-fe:0.9.11 -> 0.9.11)
  local version
  version=$(echo "${APP_FE_IMAGE:-unknown}" | sed 's/.*://')
  echo "${version}"
}

# Get product release version from deployment package.json, then repo package.json; fallback to FE image tag
get_release_version() {
  local version=""
  if [[ -f "${DEPLOYMENT_DIR}/package.json" ]]; then
    version=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "${DEPLOYMENT_DIR}/package.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  fi
  if [[ -z "${version}" ]] && [[ -f "${REPO_ROOT}/package.json" ]]; then
    version=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "${REPO_ROOT}/package.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  fi
  if [[ -z "${version}" ]]; then
    version=$(get_app_version)
  fi
  echo "${version}"
}

# Export container images
export_images() {
  local images_dir="$1"
  mkdir -p "${images_dir}"
  
  local images=("${APP_FE_IMAGE:-}" "${APP_BE_IMAGE:-}" "${APP_DB_IMAGE:-}" "${APP_PROXY_IMAGE:-}" "${APP_STATE_IMAGE:-}" "${APP_WORKER_IMAGE:-}" "${APP_FS_IMAGE:-}")
  local names=("fe" "be" "db" "caddy" "state" "worker" "fs")
  
  # include pgadmin image if present locally (enables offline restore regardless of APP_PGADMIN_ENABLED)
  local pgadmin_img="${APP_PGADMIN_IMAGE:-docker.io/dpage/pgadmin4:9.15}"
  if podman image exists "${pgadmin_img}" 2>/dev/null; then
    images+=("${pgadmin_img}")
    names+=("pgadmin")
  fi
  
  local total_size=0
  for i in "${!images[@]}"; do
    local image="${images[$i]}"
    local name="${names[$i]}"
    local output="${images_dir}/${name}.tar"
    
    if ! podman image exists "${image}" 2>/dev/null; then
      warn "Image ${image} not found locally, pulling..."
      podman pull "${image}" || { err "Failed to pull ${image}"; return 1; }
    fi
    
    podman save -o "${output}" "${image}" || { err "Failed to export ${image}"; return 1; }
    
    local size
    size=$(stat -c%s "${output}" 2>/dev/null || stat -f%z "${output}" 2>/dev/null || echo "0")
    total_size=$((total_size + size))
  done
  
  echo "${total_size}"
}

# Export fs_data Podman volume (SeaweedFS) to a tar under fs/
export_fs_volume() {
  local fs_dir="$1"
  mkdir -p "${fs_dir}"
  local output="${fs_dir}/fs_data.tar"

  if ! podman volume inspect fs_data >/dev/null 2>&1; then
    warn "Volume fs_data not found, skipping fs volume export"
    echo "0"
    return 0
  fi

  podman volume export -o "${output}" fs_data || { err "Failed to export fs_data volume"; return 1; }

  local size
  size=$(stat -c%s "${output}" 2>/dev/null || stat -f%z "${output}" 2>/dev/null || echo "0")
  echo "${size}"
}

# Export state_data Podman volume (Valkey AOF persistence) to a tar under state/
export_state_volume() {
  local state_dir="$1"
  mkdir -p "${state_dir}"
  local output="${state_dir}/state_data.tar"

  if ! podman volume inspect state_data >/dev/null 2>&1; then
    warn "Volume state_data not found, skipping state volume export"
    echo "0"
    return 0
  fi

  podman volume export -o "${output}" state_data || { err "Failed to export state_data volume"; return 1; }

  local size
  size=$(stat -c%s "${output}" 2>/dev/null || stat -f%z "${output}" 2>/dev/null || echo "0")
  echo "${size}"
}

# Dump PostgreSQL database
dump_database() {
  local db_dir="$1"
  mkdir -p "${db_dir}"
  
  local dump_file="${db_dir}/maindb.dump"
  
  # Check if db is running
  if ! podman container inspect db --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    err "db container is not running"
    return 1
  fi
  
  # Create dump using pg_dump custom format
  podman exec db pg_dump -U postgres -d "${APP_POSTGRES_DB:-}" \
    -Fc --clean --if-exists --no-owner \
    -f "/tmp/maindb.dump" || { err "pg_dump failed"; return 1; }
  
  # Copy dump out of container
  podman cp "db:/tmp/maindb.dump" "${dump_file}" || { err "Failed to copy dump"; return 1; }
  
  # Clean up in container
  podman exec db rm -f "/tmp/maindb.dump" 2>/dev/null || true
  
  local size
  size=$(stat -c%s "${dump_file}" 2>/dev/null || stat -f%z "${dump_file}" 2>/dev/null || echo "0")
  echo "${size}"
}

# Copy environment files
copy_env_files() {
  local env_dir="$1"
  mkdir -p "${env_dir}"
  
  [[ -f "${APP_ENV_FILE}" ]] && cp "${APP_ENV_FILE}" "${env_dir}/"
  [[ -f "${APP_SECRETS_FILE}" ]] && cp "${APP_SECRETS_FILE}" "${env_dir}/"
  
  # Set restrictive permissions on secrets
  chmod 600 "${env_dir}"/*.env 2>/dev/null || true
}

# Copy TLS certificates (from config/tls)
copy_tls_files() {
  local tls_dir="$1"
  
  if [[ -d "${TLS_DIR}" ]] && [[ -n "$(ls -A "${TLS_DIR}" 2>/dev/null)" ]]; then
    mkdir -p "${tls_dir}"
    cp -r "${TLS_DIR}"/* "${tls_dir}/" 2>/dev/null || true
    chmod 600 "${tls_dir}"/*.pem 2>/dev/null || true
  fi
}

# Copy JWT secrets
copy_jwt_secrets() {
  local secrets_dir="$1"
  local jwt_file="${APP_STATE_DIR:-}/secrets/jwt_private_key.pem"
  
  if [[ -f "${jwt_file}" ]]; then
    mkdir -p "${secrets_dir}"
    cp "${jwt_file}" "${secrets_dir}/"
    chmod 600 "${secrets_dir}"/*.pem 2>/dev/null || true
  fi
}

# Copy pgAdmin data (pgadmin4.db is owned by remapped UID 5050, so podman unshare is required)
copy_pgadmin_data() {
  local pgadmin_dir="$1"
  local source_dir="${APP_STATE_DIR:-}/pgadmin"
  
  if [[ -d "${source_dir}" ]]; then
    mkdir -p "${pgadmin_dir}"
    
    # pgadmin4.db belongs to container-mapped UID 5050; use podman unshare to read it
    if [[ -f "${source_dir}/data/pgadmin4.db" ]]; then
      podman unshare cp "${source_dir}/data/pgadmin4.db" "${pgadmin_dir}/" 2>/dev/null \
        || warn "Could not copy pgadmin4.db (permission denied); pgAdmin data skipped"
    fi
    [[ -f "${source_dir}/servers.json" ]] && cp "${source_dir}/servers.json" "${pgadmin_dir}/" 2>/dev/null || true
  fi
}

# Save UFW status snapshot for documentation (informational; restore uses env variables)
copy_ufw_status() {
  local ufw_dir="$1"
  if command -v ufw >/dev/null 2>&1; then
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
      mkdir -p "${ufw_dir}"
      sudo ufw status verbose > "${ufw_dir}/ufw-status.txt" 2>/dev/null || true
    fi
  fi
}

# Create manifest.json
create_manifest() {
  local manifest_file="$1"
  local app_version="$2"
  local compression="$3"
  local encrypted="$4"
  
  local hostname
  hostname=$(hostname 2>/dev/null || echo "unknown")
  
  local created_at
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Detect architecture and translate to container platform format
  local arch
  arch=$(uname -m 2>/dev/null || echo "unknown")
  local platform="linux/unknown"
  case "${arch}" in
    x86_64)   platform="linux/amd64" ;;
    aarch64)  platform="linux/arm64" ;;
    arm64)    platform="linux/arm64" ;;
    armv7l)   platform="linux/arm/v7" ;;
    *)        platform="linux/${arch}" ;;
  esac
  
  local pg_version="18"
  if podman container inspect db --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    pg_version=$(podman exec db psql -U postgres -t -c "SHOW server_version;" 2>/dev/null | tr -d ' ' | cut -d. -f1 || echo "18")
  fi
  
  # Determine pgadmin image value for JSON (based on local image presence)
  local pgadmin_img="${APP_PGADMIN_IMAGE:-docker.io/dpage/pgadmin4:9.15}"
  local pgadmin_image_json="null"
  if podman image exists "${pgadmin_img}" 2>/dev/null; then
    pgadmin_image_json="\"${pgadmin_img}\""
  fi
  
  local pgadmin_backed_up="false"
  podman image exists "${pgadmin_img}" 2>/dev/null && pgadmin_backed_up="true"
  
  # Determine boolean values
  local tls_enabled="false"
  [[ -d "${TLS_DIR}" ]] && tls_enabled="true"
  
  local jwt_enabled="false"
  [[ -f "${APP_STATE_DIR:-}/secrets/jwt_private_key.pem" ]] && jwt_enabled="true"
  
  local ufw_enabled="false"
  if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw_enabled="true"
  fi

  local manifest_dir
  manifest_dir=$(dirname "${manifest_file}")
  local fs_volume_json="false"
  [[ -f "${manifest_dir}/fs/fs_data.tar" ]] && fs_volume_json="true"
  local state_volume_json="false"
  [[ -f "${manifest_dir}/state/state_data.tar" ]] && state_volume_json="true"
  
  cat > "${manifest_file}" <<EOF
{
  "backup_format_version": "1.0",
  "app_version": "${app_version}",
  "created_at": "${created_at}",
  "created_by": "app backup",
  "hostname": "${hostname}",
  "architecture": "${arch}",
  "platform": "${platform}",
  "compression": "${compression}",
  "encrypted": ${encrypted},
  "components": {
    "images": {
      "fe": "${APP_FE_IMAGE:-}",
      "be": "${APP_BE_IMAGE:-}",
      "db": "${APP_DB_IMAGE:-}",
      "caddy": "${APP_PROXY_IMAGE:-}",
      "state": "${APP_STATE_IMAGE:-}",
      "worker": "${APP_WORKER_IMAGE:-}",
      "fs": "${APP_FS_IMAGE:-}",
      "pgadmin": ${pgadmin_image_json}
    },
    "database": {
      "name": "${APP_POSTGRES_DB:-}",
      "postgres_version": "${pg_version}",
      "dump_format": "custom"
    },
    "env": true,
    "tls": ${tls_enabled},
    "jwt": ${jwt_enabled},
    "pgadmin": ${pgadmin_backed_up},
    "fs_volume": ${fs_volume_json},
    "state_volume": ${state_volume_json},
    "ufw": ${ufw_enabled}
  }
}
EOF
}

# Get server IP addresses (non-loopback)
get_server_ips() {
  # Try different methods to get IP addresses
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | tr '\n' ', ' | sed 's/,$//'
  elif command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//'
  else
    echo "unknown"
  fi
}

# Get OS version
get_os_version() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-${NAME} ${VERSION_ID}}"
  elif [[ -f /etc/redhat-release ]]; then
    cat /etc/redhat-release
  elif command -v sw_vers >/dev/null 2>&1; then
    echo "macOS $(sw_vers -productVersion)"
  else
    uname -sr 2>/dev/null || echo "unknown"
  fi
}

# Determine certificate type based on domain configuration
get_cert_type() {
  local domain="${APP_DOMAIN:-unknown}"
  local tls_mode="${APP_TLS_MODE:-unknown}"
  
  # Check if domain is IP address
  if [[ "${domain}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Self-signed for IP address (${domain})"
  # Check if domain looks like intranet (no dots or .local/.internal/.lan)
  elif [[ "${domain}" =~ \.(local|internal|lan|intranet|corp|home)$ ]] || [[ ! "${domain}" =~ \. ]]; then
    echo "Self-signed for intranet domain (${domain})"
  # Let's Encrypt mode
  elif [[ "${tls_mode}" == "letsencrypt" ]]; then
    echo "Let's Encrypt for public domain (${domain})"
  # Manual mode with public-looking domain
  elif [[ "${tls_mode}" == "manual" ]]; then
    echo "Manual certificate for domain (${domain})"
  else
    echo "Unknown (${domain}, mode: ${tls_mode})"
  fi
}

# Create README-RESTORE-STEP-BY-STEP.md
create_readme() {
  local readme_file="$1"
  local app_version="$2"
  local encrypted="$3"
  local backup_name="$4"
  
  local hostname
  hostname=$(hostname 2>/dev/null || echo "unknown")
  
  local created_at
  created_at=$(date "+%Y-%m-%d %H:%M:%S")
  
  # Gather additional server info
  local server_ips
  server_ips=$(get_server_ips)
  
  local os_version
  os_version=$(get_os_version)
  
  local cert_type
  cert_type=$(get_cert_type)
  
  local domain="${APP_DOMAIN:-unknown}"
  local tls_mode="${APP_TLS_MODE:-unknown}"
  
  # Detect architecture
  local arch
  arch=$(uname -m 2>/dev/null || echo "unknown")
  local platform="unknown"
  case "${arch}" in
    x86_64)   platform="linux/amd64" ;;
    aarch64)  platform="linux/arm64" ;;
    arm64)    platform="linux/arm64" ;;
    armv7l)   platform="linux/arm/v7" ;;
    *)        platform="linux/${arch}" ;;
  esac
  
  cat > "${readme_file}" <<EOF
# Application backup restore instructions

Full backup of the application: database, container images, environment
configuration, TLS certificates, JWT secrets, SeaweedFS files (when present),
Valkey state volume (when present), and installation scripts. Use this archive to restore the application on the same or a new server.

## Restore Scenarios

This backup supports two restore scenarios:

1. **New server** — restore the application on a fresh server with no prior installation.
   The installer will automatically set up all system prerequisites
   (podman, cockpit, etc.) before restoring application data.

2. **Existing installation** — restore over a running application instance
   (e.g. to roll back after a failed update or recover from data corruption).
   The existing installation and all its containers, volumes, and configuration
   will be completely wiped and replaced with the backup contents.
   The backup is located in \`~/app/config/backup/\` by default and will be
   detected automatically when you run the restore option in install.sh.

## Backup Information

Created: ${created_at}
App Version: ${app_version}
Encrypted: ${encrypted}

## Source Server Information

Hostname: ${hostname}
IP Address(es): ${server_ips}
OS: ${os_version}
Architecture: ${arch} (${platform})
Domain: ${domain}
TLS Mode: ${tls_mode}
Certificate Type: ${cert_type}

## Preparation Notes

When restoring to a new server, consider the following:

- **OS compatibility**: This backup was created on ${os_version} (${arch}).
  For best results, restore to the same OS distribution and architecture.
  Container images in this backup are built for ${platform}.

$(if [[ "${domain}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
cat <<IPNOTE
- **IP-based certificate**: The original server used IP address \`${domain}\` for TLS.
  If the new server has a different IP, you will need to regenerate certificates
  using the guided configuration in install.sh.
IPNOTE
elif [[ "${tls_mode}" == "letsencrypt" ]]; then
cat <<LENOTE
- **Let's Encrypt certificate**: Ensure the new server:
  - Has the same domain name (${domain}) pointing to it via DNS
  - Has ports 80 and 443 accessible from the internet
  - Caddy will automatically obtain new certificates on first start
LENOTE
elif [[ "${domain}" =~ \.(local|internal|lan|intranet|corp|home)$ ]]; then
cat <<INTRANOTE
- **Intranet domain**: The original server used intranet domain \`${domain}\`.
  If restoring to a different network, update \`config/app.env\` (set \`APP_DOMAIN\`
  to new server's hostname/IP) and regenerate certificates using guided configuration.
INTRANOTE
else
cat <<MANUALNOTE
- **Manual certificate**: The original server used manually configured certificates.
  Ensure the new server is accessible via \`${domain}\` or update the domain in \`config/app.env\`.
MANUALNOTE
fi)

## Contents

- \`app-v${app_version}.tar.gz\` — Installation scripts and templates
- \`app-data-v${app_version}.tar.gz$([ "${encrypted}" = "true" ] && echo ".gpg")\` — Database, container images, secrets, certificates

## Restore Steps

### Step 1: Copy backup archives

Copy backup archives to your home directory. Start terminal and proceed to Step 2.

### Step 2: Extract installation scripts

\`\`\`bash
tar -xzf app-v${app_version}.tar.gz
cd app
\`\`\`

### Step 3: Restore application from full backup

\`\`\`bash
./install.sh
# select: restore application from full backup
\`\`\`

System prerequisites (podman, cockpit, etc.) are installed automatically if not
already present — an internet connection is required for this step.

On a **new server** you will see the fresh install menu (options: configure, deploy,
restore, uninstall). On an **existing installation** you will see the manage menu
(options: check prerequisites, reconfigure, apply, restore, uninstall).
In both cases select "restore application from full backup".

On an existing installation, the backup in \`~/app/config/backup/\` will be
detected automatically. On a new server, copy the backup archives to your home
directory (\`~/\`) before running install.sh — they will be detected automatically.

$([ "${encrypted}" = "true" ] && echo "You will be prompted for the encryption password.")

### Step 4: Verify

After restore completes, the script will start all application services automatically.
Check the restore summary for container status. You can also verify via cockpit
at https://<server-ip>:9090.

## What Is Included

- Container images: fe, be, db, caddy, state, worker, fs$(podman image exists "${APP_PGADMIN_IMAGE:-docker.io/dpage/pgadmin4:9.15}" 2>/dev/null && echo ", pgadmin")
- PostgreSQL database dump (${APP_POSTGRES_DB:-})
$(podman volume inspect fs_data >/dev/null 2>&1 && echo "- SeaweedFS file storage volume (fs_data)")
$(podman volume inspect state_data >/dev/null 2>&1 && echo "- Valkey state store volume (state_data)")
- Environment configuration (app.env, app.secrets.env)
- TLS certificates (if configured)
- JWT signing keys
$([ -d "${APP_STATE_DIR:-}/pgadmin" ] && echo "- pgAdmin configuration and data")

## What Is NOT Included

- Host OS packages (podman, cockpit, curl, openssl) — installed automatically during restore (requires internet)
- Operating system configuration

## Support

If you encounter issues, check container logs via cockpit or:

\`\`\`bash
journalctl --user -u db.service -n 100
journalctl --user -u be.service -n 100
podman logs db
podman logs be
\`\`\`
EOF
}

# Archive evi repository
archive_install_repo() {
  local output_file="$1"
  local app_version="$2"
  
  # Create archive excluding .git, runtime config dir, backup plan, and temporary kit files
  tar -czf "${output_file}" \
    -C "$(dirname "${DEPLOYMENT_DIR}")" \
    --exclude='.git' \
    --exclude='config' \
    --exclude='backup-function-plan.md' \
    --exclude='app-kit-*.tar.gz' \
    --exclude='app-staging-*' \
    --transform "s|^$(basename "${DEPLOYMENT_DIR}")|app|" \
    "$(basename "${DEPLOYMENT_DIR}")" || return 1
}

# Compress data directory
compress_data() {
  local input_dir="$1"
  local output_file="$2"
  local compression="$3"
  
  local tar_opts="-cf"
  local compress_cmd=""
  
  case "${compression}" in
    zstd-fast)
      compress_cmd="zstd -1 -T0"
      output_file="${output_file%.gz}.zst"
      ;;
    zstd-max)
      compress_cmd="zstd -19 -T0"
      output_file="${output_file%.gz}.zst"
      ;;
    gzip-standard|*)
      compress_cmd="gzip -6"
      ;;
  esac
  
  tar ${tar_opts} - -C "$(dirname "${input_dir}")" "$(basename "${input_dir}")" | \
    ${compress_cmd} > "${output_file}" || return 1
  
  echo "${output_file}"
}

# Encrypt file with GPG
encrypt_file() {
  local input_file="$1"
  local password="$2"
  local output_file="${input_file}.gpg"
  
  gpg --symmetric --cipher-algo AES256 --batch --yes \
    --passphrase "${password}" \
    --output "${output_file}" \
    "${input_file}" || return 1
  
  # Remove unencrypted file
  rm -f "${input_file}"
  
  echo "${output_file}"
}

# Format bytes to human readable
format_bytes() {
  local bytes="$1"
  if [[ ${bytes} -ge 1073741824 ]]; then
    echo "$(echo "scale=1; ${bytes}/1073741824" | bc) GB"
  elif [[ ${bytes} -ge 1048576 ]]; then
    echo "$(echo "scale=1; ${bytes}/1048576" | bc) MB"
  elif [[ ${bytes} -ge 1024 ]]; then
    echo "$(echo "scale=1; ${bytes}/1024" | bc) KB"
  else
    echo "${bytes} B"
  fi
}

# Main function
main() {
  local start_time
  start_time=$(date +%s)
  
  # Check required commands
  command -v podman >/dev/null 2>&1 || { err "podman not found"; exit 1; }
  command -v tar >/dev/null 2>&1 || { err "tar not found"; exit 1; }
  
  if [[ "${BACKUP_ENCRYPT}" == "true" ]]; then
    command -v gpg >/dev/null 2>&1 || { err "gpg not found (required for encryption)"; exit 1; }
  fi
  
  # Check compression tool
  case "${BACKUP_COMPRESSION}" in
    zstd-fast|zstd-max)
      command -v zstd >/dev/null 2>&1 || { err "zstd not found"; exit 1; }
      ;;
  esac
  
  load_env

  local app_version
  app_version=$(get_release_version)
  
  # Validate backup directory
  if [[ -z "${BACKUP_DIR}" ]]; then
    err "BACKUP_DIR not set"
    exit 2
  fi
  
  # Get password if encryption enabled
  if [[ "${BACKUP_ENCRYPT}" == "true" ]]; then
    if [[ -n "${BACKUP_PASSWORD_FILE}" ]] && [[ -f "${BACKUP_PASSWORD_FILE}" ]]; then
      BACKUP_PASSWORD=$(cat "${BACKUP_PASSWORD_FILE}")
    fi
    if [[ -z "${BACKUP_PASSWORD}" ]]; then
      err "Encryption enabled but no password provided"
      exit 3
    fi
  fi
  
  # Create backup directory
  mkdir -p "${BACKUP_DIR}" || { err "Cannot create backup directory"; exit 2; }
  
  # Create temporary working directory
  TEMP_DIR=$(mktemp -d)
  local data_dir="${TEMP_DIR}/app-data"
  mkdir -p "${data_dir}"
  
  log "backup-create.sh version ${BACKUP_SCRIPT_VERSION}"
  log ""
  log "creating backup..."
  
  # Export container images
  start_spinner "exporting container images..."
  local images_size
  images_size=$(export_images "${data_dir}/images") || { stop_spinner; fail "exporting container images"; exit 1; }
  stop_spinner
  ok "exporting container images     ($(format_bytes "${images_size}"))"
  
  # Export fs_data volume (SeaweedFS)
  start_spinner "exporting fs volume..."
  local fs_vol_size
  fs_vol_size=$(export_fs_volume "${data_dir}/fs") || { stop_spinner; fail "exporting fs volume"; exit 1; }
  stop_spinner
  ok "exporting fs volume             ($(format_bytes "${fs_vol_size}"))"
  
  # Export state_data volume (Valkey)
  start_spinner "exporting state volume..."
  local state_vol_size
  state_vol_size=$(export_state_volume "${data_dir}/state") || { stop_spinner; fail "exporting state volume"; exit 1; }
  stop_spinner
  ok "exporting state volume          ($(format_bytes "${state_vol_size}"))"
  
  # Dump database
  start_spinner "dumping database..."
  local db_size
  db_size=$(dump_database "${data_dir}/database") || { stop_spinner; fail "dumping database"; exit 1; }
  stop_spinner
  ok "dumping database               ($(format_bytes "${db_size}"))"
  
  # Copy environment files
  start_spinner "copying environment files..."
  copy_env_files "${data_dir}/env"
  stop_spinner
  ok "copying environment files"
  
  # Copy TLS certificates
  start_spinner "copying tls certificates..."
  copy_tls_files "${data_dir}/tls"
  stop_spinner
  ok "copying tls certificates"
  
  # Copy JWT secrets
  start_spinner "copying jwt secrets..."
  copy_jwt_secrets "${data_dir}/secrets"
  stop_spinner
  ok "copying jwt secrets"
  
  # Copy pgAdmin data (if pgadmin state dir exists)
  if [[ -d "${APP_STATE_DIR:-}/pgadmin" ]]; then
    start_spinner "copying pgadmin data..."
    copy_pgadmin_data "${data_dir}/pgadmin"
    stop_spinner
    ok "copying pgadmin data"
  fi
  
  # Copy UFW status snapshot (informational)
  start_spinner "copying ufw status..."
  copy_ufw_status "${data_dir}/ufw"
  stop_spinner
  ok "copying ufw status"
  
  # Create manifest
  start_spinner "creating manifest..."
  create_manifest "${data_dir}/manifest.json" "${app_version}" "${BACKUP_COMPRESSION}" "${BACKUP_ENCRYPT}"
  stop_spinner
  ok "creating manifest"
  
  # Archive evi repository
  start_spinner "archiving repository..."
  local repo_archive="${BACKUP_DIR}/app-v${app_version}.tar.gz"
  archive_install_repo "${repo_archive}" "${app_version}" || { stop_spinner; fail "archiving repository"; exit 2; }
  stop_spinner
  ok "archiving repository"
  
  # Compress data archive
  start_spinner "compressing data archive..."
  local data_archive="${TEMP_DIR}/app-data-v${app_version}.tar.gz"
  data_archive=$(compress_data "${data_dir}" "${data_archive}" "${BACKUP_COMPRESSION}") || { stop_spinner; fail "compressing archive"; exit 2; }
  stop_spinner
  
  local compressed_size
  compressed_size=$(stat -c%s "${data_archive}" 2>/dev/null || stat -f%z "${data_archive}" 2>/dev/null || echo "0")
  local uncompressed_size
  uncompressed_size=$(du -sb "${data_dir}" 2>/dev/null | cut -f1 || echo "0")
  ok "compressing archive            ($(format_bytes "${uncompressed_size}") → $(format_bytes "${compressed_size}"))"
  
  # Encrypt if enabled
  if [[ "${BACKUP_ENCRYPT}" == "true" ]]; then
    start_spinner "encrypting archive..."
    data_archive=$(encrypt_file "${data_archive}" "${BACKUP_PASSWORD}") || { stop_spinner; fail "encrypting archive"; exit 3; }
    stop_spinner
    ok "encrypting archive"
  fi
  
  # Move data archive to backup directory
  local final_data_archive="${BACKUP_DIR}/$(basename "${data_archive}")"
  mv "${data_archive}" "${final_data_archive}"
  
  # Generate README
  start_spinner "generating README..."
  create_readme "${BACKUP_DIR}/README-RESTORE-STEP-BY-STEP.md" "${app_version}" "${BACKUP_ENCRYPT}" "$(basename "${BACKUP_DIR}")"
  stop_spinner
  ok "generating README"
  
  # Clean up
  start_spinner "cleaning up..."
  rm -rf "${TEMP_DIR}"
  TEMP_DIR=""
  stop_spinner
  ok "cleaning up"
  
  # Calculate final sizes and time
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local minutes=$((duration / 60))
  local seconds=$((duration % 60))
  
  local readme_size repo_size data_size total_size
  readme_size=$(stat -c%s "${BACKUP_DIR}/README-RESTORE-STEP-BY-STEP.md" 2>/dev/null || stat -f%z "${BACKUP_DIR}/README-RESTORE-STEP-BY-STEP.md" 2>/dev/null || echo "0")
  repo_size=$(stat -c%s "${repo_archive}" 2>/dev/null || stat -f%z "${repo_archive}" 2>/dev/null || echo "0")
  data_size=$(stat -c%s "${final_data_archive}" 2>/dev/null || stat -f%z "${final_data_archive}" 2>/dev/null || echo "0")
  total_size=$((readme_size + repo_size + data_size))
  
  log ""
  log "${GREEN}backup completed!${NC}"
  log "  location: ${CYAN}${BACKUP_DIR}/${NC}"
  log "  files:"
  log "    - README-RESTORE-STEP-BY-STEP.md  ($(format_bytes "${readme_size}"))"
  log "    - app-v${app_version}.tar.gz       ($(format_bytes "${repo_size}"))"
  log "    - $(basename "${final_data_archive}")      ($(format_bytes "${data_size}"))"
  log "  total size: $(format_bytes "${total_size}")"
  log "  time: ${minutes} min ${seconds} sec"
  log ""
  log "to restore, follow instructions in:"
  log "  ${CYAN}${BACKUP_DIR}/README-RESTORE-STEP-BY-STEP.md${NC}"
}

main "$@"
#!/usr/bin/env bash
#
# Version: 0.26.2
# Purpose: Generate self-signed TLS certificates with proper CA chain for internal deployments.
# Deployment file: gen-self-signed-tls.sh
# Logic:
# - Generates Root CA (app-ca.crt, app-ca.key)
# - Generates server certificate signed by CA with proper SAN (cert.pem, key.pem)
# - Creates client-installable CA certificate (app-tls.crt)
# - Supports both IP addresses and DNS names
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
#
# Changes in v2.1.0:
# - Updated all container name references to short forms without evi- prefix.
#
# Changes in v2.0.0:
# - Complete rewrite with Root CA + signed server certificate
# - Added SAN (Subject Alternative Name) support for IP addresses and DNS names
# - Added client-installable CA certificate (evi-tls.crt)
# - Added certificate validation and expiry check
# - Added quiet mode for automation
#
# Changes in v1.0.0:
# - Initial self-signed TLS generator
#

set -euo pipefail

# --- Configuration ---
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
DEFAULT_VALIDITY_DAYS=3650  # 10 years for CA
SERVER_VALIDITY_DAYS=825    # ~2.25 years for server cert (Apple's limit)
KEY_SIZE=4096
CA_KEY_SIZE=4096

# Colors (disabled if not terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

# --- Helpers ---
log() { printf "${CYAN}[tls-gen]${NC} %s\n" "$*"; }
info() { printf "${GREEN}INFO:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}WARN:${NC} %s\n" "$*"; }
err() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} <domain_or_ip> [output_dir] [options]

Arguments:
  domain_or_ip    The domain name or IP address for the certificate
  output_dir      Directory to store generated files (default: current directory)

Options:
  --force         Overwrite existing certificates
  --quiet         Suppress informational output
  --check         Only check if certificates exist and are valid
  --validity N    Server certificate validity in days (default: ${SERVER_VALIDITY_DAYS})

Output files:
  app-ca.crt      Root CA certificate (for internal use)
  app-ca.key      Root CA private key (keep secure!)
  cert.pem        Server certificate (for Caddy)
  key.pem         Server private key (for Caddy)
  app-tls.crt     Client-installable CA certificate (copy of app-ca.crt)

Examples:
  ${SCRIPT_NAME} 192.168.3.15 ./tls
  ${SCRIPT_NAME} app.local ./tls --force
  ${SCRIPT_NAME} myserver.internal ./tls --validity 365
EOF
  exit 0
}

# --- Functions ---

# Detect if input is an IP address
is_ip_address() {
  local input="$1"
  # IPv4 pattern
  if [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  # IPv6 pattern (simplified)
  if [[ "$input" =~ ^[0-9a-fA-F:]+$ && "$input" == *:* ]]; then
    return 0
  fi
  return 1
}

# Generate SAN (Subject Alternative Name) configuration
generate_san_config() {
  local domain="$1"
  local san_file="$2"
  
  cat > "${san_file}" <<EOF
[req]
default_bits = ${KEY_SIZE}
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = XX
ST = Internal
L = Internal
O = app
OU = app-deployment
CN = ${domain}

[req_ext]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
EOF

  # Add appropriate SAN entries
  if is_ip_address "${domain}"; then
    echo "IP.1 = ${domain}" >> "${san_file}"
    # Also add localhost for local testing
    echo "IP.2 = 127.0.0.1" >> "${san_file}"
  else
    echo "DNS.1 = ${domain}" >> "${san_file}"
    # Add wildcard if not already a wildcard
    if [[ ! "${domain}" == \** ]]; then
      echo "DNS.2 = *.${domain}" >> "${san_file}"
    fi
    echo "DNS.3 = localhost" >> "${san_file}"
    echo "IP.1 = 127.0.0.1" >> "${san_file}"
  fi
}

# Generate CA certificate
generate_ca() {
  local out_dir="$1"
  local ca_key="${out_dir}/app-ca.key"
  local ca_crt="${out_dir}/app-ca.crt"
  
  log "Generating Root CA..."
  
  # Generate CA private key
  openssl genrsa -out "${ca_key}" ${CA_KEY_SIZE} 2>/dev/null
  
  # Generate CA certificate
  openssl req -x509 -new -nodes \
    -key "${ca_key}" \
    -sha256 \
    -days ${DEFAULT_VALIDITY_DAYS} \
    -out "${ca_crt}" \
    -subj "/C=XX/ST=Internal/L=Internal/O=app/OU=app-ca/CN=App Root CA"
  
  chmod 600 "${ca_key}"
  chmod 644 "${ca_crt}"
  
  info "Root CA generated: ${ca_crt}"
}

# Generate server certificate signed by CA
generate_server_cert() {
  local domain="$1"
  local out_dir="$2"
  local validity="${3:-${SERVER_VALIDITY_DAYS}}"
  
  local ca_key="${out_dir}/app-ca.key"
  local ca_crt="${out_dir}/app-ca.crt"
  local server_key="${out_dir}/key.pem"
  local server_csr="${out_dir}/server.csr"
  local server_crt="${out_dir}/cert.pem"
  local san_config="${out_dir}/.san.cnf"
  local ext_file="${out_dir}/.ext.cnf"
  
  log "Generating server certificate for: ${domain}"
  
  # Generate SAN configuration
  generate_san_config "${domain}" "${san_config}"
  
  # Create extensions file for signing
  cat > "${ext_file}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

  # Add SAN from config
  echo "subjectAltName = @alt_names" >> "${ext_file}"
  echo "" >> "${ext_file}"
  echo "[alt_names]" >> "${ext_file}"
  
  # Extract alt_names section from san config
  sed -n '/\[alt_names\]/,$ p' "${san_config}" | tail -n +2 >> "${ext_file}"
  
  # Generate server private key
  openssl genrsa -out "${server_key}" ${KEY_SIZE} 2>/dev/null
  
  # Generate CSR
  openssl req -new \
    -key "${server_key}" \
    -out "${server_csr}" \
    -config "${san_config}"
  
  # Sign with CA
  openssl x509 -req \
    -in "${server_csr}" \
    -CA "${ca_crt}" \
    -CAkey "${ca_key}" \
    -CAcreateserial \
    -out "${server_crt}" \
    -days "${validity}" \
    -sha256 \
    -extfile "${ext_file}"
  
  # Set permissions
  chmod 600 "${server_key}"
  chmod 644 "${server_crt}"
  
  # Cleanup temp files
  rm -f "${server_csr}" "${san_config}" "${ext_file}" "${out_dir}/app-ca.srl"
  
  info "Server certificate generated: ${server_crt}"
}

# Create client-installable CA certificate
create_client_cert() {
  local out_dir="$1"
  local ca_crt="${out_dir}/app-ca.crt"
  local client_crt="${out_dir}/app-tls.crt"
  
  cp "${ca_crt}" "${client_crt}"
  chmod 644 "${client_crt}"
  
  info "Client CA certificate: ${client_crt}"
}

# Check certificate validity
check_certificate() {
  local out_dir="$1"
  local cert_file="${out_dir}/cert.pem"
  local ca_file="${out_dir}/app-ca.crt"
  
  if [[ ! -f "${cert_file}" ]]; then
    echo "NOT_FOUND"
    return 1
  fi
  
  if [[ ! -f "${ca_file}" ]]; then
    echo "CA_MISSING"
    return 1
  fi
  
  # Check expiry
  local expiry
  expiry=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)
  local expiry_epoch
  expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${expiry}" +%s 2>/dev/null)
  local now_epoch
  now_epoch=$(date +%s)
  local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
  
  if [[ ${days_left} -lt 0 ]]; then
    echo "EXPIRED"
    return 1
  elif [[ ${days_left} -lt 30 ]]; then
    echo "EXPIRING_SOON:${days_left}"
    return 0
  else
    echo "VALID:${days_left}"
    return 0
  fi
}

# Show certificate info
show_certificate_info() {
  local out_dir="$1"
  local cert_file="${out_dir}/cert.pem"
  
  if [[ ! -f "${cert_file}" ]]; then
    warn "Certificate not found: ${cert_file}"
    return 1
  fi
  
  log "Certificate details:"
  echo "  Subject: $(openssl x509 -subject -noout -in "${cert_file}" | sed 's/subject=//')"
  echo "  Issuer:  $(openssl x509 -issuer -noout -in "${cert_file}" | sed 's/issuer=//')"
  echo "  Valid:   $(openssl x509 -startdate -noout -in "${cert_file}" | sed 's/notBefore=//')"
  echo "  Expires: $(openssl x509 -enddate -noout -in "${cert_file}" | sed 's/notAfter=//')"
  echo "  SANs:"
  openssl x509 -text -noout -in "${cert_file}" 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | tr ',' '\n' | sed 's/^/    /'
}

# --- Main ---

main() {
  local domain=""
  local out_dir="."
  local force=false
  local quiet=false
  local check_only=false
  local validity=${SERVER_VALIDITY_DAYS}
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --force)
        force=true
        shift
        ;;
      --quiet)
        quiet=true
        shift
        ;;
      --check)
        check_only=true
        shift
        ;;
      --validity)
        validity="$2"
        shift 2
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -z "${domain}" ]]; then
          domain="$1"
        elif [[ "${out_dir}" == "." ]]; then
          out_dir="$1"
        else
          die "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done
  
  # Validate
  if [[ -z "${domain}" ]]; then
    usage
fi

if ! command -v openssl >/dev/null 2>&1; then
    die "openssl is required but not found"
  fi
  
  # Create output directory
  mkdir -p "${out_dir}"
  
  # Check mode
  if [[ "${check_only}" == true ]]; then
    local status
    status=$(check_certificate "${out_dir}")
    echo "${status}"
    if [[ "${status}" == VALID* ]] || [[ "${status}" == EXPIRING_SOON* ]]; then
      [[ "${quiet}" != true ]] && show_certificate_info "${out_dir}"
      exit 0
    else
  exit 1
    fi
  fi
  
  # Check existing certificates
  if [[ -f "${out_dir}/cert.pem" && "${force}" != true ]]; then
    local status
    status=$(check_certificate "${out_dir}")
    if [[ "${status}" == VALID* ]]; then
      [[ "${quiet}" != true ]] && info "Certificates already exist and are valid."
      [[ "${quiet}" != true ]] && show_certificate_info "${out_dir}"
      [[ "${quiet}" != true ]] && info "Use --force to regenerate."
      exit 0
    fi
  fi
  
  [[ "${quiet}" != true ]] && log "Generating TLS certificates for: ${domain}"
  [[ "${quiet}" != true ]] && log "Output directory: ${out_dir}"
  
  # Generate CA (if not exists or force)
  if [[ ! -f "${out_dir}/app-ca.crt" || "${force}" == true ]]; then
    generate_ca "${out_dir}"
  else
    [[ "${quiet}" != true ]] && info "Using existing CA: ${out_dir}/app-ca.crt"
  fi
  
  # Generate server certificate
  generate_server_cert "${domain}" "${out_dir}" "${validity}"
  
  # Create client certificate
  create_client_cert "${out_dir}"
  
  [[ "${quiet}" != true ]] && echo ""
  [[ "${quiet}" != true ]] && log "=== TLS Generation Complete ==="
  [[ "${quiet}" != true ]] && echo ""
  [[ "${quiet}" != true ]] && echo "Files created:"
  [[ "${quiet}" != true ]] && echo "  ${out_dir}/cert.pem      - Server certificate (for Caddy)"
  [[ "${quiet}" != true ]] && echo "  ${out_dir}/key.pem       - Server private key (for Caddy)"
  [[ "${quiet}" != true ]] && echo "  ${out_dir}/app-ca.crt    - Root CA certificate"
  [[ "${quiet}" != true ]] && echo "  ${out_dir}/app-ca.key    - Root CA private key (keep secure!)"
  [[ "${quiet}" != true ]] && echo "  ${out_dir}/app-tls.crt   - CA for client installation"
  [[ "${quiet}" != true ]] && echo ""
  [[ "${quiet}" != true ]] && info "To eliminate browser warnings, install app-tls.crt on client devices."
  [[ "${quiet}" != true ]] && show_certificate_info "${out_dir}"
}

main "$@"

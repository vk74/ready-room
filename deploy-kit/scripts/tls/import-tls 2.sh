#!/usr/bin/env bash
#
# Version: 1.0.0
# Purpose: Validate and copy user-provided TLS certificate/key into a target directory.
# Deployment file: import-tls.sh
# Logic: Copies cert/key to predictable filenames for mounting into the proxy container.
#
# Changes in v1.0.0:
# - Initial TLS import helper
#

set -euo pipefail

CERT_PATH="${1:-}"
KEY_PATH="${2:-}"
OUT_DIR="${3:-.}"

if [[ -z "${CERT_PATH}" || -z "${KEY_PATH}" ]]; then
  echo "Usage: $0 <cert_path> <key_path> [out_dir]" >&2
  exit 1
fi

if [[ ! -f "${CERT_PATH}" ]]; then
  echo "ERROR: cert file not found: ${CERT_PATH}" >&2
  exit 1
fi

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "ERROR: key file not found: ${KEY_PATH}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

cp -f "${CERT_PATH}" "${OUT_DIR}/cert.pem"
cp -f "${KEY_PATH}" "${OUT_DIR}/key.pem"

chmod 644 "${OUT_DIR}/cert.pem"
chmod 600 "${OUT_DIR}/key.pem"

echo "OK: imported TLS files to ${OUT_DIR}/cert.pem and ${OUT_DIR}/key.pem"



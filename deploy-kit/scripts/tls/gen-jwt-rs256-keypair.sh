#!/usr/bin/env bash
#
# Version: 1.0.0
# Purpose: Generate RSA private key PEM for JWT signing (RS256).
# Deployment file: gen-jwt-rs256-keypair.sh
# Logic: Creates a private key PEM suitable for jsonwebtoken RS256 signing.
#
# Changes in v1.0.0:
# - Initial RS256 key generator
#

set -euo pipefail

OUT_DIR="${1:-.}"
OUT_FILE="${2:-jwt_rs256_private_key.pem}"

mkdir -p "${OUT_DIR}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not found." >&2
  exit 1
fi

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${OUT_DIR}/${OUT_FILE}"
chmod 600 "${OUT_DIR}/${OUT_FILE}"

echo "OK: generated ${OUT_DIR}/${OUT_FILE}"



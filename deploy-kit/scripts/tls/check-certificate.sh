#!/usr/bin/env bash
#
# Version: 1.0.0
# Purpose: Check certificate details for debugging SSL issues
# Deployment file: check-certificate.sh
# Logic: Connects to HTTPS endpoint and displays certificate information
#

set -euo pipefail

DOMAIN="${1:-192.168.3.15}"
PORT="${2:-443}"

echo "=========================================="
echo "Checking certificate for ${DOMAIN}:${PORT}"
echo "=========================================="
echo ""

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not found. Install it first." >&2
  exit 1
fi

echo "1. Testing connection..."
if timeout 5 bash -c "echo > /dev/tcp/${DOMAIN}/${PORT}" 2>/dev/null; then
  echo "   ✓ Port ${PORT} is open"
else
  echo "   ✗ Port ${PORT} is closed or unreachable"
  exit 1
fi
echo ""

echo "2. Fetching certificate details..."
echo | openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" 2>/dev/null | openssl x509 -noout -text -in /dev/stdin 2>/dev/null || {
  echo "   ✗ Failed to retrieve certificate"
  exit 1
}
echo ""

echo "3. Certificate Subject and SAN:"
echo | openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null || true
echo ""

echo "4. Certificate validity:"
echo | openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || true
echo ""

echo "5. Certificate issuer:"
echo | openssl s_client -connect "${DOMAIN}:${PORT}" -servername "${DOMAIN}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true
echo ""

echo "6. Testing with curl (verbose):"
curl -k -v "https://${DOMAIN}:${PORT}" 2>&1 | head -50 || true
echo ""

echo "=========================================="
echo "Check complete"
echo "=========================================="
echo ""
echo "NOTE: If certificate shows errors, it may need to include the IP address"
echo "      in Subject Alternative Names (SAN) field."

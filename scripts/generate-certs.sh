#!/bin/bash
#
# Self-Signed Certificate Generator for Rediacc Elite Standalone Mode
#
# This script generates self-signed SSL certificates for local HTTPS testing.
# Certificates include Subject Alternative Names (SANs) for multiple access methods.
#
# WARNING: Self-signed certificates will show browser security warnings.
# These certificates are for development/testing only, NOT for production use.
#

set -e

# Configuration
CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/certs"
CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/key.pem"
CA_FILE="${CERT_DIR}/ca.pem"
VALIDITY_DAYS=1825

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for openssl
if ! command -v openssl &> /dev/null; then
    log_error "OpenSSL is not installed. Please install it first."
    exit 1
fi

# Create certificate directory
mkdir -p "${CERT_DIR}"

# Get SYSTEM_DOMAIN from environment (default to localhost)
SYSTEM_DOMAIN="${SYSTEM_DOMAIN:-localhost}"

# Get additional domains from SSL_EXTRA_DOMAINS (comma-separated)
EXTRA_DOMAINS="${SSL_EXTRA_DOMAINS:-}"

# Detect host IP address (first non-loopback IPv4)
HOST_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
if [ -z "$HOST_IP" ]; then
    # Fallback for systems without ip command or WSL
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' | grep -v '127.0.0.1' || echo "")
fi

# Build Subject Alternative Names (SANs)
SAN_LIST="DNS:localhost,DNS:*.${SYSTEM_DOMAIN},DNS:${SYSTEM_DOMAIN},IP:127.0.0.1"

# Add host IP if detected
if [ -n "$HOST_IP" ]; then
    SAN_LIST="${SAN_LIST},IP:${HOST_IP}"
fi

# Add extra domains
if [ -n "$EXTRA_DOMAINS" ]; then
    IFS=',' read -ra DOMAINS <<< "$EXTRA_DOMAINS"
    for domain in "${DOMAINS[@]}"; do
        domain=$(echo "$domain" | tr -d ' ') # Remove whitespace
        if [ -n "$domain" ]; then
            SAN_LIST="${SAN_LIST},DNS:${domain}"
        fi
    done
fi

log_info "Generating self-signed certificate for Rediacc Elite..."
log_info "Certificate directory: ${CERT_DIR}"
log_info "Primary domain: ${SYSTEM_DOMAIN}"
log_info "Subject Alternative Names: ${SAN_LIST}"

# Generate private key
log_info "Generating private key..."
openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null

# Create OpenSSL configuration for SAN
OPENSSL_CNF=$(mktemp)
cat > "${OPENSSL_CNF}" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C = US
ST = Development
L = Local
O = Rediacc
OU = Elite Standalone
CN = ${SYSTEM_DOMAIN}

[v3_req]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
EOF

# Add SANs to config
IFS=',' read -ra SAN_ARRAY <<< "$SAN_LIST"
for i in "${!SAN_ARRAY[@]}"; do
    SAN_ENTRY="${SAN_ARRAY[$i]}"
    # Determine if it's DNS or IP
    if [[ $SAN_ENTRY == DNS:* ]]; then
        echo "DNS.$((i+1)) = ${SAN_ENTRY#DNS:}" >> "${OPENSSL_CNF}"
    elif [[ $SAN_ENTRY == IP:* ]]; then
        echo "IP.$((i+1)) = ${SAN_ENTRY#IP:}" >> "${OPENSSL_CNF}"
    fi
done

# Generate certificate signing request and self-signed certificate
log_info "Generating self-signed certificate (valid for ${VALIDITY_DAYS} days)..."
openssl req -new -x509 -key "${KEY_FILE}" -out "${CERT_FILE}" -days ${VALIDITY_DAYS} \
    -config "${OPENSSL_CNF}" -extensions v3_req 2>/dev/null

# Create CA file (copy of cert for compatibility)
cp "${CERT_FILE}" "${CA_FILE}"

# Set proper permissions
chmod 644 "${CERT_FILE}" "${CA_FILE}"
chmod 600 "${KEY_FILE}"

# Clean up temp file
rm -f "${OPENSSL_CNF}"

# Display certificate information
log_info "Certificate generated successfully!"
echo ""
log_info "Certificate details:"
openssl x509 -in "${CERT_FILE}" -noout -text | grep -A 2 "Subject:"
openssl x509 -in "${CERT_FILE}" -noout -text | grep -A 10 "Subject Alternative Name"
echo ""
log_info "Certificate files:"
echo "  - Certificate: ${CERT_FILE}"
echo "  - Private Key: ${KEY_FILE}"
echo "  - CA Bundle:   ${CA_FILE}"
echo ""

# Browser warning information
log_warn "⚠️  IMPORTANT: Browser Security Warnings"
echo ""
echo "Self-signed certificates will show security warnings in browsers."
echo "This is expected and safe for local development."
echo ""
echo "To accept the certificate:"
echo "  • Chrome/Edge: Click 'Advanced' → 'Proceed to ${SYSTEM_DOMAIN} (unsafe)'"
echo "  • Firefox: Click 'Advanced' → 'Accept the Risk and Continue'"
echo "  • Safari: Click 'Show Details' → 'visit this website'"
echo ""
echo "For curl/wget testing, use the -k/--insecure flag:"
echo "  curl -k https://${SYSTEM_DOMAIN}"
echo ""

log_info "✓ Certificate generation complete!"

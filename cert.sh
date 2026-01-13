#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${CERT_DIR:-/data/certs}"
mkdir -p "${CERT_DIR}"

# Server FQDN used for CN + DNS SAN
FQDN="${PUKAIPU_FQDN:-${FQDN:-localhost}}"

# Client CN derived from PUKAIPU_USER
PU_USER="${PUKAIPU_USER:-}"
if [[ -n "${PU_USER}" ]]; then
  CLIENT_CN="pukaipu-${PU_USER}"
else
  CLIENT_CN="pukaipu-client"
fi

# Root CA
CA_KEY="${CERT_DIR}/ca.key"
CA_CERT="${CERT_DIR}/ca.crt"

# Server
SRV_KEY="${CERT_DIR}/server.key"
SRV_CSR="${CERT_DIR}/server.csr"
SRV_CERT="${CERT_DIR}/server.crt"
SRV_EXT="${CERT_DIR}/server.ext"

# Client
CLI_KEY="${CERT_DIR}/client.key"
CLI_CSR="${CERT_DIR}/client.csr"
CLI_CERT="${CERT_DIR}/client.crt"
CLI_EXT="${CERT_DIR}/client.ext"

# Convenience bundle for browser import
CLI_P12="${CERT_DIR}/client.p12"

# -------------------------
# 1) Root CA (once)
# -------------------------
if [ ! -s "${CA_KEY}" ] || [ ! -s "${CA_CERT}" ]; then
  echo "[certs] generating Root CA..."
  openssl genrsa -out "${CA_KEY}" 4096
  chmod 600 "${CA_KEY}"

  openssl req -x509 -new -nodes \
    -key "${CA_KEY}" \
    -sha256 -days 3650 \
    -subj "/CN=pukaipu-root-ca" \
    -out "${CA_CERT}"
fi

# -------------------------
# 2) Server cert (once) signed by CA
#    SAN: DNS = FQDN only
# -------------------------
if [ ! -s "${SRV_KEY}" ] || [ ! -s "${SRV_CERT}" ]; then
  echo "[certs] issuing server cert for '${FQDN}'..."
  openssl genrsa -out "${SRV_KEY}" 2048
  chmod 600 "${SRV_KEY}"

  openssl req -new \
    -key "${SRV_KEY}" \
    -subj "/CN=${FQDN}" \
    -out "${SRV_CSR}"

  cat > "${SRV_EXT}" <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${FQDN}
EOF

  openssl x509 -req \
    -in "${SRV_CSR}" \
    -CA "${CA_CERT}" -CAkey "${CA_KEY}" \
    -CAcreateserial \
    -out "${SRV_CERT}" \
    -days 825 -sha256 \
    -extfile "${SRV_EXT}"

  rm -f "${SRV_CSR}"
fi

# -------------------------
# 3) Client cert + p12 (only if p12 missing)
#
# Rationale:
# - If we delete client.key after p12 creation, we can’t recreate p12 later.
# - Therefore: generate client cert/key only when we need to create the p12.
# -------------------------
if [ ! -s "${CLI_P12}" ]; then
  echo "[certs] creating client cert + client.p12 (CN='${CLIENT_CN}')..."

  # Create client key/cert
  openssl genrsa -out "${CLI_KEY}" 2048
  chmod 600 "${CLI_KEY}"

  openssl req -new \
    -key "${CLI_KEY}" \
    -subj "/CN=${CLIENT_CN}" \
    -out "${CLI_CSR}"

  cat > "${CLI_EXT}" <<'EOF'
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

  openssl x509 -req \
    -in "${CLI_CSR}" \
    -CA "${CA_CERT}" -CAkey "${CA_KEY}" \
    -CAcreateserial \
    -out "${CLI_CERT}" \
    -days 825 -sha256 \
    -extfile "${CLI_EXT}"

  rm -f "${CLI_CSR}"

  # Create p12 with an ephemeral passphrase (NOT stored)
  P12PASS="$(openssl rand -base64 24)"
  echo "[certs] client.p12 passphrase (save this now): ${P12PASS}"

  openssl pkcs12 -export \
    -inkey "${CLI_KEY}" \
    -in "${CLI_CERT}" \
    -certfile "${CA_CERT}" \
    -out "${CLI_P12}" \
    -passout "pass:${P12PASS}"

  # Delete private key after p12 exists
  if command -v shred >/dev/null 2>&1; then
    shred -u "${CLI_KEY}" 2>/dev/null || rm -f "${CLI_KEY}"
  else
    rm -f "${CLI_KEY}"
  fi
else
  # p12 exists; do not recreate; do not print passphrase
  :
fi

echo "[certs] done. Files in ${CERT_DIR}:"
echo "  CA:     ca.crt"
echo "  Server: server.crt/server.key  (CN/SAN: ${FQDN})"
echo "  Client: client.crt  (CN: ${CLIENT_CN})"
echo "  Bundle: client.p12  (created once; passphrase printed only at first creation)"

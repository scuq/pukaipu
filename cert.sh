#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${CERT_DIR:-/data/certs}"
mkdir -p "${CERT_DIR}"

# Root CA
CA_KEY="${CERT_DIR}/ca.key"
CA_CERT="${CERT_DIR}/ca.crt"
CA_SRL="${CERT_DIR}/ca.srl"

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

# Optional: convenience bundles for import
CLI_P12="${CERT_DIR}/client.p12"
CLI_P12_PASS_FILE="${CERT_DIR}/client.p12.pass"

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
    -subj "/CN=xpra-root-ca" \
    -out "${CA_CERT}"
fi

# -------------------------
# 2) Server cert (once) signed by CA
#    Use SANs for localhost + 127.0.0.1
# -------------------------
if [ ! -s "${SRV_KEY}" ] || [ ! -s "${SRV_CERT}" ]; then
  echo "[certs] issuing server cert..."
  openssl genrsa -out "${SRV_KEY}" 2048
  chmod 600 "${SRV_KEY}"

  openssl req -new \
    -key "${SRV_KEY}" \
    -subj "/CN=localhost" \
    -out "${SRV_CSR}"

  cat > "${SRV_EXT}" <<'EOF'
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
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
# 3) Client cert (once) signed by CA
# -------------------------
if [ ! -s "${CLI_KEY}" ] || [ ! -s "${CLI_CERT}" ]; then
  echo "[certs] issuing client cert..."
  openssl genrsa -out "${CLI_KEY}" 2048
  chmod 600 "${CLI_KEY}"

  openssl req -new \
    -key "${CLI_KEY}" \
    -subj "/CN=xpra-client" \
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
fi

# -------------------------
# 4) Optional: export client cert as PKCS#12 for easy browser import
# -------------------------
if [ ! -s "${CLI_P12}" ]; then
  echo "[certs] exporting client.p12 (for browser import)..."
  # Generate a random passphrase once and persist it
  if [ ! -s "${CLI_P12_PASS_FILE}" ]; then
    umask 077
    openssl rand -base64 24 > "${CLI_P12_PASS_FILE}"
  fi
  P12PASS="$(cat "${CLI_P12_PASS_FILE}")"

  openssl pkcs12 -export \
    -inkey "${CLI_KEY}" \
    -in "${CLI_CERT}" \
    -certfile "${CA_CERT}" \
    -out "${CLI_P12}" \
    -passout "pass:${P12PASS}"
fi

echo "[certs] done. Files in ${CERT_DIR}:"
echo "  CA:     ca.crt"
echo "  Server: server.crt/server.key"
echo "  Client: client.crt/client.key (and client.p12)"

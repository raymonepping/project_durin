#!/usr/bin/env bash
# scripts/vault-gen-certs.sh — Generate a self-signed CA and per-node TLS certs
# for the Durin Vault cluster. Output goes to vault-tls/.
#
# Idempotent: skips generation if vault-tls/ca-chain.pem already exists.
# Re-run with --force to regenerate everything.
set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
TLS_DIR="$PROJECT_ROOT/vault-tls"
CNF="$SCRIPT_DIR/vault-tls.cnf"

usage() {
  echo "Usage: $0 [--force | --reissue-server]"
  echo "  --force           Regenerate all certificates (NEW CA — every client must re-trust)"
  echo "  --reissue-server  Re-sign vault.crt with the EXISTING CA and key (e.g. after adding"
  echo "                    a SAN to scripts/vault-tls.cnf), then SIGHUP running Vault nodes"
}

reissue_server() {
  cd "$TLS_DIR"
  [ -f ca.key ] && [ -f ca.crt ] && [ -f vault.key ] || {
    echo "vault-gen-certs: ca.key, ca.crt and vault.key are required for --reissue-server" >&2; exit 1; }
  openssl req -new -key vault.key -subj "/CN=vault/O=Durin/C=NL" -out vault.csr
  openssl x509 -req -days 3650 -in vault.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -extfile "$CNF" -out vault.crt.new
  openssl verify -CAfile ca-chain.pem vault.crt.new
  mv vault.crt.new vault.crt
  rm -f vault.csr ca.srl
  chmod 644 vault.crt
  echo "vault-gen-certs: re-signed vault.crt — SANs:"
  openssl x509 -in vault.crt -noout -ext subjectAltName | tail -1
  # Vault reloads its listener certificate on SIGHUP (no restart, no unseal).
  for c in durin-vault_s durin-vault_1 durin-vault_2 durin-vault_3; do
    if command -v podman >/dev/null 2>&1 && podman container exists "$c" 2>/dev/null; then
      podman kill --signal HUP "$c" >/dev/null && echo "vault-gen-certs: SIGHUP → $c"
    fi
  done
}

FORCE=false
case "${1:-}" in
  --force) FORCE=true ;;
  --reissue-server) reissue_server; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 64 ;;
esac

command -v openssl >/dev/null 2>&1 || { echo "openssl not found on PATH" >&2; exit 127; }

if [ -f "$TLS_DIR/ca-chain.pem" ] && [ "$FORCE" = false ]; then
  echo "vault-gen-certs: vault-tls/ca-chain.pem already exists — skipping (use --force to regenerate)"
  exit 0
fi

mkdir -p "$TLS_DIR"
cd "$TLS_DIR"

echo "vault-gen-certs: generating CA key and certificate..."
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key \
  -subj "/CN=Durin Vault CA/O=Durin/C=NL" \
  -out ca.crt

# Intermediate CA (same cert used as the full chain for this single-level PKI)
cp ca.crt ca-chain.pem

echo "vault-gen-certs: generating shared server key and CSR..."
openssl genrsa -out vault.key 2048
openssl req -new -key vault.key \
  -subj "/CN=vault/O=Durin/C=NL" \
  -out vault.csr

echo "vault-gen-certs: signing server certificate..."
openssl x509 -req -days 3650 \
  -in vault.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -extfile "$CNF" \
  -out vault.crt

# Verify
openssl verify -CAfile ca-chain.pem vault.crt

# Cleanup CSR and serial
rm -f vault.csr ca.srl

chmod 600 ca.key vault.key
chmod 644 ca.crt ca-chain.pem vault.crt

echo "vault-gen-certs: certificates written to vault-tls/"
ls -la "$TLS_DIR"

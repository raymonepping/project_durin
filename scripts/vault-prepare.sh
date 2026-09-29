#!/usr/bin/env bash
set -euo pipefail
umask 077
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
for tool in openssl vault jq; do command -v "$tool" >/dev/null || {
  echo "Missing command: $tool" >&2
  exit 1
}; done
# License is provided via VAULT_LICENSE env var in .env — no .hclic file needed.
# Load it from .env if not already in the environment (vault-bootstrap.sh doesn't
# source .env directly; the compose stacks get it via --env-file .env).
if [ -z "${VAULT_LICENSE:-}" ] && [ -f "$root/.env" ]; then
  VAULT_LICENSE=$(grep -E '^VAULT_LICENSE=' "$root/.env" | head -1 | cut -d= -f2-)
  export VAULT_LICENSE
fi
test -n "${VAULT_LICENSE:-}" || {
  echo "VAULT_LICENSE is not set — add it to .env" >&2
  exit 1
}
mkdir -p .secrets/vault vault-tls
chmod 700 .secrets .secrets/vault vault-tls

# Never silently replace a CA or private key for an existing cluster.
if [ -f vault-tls/vault.crt ]; then
  openssl verify -CAfile vault-tls/ca-chain.pem vault-tls/vault.crt
  openssl x509 -checkend 86400 -noout -in vault-tls/vault.crt
  test -s vault-tls/vault.key
else
  if [ -n "$(ls -A vault-tls)" ] || [ -e .secrets/vault/ca.key ]; then
    echo 'Incomplete TLS directory. Review existing files before generating certificates.' >&2
    exit 1
  fi
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -subj '/CN=Durin Local Vault CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout .secrets/vault/ca.key -out vault-tls/ca-chain.pem 2>/dev/null
  openssl req -new -newkey rsa:3072 -nodes -sha256 \
    -subj '/CN=Durin Vault' -keyout vault-tls/vault.key \
    -out .secrets/vault/server.csr 2>/dev/null
  openssl x509 -req -sha256 -days 365 \
    -in .secrets/vault/server.csr -CA vault-tls/ca-chain.pem \
    -CAkey .secrets/vault/ca.key -CAcreateserial \
    -extfile scripts/vault-tls.cnf -out vault-tls/vault.crt 2>/dev/null
fi
chmod 600 vault-tls/vault.key
echo 'Durin licenses and TLS are ready. No reference data or credentials were imported.'

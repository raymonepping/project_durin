#!/bin/sh
# scripts/vault-hsm-bootstrap.sh — Prompt 14.1
#
# Turns the seal-only `vault-hsm` node into a Managed-Key custody demo:
#   transit engine + approle + audit
#   sys/managed-keys/pkcs11/docsign-hsm   (RSA-4096, private key generated in SoftHSM)
#   transit/keys/document-signing-key      type=managed_key -> docsign-hsm
#   policy + approle role  document-signing  (used by the workload)
#   policy + approle role  arcanium-hsm-read (read-only, used by the Arcanium API)
#
# vault-hsm must already be initialised. The root token is read from
# .secrets/vault/vault-hsm-init.json (written by `make hsm-init`).
#
# Idempotent: safe to re-run.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
INIT_FILE="$REPO_ROOT/.secrets/vault/vault-hsm-init.json"
SLOT_FILE="$REPO_ROOT/.secrets/hsm/slot-id"
WL_ENV="$REPO_ROOT/.env.workloads"

[ -f "$INIT_FILE" ] || {
  echo "Missing $INIT_FILE — run 'make hsm-init' first." >&2
  exit 1
}
[ -f "$SLOT_FILE" ] || {
  echo "Missing $SLOT_FILE — run 'make hsm-bootstrap' first." >&2
  exit 1
}

ROOT_TOKEN=$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])")
SLOT=$(tr -d '[:space:]' <"$SLOT_FILE")
PIN=$(grep -E '^SOFTHSM_USER_PIN=' "$REPO_ROOT/.env" | cut -d= -f2)

vx() { podman exec -e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_SKIP_VERIFY=1 \
  -e VAULT_TOKEN="$ROOT_TOKEN" arcanium-vault_hsm "$@"; }

echo "▸ enabling engines"
vx sh -c 'vault secrets enable transit 2>/dev/null || true'
vx sh -c 'vault auth enable approle 2>/dev/null || true'
vx sh -c 'vault audit enable file file_path=/vault/audit/vault-audit.log 2>/dev/null || true'

echo "▸ managed key: sys/managed-keys/pkcs11/docsign-hsm (RSA-4096, key in SoftHSM)"
vx vault write sys/managed-keys/pkcs11/docsign-hsm \
  library=softhsm-proxy slot="$SLOT" pin="$PIN" \
  key_label=docsign-hsm-rsa allow_generate_key=true key_bits=4096 mechanism=0x0001

echo "▸ transit key: document-signing-key (type=managed_key)"
vx vault secrets tune -allowed-managed-keys=docsign-hsm transit/
vx vault write transit/keys/document-signing-key type=managed_key managed_key_name=docsign-hsm

echo "▸ workload policy + approle: document-signing"
vx sh -c 'cat > /tmp/ds.hcl <<EOF
path "transit/sign/document-signing-key"        { capabilities = ["update"] }
path "transit/verify/document-signing-key"      { capabilities = ["update"] }
path "transit/keys/document-signing-key"        { capabilities = ["read"] }
path "transit/keys/document-signing-key/rotate" { capabilities = ["update"] }
EOF
vault policy write document-signing /tmp/ds.hcl'
vx vault write auth/approle/role/document-signing \
  token_policies=document-signing token_ttl=1h token_max_ttl=4h
DS_RID=$(vx vault read -field=role_id auth/approle/role/document-signing/role-id)
DS_SID=$(vx vault write -f -field=secret_id auth/approle/role/document-signing/secret-id)

echo "▸ Arcanium API read-only policy + approle: arcanium-hsm-read"
vx sh -c 'cat > /tmp/ar.hcl <<EOF
path "sys/managed-keys/pkcs11"   { capabilities = ["list"] }
path "sys/managed-keys/pkcs11/*" { capabilities = ["read"] }
path "transit/keys"             { capabilities = ["list"] }
path "transit/keys/*"           { capabilities = ["read"] }
path "sys/health"               { capabilities = ["read"] }
EOF
vault policy write arcanium-hsm-read /tmp/ar.hcl'
vx vault write auth/approle/role/arcanium-hsm-read \
  token_policies=arcanium-hsm-read token_ttl=1h token_max_ttl=24h token_period=1h
API_RID=$(vx vault read -field=role_id auth/approle/role/arcanium-hsm-read/role-id)
API_SID=$(vx vault write -f -field=secret_id auth/approle/role/arcanium-hsm-read/secret-id)

echo "▸ writing credentials"
# document-signing workload creds -> .env.workloads
tmp=$(mktemp)
grep -v -E '^DOCSIGN_VAULT_(ROLE|SECRET)_ID=' "$WL_ENV" >"$tmp" || true
{
  echo "DOCSIGN_VAULT_ROLE_ID=$DS_RID"
  echo "DOCSIGN_VAULT_SECRET_ID=$DS_SID"
} >>"$tmp"
mv "$tmp" "$WL_ENV"

echo ""
echo "  Add to .env (Arcanium API read-only vault-hsm client):"
echo "    VAULT_HSM_ADDR=https://vault-hsm:8200"
echo "    ARCANIUM_HSM_ROLE_ID=$API_RID"
echo "    ARCANIUM_HSM_SECRET_ID=$API_SID"
echo ""
echo "  ✓ vault-hsm managed-key bootstrap complete"

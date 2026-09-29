#!/usr/bin/env bash
# scripts/vault-secrets-bootstrap.sh —
# prompts/improvements/01_07_vault_kv_secrets_migration.md.
#
# Seeds terraform/vault-secrets' six KV values on a fresh cluster.
# Safe to re-run: for every value that already exists in Vault, this
# reads the CURRENT value back and passes it straight through to
# `terraform apply`, so Terraform sees no diff and no-ops. Only values
# that genuinely don't exist yet get a freshly generated one — re-running
# this is not a way to rotate secrets (see docs/operations.md for the
# real rotation flow: write a new value directly, then re-sync/restart
# consumers).
#
# Must run AFTER terraform/vault-platform's own apply (creates the
# factory namespace, the identity-secrets AppRole, and the policies
# these values are read under) and AFTER scripts/vault-admin-bootstrap.sh
# (this applies with the vault-admin token, not root, like every other
# routine Terraform apply in this project).
set -euo pipefail
umask 077
# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"
cd "$VAULT_PROJECT_ROOT"

ADMIN_TOKEN_FILE="$VAULT_STATE/vault-admin-token"
[ -s "$ADMIN_TOKEN_FILE" ] || {
  echo "No vault-admin token — run 'make vault-admin-bootstrap' first." >&2
  exit 1
}

vault_node_leader
vault_wait unsealed

export VAULT_TOKEN
VAULT_TOKEN=$(cat "$ADMIN_TOKEN_FILE")
export VAULT_NAMESPACE=factory

current_or_generate() {
  local path=$1 field=$2
  vault kv get -field="$field" "$path" 2>/dev/null || openssl rand -hex 24
}

agent_a_token=$(current_or_generate secret/agents/bearer-tokens agent_a)
agent_b_token=$(current_or_generate secret/agents/bearer-tokens agent_b)
agent_c_token=$(current_or_generate secret/agents/bearer-tokens agent_c)
agent_d_token=$(current_or_generate secret/agents/bearer-tokens agent_d)
jwt_signing_secret=$(current_or_generate secret/backend/jwt-signing-secret value)
cli_operator_token=$(current_or_generate secret/backend/cli-operator-token value)
oidc_client_secret=$(current_or_generate secret/identity/oidc-client-secret value)
ldap_admin_password=$(current_or_generate secret/identity/ldap-admin-password value)
keycloak_admin_password=$(current_or_generate secret/identity/keycloak-admin-password value)
# prompts/v3/03_01: unlike every value above, this one is never
# randomly generated here — it must be a real RSA private key matching
# the public key registered in the v3 oauth-resource-server profile
# (terraform/vault-platform/v3-root-credential-path.tf). Generated once
# via `openssl genrsa` into .secrets/vault/v3-jwt-signing-key.pem
# (gitignored); this reads the current Vault value if one already
# exists (idempotent pass-through, same as every value above), else
# falls back to that generated file rather than current_or_generate's
# own openssl-rand-hex fallback, which would produce a value that
# doesn't match the registered public key at all.
v3_jwt_signing_key=$(vault kv get -field=value secret/backend/v3-jwt-signing-key 2>/dev/null || cat "$VAULT_PROJECT_ROOT/.secrets/vault/v3-jwt-signing-key.pem")

# terraform/vault-secrets/main.tf's own provider block already declares
# namespace = "factory" — leaving VAULT_NAMESPACE=factory set here too
# doubly-scopes the vault-admin token (root-homed) and breaks its
# internal child-token-creation step ("root or sudo privileges required
# to directly generate a token in a child namespace", found live doing
# this exact thing). Unset both before handing off to Terraform.
unset VAULT_TOKEN VAULT_NAMESPACE
terraform -chdir=terraform/vault-secrets init -input=false
VAULT_TOKEN=$(cat "$ADMIN_TOKEN_FILE") \
  terraform -chdir=terraform/vault-secrets apply -auto-approve \
  -var="agent_a_token=$agent_a_token" \
  -var="agent_b_token=$agent_b_token" \
  -var="agent_c_token=$agent_c_token" \
  -var="agent_d_token=$agent_d_token" \
  -var="jwt_signing_secret=$jwt_signing_secret" \
  -var="cli_operator_token=$cli_operator_token" \
  -var="oidc_client_secret=$oidc_client_secret" \
  -var="ldap_admin_password=$ldap_admin_password" \
  -var="keycloak_admin_password=$keycloak_admin_password" \
  -var="v3_jwt_signing_key=$v3_jwt_signing_key"

echo
echo "Vault KV seeded. Next steps on a fresh cluster:"
echo "  make agents-secrets-sync   # pulls agent tokens + CLI token into .env"
echo "  make identity-up           # identity-secrets-init renders LDAP/Keycloak passwords"
echo "  make identity-bootstrap    # LDAP fixture + Keycloak realm, reads the same Vault values directly"

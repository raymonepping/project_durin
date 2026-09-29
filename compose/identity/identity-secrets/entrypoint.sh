#!/bin/sh
# compose/identity/identity-secrets/entrypoint.sh — prompts/security/17_02
#
# One-shot: AppRole login → read identity secrets from Vault KV → render them
# to the shared identity-secrets volume → revoke own token → exit.
# Pattern from Editors Factory (prompts/improvements/01_07): a persistent Vault
# Agent is unnecessary for values that are only needed once per stack start.
#
# openldap, keycloak and their bootstrap containers mount the volume read-only
# and never talk to Vault themselves. Vault is reached through vault-lb.
set -eu

export VAULT_ADDR="${VAULT_ADDR:-https://vault-lb:8200}"
export VAULT_CACERT="${VAULT_CACERT:-/vault/tls/ca-chain.pem}"
ROLE_ID="$(cat /approle/identity-role-id)"
SECRET_ID="$(cat /approle/identity-secret-id)"

echo "[identity-secrets-init] authenticating via AppRole durin-identity-secrets..."
attempt=0
until VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID" 2>/tmp/login.err); do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 15 ]; then
    echo "[identity-secrets-init] AppRole login failed after $((attempt * 2))s:" >&2
    cat /tmp/login.err >&2
    exit 1
  fi
  sleep 2
done
export VAULT_TOKEN

out=/run/secrets
mkdir -p "$out/users"
for key in ldap-admin-password keycloak-admin-password oidc-client-secret; do
  vault kv get -mount=secret -field=value "durin/identity/$key" > "$out/$key"
done
count=0
for u in raymon barend security-admin viewer; do
  vault kv get -mount=secret -field=value "durin/identity/users/$u" > "$out/users/$u"
  count=$((count + 1))
done
# Readable by the non-root keycloak user (uid 1000) and the osixia containers.
chmod 0755 "$out/users"
chmod 0644 "$out"/*-password "$out/oidc-client-secret" "$out"/users/*

vault token revoke -self >/dev/null 2>&1 || true
echo "[identity-secrets-init] rendered 3 platform secrets + $count user passwords; token revoked"

#!/bin/sh
# compose/ui/ui-secrets/entrypoint.sh — prompts/frontend/01_02
#
# One-shot: AppRole durin-ui login → read the OIDC client secret from Vault KV
# → render it onto the ui-secrets volume → revoke own token → exit.
# The Web Console (durin-ui) mounts that volume read-only and never talks to
# Vault itself. Same pattern as identity-secrets-init.
set -eu

export VAULT_ADDR="${VAULT_ADDR:-https://vault-lb:8200}"
export VAULT_CACERT="${VAULT_CACERT:-/vault/tls/ca-chain.pem}"
ROLE_ID="$(cat /approle/ui-role-id)"
SECRET_ID="$(cat /approle/ui-secret-id)"

echo "[ui-secrets-init] authenticating via AppRole durin-ui..."
attempt=0
until VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID" 2>/tmp/login.err); do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 15 ]; then
    echo "[ui-secrets-init] AppRole login failed after $((attempt * 2))s:" >&2
    cat /tmp/login.err >&2
    exit 1
  fi
  sleep 2
done
export VAULT_TOKEN

vault kv get -mount=secret -field=value durin/identity/oidc-client-secret > /run/secrets/oidc-client-secret
chmod 0644 /run/secrets/oidc-client-secret   # read by the non-root node user in durin-ui

vault token revoke -self >/dev/null 2>&1 || true
echo "[ui-secrets-init] rendered oidc-client-secret; token revoked"

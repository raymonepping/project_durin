#!/usr/bin/env bash
# scripts/agents-secrets-sync.sh —
# prompts/improvements/01_07_vault_kv_secrets_migration.md.
#
# Agent containers (agent-a/b/c/d) must never hold a Vault credential or
# talk to Vault at all — security/authority-model.md's own "Why agents do
# not hold Vault credentials directly" is a hard architectural boundary,
# not a detail. So unlike the backend (which fetches its own copy of
# these same tokens directly from Vault at startup — backend/src/vault.js's
# loadSecretsFromVault), the agent containers' own copy of their bearer
# token can only reach them the way it always has: a plain environment
# variable set at container creation time.
#
# This script is the bridge: it reads the current values from Vault KV
# (using the routine vault-admin token — exactly the kind of read this
# exists for) and rewrites AGENT_A_TOKEN..AGENT_D_TOKEN and
# FACTORY_CLI_OPERATOR_TOKEN in .env. Vault is where the value is
# generated, audited, and rotated; .env stays the mechanism that
# actually gets the value into the container, unchanged.
#
# FACTORY_AGENT_JWT_SECRET and FACTORY_OIDC_CLIENT_SECRET are NOT
# synced here — nothing reads either from .env anymore (backend/src/
# vault.js's loadSecretsFromVault() is the only remaining consumer of
# either, and it reads straight from Vault). AGENT_A_TOKEN..D_TOKEN and
# FACTORY_CLI_OPERATOR_TOKEN stay because .env is still their real
# delivery mechanism: the agent containers stay Vault-blind by design
# (see above), and the Makefile's own demo-bad/demo-good/reset targets
# and backend/test/helpers/env.js read FACTORY_CLI_OPERATOR_TOKEN and
# AGENT_A_TOKEN/AGENT_C_TOKEN directly from .env, not from Vault.
set -euo pipefail
umask 077
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

ADMIN_TOKEN_FILE=".secrets/vault/vault-admin-token"
[ -s "$ADMIN_TOKEN_FILE" ] || {
  echo "No vault-admin token — run 'make vault-admin-bootstrap' first." >&2
  exit 1
}

export VAULT_TOKEN
VAULT_TOKEN=$(cat "$ADMIN_TOKEN_FILE")
export VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18200}"
export VAULT_CACERT="$REPO_ROOT/vault-tls/ca-chain.pem"
export VAULT_NAMESPACE=factory

set_env_line() {
  local key=$1 value=$2
  if grep -q "^${key}=" .env; then
    sed -i '' "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >>.env
  fi
}

set_env_line AGENT_A_TOKEN "$(vault kv get -field=agent_a secret/agents/bearer-tokens)"
set_env_line AGENT_B_TOKEN "$(vault kv get -field=agent_b secret/agents/bearer-tokens)"
set_env_line AGENT_C_TOKEN "$(vault kv get -field=agent_c secret/agents/bearer-tokens)"
set_env_line AGENT_D_TOKEN "$(vault kv get -field=agent_d secret/agents/bearer-tokens)"
set_env_line FACTORY_CLI_OPERATOR_TOKEN "$(vault kv get -field=value secret/backend/cli-operator-token)"

unset VAULT_TOKEN
echo "Synced .env from Vault KV. Recreate the agent containers to pick up any changed token:"
echo "  ./scripts/compose.sh agents up -d --force-recreate"

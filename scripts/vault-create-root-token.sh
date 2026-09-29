#!/usr/bin/env bash
# scripts/vault-create-root-token.sh
#
# Generates a new administrative/root-level token for accessing the Vault UI / CLI.
# Uses the cluster root token from .secrets/vault/cluster-init.json to mint an
# orphan token with root (all) privileges and a configurable TTL.
set -euo pipefail
umask 077
# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"
cd "$VAULT_PROJECT_ROOT"

if [ ! -s "$VAULT_STATE/cluster-init.json" ]; then
  echo "Error: No cluster-init.json found in $VAULT_STATE. Run 'make vault-up' first." >&2
  exit 1
fi

vault_node_leader
vault_wait unsealed

# Authenticate as cluster root
vault_root cluster

# Default TTL is 24h if not specified as first argument (e.g. ./scripts/vault-create-root-token.sh 4h)
TOKEN_TTL="${1:-24h}"

echo "Connecting to Vault leader at: $VAULT_ADDR" >&2
echo "Minting a new root token (orphan, policy: root, TTL: $TOKEN_TTL)..." >&2

# Mint an orphan root token
NEW_TOKEN=$(vault token create -policy=root -orphan -ttl="$TOKEN_TTL" -format=json | jq -r '.auth.client_token')

unset VAULT_TOKEN

echo ""
echo "========================================================================"
echo "  VAULT ROOT TOKEN GENERATED SUCCESSFULLY"
echo "========================================================================"
echo "Vault UI URL:  https://localhost:18200/ui/vault/auth"
echo "Root Token:    $NEW_TOKEN"
echo "TTL:           $TOKEN_TTL"
echo ""
echo "To export in your current shell:"
echo "  export VAULT_ADDR=https://127.0.0.1:18200"
echo "  export VAULT_CACERT=$VAULT_CACERT"
echo "  export VAULT_TOKEN=$NEW_TOKEN"
echo "========================================================================"

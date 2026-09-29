#!/bin/sh
# scripts/vault-check-entitlement.sh — Prompt 14.3 / 14.4
# Prints the Vault Enterprise licence features and whether a named feature is
# present. Exit 0 if present, 1 if not.
#
# Usage:
#   ./scripts/vault-check-entitlement.sh                 # list all features
#   ./scripts/vault-check-entitlement.sh "Sentinel"      # test one feature
#   ./scripts/vault-check-entitlement.sh "Key Management Secrets Engine"

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# prompts/improvements/01_06_vault_root_token_elimination.md: the narrow
# vault-admin token, not the cluster root token — sys/license/status only
# ever needed plain read capability, already granted to vault-admin.
ADMIN_TOKEN=$(cat "$REPO_ROOT/.secrets/vault/vault-admin-token")

FEATURES=$(podman exec -e VAULT_ADDR=https://127.0.0.1:8200 \
  -e VAULT_CACERT=/vault/config/tls/ca-chain.pem \
  -e VAULT_TOKEN="$ADMIN_TOKEN" factory-vault_1 \
  vault read -format=json sys/license/status 2>/dev/null |
  python3 -c "import sys,json;print('\n'.join(json.load(sys.stdin)['data']['autoloaded']['features']))")

if [ "$#" -eq 0 ]; then
  echo "$FEATURES"
  exit 0
fi

if echo "$FEATURES" | grep -qxF "$1"; then
  echo "✓ entitled: $1"
  exit 0
else
  echo "✗ NOT entitled: $1"
  exit 1
fi

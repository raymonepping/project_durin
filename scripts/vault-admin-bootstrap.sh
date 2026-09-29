#!/usr/bin/env bash
# scripts/vault-admin-bootstrap.sh —
# prompts/improvements/01_06_vault_root_token_elimination.md.
#
# Mints (or confirms) the one narrowly-scoped, periodic token routine
# Vault administration should ever need after initial bootstrap —
# terraform/vault-platform/policies.tf's own vault-admin policy. Must run
# AFTER `terraform -chdir=terraform/vault-platform apply` has created
# that policy (and the factory namespace); it cannot be part of
# scripts/vault-bootstrap.sh itself, which runs before any Terraform
# apply and has no namespace yet to scope anything into.
#
# Idempotent, matching vault-bootstrap.sh's own initialize()/transit-token
# pattern: if a locally-saved admin token already exists and Vault still
# considers it valid, do nothing.
set -euo pipefail
umask 077
# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"
cd "$VAULT_PROJECT_ROOT"

ADMIN_TOKEN_FILE="$VAULT_STATE/vault-admin-token"

vault_node_leader
vault_wait unsealed

token_valid=false
if [ -s "$ADMIN_TOKEN_FILE" ]; then
  token=$(cat "$ADMIN_TOKEN_FILE")
  if VAULT_TOKEN="$token" vault token lookup >/dev/null 2>&1; then
    token_valid=true
  fi
  unset token
fi

if [ "$token_valid" = true ]; then
  echo "vault-admin token already exists and is valid; nothing to do."
  exit 0
fi

if [ ! -s "$VAULT_STATE/cluster-init.json" ]; then
  echo "No cluster-init.json — run 'make vault-up' first." >&2
  exit 1
fi

# Requires terraform/vault-platform's own apply (root token, one-time on a
# fresh cluster) to already have created the vault-admin policy.
vault_root cluster
if ! vault policy read vault-admin >/dev/null 2>&1; then
  echo "The 'vault-admin' policy does not exist yet." >&2
  echo "Run 'terraform -chdir=terraform/vault-platform apply' with the root token first." >&2
  exit 1
fi

tmp=$(mktemp "$VAULT_STATE/vault-admin-token.pending.XXXXXX")
vault token create -policy=vault-admin -orphan -period=720h -field=token >"$tmp"
test -s "$tmp"
mv "$tmp" "$ADMIN_TOKEN_FILE"
unset VAULT_TOKEN
echo "vault-admin token minted and saved to $ADMIN_TOKEN_FILE (mode 0600, periodic — renew within 30 days: VAULT_TOKEN=\$(cat $ADMIN_TOKEN_FILE) vault token renew)."

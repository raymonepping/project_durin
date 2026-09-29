#!/usr/bin/env bash
# Shared, host-side helpers. Never source the reference project's .env.
set -euo pipefail
umask 077
VAULT_PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VAULT_STATE="$VAULT_PROJECT_ROOT/.secrets/vault"
export VAULT_CACERT="$VAULT_PROJECT_ROOT/vault-tls/ca-chain.pem"
unset VAULT_SKIP_VERIFY VAULT_NAMESPACE VAULT_TOKEN VAULT_TLS_SERVER_NAME

vault_node() {
  case "$1" in
  vault-s) export VAULT_ADDR=https://127.0.0.1:18190 ;;
  vault-1) export VAULT_ADDR=https://127.0.0.1:18200 ;;
  vault-2) export VAULT_ADDR=https://127.0.0.1:18201 ;;
  vault-3) export VAULT_ADDR=https://127.0.0.1:18202 ;;
  *)
    echo "Unknown Vault node: $1" >&2
    return 1
    ;;
  esac
}

vault_json() {
  local code=0
  vault status -format=json || code=$?
  [ "$code" -eq 0 ] || [ "$code" -eq 2 ]
}

vault_wait() {
  local mode=$1 attempt state
  for ((attempt = 0; attempt < 60; attempt++)); do
    if state=$(vault_json 2>/dev/null); then
      if [ "$mode" = reachable ] || jq -e '.initialized and (.sealed | not)' <<<"$state" >/dev/null; then
        return 0
      fi
    fi
    sleep 2
  done
  echo "Timed out waiting for $VAULT_ADDR ($mode)." >&2
  return 1
}

vault_root() {
  local cluster=$1
  VAULT_TOKEN=$(jq -er '.root_token' "$VAULT_STATE/$cluster-init.json")
  export VAULT_TOKEN
}

# Point VAULT_ADDR at whichever of vault-1/2/3 is CURRENTLY the Raft
# leader, not a hardcoded node. Found live while proving Prompt 24's
# restore drill: any raft-snapshot-save call issued against a standby
# node gets redirected by Vault to the leader's CLUSTER-INTERNAL hostname
# (e.g. "vault-2:8200"), which only resolves from inside the Podman
# network — a host-side script following that redirect fails with "no
# such host" the moment leadership isn't on the node it assumed. Checking
# each node's own published port for "standby: false" and talking to that
# one directly avoids the redirect (and the internal-hostname problem)
# entirely, regardless of which node currently leads.
vault_node_leader() {
  local node
  for node in vault-1 vault-2 vault-3; do
    vault_node "$node"
    # This Vault Enterprise build's `vault status -format=json` has no
    # plain `.standby` boolean here (found live — it reports
    # `performance_standby: true` on standbys instead, and omits both
    # fields on the leader). The one field that reliably distinguishes
    # the leader is `active_time`: standbys always report the zero epoch
    # ("0001-01-01T00:00:00Z"); the leader reports its real activation time.
    local active_time
    active_time=$(vault_json 2>/dev/null | jq -r '.active_time' 2>/dev/null) || continue
    [ -n "$active_time" ] && [ "$active_time" != "0001-01-01T00:00:00Z" ] && [ "$active_time" != "null" ] && return 0
  done
  echo "Could not find the current Raft leader among vault-1/2/3." >&2
  return 1
}

#!/usr/bin/env bash
# Adapted from vault_reference/vault-s/vault-s-init.sh and vault-1/vault-init.sh.
# Local POC: one Shamir share for vault-s, one recovery share for the cluster.
set -euo pipefail
umask 077
# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"
"$VAULT_PROJECT_ROOT/scripts/vault-prepare.sh"
cd "$VAULT_PROJECT_ROOT"

# Serialize bootstrap to avoid losing initialization output in concurrent runs.
mkdir "$VAULT_STATE/bootstrap.lock" 2>/dev/null || {
  echo 'Bootstrap lock exists. Check for an active bootstrap before removing it.' >&2
  exit 1
}
trap 'rmdir "$VAULT_STATE/bootstrap.lock"' EXIT
compose() { "$VAULT_PROJECT_ROOT/scripts/compose.sh" vault "$@"; }

initialize() {
  local name=$1 state tmp
  shift
  state=$(vault_json)
  if jq -e '.initialized' <<<"$state" >/dev/null; then
    test -s "$VAULT_STATE/$name-init.json" || {
      echo "$name is initialized but its local credentials are missing. Restore them; refusing to initialize again." >&2
      return 1
    }
  else
    test ! -e "$VAULT_STATE/$name-init.json" || {
      echo "$name has saved credentials but no initialized storage. Restore the matching volume." >&2
      return 1
    }
    tmp=$(mktemp "$VAULT_STATE/$name-init.pending.XXXXXX")
    vault operator init -format=json "$@" >"$tmp"
    jq -e '.root_token' "$tmp" >/dev/null
    mv "$tmp" "$VAULT_STATE/$name-init.json"
    echo "$name initialized; credentials saved locally with mode 0600."
  fi
}

compose up -d vault-s
vault_node vault-s
vault_wait reachable
initialize vault-s -key-shares=1 -key-threshold=1
if vault_json | jq -e '.sealed' >/dev/null; then
  key=$(jq -er '.unseal_keys_b64[0]' "$VAULT_STATE/vault-s-init.json")
  vault operator unseal "$key" >/dev/null
  unset key
fi
vault_wait unsealed
vault_root vault-s
if ! vault secrets list -format=json | jq -e 'has("transit/")' >/dev/null; then
  vault secrets enable transit >/dev/null
fi
vault write -f transit/keys/autounseal >/dev/null
vault policy write autounseal vault-s/policies/autounseal.hcl >/dev/null
if ! vault audit list -format=json | jq -e 'has("primary/")' >/dev/null; then
  vault audit enable -path=primary file file_path=/vault/audit/vault-audit.log >/dev/null
fi

token_valid=false
if [ -s "$VAULT_STATE/transit-token" ]; then
  token=$(cat "$VAULT_STATE/transit-token")
  if VAULT_TOKEN="$token" vault token lookup >/dev/null 2>&1; then token_valid=true; fi
  unset token
fi
if [ "$token_valid" = false ]; then
  tmp=$(mktemp "$VAULT_STATE/transit-token.pending.XXXXXX")
  vault token create -orphan -policy=autounseal -period=720h \
    -display-name=factory-auto-unseal -field=token >"$tmp"
  test -s "$tmp"
  mv "$tmp" "$VAULT_STATE/transit-token"
fi
unset VAULT_TOKEN

# Recreate only the three cluster nodes when replacing an expired token,
# because the server reads it once at startup. Named data volumes are retained.
if [ "$token_valid" = false ]; then
  compose up -d --force-recreate vault-1 vault-2 vault-3
else
  compose up -d vault-1 vault-2 vault-3
fi
vault_node vault-1
vault_wait reachable
initialize cluster -recovery-shares=1 -recovery-threshold=1
for node in vault-1 vault-2 vault-3; do
  vault_node "$node"
  vault_wait unsealed
done
vault_root cluster
# `vault_wait unsealed` above only confirms each node answers "initialized
# and not sealed" — not that Raft leader election has finished. Any write
# against the cluster (audit-enable included) needs an active node, and
# right after a fresh `compose up`, unsealed-but-no-leader-yet is a real,
# transient window (found live, repeatedly, during pre-24's hostile
# restart scenario: "local node not active but active cluster node not
# found", self-resolving within a few seconds). Retry rather than
# fail-fast on this one specific, known-transient condition.
#
# Re-resolve the leader on EVERY attempt (vault_node_leader), not once
# before the loop with a hardcoded `vault_node vault-1` — found live during
# a cold Podman-machine restart (all 3 nodes starting simultaneously):
# pinning to vault-1 fails outright with "dial tcp: lookup vault-2: no such
# host" the moment leadership actually lands elsewhere, because a request
# to a standby redirects to the leader's cluster-internal hostname, which
# the host can't resolve (the same class of bug already fixed in
# vault-backup.sh). Re-resolving each pass also naturally rides out
# leadership moving during the election window itself.
leader_wait_attempts=0
until vault_node_leader 2>/dev/null && vault audit list -format=json >/tmp/vault-bootstrap-audit-check.$$ 2>&1; do
  leader_wait_attempts=$((leader_wait_attempts + 1))
  if [ "$leader_wait_attempts" -lt 15 ] && { [ ! -s /tmp/vault-bootstrap-audit-check.$$ ] || grep -q "active cluster node not found\|no such host" /tmp/vault-bootstrap-audit-check.$$; }; then
    sleep 2
    continue
  fi
  cat /tmp/vault-bootstrap-audit-check.$$ >&2 2>/dev/null
  rm -f /tmp/vault-bootstrap-audit-check.$$
  exit 1
done
rm -f /tmp/vault-bootstrap-audit-check.$$
if ! vault audit list -format=json | jq -e 'has("primary/")' >/dev/null; then
  vault audit enable -path=primary file file_path=/vault/audit/vault-audit.log >/dev/null
fi
unset VAULT_TOKEN
"$VAULT_PROJECT_ROOT/scripts/vault-status.sh"
echo 'Ready. Back up both Raft clusters and the local initialization material.'

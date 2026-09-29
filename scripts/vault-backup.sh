#!/usr/bin/env bash
# Adapted from vault_reference/vault-s/scripts/vault_raft_snapshot.sh.
set -euo pipefail
umask 077
# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"
mkdir -p "$VAULT_PROJECT_ROOT/backups"
backup=$(mktemp -d "$VAULT_PROJECT_ROOT/backups/vault-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
for cluster in vault-s cluster; do
  # Prompt 24 — talk to the current Raft leader directly, not a hardcoded
  # node: a snapshot-save call against a standby redirects to the leader's
  # cluster-internal hostname, which a host-side script can't resolve.
  if [ "$cluster" = vault-s ]; then vault_node vault-s; else vault_node_leader; fi
  vault_root "$cluster"
  vault operator raft snapshot save "$backup/$cluster.snap"
  vault operator raft snapshot inspect "$backup/$cluster.snap" >"$backup/$cluster.inspect.txt"
done
echo "Snapshots saved and inspected in $backup"
echo 'Store a protected copy of .secrets/vault, vault-tls and licenses separately; snapshots alone cannot recover the root of trust.'

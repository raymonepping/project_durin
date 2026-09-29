#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"
failed=0
for node in vault-s vault-1 vault-2 vault-3; do
  vault_node "$node"
  if state=$(vault_json 2>/dev/null); then
    jq -r --arg node "$node" '"\($node): initialized=\(.initialized) sealed=\(.sealed) seal=\(.type) version=\(.version)"' <<<"$state"
    jq -e '.initialized and (.sealed | not)' <<<"$state" >/dev/null || failed=1
  else
    echo "$node: unreachable"
    failed=1
  fi
done
if [ "$failed" -eq 0 ]; then
  # Always query the leader node (vault-1) by host port to avoid internal
  # hostname redirects that the host cannot resolve.
  vault_node vault-1
  vault_root cluster
  peers=$(VAULT_ADDR=https://127.0.0.1:18200 vault operator raft list-peers -format=json)
  jq -r '.data.config.servers[] | "  \(.node_id): leader=\(.leader) voter=\(.voter)"' <<<"$peers"
  jq -e '(.data.config.servers | length) == 3' <<<"$peers" >/dev/null || failed=1
fi
exit "$failed"

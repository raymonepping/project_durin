#!/bin/sh
# compose/vault/vault-agent/entrypoint.sh
#
# Vault Agent reads role-id and secret-id from the shared /run/approle volume,
# which is managed and automatically rotated by the vault-rotator sidecar.
# The depends_on: vault-rotator: condition: service_healthy in compose.yaml
# guarantees the files are present before this container starts, but a brief
# wait loop is kept as a belt-and-suspenders guard against timing edge cases
# (e.g. manual container restarts outside Compose's dependency tracking).
set -eu

umask 077

echo "[vault-agent entrypoint] waiting for role-id and secret-id in /run/approle..."
attempt=0
while [ ! -s /run/approle/role-id ] || [ ! -s /run/approle/secret-id ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "[vault-agent entrypoint] timed out waiting for /run/approle files — is vault-rotator healthy?" >&2
    exit 1
  fi
  sleep 1
done

echo "[vault-agent entrypoint] AppRole credentials found, starting vault agent..."
exec vault agent -config=/vault/agent/config.hcl

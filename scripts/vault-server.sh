#!/bin/sh
set -eu
# Run as container root with all capabilities dropped so 0600 bind-mounted
# licenses/keys are readable under rootless Podman without loosening host modes.
if [ -f /run/secrets/transit-token ]; then
  VAULT_TOKEN=$(cat /run/secrets/transit-token)
  [ -n "$VAULT_TOKEN" ] || {
    echo 'Transit token is empty; run make vault-bootstrap.' >&2
    exit 1
  }
  export VAULT_TOKEN
fi
# Data and audit directories are supplied by named volumes.
# Ensure the audit log file exists and is writable by vault(100) before Vault
# starts — Podman initialises new named volumes owned by root, which causes
# "permission denied" on the audit sink on first boot of a standby node.
mkdir -p /vault/file /vault/audit
touch /vault/audit/vault-audit.log
exec vault server -config=/vault/config/config.hcl

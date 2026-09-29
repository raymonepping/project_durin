#!/bin/sh
# scripts/vault-seed-users.sh — Prompt 14.5
# Enables Vault userpass and seeds the demo persona users. Idempotent.
# Passwords are POC-only.

set -eu
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(python3 -c "import json;print(json.load(open('$REPO_ROOT/.secrets/vault/cluster-init.json'))['root_token'])")

vx() { podman exec -e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_SKIP_VERIFY=1 \
  -e VAULT_TOKEN="$ROOT" arcanium-vault_1 "$@"; }

vx sh -c 'vault auth enable userpass 2>/dev/null || true'

for pair in \
  "ciso:Arcanium-ciso-2026" \
  "architect:Arcanium-arch-2026" \
  "operator:Arcanium-ops-2026" \
  "auditor:Arcanium-audit-2026" \
  "pepsi-admin:Arcanium-pepsi-2026" \
  "cocacola-admin:Arcanium-cocacola-2026"; do
  u=${pair%%:*}
  p=${pair#*:}
  vx vault write "auth/userpass/users/$u" password="$p" token_policies=default token_ttl=1h >/dev/null
  echo "  ✓ $u"
done
echo "  ✓ userpass users seeded"

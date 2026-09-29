#!/usr/bin/env bash
# scripts/vault-agent-recover.sh — prompts/hardening/01_00.
#
# One-command version of CLAUDE.md gotcha #9's documented manual
# recovery procedure: force-recreate vault-agent, unseal vault-s if
# the recreate still triggers the compose dependency-cascade a future
# regression might reintroduce (Phase 2 removed the depends_on that
# caused this; this script stays defensive rather than assuming that
# fix holds forever), recreate factory-api to pick up the fresh
# token, then the agents (recreating factory-api breaks their SSE
# connections — gotcha #3). Idempotent and safe to run even when
# nothing is actually broken: every step already tolerates being
# re-run (compose.sh up -d, vault-unseal.sh's own already-unsealed
# no-op, a plain recreate).
set -euo pipefail
umask 077
# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"
cd "$VAULT_PROJECT_ROOT"

echo "==> Force-recreating vault-agent..."
./scripts/compose.sh vault up -d --force-recreate vault-agent

echo "==> Waiting for vault-agent's own (real) healthcheck..."
for ((attempt = 0; attempt < 30; attempt++)); do
  status=$(podman inspect factory-vault_agent --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
  [ "$status" = healthy ] && break
  sleep 2
done
if [ "$status" != healthy ]; then
  echo "vault-agent did not become healthy — inspect: podman logs factory-vault_agent" >&2
  exit 1
fi
echo "    vault-agent healthy."

echo "==> Checking Vault cluster seal status..."
if ! ./scripts/vault-status.sh; then
  echo "    vault-s reported sealed — unsealing..."
  ./scripts/vault-unseal.sh
  ./scripts/vault-status.sh
fi

echo "==> Recreating factory-api to pick up the fresh token..."
./scripts/compose.sh api up -d --force-recreate

for ((attempt = 0; attempt < 30; attempt++)); do
  status=$(podman inspect factory-api --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
  [ "$status" = healthy ] && break
  sleep 2
done
if [ "$status" != healthy ]; then
  echo "factory-api did not become healthy — inspect: podman logs factory-api" >&2
  exit 1
fi
echo "    factory-api healthy."

echo "==> Recreating agents (factory-api recreate breaks their SSE connections — gotcha #3)..."
./scripts/compose.sh agents up -d --force-recreate

echo
echo "Recovery complete. Final health check:"
curl -s http://localhost:3001/api/health || true
echo

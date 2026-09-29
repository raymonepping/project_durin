#!/usr/bin/env bash
# scripts/verify-stack.sh — Durin stack smoke test.
#
# Checks all containers are healthy, Vault cluster is operational, and
# basic backend endpoints respond. Run after `make up` to confirm the
# stack is in a good state.
#
# Exit code: 0 if all checks pass, 1 if any fail (warnings never fail).
set -uo pipefail

# shellcheck source=scripts/vault-common.sh
source "$(dirname -- "$0")/vault-common.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass=0; fail=0; warn=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "${GREEN}  ✓${NC} %s\n" "$desc"; pass=$((pass + 1))
  else
    printf "${RED}  ✗${NC} %s\n" "$desc" >&2; fail=$((fail + 1))
  fi
}
warning() {
  printf "${YELLOW}  ~${NC} %s\n" "$1"; warn=$((warn + 1))
}

echo "=== Vault cluster ==="
for node in vault-s vault-1 vault-2 vault-3; do
  vault_node "$node"
  if state=$(vault_json 2>/dev/null); then
    sealed=$(jq -r '.sealed' <<<"$state")
    version=$(jq -r '.version' <<<"$state")
    if [ "$sealed" = "false" ]; then
      printf "${GREEN}  ✓${NC} %s: unsealed (v%s)\n" "$node" "$version"; pass=$((pass + 1))
    else
      printf "${RED}  ✗${NC} %s: sealed\n" "$node" >&2; fail=$((fail + 1))
    fi
  else
    printf "${RED}  ✗${NC} %s: unreachable\n" "$node" >&2; fail=$((fail + 1))
  fi
done

echo ""
echo "=== Containers ==="
# Container names come from compose container_name: (underscores, not hyphens).
for name in durin-vault_s durin-vault_1 durin-vault_2 durin-vault_3 durin-vault_lb \
            durin-vault_rotator durin-vault_agent \
            durin-postgres durin-backend; do
  status=$(podman inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || echo "not found")
  case "$status" in
    healthy) printf "${GREEN}  ✓${NC} %s: healthy\n" "$name"; pass=$((pass + 1)) ;;
    "not found") printf "${RED}  ✗${NC} %s: not running\n" "$name" >&2; fail=$((fail + 1)) ;;
    *) printf "${RED}  ✗${NC} %s: %s\n" "$name" "$status" >&2; fail=$((fail + 1)) ;;
  esac
done

echo ""
echo "=== Vault load balancer ==="
check "vault-lb serves the active node over verified TLS (127.0.0.1:18300)" bash -c \
  "curl -sf --cacert '$(dirname -- "$0")/../vault-tls/ca-chain.pem' https://127.0.0.1:18300/v1/sys/health | jq -e '.standby == false and .sealed == false'"
check "backend reaches Vault through vault-lb" bash -c \
  '[ "$(podman exec durin-backend printenv VAULT_ADDR)" = "https://vault-lb:8200" ]'
check "vault-lb routes to the Raft leader (/api/v1/vault/status)" bash -c \
  'source "$(dirname -- "$0")/lib/durin-auth.sh" 2>/dev/null || source scripts/lib/durin-auth.sh; curl -s http://localhost:3001/api/v1/vault/status | jq -e ".data.summary.status == \"healthy\" and .data.summary.loadBalancerAgrees"'
check "vault agent reaches Vault through vault-lb" bash -c \
  'podman exec durin-vault_agent grep -q "https://vault-lb:8200" /vault/agent/config.hcl'

echo ""
echo "=== Identity ==="
for name in durin-openldap durin-keycloak; do
  status=$(podman inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || echo "not found")
  [ "$status" = healthy ] && { printf "${GREEN}  ✓${NC} %s: healthy\n" "$name"; pass=$((pass + 1)); } \
    || { printf "${RED}  ✗${NC} %s: %s\n" "$name" "$status" >&2; fail=$((fail + 1)); }
done
check "Keycloak realm durin published" bash -c \
  'curl -sf http://localhost:8083/realms/durin/.well-known/openid-configuration | jq -e .issuer'
check "backend enforces OIDC (DURIN_AUTH_ENABLED=true)" bash -c \
  '[ "$(curl -s http://localhost:3001/api/v1/health | jq -r .auth.enabled)" = true ]'
check "backend rejects requests without a token (401)" bash -c \
  '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "x-tenant: acme" http://localhost:3001/api/v1/customers)" = 401 ]'

echo ""
echo "=== Backend API ==="
check "durin-backend /health" curl -sf http://localhost:3001/api/v1/health
check "durin-backend vault connected" bash -c \
  '[ "$(curl -s http://localhost:3001/api/v1/health | jq -r .vault.status)" = connected ]'
check "durin-backend db connected (Vault dynamic credential)" bash -c \
  '[ "$(curl -s http://localhost:3001/api/v1/health | jq -r .db.connected)" = true ]'
check "durin-backend holds broker-only Vault authority (no durin-admin)" bash -c \
  '[ "$(curl -s http://localhost:3001/api/v1/health | jq -c ".vault.policies|sort")" = "[\"default\",\"durin-backend\",\"durin-database\"]" ]'
check "database schema migrated (make db-migrate)" bash -c \
  '[ -n "$(podman exec durin-postgres psql -At -U durin -d durin_db -c "select 1 from schema_migrations limit 1" 2>/dev/null)" ]'

echo ""
echo "=== Networks ==="
check "durin-internal network" podman network inspect durin-internal

echo ""
printf "Verify complete: ${GREEN}%d passed${NC}" "$pass"
[ "$warn" -gt 0 ] && printf ", ${YELLOW}%d warnings${NC}" "$warn"
[ "$fail" -gt 0 ] && printf ", ${RED}%d failed${NC}" "$fail"
echo ""

[ "$fail" -eq 0 ]

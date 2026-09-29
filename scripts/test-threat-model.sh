#!/usr/bin/env bash
# scripts/test-threat-model.sh — Durin threat model validation
#
# Executes testable threat scenarios T1–T3, T5, T7.
# T4 (compromised operator) and T6 (credential leakage) are documented in
# docs/threat-model.md — they are architectural/operational, not automatable.
#
# Usage:
#   ./scripts/test-threat-model.sh          # all testable scenarios
#   ./scripts/test-threat-model.sh --t1     # T1: compromised database
#   ./scripts/test-threat-model.sh --t2     # T2: compromised application
#   ./scripts/test-threat-model.sh --t3     # T3: cross-tenant compromise
#   ./scripts/test-threat-model.sh --t5     # T5: break glass abuse
#   ./scripts/test-threat-model.sh --t7     # T7: vault unavailable

set -euo pipefail

# Real OIDC tokens when the backend enforces auth; pass-through in demo mode.
# shellcheck source=scripts/lib/durin-auth.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib/durin-auth.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$PROJECT_ROOT/.env" | grep -v '^$' | xargs) 2>/dev/null || true
fi

# 18300 = vault-lb (HAProxy → active node). 18190 is vault-s (auto-unseal only).
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18300}"
VAULT_CACERT="${VAULT_CACERT:-$PROJECT_ROOT/vault-tls/ca-chain.pem}"
BACKEND_URL="${BACKEND_URL:-http://localhost:3001}"
export VAULT_ADDR VAULT_CACERT

TOKEN_FILE="$PROJECT_ROOT/.secrets/vault/cluster-init.json"
if [ -z "${VAULT_TOKEN:-}" ] && [ -f "$TOKEN_FILE" ]; then
  export VAULT_TOKEN=$(jq -r '.root_token' "$TOKEN_FILE" 2>/dev/null || echo "")
fi

PASS=0; FAIL=0; SKIP=0

pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s  %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s  (%s)\n' "$1" "${2:-}"; }

vault_ok() { [ -n "${VAULT_TOKEN:-}" ] && vault status >/dev/null 2>&1; }
# Reachable = the backend answers at all. A degraded backend (503 because Vault
# is down) is exactly what T7 needs to test, so do not require a 2xx.
backend_ok() {
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' "$BACKEND_URL/api/v1/health" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ]
}
postgres_ok() { podman exec durin-postgres psql -U durin -d durin_db -c 'SELECT 1' >/dev/null 2>&1; }

# ── T1: Compromised database ──────────────────────────────────────────────────

test_t1() {
  printf '\n── T1: Compromised database ─────────────────────────────────────────────\n'
  printf '  Attacker has full PostgreSQL read access. Tests that all sensitive\n'
  printf '  fields are ciphertext — never plaintext.\n\n'

  if ! postgres_ok; then
    skip "T1: protected_values contain only vault: ciphertext" "postgres unavailable"
    skip "T1: no plaintext IBAN/tax_id in database" "postgres unavailable"
    skip "T1: decrypt attempt without Vault auth returns DENIED" "postgres unavailable"
    return
  fi

  # All protected_values must start with vault:v
  local total non_vault
  total=$(podman exec durin-postgres psql -U durin -d durin_db -tAc \
    "SELECT COUNT(*) FROM protected_values;" 2>/dev/null | tr -d ' ' || echo "0")
  non_vault=$(podman exec durin-postgres psql -U durin -d durin_db -tAc \
    "SELECT COUNT(*) FROM protected_values WHERE ciphertext NOT LIKE 'vault:%';" 2>/dev/null | tr -d ' ' || echo "0")

  if [ "$total" -gt 0 ] && [ "$non_vault" = "0" ]; then
    pass "T1: all $total protected_values are vault: ciphertext (0 plaintext)"
  elif [ "$total" = "0" ]; then
    skip "T1: protected_values contain only vault: ciphertext" "no data — run make seed first"
  else
    fail "T1: protected_values contain only vault: ciphertext" "$non_vault plaintext values found"
  fi

  # Customers table must not contain IBAN patterns in any column
  local iban_in_customers
  iban_in_customers=$(podman exec durin-postgres psql -U durin -d durin_db -tAc \
    "SELECT COUNT(*) FROM customers WHERE name LIKE '%NL%ABNA%' OR company LIKE '%NL%ABNA%';" \
    2>/dev/null | tr -d ' ' || echo "0")
  [ "$iban_in_customers" = "0" ] \
    && pass "T1: no IBAN patterns found in customers table plaintext columns" \
    || fail "T1: no IBAN patterns in customers table" "$iban_in_customers rows found"

  # Transit keys are NOT stored in PostgreSQL (check user-defined tables only)
  local vault_key_in_db
  vault_key_in_db=$(podman exec durin-postgres psql -U durin -d durin_db -tAc \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND (table_name LIKE '%transit%' OR table_name LIKE '%vault_key%');" \
    2>/dev/null | tr -d ' ' || echo "0")
  [ "$vault_key_in_db" = "0" ] \
    && pass "T1: no Transit key tables exist in PostgreSQL (user schema is clean)" \
    || fail "T1: no Transit key tables in PostgreSQL" "$vault_key_in_db tables found"

  # Decrypt attempt via compromise endpoint must return DENIED
  if backend_ok; then
    local result
    result=$(curl -sf -X POST "$BACKEND_URL/api/v1/scenarios/compromise/decrypt-attempt" \
      -H 'Content-Type: application/json' -H 'x-tenant: acme' \
      -d '{"actor":"attacker","ciphertext":"vault:v1:AQICAHjTestCiphertextThatCannotBeDecryptedWithoutVaultAuth=="}' \
      2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("data",{}).get("result",""))' \
      2>/dev/null || echo "")
    [ "$result" = "DENIED" ] \
      && pass "T1: compromise/decrypt-attempt without Vault auth returns DENIED" \
      || fail "T1: compromise/decrypt-attempt returns DENIED" "endpoint returned: '$result'"
  else
    skip "T1: compromise/decrypt-attempt" "backend unavailable"
  fi
}

# ── T2: Compromised application ───────────────────────────────────────────────

test_t2() {
  printf '\n── T2: Compromised application ──────────────────────────────────────────\n'
  printf '  Attacker has backend API access. Tests that the backend token has\n'
  printf '  only expected policies (no admin, no root).\n\n'

  if ! vault_ok; then
    skip "T2: backend Vault token has only transit+database policies" "vault unavailable"
    skip "T2: Transit keys are not exportable" "vault unavailable"
    skip "T2: backend token cannot modify Vault policies" "vault unavailable"
    return
  fi

  # Read the backend token accessor from the health endpoint
  local accessor
  accessor=$(curl -sf "$BACKEND_URL/api/v1/health" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("vault",{}).get("accessor",""))' \
    2>/dev/null || echo "")

  if [ -n "$accessor" ]; then
    # Look up the token by accessor using Vault HTTP API directly
    # (avoids the vault CLI needing a valid root token)
    local policies
    policies=$(curl -sk \
      -H "X-Vault-Token: ${VAULT_TOKEN:-}" \
      "$VAULT_ADDR/v1/auth/token/lookup-accessor" \
      -d "{\"accessor\":\"$accessor\"}" \
      2>/dev/null | python3 -c \
      'import sys,json; d=json.load(sys.stdin); print(" ".join(sorted(d.get("data",{}).get("policies",[]))))' \
      2>/dev/null || echo "")
    printf '    Backend token policies: %s\n' "$policies"

    if [ -z "$policies" ]; then
      skip "T2: backend token has expected policies" \
        "accessor lookup requires valid admin token — set VAULT_TOKEN and VAULT_CACERT"
    elif [ "$policies" = "default durin-backend durin-database" ]; then
      pass "T2: backend token is broker-only (default durin-backend durin-database)"
    else
      fail "T2: backend token has expected policies" "got: $policies"
    fi

    if echo "$policies" | grep -q 'durin-admin\|root'; then
      fail "T2: backend token does NOT have admin/root policy" "found: $policies"
    else
      pass "T2: backend token does NOT have admin/root policy"
    fi
  else
    skip "T2: backend Vault token policy check" "could not read accessor from health endpoint"
  fi

  # Transit keys not exportable (re-uses test from hardening suite)
  local export_h
  export_h=$(curl -sk -o /dev/null -w '%{http_code}' \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/transit/export/encryption-key/durin-acme-customer-data" 2>/dev/null || echo "0")
  [ "$export_h" = "403" ] || [ "$export_h" = "400" ] \
    && pass "T2: Transit keys not exportable (HTTP $export_h)" \
    || fail "T2: Transit keys not exportable" "got HTTP $export_h"

  # A token with exactly the backend's policies: what can a compromised backend do?
  local twin
  twin=$(vault token create -policy=durin-backend -policy=durin-database -ttl=2m -field=token 2>/dev/null || echo "")
  if [ -n "$twin" ]; then
    local cap
    for path in sys/policies/acl/evil-policy sys/auth/evil sys/mounts/evil auth/token/create \
                transit/decrypt/durin-acme-customer-data transit/datakey/plaintext/durin-acme-customer-data \
                transit/export/encryption-key/durin-acme-customer-data transit/keys/durin-acme-customer-data/config; do
      cap=$(vault token capabilities "$twin" "$path" 2>/dev/null)
      case "$path" in
        */config)
          grep -qE 'update|create|sudo' <<<"$cap" \
            && fail "T2: backend cannot change key config" "got $cap" \
            || pass "T2: backend cannot change key config (moved to the operator's own Vault identity)";;
        *)
          [ "$cap" = "deny" ] \
            && pass "T2: backend token denied on $path" \
            || fail "T2: backend token denied on $path" "got $cap";;
      esac
    done
    vault token revoke "$twin" >/dev/null 2>&1 || true
  else
    skip "T2: backend capability matrix" "could not create an equivalent token"
  fi
}

# ── T3: Cross-tenant compromise ───────────────────────────────────────────────

test_t3() {
  printf '\n── T3: Cross-tenant compromise (Vault-enforced) ─────────────────────────\n'
  printf '  Delegates to test-isolation.sh --vault and --api\n\n'
  local out
  out=$(bash "$SCRIPT_DIR/test-isolation.sh" --vault 2>&1; bash "$SCRIPT_DIR/test-isolation.sh" --api 2>&1)
  grep -E 'PASS|FAIL|SKIP' <<<"$out" | sed 's/^/  /'
  if grep -qE 'FAIL: [1-9]' <<<"$out"; then
    fail "T3: cross-tenant isolation" "see failures above"
  else
    pass "T3: cross-tenant isolation enforced (Vault + API layers)"
  fi
}

# ── T5: Break Glass abuse ─────────────────────────────────────────────────────

test_t5() {
  printf '\n── T5: Emergency access abuse (Break Glass, Vault Control Groups) ────────\n'
  printf '  Normal access denied by Vault; approval happens in Vault; one release only.\n\n'

  if ! backend_ok; then
    skip "T5: break glass" "backend unavailable"
    return
  fi

  local doc_id h body bg_id
  doc_id=$(curl -sf -H 'x-tenant: acme' "$BACKEND_URL/api/v1/documents" 2>/dev/null \
    | jq -r '[.data[]|select(.classification=="RESTRICTED")][0].id // empty' 2>/dev/null || echo "")
  if [ -z "$doc_id" ]; then
    skip "T5: break glass tests" "no RESTRICTED document found (make seed)"
    return
  fi
  t5() { curl -s -o /tmp/t5-body.json -w '%{http_code}' "$@" 2>/dev/null || echo "0"; }
  err() { jq -r '.error // empty' /tmp/t5-body.json 2>/dev/null; }

  h=$(t5 -H 'x-tenant: acme' "$BACKEND_URL/api/v1/documents/$doc_id/content")
  [ "$h" = "403" ] && pass "T5: normal access to RESTRICTED document denied by Vault (403)" \
                   || fail "T5: normal access to RESTRICTED document denied" "got $h"

  h=$(t5 -H 'x-tenant: acme' -H "x-break-glass-request: $(uuidgen | tr 'A-Z' 'a-z')" "$BACKEND_URL/api/v1/documents/$doc_id/content")
  [ "$h/$(err)" = "403/break_glass_invalid" ] && pass "T5: unknown break-glass request refused" \
                   || fail "T5: unknown break-glass request refused" "got $h/$(err)"

  h=$(t5 -X POST -H 'Content-Type: application/json' -H 'x-tenant: acme' -H 'x-durin-actor: security-admin' \
      -d "{\"resource_id\":\"$doc_id\",\"reason\":\"Approver self-request\"}" "$BACKEND_URL/api/v1/break-glass/request")
  [ "$h" = "403" ] && pass "T5: an approver cannot request (Vault bound claims — separation of duties)" \
                   || fail "T5: an approver cannot request" "got $h"

  h=$(t5 -X POST -H 'Content-Type: application/json' -H 'x-tenant: acme' -H 'x-durin-actor: test@threat-model' \
      -d "{\"resource_id\":\"$doc_id\",\"reason\":\"T5 threat model test\"}" "$BACKEND_URL/api/v1/break-glass/request")
  bg_id=$(jq -r '.data.id // empty' /tmp/t5-body.json)
  [ "$h" = "201" ] && [ -n "$bg_id" ] && pass "T5: request recorded as a Vault control-group request" \
                   || { fail "T5: request" "got $h/$(err)"; return; }

  h=$(t5 -H 'x-tenant: acme' -H "x-break-glass-request: $bg_id" -H 'x-durin-actor: test@threat-model' "$BACKEND_URL/api/v1/documents/$doc_id/content")
  [ "$h/$(err)" = "403/break_glass_pending" ] && pass "T5: no release before approval" \
                   || fail "T5: no release before approval" "got $h/$(err)"

  h=$(t5 -X POST -H 'x-durin-actor: test@threat-model' "$BACKEND_URL/api/v1/break-glass/$bg_id/approve")
  [ "$h" = "403" ] && pass "T5: requester cannot approve own request" \
                   || fail "T5: requester cannot approve own request" "got $h"

  h=$(t5 -X POST -H 'x-durin-actor: security-admin' "$BACKEND_URL/api/v1/break-glass/$bg_id/approve")
  [ "$h" = "200" ] && pass "T5: security-admin approves in Vault" || fail "T5: approval" "got $h/$(err)"

  h=$(t5 -H 'x-tenant: acme' -H "x-break-glass-request: $bg_id" -H 'x-durin-actor: test@threat-model' "$BACKEND_URL/api/v1/documents/$doc_id/content")
  [ "$h" = "200" ] && pass "T5: approved request released once (HTTP 200)" || fail "T5: release" "got $h/$(err)"
  h=$(t5 -H 'x-tenant: acme' -H "x-break-glass-request: $bg_id" -H 'x-durin-actor: test@threat-model' "$BACKEND_URL/api/v1/documents/$doc_id/content")
  [ "$h" = "403" ] && pass "T5: second release refused (single use)" || fail "T5: second release" "got $h"

  local has_actor
  has_actor=$(curl -sf "$BACKEND_URL/api/v1/audit?operation=BREAK_GLASS_APPROVED&result=ALLOWED" 2>/dev/null \
    | jq -r '(.data|length) > 0 and all(.data[]; .actor != null and .actor != "")' 2>/dev/null)
  [ "$has_actor" = true ] && pass "T5: BREAK_GLASS_APPROVED events carry the approver identity" \
                          || fail "T5: approver identity in audit" "missing actor"
}

# ── T7: Vault unavailable ─────────────────────────────────────────────────────

test_t7() {
  printf '\n── T7: Vault unavailable ────────────────────────────────────────────────\n'
  printf '  Backend must fail safely — 503, never plaintext fallback.\n\n'

  if ! backend_ok; then
    skip "T7: Vault-unavailable behavior" "backend unavailable"
    return
  fi

  # Check current vault health from backend's perspective
  local vault_health
  vault_health=$(curl -s "$BACKEND_URL/api/v1/health" 2>/dev/null \
    | jq -r '.vault.ok' \
    2>/dev/null || echo "false")

  if [ "$vault_health" = "True" ] || [ "$vault_health" = "true" ]; then
    printf '  INFO   Vault is UP — testing that protect operation succeeds (not the failure path)\n'
    # Vault is up: verify protect succeeds normally
    local protect_h
    protect_h=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -H 'x-tenant: acme' -d '{"field":"iban","value":"NL91ABNA0417164300"}' \
        "$BACKEND_URL/api/v1/scenarios/protect" 2>/dev/null || echo "0")
    [ "$protect_h" = "200" ] \
      && pass "T7: protect returns 200 when Vault is available" \
      || fail "T7: protect returns 200 when Vault is available" "got $protect_h"

    printf '  INFO   To test failure path: make vault-down && sleep 5 && %s --t7\n' "$0"
    skip "T7: protect returns 503 when Vault unavailable" "Vault is currently UP — run 'make vault-down' first"
    skip "T7: backend never returns plaintext when Vault unavailable" "Vault is currently UP"
  else
    printf '  INFO   Vault is DOWN — testing safe failure behavior\n'
    # Vault is down: all protect/recover must 503
    local protect_h
    protect_h=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -H 'x-tenant: acme' -d '{"field":"iban","value":"NL91ABNA0417164300"}' \
        "$BACKEND_URL/api/v1/scenarios/protect" 2>/dev/null || echo "0")
    [ "$protect_h" = "503" ] \
      && pass "T7: protect returns 503 when Vault unavailable (no plaintext fallback)" \
      || fail "T7: protect returns 503 when Vault unavailable" "got $protect_h"

    # Read a document — must NOT return decrypted plaintext
    local doc_id
    doc_id=$(curl -sf -H 'x-tenant: acme' "$BACKEND_URL/api/v1/documents" 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["data"][0]["id"] if d["data"] else "")' \
      2>/dev/null || echo "")
    if [ -n "$doc_id" ]; then
      local doc_h doc_body
      doc_h=$(curl -s -o /tmp/t7-doc-body.json -w '%{http_code}' -H 'x-tenant: acme' \
          "$BACKEND_URL/api/v1/documents/$doc_id/content" 2>/dev/null || echo "0")
      [ "$doc_h" = "503" ] \
        && pass "T7: document content returns 503 when Vault unavailable" \
        || fail "T7: document content returns 503 when Vault unavailable" "got $doc_h"

      # Verify the response body does not contain plaintext
      if [ -f /tmp/t7-doc-body.json ]; then
        local has_payload
        has_payload=$(python3 -c \
          'import sys,json; d=json.load(open("/tmp/t7-doc-body.json")); print(bool(d.get("data",{}).get("payload")))' \
          2>/dev/null || echo "False")
        [ "$has_payload" = "False" ] \
          && pass "T7: error response does not contain plaintext payload" \
          || fail "T7: error response does not contain plaintext payload" "payload present in 503 response"
      fi
    else
      skip "T7: document content 503 check" "no documents available"
    fi
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────

summary() {
  local total=$((PASS+FAIL+SKIP))
  printf '\n══════════════════════════════════════════════════════════════════════════\n'
  printf 'Durin Threat Model Validation Results\n'
  printf '══════════════════════════════════════════════════════════════════════════\n'
  printf '  T4 (operator compromise) — documented in docs/threat-model.md (not automatable)\n'
  printf '  T6 (credential leakage)  — documented in docs/threat-model.md (architectural)\n'
  printf '──────────────────────────────────────────────────────────────────────────\n'
  printf '  Total: %d   \033[32mPASS: %d\033[0m   \033[31mFAIL: %d\033[0m   \033[33mSKIP: %d\033[0m\n' \
    "$total" "$PASS" "$FAIL" "$SKIP"
  printf '══════════════════════════════════════════════════════════════════════════\n'
  [ "$FAIL" -eq 0 ] || exit 1
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

case "${1:-all}" in
  --t1) test_t1 ;;
  --t2) test_t2 ;;
  --t3) test_t3 ;;
  --t5) test_t5 ;;
  --t7) test_t7 ;;
  all|--all|"")
    test_t1; test_t2; test_t3; test_t5; test_t7 ;;
  *)
    printf 'Usage: %s [--t1|--t2|--t3|--t5|--t7|all]\n' "$0"; exit 1 ;;
esac

summary

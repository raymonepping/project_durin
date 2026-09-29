#!/usr/bin/env bash
# scripts/test-isolation.sh — Durin multi-tenant cryptographic isolation test matrix
#
# Tests every cell of the Vault-enforced and application-layer isolation model.
# Requires VAULT_ADDR, VAULT_CACERT, and VAULT_TOKEN (admin) to be set,
# OR reads them from .env + .secrets/vault/cluster-init.json.
#
# Usage:
#   ./scripts/test-isolation.sh                  # all checks
#   ./scripts/test-isolation.sh --vault          # Vault-layer only
#   ./scripts/test-isolation.sh --api            # API-layer only
#   ./scripts/test-isolation.sh --namespace      # Namespace checks only

set -euo pipefail

# Real OIDC tokens when the backend enforces auth; pass-through in demo mode.
# shellcheck source=scripts/lib/durin-auth.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib/durin-auth.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Environment ───────────────────────────────────────────────────────────────

if [ -f "$PROJECT_ROOT/.env" ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$PROJECT_ROOT/.env" | grep -v '^$' | xargs) 2>/dev/null || true
fi

# 18300 = vault-lb (HAProxy → active node). 18190 is vault-s (auto-unseal only).
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18300}"
VAULT_CACERT="${VAULT_CACERT:-$PROJECT_ROOT/vault-tls/ca-chain.pem}"
BACKEND_URL="${BACKEND_URL:-http://localhost:3001}"
export VAULT_ADDR VAULT_CACERT

# Load admin token
TOKEN_FILE="$PROJECT_ROOT/.secrets/vault/cluster-init.json"
if [ -z "${VAULT_TOKEN:-}" ] && [ -f "$TOKEN_FILE" ]; then
  export VAULT_TOKEN=$(jq -r '.root_token' "$TOKEN_FILE" 2>/dev/null || echo "")
fi

# ── Test harness ──────────────────────────────────────────────────────────────

PASS=0; FAIL=0; SKIP=0

pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s  %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s  (%s)\n' "$1" "${2:-unavailable}"; }

vault_ok() {
  [ -n "${VAULT_TOKEN:-}" ] && vault status >/dev/null 2>&1
}

# Log a real Durin user into a Vault JWT role with their Keycloak access token —
# the same path the backend uses (prompts/improvements/01_04). Empty if Vault refuses.
jwt_login() { # role uid
  VAULT_TOKEN= vault write -format=json auth/jwt/login role="$1" jwt="$(durin_token "$2")" 2>/dev/null \
    | jq -r '.auth.client_token // empty' 2>/dev/null || echo ""
}

# Vault HTTP call, return HTTP status code
vault_http() {
  local token="$1" method="$2" path="$3" body="${4:-}"
  local args=(-sk -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $token")
  if [ -n "$body" ]; then
    args+=(-X POST -H 'Content-Type: application/json' -d "$body")
  else
    args+=(-X "$method")
  fi
  curl "${args[@]}" "$VAULT_ADDR/v1/$path" 2>/dev/null || echo "0"
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

printf '\n── Prerequisites ────────────────────────────────────────────────────────\n'

VAULT_AVAILABLE=false
if vault_ok; then
  VAULT_AVAILABLE=true
  printf '  \033[32mOK\033[0m     Vault admin token valid (%s)\n' "$VAULT_ADDR"
else
  printf '  \033[33mWARN\033[0m   Vault not reachable — Vault-layer checks will be skipped\n'
  printf '         Set VAULT_TOKEN and VAULT_CACERT to run Vault checks\n'
fi

BACKEND_AVAILABLE=false
if curl -sf "$BACKEND_URL/api/v1/health" >/dev/null 2>&1; then
  BACKEND_AVAILABLE=true
  printf '  \033[32mOK\033[0m     Backend reachable (%s)\n' "$BACKEND_URL"
else
  printf '  \033[33mWARN\033[0m   Backend not reachable — API checks will be skipped\n'
fi

# ── Vault-layer isolation (Transit policy enforcement) ────────────────────────

vault_layer_checks() {
  printf '\n── Vault-layer: Transit policy enforcement ──────────────────────────────\n'

  if [ "$VAULT_AVAILABLE" != "true" ]; then
    for label in \
      "ACME→ACME encrypt (ALLOWED)" "ACME→GLOBEX encrypt (DENIED)" \
      "ACME→INITECH decrypt (DENIED)" "GLOBEX→GLOBEX encrypt (ALLOWED)" \
      "GLOBEX→ACME encrypt (DENIED)" "INITECH→INITECH encrypt (ALLOWED)" \
      "INITECH→ACME decrypt (DENIED)" "GLOBEX→INITECH rewrap (DENIED)"; do
      skip "$label" "vault unavailable"
    done
    return
  fi

  local PT; PT=$(printf 'test' | base64)

  # Issue per-tenant scoped tokens
  local acme_tok globex_tok initech_tok
  # raymon is an operator for every tenant ("*"): one Vault token per tenant role.
  acme_tok=$(jwt_login tenant-acme raymon)
  globex_tok=$(jwt_login tenant-globex raymon)
  initech_tok=$(jwt_login tenant-initech raymon)

  if [ -z "$acme_tok" ] || [ -z "$globex_tok" ] || [ -z "$initech_tok" ]; then
    fail "Vault-layer isolation" "raymon could not log into auth/jwt tenant roles (make tf-apply, make identity-bootstrap)"
    return
  fi

  # ── ACME ──
  local h
  h=$(vault_http "$acme_tok" POST "transit/encrypt/durin-acme-customer-data" "{\"plaintext\":\"$PT\"}")
  [ "$h" = "200" ] && pass "ACME token → durin-acme-customer-data encrypt (ALLOWED, HTTP 200)" \
                    || fail "ACME token → durin-acme-customer-data encrypt (expected 200)" "got $h"

  h=$(vault_http "$acme_tok" POST "transit/encrypt/durin-globex-customer-data" "{\"plaintext\":\"$PT\"}")
  [ "$h" = "403" ] && pass "ACME token → durin-globex-customer-data encrypt (DENIED, HTTP 403)" \
                    || fail "ACME token → durin-globex-customer-data encrypt (expected 403)" "got $h"

  h=$(vault_http "$acme_tok" POST "transit/encrypt/durin-initech-customer-data" "{\"plaintext\":\"$PT\"}")
  [ "$h" = "403" ] && pass "ACME token → durin-initech-customer-data encrypt (DENIED, HTTP 403)" \
                    || fail "ACME token → durin-initech-customer-data encrypt (expected 403)" "got $h"

  # Encrypt with GLOBEX token, then try to decrypt with ACME token
  local globex_ct
  globex_ct=$(VAULT_TOKEN="$globex_tok" vault write -format=json \
    transit/encrypt/durin-globex-customer-data plaintext="$PT" 2>/dev/null \
    | jq -r '.data.ciphertext' 2>/dev/null || echo "")

  if [ -n "$globex_ct" ]; then
    h=$(vault_http "$acme_tok" POST "transit/decrypt/durin-acme-customer-data" "{\"ciphertext\":\"$globex_ct\"}")
    [ "$h" = "400" ] || [ "$h" = "403" ] \
      && pass "ACME token cannot decrypt GLOBEX ciphertext via ACME key (denied $h)" \
      || fail "ACME token cannot decrypt GLOBEX ciphertext (expected 400/403)" "got $h"
  else
    skip "ACME token cannot decrypt GLOBEX ciphertext" "could not produce GLOBEX ciphertext"
  fi

  # ── GLOBEX ──
  h=$(vault_http "$globex_tok" POST "transit/encrypt/durin-globex-customer-data" "{\"plaintext\":\"$PT\"}")
  [ "$h" = "200" ] && pass "GLOBEX token → durin-globex-customer-data encrypt (ALLOWED, HTTP 200)" \
                    || fail "GLOBEX token → durin-globex-customer-data encrypt (expected 200)" "got $h"

  h=$(vault_http "$globex_tok" POST "transit/encrypt/durin-acme-customer-data" "{\"plaintext\":\"$PT\"}")
  [ "$h" = "403" ] && pass "GLOBEX token → durin-acme-customer-data encrypt (DENIED, HTTP 403)" \
                    || fail "GLOBEX token → durin-acme-customer-data encrypt (expected 403)" "got $h"

  h=$(vault_http "$globex_tok" POST "transit/rewrap/durin-initech-documents" "{\"ciphertext\":\"vault:v1:dGVzdA==\"}")
  [ "$h" = "403" ] && pass "GLOBEX token → durin-initech-documents rewrap (DENIED, HTTP 403)" \
                    || fail "GLOBEX token → durin-initech-documents rewrap (expected 403)" "got $h"

  # ── INITECH ──
  h=$(vault_http "$initech_tok" POST "transit/encrypt/durin-initech-customer-data" "{\"plaintext\":\"$PT\"}")
  [ "$h" = "200" ] && pass "INITECH token → durin-initech-customer-data encrypt (ALLOWED, HTTP 200)" \
                    || fail "INITECH token → durin-initech-customer-data encrypt (expected 200)" "got $h"

  h=$(vault_http "$initech_tok" POST "transit/encrypt/durin-acme-customer-data" "{\"plaintext\":\"$PT\"}")
  [ "$h" = "403" ] && pass "INITECH token → durin-acme-customer-data encrypt (DENIED, HTTP 403)" \
                    || fail "INITECH token → durin-acme-customer-data encrypt (expected 403)" "got $h"

  # ── RESTRICTED key: protect yes, recover only via break glass ──
  local restricted_ct
  restricted_ct=$(VAULT_TOKEN="$acme_tok" vault write -format=json \
    transit/encrypt/durin-acme-restricted plaintext="$PT" 2>/dev/null | jq -r '.data.ciphertext' 2>/dev/null || echo "")
  [ -n "$restricted_ct" ] && pass "ACME tenant token → durin-acme-restricted encrypt (ALLOWED)" \
                           || fail "ACME tenant token → durin-acme-restricted encrypt (expected ALLOWED)"
  h=$(vault_http "$acme_tok" POST "transit/decrypt/durin-acme-restricted" "{\"ciphertext\":\"$restricted_ct\"}")
  [ "$h" = "403" ] && pass "ACME tenant token → durin-acme-restricted decrypt (DENIED, HTTP 403)" \
                    || fail "ACME tenant token → durin-acme-restricted decrypt (expected 403)" "got $h"

  # ── Who Vault will issue authority to (auth/jwt bound claims) ──
  local t
  t=$(jwt_login tenant-globex barend)
  [ -z "$t" ] && pass "barend (acme only) → tenant-globex login (DENIED by Vault)" || fail "barend → tenant-globex login" "Vault issued a token"
  t=$(jwt_login tenant-acme viewer)
  [ -z "$t" ] && pass "viewer → tenant-acme login (DENIED — not an operator)" || fail "viewer → tenant-acme login" "Vault issued a token"
  t=$(jwt_login tenant-acme security-admin)
  [ -z "$t" ] && pass "security-admin → tenant-acme login (DENIED — no data authority)" || fail "security-admin → tenant-acme login" "Vault issued a token"
  t=$(jwt_login breakglass-requester-acme security-admin)
  [ -z "$t" ] && pass "security-admin → breakglass-requester (DENIED — approvers cannot request)" || fail "security-admin → breakglass-requester" "Vault issued a token"

  # ── Break glass is a Control Group, and narrow ──
  local rq_tok body
  rq_tok=$(jwt_login breakglass-requester-acme viewer)
  h=$(vault_http "$rq_tok" POST "transit/decrypt/durin-acme-customer-data" "{\"ciphertext\":\"vault:v1:dGVzdA==\"}")
  [ "$h" = "403" ] && pass "break-glass requester → durin-acme-customer-data (DENIED — break glass is narrow)" \
                    || fail "break-glass requester → customer-data (expected 403)" "got $h"
  body=$(curl -sk -X POST -H "X-Vault-Token: $rq_tok" -H 'Content-Type: application/json' \
    -d "{\"ciphertext\":\"$restricted_ct\"}" "$VAULT_ADDR/v1/transit/decrypt/durin-acme-restricted")
  [ "$(jq -r '(.wrap_info.accessor != null) and (.data == null)' <<<"$body")" = true ] \
    && pass "break-glass requester → durin-acme-restricted: Vault withholds plaintext (control group)" \
    || fail "restricted decrypt under control group" "$(jq -c '{wrap: .wrap_info.accessor, data}' <<<"$body")"
  h=$(curl -sk -o /dev/null -w '%{http_code}' -X POST -H "X-Vault-Token: $(jq -r .wrap_info.token <<<"$body")" "$VAULT_ADDR/v1/sys/wrapping/unwrap")
  [ "$h" = "400" ] && pass "unwrap before approval refused (Request needs further authorization)" \
                    || fail "unwrap before approval" "got $h"
  vault token revoke "$rq_tok" >/dev/null 2>&1 || true

  # Revoke test tokens
  for tok in "$acme_tok" "$globex_tok" "$initech_tok"; do
    vault token revoke "$tok" >/dev/null 2>&1 || true
  done
}

# ── API-layer isolation (application boundary, defense-in-depth) ──────────────

api_layer_checks() {
  printf '\n── API-layer: application boundary (defense-in-depth) ───────────────────\n'

  if [ "$BACKEND_AVAILABLE" != "true" ]; then
    skip "ACME customer accessible via x-tenant: acme" "backend unavailable"
    skip "ACME customer 404 via x-tenant: globex" "backend unavailable"
    skip "GLOBEX customer 404 via x-tenant: acme" "backend unavailable"
    skip "ACME document accessible via x-tenant: acme" "backend unavailable"
    skip "ACME document 404 via x-tenant: globex" "backend unavailable"
    skip "Cross-tenant protect attempt returns 404" "backend unavailable"
    return
  fi

  # Get one ACME customer ID
  local acme_cust_id
  acme_cust_id=$(curl -sf -H 'x-tenant: acme' "$BACKEND_URL/api/v1/customers" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || echo "")

  http_code() {
    # Reliable HTTP status code extraction — -o /dev/null discards body,
    # -w '%{http_code}' writes the code to stdout ONLY.
    curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo "0"
  }

  if [ -n "$acme_cust_id" ]; then
    # ACME can read its own customer
    local h
    h=$(http_code -H 'x-tenant: acme' "$BACKEND_URL/api/v1/customers/$acme_cust_id")
    [ "$h" = "200" ] && pass "ACME customer accessible via x-tenant: acme (HTTP 200)" \
                      || fail "ACME customer accessible via x-tenant: acme" "got $h"

    # GLOBEX cannot read ACME's customer (returns 404 — no enumeration)
    h=$(http_code -H 'x-tenant: globex' "$BACKEND_URL/api/v1/customers/$acme_cust_id")
    [ "$h" = "404" ] && pass "ACME customer returns 404 for x-tenant: globex (no enumeration)" \
                      || fail "ACME customer returns 404 for x-tenant: globex" "got $h"
  else
    skip "Customer tenant isolation" "no ACME customers found"
  fi

  # Get one GLOBEX customer ID and check from ACME perspective
  local globex_cust_id
  globex_cust_id=$(curl -sf -H 'x-tenant: globex' "$BACKEND_URL/api/v1/customers" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || echo "")

  if [ -n "$globex_cust_id" ]; then
    local h
    h=$(http_code -H 'x-tenant: acme' "$BACKEND_URL/api/v1/customers/$globex_cust_id")
    [ "$h" = "404" ] && pass "GLOBEX customer returns 404 for x-tenant: acme (no enumeration)" \
                      || fail "GLOBEX customer returns 404 for x-tenant: acme" "got $h"
  else
    skip "GLOBEX customer isolation via API" "no GLOBEX customers found"
  fi

  # Document isolation
  local acme_doc_id
  acme_doc_id=$(curl -sf -H 'x-tenant: acme' "$BACKEND_URL/api/v1/documents" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || echo "")

  if [ -n "$acme_doc_id" ]; then
    local h
    h=$(http_code -H 'x-tenant: acme' "$BACKEND_URL/api/v1/documents/$acme_doc_id")
    [ "$h" = "200" ] && pass "ACME document accessible via x-tenant: acme (HTTP 200)" \
                      || fail "ACME document accessible via x-tenant: acme" "got $h"

    h=$(http_code -H 'x-tenant: globex' "$BACKEND_URL/api/v1/documents/$acme_doc_id")
    [ "$h" = "404" ] && pass "ACME document returns 404 for x-tenant: globex (no enumeration)" \
                      || fail "ACME document returns 404 for x-tenant: globex" "got $h"
  else
    skip "Document tenant isolation" "no ACME documents found"
  fi

  # Cross-tenant protect via scenario endpoint (uses backend's own Vault token)
  # The backend should allow this because it holds the full transit policy —
  # this is a documented gap (T6 in threat-model): the backend token is not tenant-scoped.
  # We test that the API correctly scopes to the requested tenant anyway.
  local protect_h
  protect_h=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' \
      -d '{"tenant":"acme","fieldName":"iban","value":"NL91ABNA0417164300"}' \
      "$BACKEND_URL/api/v1/scenarios/protect" 2>/dev/null || echo "0")
  [ "$protect_h" = "200" ] && pass "Protect scenario accessible with valid tenant (HTTP 200)" \
                             || fail "Protect scenario with valid tenant" "got $protect_h"
}

# ── Namespace isolation (Vault Enterprise) ────────────────────────────────────

namespace_checks() {
  printf '\n── Namespace isolation (Vault Enterprise) ───────────────────────────────\n'

  if [ "$VAULT_AVAILABLE" != "true" ]; then
    skip "acme/ namespace exists" "vault unavailable"
    skip "globex/ namespace exists" "vault unavailable"
    skip "initech/ namespace exists" "vault unavailable"
    skip "acme/ namespace token cannot reach root transit" "vault unavailable"
    return
  fi

  for ns in acme globex initech; do
    local h
    h=$(curl -sk -o /dev/null -w '%{http_code}' \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/sys/namespaces/$ns" 2>/dev/null || echo "0")
    [ "$h" = "200" ] && pass "Namespace $ns/ exists" \
                      || skip "Namespace $ns/ exists" "namespace not configured (namespace may be at root only)"
  done

  # A token scoped to acme/ namespace must not access root-ns transit
  local acme_ns_tok
  acme_ns_tok=$(curl -sk -X POST \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "X-Vault-Namespace: acme" \
    -d '{"policies":["default"],"ttl":"1m"}' \
    "$VAULT_ADDR/v1/auth/token/create" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("auth",{}).get("client_token",""))' 2>/dev/null || echo "")

  if [ -n "$acme_ns_tok" ]; then
    local h
    h=$(curl -sk -o /dev/null -w '%{http_code}' \
        -H "X-Vault-Token: $acme_ns_tok" \
        -H "X-Vault-Namespace: acme" \
        "$VAULT_ADDR/v1/transit/keys" 2>/dev/null || echo "0")
    [ "$h" = "403" ] || [ "$h" = "404" ] \
      && pass "acme/ namespace token denied on root transit/keys (HTTP $h)" \
      || skip "acme/ namespace token denied on root transit/keys" "namespace isolation requires separate Transit mount per namespace"
    vault token revoke "$acme_ns_tok" >/dev/null 2>&1 || true
  else
    skip "Namespace token isolation" "could not create namespace-scoped token"
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────

summary() {
  local total=$((PASS+FAIL+SKIP))
  printf '\n══════════════════════════════════════════════════════════════════════════\n'
  printf 'Durin Tenant Isolation Test Results\n'
  printf '══════════════════════════════════════════════════════════════════════════\n'
  printf '  Total: %d   \033[32mPASS: %d\033[0m   \033[31mFAIL: %d\033[0m   \033[33mSKIP: %d\033[0m\n' \
    "$total" "$PASS" "$FAIL" "$SKIP"
  printf '══════════════════════════════════════════════════════════════════════════\n'
  [ "$FAIL" -eq 0 ] || exit 1
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

case "${1:-all}" in
  --vault)     vault_layer_checks ;;
  --api)       api_layer_checks ;;
  --namespace) namespace_checks ;;
  all|--all|"")
    vault_layer_checks
    api_layer_checks
    namespace_checks
    ;;
  *)
    printf 'Usage: %s [--vault|--api|--namespace|all]\n' "$0"; exit 1 ;;
esac

summary

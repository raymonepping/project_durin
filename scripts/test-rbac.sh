#!/usr/bin/env bash
# scripts/test-rbac.sh — RBAC with real logins (prompts/security/17_01 + 17_02).
#
# Every request carries a real Keycloak access token for an LDAP user:
#   raymon (operator, *), barend (operator, acme), security-admin (*), viewer (acme, globex)
#
# Checks the Prompt 17 surface matrix, tenant-claim enforcement, "authenticated
# is not decryption authority", separation of duties, audit attribution, header
# spoofing, and JWT negatives. Requires DURIN_AUTH_ENABLED=true.
#
# Light mutation: one protect, one key rotation (acme customer-data), a few
# break-glass requests, compromise on/off. `make reset` restores baseline.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/lib/durin-auth.sh
source "$root/scripts/lib/durin-auth.sh"
B="$DURIN_BACKEND_BASE/api/v1"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s  (%s)\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi; }
section() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

# as <uid> METHOD PATH [JSON] [tenant]  → prints HTTP status; body in $BODY_FILE
BODY_FILE=$(mktemp); trap 'rm -f "$BODY_FILE"' EXIT
as() { # uid METHOD PATH [JSON] [tenant] [extra curl args...]
  local uid=$1 m=$2 p=$3 d=${4:-} t=${5:-acme} tok
  shift $(( $# < 5 ? $# : 5 ))
  tok=$(durin_token "$uid") || { echo 000; return; }
  if [ -n "$d" ]; then
    command curl -s -o "$BODY_FILE" -w '%{http_code}' -X "$m" "$B$p" -H "Authorization: Bearer $tok" \
      -H "x-tenant: $t" -H 'content-type: application/json' -d "$d" "$@"
  else
    command curl -s -o "$BODY_FILE" -w '%{http_code}' -X "$m" "$B$p" -H "Authorization: Bearer $tok" -H "x-tenant: $t" "$@"
  fi
}
body() { jq -r "$1" "$BODY_FILE" 2>/dev/null; }

durin_auth_enabled || { echo "backend is in demo mode (DURIN_AUTH_ENABLED=false) — nothing to test" >&2; exit 2; }

# Fixtures
as raymon GET /customers >/dev/null; CUST=$(body '.data[0].id')
as raymon GET /documents >/dev/null
RESTRICTED=$(body '[.data[]|select(.classification=="RESTRICTED")][0].id')
NORMAL=$(body '[.data[]|select(.classification!="RESTRICTED")][0].id')

section "Authentication"
check "no token → 401" "$(command curl -s -o /dev/null -w '%{http_code}' -H 'x-tenant: acme' "$B/customers")" "401"
TOK=$(durin_token raymon)
TAMPERED="$(cut -d. -f1 <<<"$TOK").$(cut -d. -f2 <<<"$TOK" | tr 'A-Za-z' 'B-ZAb-za').$(cut -d. -f3 <<<"$TOK")"
check "tampered payload → 401" "$(command curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TAMPERED" -H 'x-tenant: acme' "$B/customers")" "401"
NONE_HDR=$(printf '{"alg":"none","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=\n')
check "alg: none → 401" "$(command curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $NONE_HDR.$(cut -d. -f2 <<<"$TOK")." -H 'x-tenant: acme' "$B/customers")" "401"
KC_ADMIN_PW=$(_durin_vault kv get -mount=secret -field=value durin/identity/keycloak-admin-password)
MASTER=$(command curl -s -X POST "$DURIN_KC_URL/realms/master/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
  --data-urlencode username=admin --data-urlencode "password=$KC_ADMIN_PW" | jq -r .access_token)
check "valid token from another realm (master admin) → 401" \
  "$(command curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $MASTER" -H 'x-tenant: acme' "$B/customers")" "401"
check "health stays open (liveness)" "$(command curl -s -o /dev/null -w '%{http_code}' "$B/health")" "200"

section "Surface matrix (Prompt 17) — viewer / operator / security-admin"
row() { # label method path json  expect_viewer expect_operator expect_secadmin
  local label=$1 m=$2 p=$3 d=$4
  check "$label — viewer"         "$(as viewer "$m" "$p" "$d")"         "$5"
  check "$label — operator"       "$(as raymon "$m" "$p" "$d")"         "$6"
  check "$label — security-admin" "$(as security-admin "$m" "$p" "$d")" "$7"
}
row "scenario state"       GET  /scenarios/state "" 200 200 200
row "audit log"            GET  /audit "" 200 200 200
row "database inspector"   GET  "/database/customers/$CUST" "" 200 200 200
row "customers (read)"     GET  /customers "" 200 200 200
row "Vault cluster status" GET  /vault/status "" 200 200 200
row "documents (read)"     GET  /documents "" 200 200 200
row "PROTECT scenario"     POST /scenarios/protect '{"field":"iban","value":"NL91ABNA0417164300"}' 403 200 403
row "RECOVER scenario"     POST /scenarios/recover '{"field":"iban"}' 403 200 403
row "isolation probe"      POST /scenarios/isolation-probe '{"targetTenant":"globex"}' 403 200 403
check "COMPROMISE scenario — viewer"         "$(as viewer POST /scenarios/compromise '{}')" "403"
check "COMPROMISE scenario — security-admin" "$(as security-admin POST /scenarios/compromise '{}')" "403"
check "COMPROMISE scenario — operator"       "$(as raymon POST /scenarios/compromise '{}')" "200"
as raymon DELETE /scenarios/compromise >/dev/null
check "SHIELD/FORTIFY — viewer"              "$(as viewer POST /scenarios/fortify '{}')" "403"
check "SHIELD/FORTIFY — security-admin"      "$(as security-admin POST /scenarios/fortify '{}')" "403"
check "reset — viewer"                       "$(as viewer DELETE /scenarios/reset)" "403"
check "key rotation — viewer"                "$(as viewer POST /transit/keys/durin-acme-customer-data/rotate '{}')" "403"
check "key rotation — security-admin"        "$(as security-admin POST /transit/keys/durin-acme-customer-data/rotate '{}')" "403"
check "key rotation — operator"              "$(as raymon POST /transit/keys/durin-acme-customer-data/rotate '{}')" "200"
check "customer create — viewer"             "$(as viewer POST /customers '{"name":"RBAC Probe"}')" "403"

section "Authenticated is not decryption authority"
as viewer GET "/customers/$CUST" >/dev/null
check "viewer: customer detail without plaintext" "$(body '.meta.recovered')/$(body '.data.iban')" "false/null"
as raymon GET "/customers/$CUST" >/dev/null
check "operator: customer detail recovered"       "$(body '.meta.recovered')/$(body '.data.iban|length>0')" "true/true"
check "viewer: document content → 403"            "$(as viewer GET "/documents/$NORMAL/content")" "403"
check "operator: document content → 200"          "$(as raymon GET "/documents/$NORMAL/content")" "200"
check "operator: RESTRICTED content → 403 (Vault)" "$(as raymon GET "/documents/$RESTRICTED/content")/$(body .vault.status)" "403/403"

section "Tenant scope (durin_tenants claim)"
check "barend (acme) → acme customers"      "$(as barend GET /customers '' acme)" "200"
check "barend (acme) → globex customers"    "$(as barend GET /customers '' globex)/$(body .error)" "403/tenant_mismatch"
check "barend (acme) → globex protect"      "$(as barend POST /scenarios/protect '{"field":"iban","value":"X1"}' globex)" "403"
check "viewer (acme,globex) → globex"       "$(as viewer GET /customers '' globex)" "200"
check "viewer (acme,globex) → initech"      "$(as viewer GET /customers '' initech)" "403"
as barend GET /tenants >/dev/null
check "barend sees only its tenants"        "$(body '[.data[].slug]|join(",")')" "acme"
as barend GET /vault/status >/dev/null
check "Vault status: keys limited to the caller's tenants" "$(body '.data.transitKeys|keys|join(",")')" "acme"
as viewer GET /break-glass/all >/dev/null
check "viewer's break-glass list excludes initech" "$(body '[.data[].tenant_slug]|map(select(.=="initech"))|length')" "0"

section "Break glass with real identities"
check "viewer may request"                  "$(as viewer POST /break-glass/request "{\"resource_id\":\"$RESTRICTED\",\"reason\":\"Viewer escalation test\"}")" "201"
V_REQ=$(body .data.id)
check "request attributed to the token user" "$(body .data.requested_by)" "viewer"
check "operator cannot approve (role)"      "$(as raymon POST "/break-glass/$V_REQ/approve" '{}')" "403"
check "x-durin-actor cannot spoof identity" \
  "$(tok=$(durin_token raymon); command curl -s -o /dev/null -w '%{http_code}' -X POST "$B/break-glass/$V_REQ/approve" -H "Authorization: Bearer $tok" -H 'x-durin-actor: security-admin')" "403"
check "security-admin approves"             "$(as security-admin POST "/break-glass/$V_REQ/approve" '{}')" "200"
check "approval attributed to security-admin" "$(body .data.approved_by)" "security-admin"
check "approval happened in Vault"           "$(body .data.vault.mechanism)/$(body .data.vault.approved)" "control-group/true"
check "viewer (requester) redeems once"     "$(as viewer GET "/documents/$RESTRICTED/content" "" acme -H "x-break-glass-request: $V_REQ")" "200"
check "second redemption refused"           "$(as viewer GET "/documents/$RESTRICTED/content" "" acme -H "x-break-glass-request: $V_REQ")" "403"
check "security-admin cannot request (Vault)" "$(as security-admin POST /break-glass/request "{\"resource_id\":\"$RESTRICTED\",\"reason\":\"Self approval test\"}")/$(body .error)" "403/vault_denied"
as raymon POST /break-glass/request "{\"resource_id\":\"$RESTRICTED\",\"reason\":\"Operator request\"}" >/dev/null
O_REQ=$(body .data.id)
check "operator (requester) cannot approve own request" "$(as raymon POST "/break-glass/$O_REQ/approve" '{}')" "403"
check "only the requester can redeem"       "$(as barend GET "/documents/$RESTRICTED/content" "" acme -H "x-break-glass-request: $O_REQ")/$(body .error)" "403/break_glass_not_requester"
as security-admin POST "/break-glass/$O_REQ/deny" '{}' >/dev/null

section "Audit attribution"
as raymon POST /scenarios/protect '{"field":"payment_info","value":"VISA-4111-1111-1111"}' >/dev/null
as viewer GET '/audit?operation=PROTECT&limit=1' >/dev/null
check "PROTECT attributed to raymon"        "$(body '.data[0].actor')" "raymon"
as viewer GET '/audit?operation=BREAK_GLASS_APPROVED&result=ALLOWED&limit=1' >/dev/null
check "BREAK_GLASS_APPROVED by security-admin" "$(body '.data[0].actor')" "security-admin"
as viewer GET '/audit?operation=RECOVER&limit=1' >/dev/null
check "RECOVER ran on a Vault token issued to the user" "$(body '.data[0].metadata.authority.source')/$(body '.data[0].metadata.authority.user')" "auth/jwt/$(body '.data[0].actor')"

printf '\n\033[1mRBAC: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

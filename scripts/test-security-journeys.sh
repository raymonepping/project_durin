#!/usr/bin/env bash
# scripts/test-security-journeys.sh — end-to-end security journeys (lead prompt §28)
#
# Exercises the running stack through the API and verifies every verdict with
# Vault and PostgreSQL directly:
#
#   privileges      backend Vault token = broker only; DB user = durin_app only
#   protect         plaintext → Transit → ciphertext → PostgreSQL (no plaintext at rest)
#   recover         authorised request → plaintext
#   unauthorised    RESTRICTED on the normal path → Vault 403
#   compromise      stolen ciphertext + no token → Vault 403
#   isolation       tenant A authority → tenant B key → Vault 403
#   break glass     denied → approved (not by requester) → allowed once → denied;
#                   revoke + Vault token actually gone
#   rotation        old ciphertext recoverable; new encryption on current version
#   fortification   stolen ciphertext recoverable by the app before, DENIED after
#   audit           evidence recorded; audit_events append-only for the app role
#
# MUTATING: rotates Transit keys and rewrites demo data. Ends with reset + seed
# so the demo is left at baseline. Requires podman, curl, jq and the vault CLI.
#
# Usage: ./scripts/test-security-journeys.sh [--keep]   (--keep: skip final reset)
set -uo pipefail

# Real OIDC tokens when the backend enforces auth; pass-through in demo mode.
# shellcheck source=scripts/lib/durin-auth.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib/durin-auth.sh"

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
B="${DURIN_BACKEND_URL:-http://localhost:3001}/api/v1"
export VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18300}"
export VAULT_CACERT="${VAULT_CACERT:-$root/vault-tls/ca-chain.pem}"
export VAULT_TOKEN="${VAULT_TOKEN:-$(jq -r .root_token "$root/.secrets/vault/cluster-init.json" 2>/dev/null)}"
PGUSER_MGMT=$(grep -E '^POSTGRES_USER=' "$root/.env" | cut -d= -f2-)
PGDB=$(grep -E '^POSTGRES_DB=' "$root/.env" | cut -d= -f2-)
KEEP=false; [ "${1:-}" = "--keep" ] && KEEP=true

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s  (%s)\n' "$1" "$2"; }
check() { # check "<name>" "<actual>" "<expected>"
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi
}
section() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

sql() { podman exec -i durin-postgres psql -X -At -U "$PGUSER_MGMT" -d "$PGDB" -c "$1" 2>&1; }
api() { # api METHOD PATH [JSON] [extra curl args...]  → body, status on last line
  local m=$1 p=$2 d=${3:-}; shift 3 2>/dev/null || shift $#
  if [ -n "$d" ]; then
    curl -s -w '\n%{http_code}' -X "$m" "$B$p" -H 'content-type: application/json' -H 'x-tenant: acme' "$@" -d "$d"
  else
    curl -s -w '\n%{http_code}' -X "$m" "$B$p" -H 'x-tenant: acme' "$@"
  fi
}
body()   { sed '$d' <<<"$1"; }
status() { tail -n1 <<<"$1"; }
jb()     { body "$1" | jq -r "$2"; }

for bin in podman curl jq vault; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 2; }
done
# Cryptographic authority is issued by Vault to people (auth/jwt), so these
# journeys need real identities.
durin_auth_enabled || { echo "backend is in demo mode — enable DURIN_AUTH_ENABLED (make identity-bootstrap)" >&2; exit 2; }

# ── Baseline ──────────────────────────────────────────────────────────────────
section "Baseline"
curl -s -X DELETE "$B/scenarios/reset" >/dev/null
r=$(curl -s -X POST "$B/scenarios/seed"); check "seed demo data" "$(jq -r .data.message <<<"$r")" "Seeded"

# ── Privileges ────────────────────────────────────────────────────────────────
section "Privileges — the backend holds no cryptographic authority of its own"
h=$(curl -s "$B/health")
check "backend Vault token policies" "$(jq -c '.vault.policies|sort' <<<"$h")" '["default","durin-backend","durin-database"]'
dbuser=$(jq -r .db.username <<<"$h")
check "DB user is a member of durin_app"            "$(sql "select pg_has_role('$dbuser','durin_app','MEMBER')")" "t"
check "DB user cannot SET ROLE to the superuser"    "$(sql "select pg_has_role('$dbuser','$PGUSER_MGMT','MEMBER')")" "f"
check "DB user has no CREATE on schema public"      "$(sql "select has_schema_privilege('$dbuser','public','CREATE')")" "f"
check "all tables owned by durin_owner"             "$(sql "select count(*) from pg_tables where schemaname='public' and tableowner<>'durin_owner'")" "0"
check "DB user owns no objects (revocable by Vault)" "$(sql "select count(*) from pg_class c join pg_roles r on r.oid=c.relowner where r.rolname like 'v-%'")" "0"
T=$(vault token create -policy=durin-backend -ttl=2m -field=token)
check "broker cannot encrypt directly"   "$(vault token capabilities "$T" transit/encrypt/durin-acme-customer-data)" "deny"
check "broker cannot decrypt directly"   "$(vault token capabilities "$T" transit/decrypt/durin-acme-customer-data)" "deny"
check "broker cannot mint plaintext data keys" "$(vault token capabilities "$T" transit/datakey/plaintext/durin-acme-customer-data)" "deny"
check "broker cannot write policies"     "$(vault token capabilities "$T" sys/policies/acl/evil)" "deny"
check "broker cannot mint any token"     "$(vault token capabilities "$T" auth/token/create)" "deny"
# The metadata read glob also matches /rotate and /config; read on those POST-only
# endpoints grants nothing — the check is that no write capability exists.
check "broker cannot rotate keys"        "$(vault token capabilities "$T" transit/keys/durin-acme-customer-data/rotate | grep -cE 'update|create|sudo')" "0"
check "broker cannot change key config"  "$(vault token capabilities "$T" transit/keys/durin-acme-customer-data/config | grep -cE 'update|create|sudo')" "0"
vault token revoke "$T" >/dev/null
r=$(api POST /scenarios/recover '{"field":"iban"}')
check "recover ran under a Vault token issued to the user" "$(jb "$r" .data.authority.source)/$(jb "$r" .data.authority.user)" "auth/jwt/raymon"

# ── Protect ───────────────────────────────────────────────────────────────────
section "PROTECT — plaintext → Vault Transit → ciphertext → PostgreSQL"
r=$(api POST /scenarios/protect '{"field":"iban","value":"NL02RABO0123456789"}')
check "protect returns 200" "$(status "$r")" "200"
CT=$(jb "$r" .data.ciphertext); CID=$(jb "$r" .data.customerId)
case "$CT" in vault:v*) pass "ciphertext has vault:vN: prefix";; *) fail "ciphertext has vault:vN: prefix" "$CT";; esac
check "row read back from PostgreSQL is the ciphertext" "$(sql "select ciphertext from protected_values where resource_id='$CID' and field_name='iban'")" "$CT"
check "protect ran under the user's Vault tenant authority" "$(jb "$r" .data.authority.role)/$(jb "$r" .data.authority.source)" "tenant-acme/auth/jwt"
check "no plaintext in protected_values" "$(sql "select count(*) from protected_values where ciphertext not like 'vault:v%'")" "0"
check "seed IBAN absent from a full database dump" \
  "$(podman exec durin-postgres pg_dump -U "$PGUSER_MGMT" -d "$PGDB" | grep -c 'NL91ABNA0417164300')" "0"

# ── Recover ───────────────────────────────────────────────────────────────────
section "RECOVER — authorised request → Vault → plaintext"
r=$(api POST /scenarios/recover "{\"field\":\"iban\",\"customerId\":\"$CID\"}")
check "recover returns the original plaintext" "$(jb "$r" .data.plaintext)" "NL02RABO0123456789"

# ── Unauthorised recovery ─────────────────────────────────────────────────────
section "UNAUTHORISED RECOVERY — RESTRICTED data on the normal path"
DOC=$(jb "$(api GET /documents)" '[.data[]|select(.classification=="RESTRICTED")][0].id')
r=$(api GET "/documents/$DOC/content")
check "normal access to RESTRICTED document → 403" "$(status "$r")" "403"
check "denial came from Vault"                     "$(jb "$r" .vault.status)" "403"
check "response points to break glass"             "$(jb "$r" .breakGlassRequired)" "true"
NON=$(jb "$(api GET /documents)" '[.data[]|select(.classification!="RESTRICTED")][0].id')
check "normal access to CONFIDENTIAL/INTERNAL document → 200" "$(status "$(api GET "/documents/$NON/content")")" "200"

# ── Compromise ────────────────────────────────────────────────────────────────
section "COMPROMISE — database access → ciphertext → no plaintext"
r=$(api POST /scenarios/compromise '{}')
check "compromise snapshot captured"             "$(jb "$r" '.data.attackerHas.ciphertexts > 0')" "true"
check "snapshot holds no plaintext"              "$(jb "$r" .data.attackerHas.plaintextSensitiveValues)" "0"
r=$(api POST /scenarios/compromise/decrypt-attempt '{"actor":"attacker"}')
check "attacker decrypt → DENIED"                "$(jb "$r" .data.result)" "DENIED"
check "Vault answered 403 to the tokenless request" "$(jb "$r" .data.vault.status)" "403"

# ── Tenant isolation ──────────────────────────────────────────────────────────
section "TENANT ISOLATION — tenant A authority → tenant B key"
r=$(api POST /scenarios/isolation-probe '{"targetTenant":"globex","operation":"encrypt"}')
check "acme → globex encrypt: Vault DENIED" "$(jb "$r" .data.result)/$(jb "$r" .data.vault.status)" "DENIED/403"
r=$(api POST /scenarios/isolation-probe '{"targetTenant":"initech","operation":"decrypt"}')
check "acme → initech decrypt: Vault DENIED" "$(jb "$r" .data.result)/$(jb "$r" .data.vault.status)" "DENIED/403"
r=$(curl -s -X POST "$B/scenarios/isolation-probe" -H 'content-type: application/json' -H 'x-tenant: globex' -d '{"targetTenant":"acme"}')
check "globex → acme encrypt: Vault DENIED" "$(jq -r .data.result <<<"$r")" "DENIED"
check "acme customer invisible under x-tenant: globex" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H 'x-tenant: globex' "$B/customers/$CID")" "404"

# ── Break glass ───────────────────────────────────────────────────────────────
section "BREAK GLASS — Vault Control Group: requested → approved in Vault → released once"
cg() { vault write -format=json sys/control-group/request accessor="$1" 2>/dev/null | jq -r '.data.approved'; }
r=$(api POST /break-glass/request "{\"resource_id\":\"$NON\",\"reason\":\"not restricted\"}")
check "request for non-RESTRICTED document refused" "$(jb "$r" .error)" "break_glass_not_required"
r=$(api POST /break-glass/request "{\"resource_id\":\"$DOC\",\"reason\":\"Approver as requester\"}" -H 'x-durin-actor: security-admin')
check "a security-admin cannot be a requester (Vault bound claims)" "$(status "$r")/$(jb "$r" .error)" "403/vault_denied"
r=$(api POST /break-glass/request "{\"resource_id\":\"$DOC\",\"reason\":\"Production incident investigation\"}" -H 'x-durin-actor: alice@acme.example')
check "request created by the requester's Vault identity" "$(status "$r")/$(jb "$r" .data.vault.mechanism)" "201/control-group"
BG=$(jb "$r" .data.id); WA=$(jb "$r" .data.vault.wrappingAccessor)
check "Vault: control group pending"           "$(cg "$WA")" "false"
check "redeem before approval → 403 pending"   "$(jb "$(api GET "/documents/$DOC/content" "" -H "x-break-glass-request: $BG" -H 'x-durin-actor: alice@acme.example')" .error)" "break_glass_pending"
check "the requester (an operator) cannot approve" "$(status "$(api POST "/break-glass/$BG/approve" '{}' -H 'x-durin-actor: alice@acme.example')")" "403"
r=$(api POST "/break-glass/$BG/approve" '{}' -H 'x-durin-actor: security-admin')
check "security-admin approves in Vault"       "$(status "$r")/$(jb "$r" .data.vault.approved)" "200/true"
check "Vault: control group approved"          "$(cg "$WA")" "true"
check "another identity cannot redeem"         "$(jb "$(api GET "/documents/$DOC/content" "" -H "x-break-glass-request: $BG" -H 'x-durin-actor: viewer')" .error)" "break_glass_not_requester"
r=$(api GET "/documents/$DOC/content" "" -H "x-break-glass-request: $BG" -H 'x-durin-actor: alice@acme.example')
check "requester redeems → 200 (Vault unwrap)" "$(status "$r")/$(jb "$r" .meta.breakGlass.mechanism)" "200/vault-control-group"
check "payload recovered"                      "$(jb "$r" '.data.payload|length > 0')" "true"
check "second redemption → 403"                "$(status "$(api GET "/documents/$DOC/content" "" -H "x-break-glass-request: $BG" -H 'x-durin-actor: alice@acme.example')")" "403"
vault token lookup -accessor "$WA" >/dev/null 2>&1 && gone=no || gone=yes
check "Vault: wrapping token consumed"         "$gone" "yes"
check "normal access restored (still denied)"  "$(status "$(api GET "/documents/$DOC/content")")" "403"
# revoke path
BG2=$(jb "$(api POST /break-glass/request "{\"resource_id\":\"$DOC\",\"reason\":\"Second investigation\"}" -H 'x-durin-actor: bob@acme.example')" .data.id)
api POST "/break-glass/$BG2/approve" '{}' -H 'x-durin-actor: security-admin' >/dev/null
check "revoke approved emergency access"       "$(status "$(api POST "/break-glass/$BG2/revoke" '{}' -H 'x-durin-actor: security-admin')")" "200"
check "revoked request cannot be redeemed"     "$(jb "$(api GET "/documents/$DOC/content" "" -H "x-break-glass-request: $BG2" -H 'x-durin-actor: bob@acme.example')" .error)" "break_glass_revoked"
# deny path
r=$(api POST /break-glass/request "{\"resource_id\":\"$DOC\",\"reason\":\"Third investigation\"}" -H 'x-durin-actor: carol@acme.example')
BG3=$(jb "$r" .data.id); WA3=$(jb "$r" .data.vault.wrappingAccessor)
check "deny pending request"                   "$(jb "$(api POST "/break-glass/$BG3/deny" '{}' -H 'x-durin-actor: security-admin')" .data.status)" "denied"
check "Vault: denied request never approved"   "$(cg "$WA3")" "false"

# ── Key rotation ──────────────────────────────────────────────────────────────
section "KEY ROTATION — old ciphertext recoverable, new encryption on current version"
OLDV=$(sql "select key_version from protected_values where resource_id='$CID' and field_name='iban'")
r=$(api POST /transit/keys/durin-acme-customer-data/rotate '{}')
NEWV=$(jb "$r" .data.currentVersion)
check "rotation advanced the key" "$([ "$NEWV" -gt "$OLDV" ] && echo yes)" "yes"
check "pre-rotation ciphertext still recoverable" \
  "$(jb "$(api POST /scenarios/recover "{\"field\":\"iban\",\"customerId\":\"$CID\"}")" .data.plaintext)" "NL02RABO0123456789"
check "new encryption uses current version" \
  "$(jb "$(api POST /scenarios/protect "{\"field\":\"tax_id\",\"value\":\"NL999999999B01\",\"customerId\":\"$CID\"}")" .data.keyVersion)" "$NEWV"

# ── Fortification ─────────────────────────────────────────────────────────────
section "SHIELD / FORTIFY — previously possible operation → DENIED by Vault"
check "before: app authority recovers stolen ciphertext" \
  "$(jb "$(api POST /scenarios/compromise/decrypt-attempt '{"actor":"application"}')" .data.result)" "ALLOWED"
r=$(api POST /scenarios/fortify '{}')
check "fortify returns 200"                 "$(status "$r")" "200"
check "fortify self-verification passed"    "$(jb "$r" .data.verification.passed)" "true"
check "all acme values rewrapped to current" \
  "$(sql "select count(*) from protected_values pv join tenants t on t.id=pv.tenant_id where t.slug='acme' and pv.key_version < (select max(key_version) from protected_values p2 where p2.key_name=pv.key_name)")" "0"
r=$(api POST /scenarios/compromise/decrypt-attempt '{"actor":"application"}')
check "after: stolen ciphertext → DENIED (version retired)" "$(jb "$r" .data.result)/$(jb "$r" .data.reason)" "DENIED/ciphertext_version_retired"
check "after: legitimate recovery still works" \
  "$(jb "$(api POST /scenarios/recover "{\"field\":\"iban\",\"customerId\":\"$CID\"}")" .data.plaintext)" "NL02RABO0123456789"

# ── Audit ─────────────────────────────────────────────────────────────────────
section "AUDIT — evidence recorded and append-only"
for op in PROTECT RECOVER ISOLATION_PROBE COMPROMISE_DECRYPT_ATTEMPT BREAK_GLASS_REQUEST BREAK_GLASS_APPROVED BREAK_GLASS_RECOVER BREAK_GLASS_REVOKED FORTIFY; do
  n=$(curl -s "$B/audit?operation=$op&limit=1" | jq '.data|length')
  check "audit has $op" "$n" "1"
done
check "Vault-sourced DENIED events recorded" "$(curl -s "$B/audit?result=DENIED&source=vault&limit=1" | jq '.data|length')" "1"
check "app role cannot DELETE audit_events" \
  "$(sql "begin; set local role durin_app; delete from audit_events; rollback;" | grep -c 'permission denied')" "1"
check "app role cannot UPDATE audit_events" \
  "$(sql "begin; set local role durin_app; update audit_events set result='ALLOWED'; rollback;" | grep -c 'permission denied')" "1"

# ── Restore ───────────────────────────────────────────────────────────────────
if ! $KEEP; then
  section "Restore baseline"
  curl -s -X DELETE "$B/scenarios/reset" >/dev/null
  check "reset + seed" "$(curl -s -X POST "$B/scenarios/seed" | jq -r .data.message)" "Seeded"
fi

printf '\n\033[1mSecurity journeys: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# scripts/test-authority.sh — identity-derived Vault authority (prompts/improvements/01_04).
#
# Proves, with real Vault calls (not only capability lookups):
#   1. A compromised backend with nobody logged in can decrypt nothing:
#      a token with exactly the backend's policies fails every data, key and
#      token-minting operation.
#   2. Vault issues data authority only to a verified person: forged, foreign
#      or missing identity tokens are refused at auth/jwt/login.
#   3. Issued authority is short-lived and scoped to one tenant.
#   4. Vault's OWN audit log names the person behind a decrypt.
#
# Non-mutating (one protect via the API for the audit check).
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/lib/durin-auth.sh
source "$root/scripts/lib/durin-auth.sh"
export VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18300}"
export VAULT_CACERT="${VAULT_CACERT:-$root/vault-tls/ca-chain.pem}"
export VAULT_TOKEN="${VAULT_TOKEN:-$(jq -r .root_token "$root/.secrets/vault/cluster-init.json")}"
B="$DURIN_BACKEND_BASE/api/v1"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s  (%s)\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi; }
section() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
code() { # token METHOD path [json]
  local args=(-s -o /dev/null -w '%{http_code}' --cacert "$VAULT_CACERT" -X "$2")
  [ -n "$1" ] && args+=(-H "X-Vault-Token: $1")
  [ -n "${4:-}" ] && args+=(-H 'Content-Type: application/json' -d "$4")
  curl "${args[@]}" "$VAULT_ADDR/v1/$3"
}
login_code() { code "" POST auth/jwt/login "{\"role\":\"$1\",\"jwt\":\"$2\"}"; }

CT=$(podman exec durin-postgres psql -U durin -d durin_db -At -c \
  "select ciphertext from protected_values where key_name='durin-acme-customer-data' limit 1")
RCT=$(podman exec durin-postgres psql -U durin -d durin_db -At -c \
  "select ciphertext from protected_values where key_name='durin-acme-restricted' limit 1")

section "1. Compromised backend, nobody logged in"
BROKER=$(vault token create -policy=durin-backend -policy=durin-database -ttl=2m -field=token)
check "decrypt customer data"                "$(code "$BROKER" POST transit/decrypt/durin-acme-customer-data "{\"ciphertext\":\"$CT\"}")" "403"
check "decrypt RESTRICTED data"              "$(code "$BROKER" POST transit/decrypt/durin-acme-restricted "{\"ciphertext\":\"$RCT\"}")" "403"
check "encrypt"                              "$(code "$BROKER" POST transit/encrypt/durin-globex-customer-data '{"plaintext":"dGVzdA=="}')" "403"
check "mint a token"                         "$(code "$BROKER" POST auth/token/create '{"policies":["durin-transit-acme"]}')" "403"
check "rotate a key"                         "$(code "$BROKER" POST transit/keys/durin-acme-customer-data/rotate)" "403"
check "lower min_decryption_version"         "$(code "$BROKER" POST transit/keys/durin-acme-customer-data/config '{"min_decryption_version":1}')" "403"
check "authorise a control group"            "$(code "$BROKER" POST sys/control-group/authorize '{"accessor":"x"}')" "403"
check "read key METADATA (still allowed)"    "$(code "$BROKER" GET transit/keys/durin-acme-customer-data)" "200"
vault token revoke "$BROKER" >/dev/null

section "2. Vault verifies the person"
TOK=$(durin_token raymon)
check "raymon's real token → tenant-acme"    "$(login_code tenant-acme "$TOK")" "200"
TAMPERED="$(cut -d. -f1 <<<"$TOK").$(cut -d. -f2 <<<"$TOK" | tr 'A-Za-z' 'B-ZAb-za').$(cut -d. -f3 <<<"$TOK")"
check "tampered token refused"               "$(login_code tenant-acme "$TAMPERED")" "400"
NONE="$(printf '{"alg":"none","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=\n').$(cut -d. -f2 <<<"$TOK")."
check "alg:none token refused"               "$(login_code tenant-acme "$NONE")" "400"
KC_ADMIN_PW=$(_durin_vault kv get -mount=secret -field=value durin/identity/keycloak-admin-password)
MASTER=$(command curl -s -X POST "$DURIN_KC_URL/realms/master/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
  --data-urlencode username=admin --data-urlencode "password=$KC_ADMIN_PW" | jq -r .access_token)
check "Keycloak master-realm admin refused"  "$(login_code tenant-acme "$MASTER")" "400"
check "no token refused"                     "$(code "" POST auth/jwt/login '{"role":"tenant-acme"}')" "400"
check "barend (acme) → tenant-globex refused" "$(login_code tenant-globex "$(durin_token barend)")" "400"
check "viewer → tenant-acme refused"          "$(login_code tenant-acme "$(durin_token viewer)")" "400"

section "3. Issued authority is short-lived and scoped"
L=$(VAULT_TOKEN= vault write -format=json auth/jwt/login role=tenant-acme jwt="$TOK")
UT=$(jq -r .auth.client_token <<<"$L")
check "TTL ≤ 300 s"                          "$(jq -r '.auth.lease_duration <= 300' <<<"$L")" "true"
# Auth-method tokens are formally renewable, but the explicit max TTL is a hard
# ceiling that renewal can never extend.
check "hard ceiling: explicit max TTL 300 s" "$(VAULT_TOKEN="$UT" vault token lookup -format=json | jq -r .data.explicit_max_ttl)" "300"
check "policies = transit + keys for acme"   "$(jq -c '.auth.policies|sort' <<<"$L")" '["default","durin-keys-acme","durin-transit-acme"]'
check "Vault records the person"             "$(jq -r .auth.metadata.username <<<"$L")" "raymon"
check "acme data: allowed"                   "$(code "$UT" POST transit/decrypt/durin-acme-customer-data "{\"ciphertext\":\"$CT\"}")" "200"
check "globex key: denied"                   "$(code "$UT" POST transit/encrypt/durin-globex-customer-data '{"plaintext":"dGVzdA=="}')" "403"
check "acme RESTRICTED: denied"              "$(code "$UT" POST transit/decrypt/durin-acme-restricted "{\"ciphertext\":\"$RCT\"}")" "403"
vault token revoke "$UT" >/dev/null

section "4. Vault's own audit log names the person"
tok=$(durin_token barend)
command curl -s -o /dev/null -X POST "$B/scenarios/recover" -H "Authorization: Bearer $tok" \
  -H 'x-tenant: acme' -H 'content-type: application/json' -d '{"field":"iban"}'
sleep 1
leader=""
for n in 1 2 3; do
  podman exec "durin-vault_$n" sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status -format=json' 2>/dev/null \
    | jq -e '.is_self == true' >/dev/null && leader=$n
done
who=$(podman exec "durin-vault_$leader" sh -c 'tail -n 400 /vault/audit/vault-audit.log' 2>/dev/null \
  | jq -r 'select(.type=="response" and .request.path=="transit/decrypt/durin-acme-customer-data" and .error==null) | .auth.metadata.username // empty' 2>/dev/null | tail -1)
check "Vault audit: decrypt by barend (vault-$leader)" "$who" "barend"

printf '\n\033[1mAuthority: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

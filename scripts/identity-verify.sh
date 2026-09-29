#!/usr/bin/env bash
# scripts/identity-verify.sh — every Durin user can log in and carries the right
# roles, tenants and audience in a real Keycloak access token.
# prompts/security/17_02. Non-mutating.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/lib/durin-auth.sh
source "$root/scripts/lib/durin-auth.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s  (%s)\n' "$1" "$2"; }
claims() { python3 -c 'import sys,base64; p=sys.argv[1].split(".")[1]; print(base64.urlsafe_b64decode(p+"="*(-len(p)%4)).decode())' "$1"; }

printf '\n\033[1m── Identity: real logins (Keycloak realm durin, LDAP-federated)\033[0m\n'

issuer=$(command curl -s "$DURIN_KC_URL/realms/$DURIN_KC_REALM/.well-known/openid-configuration" | jq -r .issuer)
[ -n "$issuer" ] && [ "$issuer" != null ] && pass "realm published — issuer $issuer" || fail "realm published" "no discovery document"

# uid | expected durin role | expected tenants (sorted, comma)
while IFS='|' read -r uid role tenants; do
  tok=$(durin_token "$uid" 2>/tmp/durin-verify.err) || { fail "$uid logs in" "$(cat /tmp/durin-verify.err)"; continue; }
  c=$(claims "$tok")
  got_roles=$(jq -c '[.realm_access.roles[]? | select(startswith("durin-"))] | sort' <<<"$c")
  got_tenants=$(jq -r '[.durin_tenants[]?] | sort | join(",")' <<<"$c")
  aud_ok=$(jq -r '(.aud | if type=="array" then . else [.] end) | index("durin-backend") != null' <<<"$c")
  [ "$got_roles" = "[\"$role\"]" ] && pass "$uid → $role" || fail "$uid role" "got $got_roles"
  [ "$got_tenants" = "$tenants" ] && pass "$uid → tenants [$tenants]" || fail "$uid tenants" "got [$got_tenants]"
  [ "$aud_ok" = true ] && pass "$uid → aud includes durin-backend" || fail "$uid audience" "$(jq -c .aud <<<"$c")"
done <<'EOF'
raymon|durin-operator|*
barend|durin-operator|acme
security-admin|durin-security-admin|*
viewer|durin-viewer|acme,globex
EOF

bad=$(command curl -s -X POST "$DURIN_KC_URL/realms/$DURIN_KC_REALM/protocol/openid-connect/token" \
  -d grant_type=password -d client_id="$DURIN_KC_CLIENT" -d username=raymon -d password=wrong-password | jq -r .error)
[ "$bad" = invalid_grant ] && pass "wrong password refused (invalid_grant)" || fail "wrong password refused" "got $bad"

printf '\n\033[1mIdentity: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

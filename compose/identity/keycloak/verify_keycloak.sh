#!/bin/bash
# compose/identity/keycloak/verify_keycloak.sh
# Quick smoke-test for the Durin Keycloak realm.
set -euo pipefail

KC=/opt/keycloak/bin/kcadm.sh
KC_URL="${KC_INTERNAL_URL:-http://keycloak:8080}"
REALM=durin
CLIENT_ID=durin-backend
CONTAINER=durin-keycloak

"$KC" config credentials --server "$KC_URL" --realm master \
  --user "${KEYCLOAK_ADMIN:-admin}" --password "${KEYCLOAK_ADMIN_PASSWORD:-$(cat /run/secrets/keycloak-admin-password)}" >/dev/null 2>&1

pass=0
fail=0

check() {
  local desc="$1"
  shift
  if eval "$*" >/dev/null 2>&1; then
    echo "  ✓ $desc"
    pass=$((pass + 1))
  else
    echo "  ✗ $desc"
    fail=$((fail + 1))
  fi
}

check "realm exists" "$KC get realms/$REALM"
check "client exists" "$KC get clients -r $REALM -q clientId=$CLIENT_ID | grep -q '\"id\"'"
check "LDAP federation exists" "$KC get components -r $REALM -q name=durin-ldap | grep -q '\"id\"'"
check "group mapper exists" "$KC get components -r $REALM -q name=durin-groups | grep -q '\"id\"'"
check "role: durin-viewer" "$KC get-roles -r $REALM --rolename durin-viewer"
check "role: durin-operator" "$KC get-roles -r $REALM --rolename durin-operator"
check "role: durin-security-admin" "$KC get-roles -r $REALM --rolename durin-security-admin"

for user in raymon barend security-admin; do
  check "user synced: $user" \
    "podman exec '$CONTAINER' /opt/keycloak/bin/kcadm.sh get users -r '$REALM' -q username=$user 2>/dev/null | grep -q '\"id\"'"
done

echo
echo "Keycloak verification: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

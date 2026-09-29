#!/usr/bin/env bash
# verify_keycloak.sh — confirms the realm, LDAP federation, confidential
# client and group mapper are actually LIVE (via kcadm get against the
# running container), not merely that setup_keycloak.sh exited zero.
#
# Runs on the host, via `podman exec` into the already-running keycloak
# container — matches the "kcadm-via-exec" pattern named in
# prompts/security/18_01_security_foundation.md (adapted from
# workshop/zero_trust/scripts/verify_keycloak.sh).
set -uo pipefail

REALM=arcanium
CLIENT_ID=arcanium-api
CONTAINER=arcanium-keycloak

kx() { podman exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"; }

if ! podman exec "$CONTAINER" true >/dev/null 2>&1; then
  echo "FAIL: $CONTAINER is not running/reachable" >&2
  exit 1
fi

if [ -z "${KEYCLOAK_ADMIN:-}" ] || [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
  # Read from the env file the same way scripts/compose.sh does, so this can
  # be run standalone without re-exporting everything by hand.
  ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
  if [ -f "$ROOT/.env" ]; then
    KEYCLOAK_ADMIN=$(grep -E '^KEYCLOAK_ADMIN=' "$ROOT/.env" | tail -1 | cut -d= -f2-)
    KEYCLOAK_ADMIN_PASSWORD=$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' "$ROOT/.env" | tail -1 | cut -d= -f2-)
  fi
fi
if [ -z "${KEYCLOAK_ADMIN:-}" ] || [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
  echo "FAIL: KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD not set and not found in .env" >&2
  exit 1
fi

kx config credentials --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

failed=0
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc" >&2
    failed=1
  fi
}

check "realm '$REALM' exists" kx get "realms/$REALM"

check "LDAP federation component present" bash -c \
  "podman exec '$CONTAINER' /opt/keycloak/bin/kcadm.sh get components -r '$REALM' -q name=arcanium-ldap 2>/dev/null | grep -q '\"id\"'"

check "LDAP group mapper present" bash -c \
  "podman exec '$CONTAINER' /opt/keycloak/bin/kcadm.sh get components -r '$REALM' -q name=arcanium-groups 2>/dev/null | grep -q '\"id\"'"

check "client '$CLIENT_ID' exists and is confidential" bash -c \
  "podman exec '$CONTAINER' /opt/keycloak/bin/kcadm.sh get clients -r '$REALM' -q clientId=$CLIENT_ID 2>/dev/null | grep -q '\"publicClient\" : false'"

CLIENT_UUID=$(kx get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id 2>/dev/null | grep -o '"[a-f0-9-]\{36\}"' | head -1 | tr -d '"')
if [ -n "$CLIENT_UUID" ]; then
  check "groups claim mapper present on client" bash -c \
    "podman exec '$CONTAINER' /opt/keycloak/bin/kcadm.sh get clients/$CLIENT_UUID/protocol-mappers/models -r '$REALM' 2>/dev/null | grep -q '\"name\" : \"groups\"'"
else
  echo "  ✗ client uuid not resolved — skipping mapper check" >&2
  failed=1
fi

for g in arcanium-ciso arcanium-architect arcanium-operator arcanium-auditor arcanium-supplier-admin arcanium-tenant-pepsi arcanium-tenant-cocacola; do
  check "realm group '$g' present" bash -c \
    "podman exec '$CONTAINER' /opt/keycloak/bin/kcadm.sh get groups -r '$REALM' -q search=$g 2>/dev/null | grep -q '\"name\" : \"$g\"'"
done

echo
if [ "$failed" -eq 0 ]; then
  echo "verify_keycloak: all checks passed"
  exit 0
else
  echo "verify_keycloak: one or more checks FAILED" >&2
  exit 1
fi

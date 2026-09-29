#!/usr/bin/env bash
# setup_ldap.sh — idempotent per-entry loader for bootstrap.ldif.
# Adapted from workshop/zero_trust/scripts/setup_ldap.sh's structure
# (check-then-add per entry), pointed at Arcanium's own fixture.
#
# Runs inside the ldap-bootstrap container (profiles: ["init"]), entrypoint.
# LDAP_ADMIN_PASSWORD / LDAP_BASE_DN / LDAP_HOST come from the compose
# environment — never hardcoded here.
set -euo pipefail

LDAP_HOST="${LDAP_HOST:-openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=arcanium,dc=local}"
BIND_DN="cn=admin,${BASE_DN}"
LDIF="/bootstrap/bootstrap.ldif"

echo "Waiting for ${LDAP_HOST}..."
# Authenticated, not anonymous: osixia/openldap restricts anonymous bind by
# default, so an anonymous search on the base DN returns "no such object"
# even once it exists — found by actually running this against a live
# container, not assumed from the image's documented defaults.
for _ in $(seq 1 30); do
  ldapsearch -x -H "ldap://${LDAP_HOST}" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" -b "$BASE_DN" -s base >/dev/null 2>&1 && break
  sleep 2
done

added=0
skipped=0
failed=0

# Split the LDIF into per-entry blocks (separated by blank lines) and apply
# each independently, so one already-present entry never blocks the rest.
entry=""
apply_entry() {
  [ -z "$1" ] && return 0
  local dn
  dn="$(printf '%s\n' "$1" | awk -F': ' '/^dn:/{print $2; exit}')"
  [ -z "$dn" ] && return 0

  if ldapsearch -x -H "ldap://${LDAP_HOST}" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" \
    -b "$dn" -s base >/dev/null 2>&1; then
    echo "  = exists: $dn"
    skipped=$((skipped + 1))
    return 0
  fi

  if printf '%s\n' "$1" | ldapadd -x -H "ldap://${LDAP_HOST}" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo "  + added: $dn"
    added=$((added + 1))
  else
    echo "  ! failed: $dn" >&2
    failed=$((failed + 1))
  fi
}

while IFS= read -r line; do
  if [ -z "$line" ]; then
    apply_entry "$entry"
    entry=""
  elif [[ "$line" == \#* ]]; then
    continue
  else
    entry="${entry}${line}"$'\n'
  fi
done <"$LDIF"
apply_entry "$entry" # final entry if the file doesn't end on a blank line

echo
echo "LDAP fixture: ${added} added, ${skipped} already present, ${failed} failed"
[ "$failed" -eq 0 ] || exit 1

echo
echo "Demo accounts (POC passwords — local lab only):"
echo "  demo-ciso / Arcanium-ciso-2026"
echo "  demo-architect / Arcanium-arch-2026"
echo "  demo-operator / Arcanium-ops-2026"
echo "  demo-auditor / Arcanium-audit-2026"
echo "  demo-pepsi / Arcanium-pepsi-2026        (arcanium-supplier-admin + arcanium-tenant-pepsi)"
echo "  demo-cocacola / Arcanium-cocacola-2026  (arcanium-supplier-admin + arcanium-tenant-cocacola)"
echo "  demo-operator-prod / Arcanium-opprod-2026        (arcanium-operator:env:production only)"
echo "  demo-auditor-platform / Arcanium-auditplat-2026  (arcanium-auditor:team:platform only)"

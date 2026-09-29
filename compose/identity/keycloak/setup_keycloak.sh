#!/bin/bash
# compose/identity/keycloak/setup_keycloak.sh
# Idempotent realm / federation / role / client setup for Durin.
# prompts/security/17_01 (topology from Arcanium) + 17_02 (completion).
#
#   realm    durin
#   LDAP     durin.local, read-only federation
#            group mapper       → `groups` claim
#            role-ldap-mapper   → LDAP groups become REALM ROLES
#                                 (durin-viewer / durin-operator / durin-security-admin)
#            attribute mapper   → businessCategory → user attribute durin_tenants
#   clients  durin-backend  confidential, Authorization Code + PKCE (Web Console)
#            durin-cli      public, direct access grants — LOCAL LAB ONLY, for
#                           scripted RBAC tests (scripts/lib/durin-auth.sh)
#   claims   realm_access.roles, durin_tenants (multi-valued), aud += durin-backend
#
# Secrets are Vault-sourced (identity-secrets-init → /run/secrets). Nothing
# secret is printed.
set -euo pipefail

KC=/opt/keycloak/bin/kcadm.sh
KC_URL="${KC_INTERNAL_URL:-http://keycloak:8080}"
REALM=durin
BACKEND_CLIENT=durin-backend
CLI_CLIENT=durin-cli
AUDIENCE=durin-backend
LDAP_BASE_DN="dc=durin,dc=local"

SECRETS="${IDENTITY_SECRETS_DIR:-/run/secrets}"
KEYCLOAK_ADMIN_PASSWORD="$(cat "$SECRETS/keycloak-admin-password")"
LDAP_ADMIN_PASSWORD="$(cat "$SECRETS/ldap-admin-password")"
OIDC_CLIENT_SECRET="$(cat "$SECRETS/oidc-client-secret")"

echo "Waiting for Keycloak at ${KC_URL}..."
attempt=0
until "$KC" config credentials --server "$KC_URL" --realm master \
  --user "${KEYCLOAK_ADMIN:-admin}" --password "$KEYCLOAK_ADMIN_PASSWORD" 2>/tmp/kcadm-login.err; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 40 ]; then
    echo "Keycloak did not become ready after $((attempt * 3))s:" >&2
    cat /tmp/kcadm-login.err >&2
    exit 1
  fi
  sleep 3
done

# ── helpers ────────────────────────────────────────────────────────────────
first_id() {
  grep -m1 '"id" *:' | sed -E 's/.*"id" *: *"([^"]*)".*/\1/'
  return 0
}

get_component_id() {
  "$KC" get components -r "$REALM" -q "name=$1" --fields id 2>/dev/null | first_id
}

get_client_uuid() {
  "$KC" get clients -r "$REALM" -q clientId="$1" --fields id 2>/dev/null | first_id
}

mapper_exists() { # client_uuid mapper_name
  "$KC" get "clients/$1/protocol-mappers/models" -r "$REALM" 2>/dev/null | grep -q "\"name\" *: *\"$2\""
}

# ── realm ──────────────────────────────────────────────────────────────────
ensure_realm() {
  if "$KC" get "realms/$REALM" >/dev/null 2>&1; then
    echo "  = realm exists: $REALM"
  else
    "$KC" create realms -s realm="$REALM" -s enabled=true -s sslRequired=NONE \
      -s accessTokenLifespan=300 -s ssoSessionIdleTimeout=3600 -s ssoSessionMaxLifespan=36000
    echo "  + realm created: $REALM"
  fi
  # Keycloak 24+ declarative user profile drops attributes it doesn't know
  # about. durin_tenants comes from LDAP, so allow unmanaged attributes.
  "$KC" get users/profile -r "$REALM" > /tmp/profile.json
  if ! grep -q '"unmanagedAttributePolicy" *: *"ENABLED"' /tmp/profile.json; then
    sed -i -E 's/"unmanagedAttributePolicy" *: *"[A-Z_]*" *,?//' /tmp/profile.json
    sed -i '0,/{/s//{"unmanagedAttributePolicy":"ENABLED",/' /tmp/profile.json
    "$KC" update users/profile -r "$REALM" -f /tmp/profile.json
    echo "  + user profile: unmanaged attributes enabled (durin_tenants from LDAP)"
  else
    echo "  = user profile: unmanaged attributes enabled"
  fi
}

# ── LDAP federation + mappers ──────────────────────────────────────────────
ensure_ldap_federation() {
  local id
  id=$(get_component_id durin-ldap)
  if [ -n "$id" ]; then
    echo "  = LDAP federation exists: $id"
    # Keep the bind credential in step with Vault (rotation-safe).
    "$KC" update "components/$id" -r "$REALM" -s "config.bindCredential=[\"${LDAP_ADMIN_PASSWORD}\"]" >/dev/null
  else
    id=$("$KC" create components -r "$REALM" -i \
      -s name=durin-ldap \
      -s providerId=ldap \
      -s providerType=org.keycloak.storage.UserStorageProvider \
      -s 'config.enabled=["true"]' \
      -s 'config.vendor=["other"]' \
      -s 'config.usernameLDAPAttribute=["uid"]' \
      -s 'config.rdnLDAPAttribute=["uid"]' \
      -s 'config.uuidLDAPAttribute=["entryUUID"]' \
      -s 'config.userObjectClasses=["inetOrgPerson, organizationalPerson"]' \
      -s 'config.connectionUrl=["ldap://openldap:389"]' \
      -s "config.usersDn=[\"ou=people,${LDAP_BASE_DN}\"]" \
      -s "config.bindDn=[\"cn=admin,${LDAP_BASE_DN}\"]" \
      -s "config.bindCredential=[\"${LDAP_ADMIN_PASSWORD}\"]" \
      -s 'config.editMode=["READ_ONLY"]' \
      -s 'config.syncRegistrations=["false"]' \
      -s 'config.pagination=["true"]' \
      -s 'config.importEnabled=["true"]' \
      -s 'config.trustEmail=["true"]')
    echo "  + LDAP federation created: $id"
  fi

  if [ -n "$(get_component_id durin-groups)" ]; then
    echo "  = group mapper exists"
  else
    "$KC" create components -r "$REALM" \
      -s name=durin-groups \
      -s providerId=group-ldap-mapper \
      -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
      -s parentId="$id" \
      -s "config.\"groups.dn\"=[\"ou=groups,${LDAP_BASE_DN}\"]" \
      -s 'config."group.name.ldap.attribute"=["cn"]' \
      -s 'config."group.object.classes"=["groupOfNames"]' \
      -s 'config."membership.ldap.attribute"=["member"]' \
      -s 'config."membership.attribute.type"=["DN"]' \
      -s 'config.mode=["READ_ONLY"]' \
      -s 'config."preserve.group.inheritance"=["false"]' \
      -s 'config."ignore.missing.groups"=["false"]'
    echo "  + group mapper created"
  fi

  if [ -n "$(get_component_id durin-roles)" ]; then
    echo "  = role mapper exists"
  else
    "$KC" create components -r "$REALM" \
      -s name=durin-roles \
      -s providerId=role-ldap-mapper \
      -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
      -s parentId="$id" \
      -s "config.\"roles.dn\"=[\"ou=groups,${LDAP_BASE_DN}\"]" \
      -s 'config."role.name.ldap.attribute"=["cn"]' \
      -s 'config."role.object.classes"=["groupOfNames"]' \
      -s 'config."membership.ldap.attribute"=["member"]' \
      -s 'config."membership.attribute.type"=["DN"]' \
      -s 'config."membership.user.ldap.attribute"=["uid"]' \
      -s 'config.mode=["READ_ONLY"]' \
      -s 'config."user.roles.retrieve.strategy"=["LOAD_ROLES_BY_MEMBER_ATTRIBUTE"]' \
      -s 'config."use.realm.roles.mapping"=["true"]'
    echo "  + role mapper created (LDAP groups → realm roles)"
  fi

  if [ -n "$(get_component_id durin-tenants)" ]; then
    echo "  = tenant attribute mapper exists"
  else
    "$KC" create components -r "$REALM" \
      -s name=durin-tenants \
      -s providerId=user-attribute-ldap-mapper \
      -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
      -s parentId="$id" \
      -s 'config."ldap.attribute"=["businessCategory"]' \
      -s 'config."user.model.attribute"=["durin_tenants"]' \
      -s 'config."read.only"=["true"]' \
      -s 'config."always.read.value.from.ldap"=["true"]' \
      -s 'config."is.mandatory.in.ldap"=["false"]' \
      -s 'config."is.binary.attribute"=["false"]' \
      -s 'config."attribute.force.default"=["false"]'
    echo "  + tenant attribute mapper created (businessCategory → durin_tenants)"
  fi

  echo "  -> triggering full LDAP sync"
  "$KC" create "user-storage/${id}/sync?action=triggerFullSync" -r "$REALM" -s x=1 >/dev/null 2>&1 ||
    echo "  ! full sync request did not confirm (non-fatal)"
}

# ── realm roles ────────────────────────────────────────────────────────────
ensure_realm_role() {
  if "$KC" get-roles -r "$REALM" --rolename "$1" >/dev/null 2>&1; then
    echo "  = role exists: $1"
  else
    "$KC" create roles -r "$REALM" -s name="$1"
    echo "  + role created: $1"
  fi
}

# ── clients ────────────────────────────────────────────────────────────────
ensure_backend_client() {
  local uuid redirect post_logout
  uuid=$(get_client_uuid "$BACKEND_CLIENT")
  redirect="${DURIN_API_CALLBACK_URL:-${DURIN_BASE_URL:-http://localhost:3000}/api/v1/auth/callback}"
  post_logout="${DURIN_BASE_URL:-http://localhost:3000}"
  if [ -n "$uuid" ]; then
    echo "  = client exists: $BACKEND_CLIENT" >&2
  else
    "$KC" create clients -r "$REALM" \
      -s clientId="$BACKEND_CLIENT" \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=true \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false \
      -s 'attributes."pkce.code.challenge.method"=S256' \
      -s "redirectUris=[\"${redirect}\"]" \
      -s webOrigins='[]' >&2
    uuid=$(get_client_uuid "$BACKEND_CLIENT")
    echo "  + client created: $BACKEND_CLIENT" >&2
  fi
  # The secret is a property of the client (PUT clients/<id>); the
  # clients/<id>/client-secret sub-resource only regenerates a random one.
  if "$KC" update "clients/$uuid" -r "$REALM" -s "secret=$OIDC_CLIENT_SECRET" >/dev/null; then
    echo "  = client secret set from Vault (secret/durin/identity/oidc-client-secret)" >&2
  else
    echo "  ! could not set the client secret for $BACKEND_CLIENT" >&2
    exit 1
  fi
  "$KC" update "clients/$uuid" -r "$REALM" \
    -s "attributes.\"post.logout.redirect.uris\"=${post_logout}" >/dev/null 2>&1
  echo "$uuid"
}

ensure_cli_client() {
  local uuid
  uuid=$(get_client_uuid "$CLI_CLIENT")
  if [ -n "$uuid" ]; then
    echo "  = client exists: $CLI_CLIENT (local lab only)" >&2
  else
    "$KC" create clients -r "$REALM" \
      -s clientId="$CLI_CLIENT" \
      -s protocol=openid-connect \
      -s publicClient=true \
      -s standardFlowEnabled=false \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=true \
      -s serviceAccountsEnabled=false \
      -s 'attributes."description"="Local lab only: scripted RBAC tests (password grant). Remove outside the lab."' >&2
    uuid=$(get_client_uuid "$CLI_CLIENT")
    echo "  + client created: $CLI_CLIENT (public, direct access grants — local lab only)" >&2
  fi
  echo "$uuid"
}

ensure_claim_mappers() { # client_uuid client_label
  local uuid="$1"
  if mapper_exists "$uuid" groups; then echo "  = $2: groups claim"; else
    "$KC" create "clients/$uuid/protocol-mappers/models" -r "$REALM" \
      -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"=false' -s 'config."id.token.claim"=true' \
      -s 'config."access.token.claim"=true' -s 'config."userinfo.token.claim"=true' \
      -s 'config."claim.name"=groups'
    echo "  + $2: groups claim"
  fi
  if mapper_exists "$uuid" durin_tenants; then echo "  = $2: durin_tenants claim"; else
    "$KC" create "clients/$uuid/protocol-mappers/models" -r "$REALM" \
      -s name=durin_tenants -s protocol=openid-connect -s protocolMapper=oidc-usermodel-attribute-mapper \
      -s 'config."user.attribute"=durin_tenants' -s 'config."claim.name"=durin_tenants' \
      -s 'config."jsonType.label"=String' -s 'config.multivalued=true' \
      -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=true' \
      -s 'config."userinfo.token.claim"=true'
    echo "  + $2: durin_tenants claim"
  fi
  if mapper_exists "$uuid" durin-backend-audience; then echo "  = $2: audience $AUDIENCE"; else
    "$KC" create "clients/$uuid/protocol-mappers/models" -r "$REALM" \
      -s name=durin-backend-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
      -s "config.\"included.client.audience\"=$AUDIENCE" \
      -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false'
    echo "  + $2: audience $AUDIENCE"
  fi
}

# ── main ───────────────────────────────────────────────────────────────────
echo "-> realm"
ensure_realm

echo "-> realm roles"
ensure_realm_role "durin-viewer"
ensure_realm_role "durin-operator"
ensure_realm_role "durin-security-admin"

echo "-> LDAP federation + mappers"
ensure_ldap_federation

echo "-> clients"
BACKEND_UUID=$(ensure_backend_client | tail -1)
CLI_UUID=$(ensure_cli_client | tail -1)

echo "-> claim mappers"
ensure_claim_mappers "$BACKEND_UUID" "$BACKEND_CLIENT"
ensure_claim_mappers "$CLI_UUID" "$CLI_CLIENT"

echo
echo "================================================================"
echo "Keycloak realm '$REALM' ready."
echo "  Web Console client : $BACKEND_CLIENT (secret in Vault KV)"
echo "  Test client        : $CLI_CLIENT (local lab only)"
echo "  Issuer             : see /realms/$REALM/.well-known/openid-configuration"
echo "  Verify             : make identity-verify"
echo "================================================================"

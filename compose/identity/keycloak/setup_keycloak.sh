#!/bin/bash
# setup_keycloak.sh — idempotent realm/federation/client setup for Arcanium.
#
# Adapted from workshop/zero_trust/scripts/setup_keycloak.sh's kcadm-via-exec
# idempotent helper pattern (ensure_client, get_client_uuid, get_client_secret,
# ensure_realm_role, ensure_group_has_role) — same shape, Arcanium naming and
# a confidential-only client (input/36; the source project issued a public
# SPA client, which Arcanium must not do).
#
# Runs inside the keycloak-bootstrap container (profiles: ["init"]) against
# the already-running keycloak service over arcanium-control.
set -euo pipefail

KC=/opt/keycloak/bin/kcadm.sh
KC_URL="${KC_INTERNAL_URL:-http://keycloak:8080}"
REALM=arcanium
CLIENT_ID=arcanium-api
LDAP_BASE_DN="dc=arcanium,dc=local"

echo "Waiting for Keycloak at ${KC_URL}..."
# The Keycloak image has no curl (found by actually running this — it's a
# minimal UBI9-micro base). kcadm.sh is the one real dependency here, so use
# the actual command this script needs as its own readiness probe instead of
# a separate HTTP check.
attempt=0
until "$KC" config credentials --server "$KC_URL" --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" 2>/tmp/kcadm-login.err; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 40 ]; then
    echo "Keycloak did not become ready after $((attempt * 3))s:" >&2
    cat /tmp/kcadm-login.err >&2
    exit 1
  fi
  sleep 3
done

# ── realm ────────────────────────────────────────────────────────────────
ensure_realm() {
  if "$KC" get "realms/$REALM" >/dev/null 2>&1; then
    echo "  = realm exists: $REALM"
  else
    "$KC" create realms -s realm="$REALM" -s enabled=true -s sslRequired=NONE \
      -s accessTokenLifespan=300 -s ssoSessionIdleTimeout=3600 -s ssoSessionMaxLifespan=36000
    echo "  + realm created: $REALM"
  fi
}

# jq isn't in this image (minimal UBI9-micro base — found by actually
# running this). kcadm's JSON is pretty-printed one-field-per-line, so grep
# + sed extract what jq would have — good enough for the narrow, known
# shapes this script reads.
first_id() {
  # "no match" (component genuinely doesn't exist yet, e.g. first run) is a
  # normal, expected outcome here, not an error — grep's exit 1 must not
  # trip `set -e` at the `id=$(get_component_id ...)` call sites.
  grep -m1 '"id" *:' | sed -E 's/.*"id" *: *"([^"]*)".*/\1/'
  return 0
}

# ── LDAP federation + group mapper ─────────────────────────────────────────
get_component_id() {
  "$KC" get components -r "$REALM" -q "name=$1" --fields id 2>/dev/null | first_id
}

ensure_ldap_federation() {
  local id
  id=$(get_component_id arcanium-ldap)
  if [ -n "$id" ]; then
    echo "  = LDAP federation exists: $id"
  else
    id=$("$KC" create components -r "$REALM" -i \
      -s name=arcanium-ldap \
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

  local gid
  gid=$(get_component_id arcanium-groups)
  if [ -n "$gid" ]; then
    echo "  = group mapper exists: $gid"
  else
    gid=$("$KC" create components -r "$REALM" -i \
      -s name=arcanium-groups \
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
      -s 'config."ignore.missing.groups"=["false"]')
    echo "  + group mapper created: $gid"
  fi

  echo "  -> triggering full LDAP sync"
  "$KC" create "user-storage/${id}/sync?action=triggerFullSync" -r "$REALM" -s x=1 >/dev/null 2>&1 ||
    echo "  ! full sync request did not confirm (non-fatal — Keycloak syncs lazily too)"
}

# ── confidential client (no public/SPA client, ever) ────────────────────────
get_client_uuid() {
  "$KC" get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id 2>/dev/null | first_id
}

ensure_client() {
  local uuid
  uuid=$(get_client_uuid)
  # Browser-facing redirect URI, through the Nuxt gateway — never Express's
  # own port directly (that would break the same-origin BFF model every
  # other part of Arcanium relies on).
  local redirect="${ARCANIUM_API_CALLBACK_URL:-${ARCANIUM_BASE_URL:-http://localhost:3000}/gateway/api/v1/auth/callback}"
  # prompts/process/00_03_frontend_quality_gate.md, Gate 4 — found live via a real "click Sign
  # out in the browser" pass: RP-initiated logout (auth/oidc.js's
  # buildLogoutUrl(), used by default.vue's signOut()) sends
  # post_logout_redirect_uri=$ARCANIUM_BASE_URL to Keycloak's end-session
  # endpoint, but this client never declared that URI as allowed — Keycloak
  # rejected it with 400 Bad Request. Must exactly match ARCANIUM_BASE_URL
  # (the same value buildLogoutUrl() sends), not the callback path above.
  local post_logout="${ARCANIUM_BASE_URL:-http://localhost:3000}"
  if [ -n "$uuid" ]; then
    echo "  = client exists: $CLIENT_ID ($uuid)"
  else
    "$KC" create clients -r "$REALM" \
      -s clientId="$CLIENT_ID" \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=true \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false \
      -s 'attributes."pkce.code.challenge.method"=S256' \
      -s "redirectUris=[\"${redirect}\"]" \
      -s webOrigins='[]'
    uuid=$(get_client_uuid)
    echo "  + client created: $CLIENT_ID ($uuid)"
    # If the caller already has a known secret (e.g. from .env), overwrite
    # Keycloak's auto-generated one so .env never needs updating after re-runs.
    if [ -n "${ARCANIUM_OIDC_CLIENT_SECRET:-}" ]; then
      "$KC" update "clients/$uuid/client-secret" -r "$REALM" \
        -s value="$ARCANIUM_OIDC_CLIENT_SECRET" >/dev/null 2>&1 &&
        echo "  + client secret set from ARCANIUM_OIDC_CLIENT_SECRET"
    fi
  fi
  # Runs on every invocation (fresh create AND an already-existing client) —
  # an already-provisioned realm from before this fix would otherwise never
  # pick it up on a re-run, since the branch above only runs once at
  # creation time.
  "$KC" update "clients/$uuid" -r "$REALM" \
    -s "attributes.\"post.logout.redirect.uris\"=${post_logout}" >/dev/null 2>&1 &&
    echo "  = post-logout redirect URI set: $post_logout"
  echo "$uuid"
}

get_client_secret() {
  "$KC" get "clients/$1/client-secret" -r "$REALM" 2>/dev/null |
    { grep -m1 '"value" *:' || true; } | sed -E 's/.*"value" *: *"([^"]*)".*/\1/'
}

# ── groups claim mapper on the client (short names, no leading path) ────────
ensure_group_claim_mapper() {
  local uuid="$1"
  local existing
  # kcadm pretty-prints one object per {..} block with "id" preceding "name"
  # by a couple of lines — grab the id closest above the "groups" name match.
  # "no match" (mapper doesn't exist yet, the normal first-run case) must not
  # trip `set -e` via pipefail — same class of bug as first_id() above.
  existing=$("$KC" get "clients/$uuid/protocol-mappers/models" -r "$REALM" 2>/dev/null |
    { grep -B8 '"name" *: *"groups"' || true; } | { grep '"id" *:' || true; } | tail -1 |
    sed -E 's/.*"id" *: *"([^"]*)".*/\1/')
  if [ -n "$existing" ]; then
    echo "  = groups claim mapper exists"
  else
    "$KC" create "clients/$uuid/protocol-mappers/models" -r "$REALM" \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"=false' \
      -s 'config."id.token.claim"=true' \
      -s 'config."access.token.claim"=true' \
      -s 'config."userinfo.token.claim"=true' \
      -s 'config."claim.name"=groups'
    echo "  + groups claim mapper created"
  fi
}

echo "-> realm"
ensure_realm

echo "-> LDAP federation + group mapper"
ensure_ldap_federation
# No separate realm-group pre-creation step: the group-ldap-mapper above
# (mode=READ_ONLY) mirrors LDAP groups into Keycloak's own group tree during
# sync — a manual pre-creation loop here would be redundant with what
# federation already does, not a second safety net.

echo "-> confidential client"
CLIENT_UUID=$(ensure_client | tail -1)

echo "-> groups claim mapper"
ensure_group_claim_mapper "$CLIENT_UUID"

SECRET=$(get_client_secret "$CLIENT_UUID")

echo
echo "================================================================"
echo "Keycloak realm '$REALM' ready."
echo "Client:  $CLIENT_ID"
echo "Secret:  $SECRET"
echo
echo "Add to .env (never commit):"
echo "  ARCANIUM_OIDC_CLIENT_SECRET=$SECRET"
echo "================================================================"

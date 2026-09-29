# scripts/lib/durin-auth.sh — real OIDC identities for Durin test scripts.
# prompts/security/17_02. Source it; do not execute it.
#
#   durin_token <uid>        access token for an LDAP user via Keycloak's
#                            durin-cli client (password grant, local lab only).
#                            The password is read from Vault KV
#                            (secret/durin/identity/users/<uid>) — never stored.
#   durin_auth_enabled       true when the backend enforces OIDC (from /health)
#   curl …                   wrapper: for requests to the Durin backend API, when
#                            auth is enabled and no Authorization header is
#                            given, adds a Bearer token. The persona comes from
#                            an `x-durin-actor` header, mapped to an LDAP user:
#                              *security-admin* → security-admin
#                              *viewer*         → viewer
#                              *barend*         → barend
#                              anything else    → raymon (operator, all tenants)
#                            In demo mode the request is passed through untouched.
#
# Tokens are cached per user for 4 minutes (Keycloak access tokens live 5).

if [ -z "${_DURIN_ROOT:-}" ]; then
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _DURIN_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
  else # sourced from zsh or another shell
    _DURIN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi
DURIN_BACKEND_BASE="${DURIN_BACKEND_BASE:-http://localhost:3001}"
DURIN_KC_URL="${DURIN_KC_URL:-http://localhost:8083}"
DURIN_KC_REALM="${DURIN_KC_REALM:-durin}"
DURIN_KC_CLIENT="${DURIN_KC_CLIENT:-durin-cli}"
if [ -z "${DURIN_TOKEN_CACHE:-}" ]; then
  DURIN_TOKEN_CACHE="$(mktemp -d -t durin-tokens.XXXXXX)"
  export DURIN_TOKEN_CACHE
fi

_durin_vault() {
  VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18300}" \
  VAULT_CACERT="${VAULT_CACERT:-$_DURIN_ROOT/vault-tls/ca-chain.pem}" \
  VAULT_TOKEN="${VAULT_TOKEN:-$(jq -r .root_token "$_DURIN_ROOT/.secrets/vault/cluster-init.json")}" \
  vault "$@"
}

durin_auth_enabled() {
  if [ -z "${_DURIN_AUTH_MODE:-}" ]; then
    _DURIN_AUTH_MODE=$(command curl -s -m 5 "$DURIN_BACKEND_BASE/api/v1/health" | jq -r '.auth.enabled // false' 2>/dev/null)
    export _DURIN_AUTH_MODE
  fi
  [ "$_DURIN_AUTH_MODE" = "true" ]
}

durin_token() {
  local uid="$1" cache="$DURIN_TOKEN_CACHE/$1" now pw resp tok
  now=$(date +%s)
  if [ -s "$cache" ] && [ $(( now - $(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache") )) -lt 240 ]; then
    cat "$cache"; return 0
  fi
  pw=$(_durin_vault kv get -mount=secret -field=value "durin/identity/users/$uid") || { echo "durin_token: no password for $uid in Vault" >&2; return 1; }
  resp=$(command curl -s -m 10 -X POST "$DURIN_KC_URL/realms/$DURIN_KC_REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode "client_id=$DURIN_KC_CLIENT" \
    --data-urlencode "username=$uid" --data-urlencode "password=$pw" --data-urlencode scope=openid)
  tok=$(jq -r '.access_token // empty' <<<"$resp")
  [ -n "$tok" ] || { echo "durin_token: login failed for $uid: $(jq -r '.error_description // .error // "no response"' <<<"$resp")" >&2; return 1; }
  umask 077; printf '%s' "$tok" > "$cache"
  printf '%s' "$tok"
}

durin_actor_user() {
  case "${1:-}" in
    *security-admin*) echo security-admin ;;
    *viewer*)         echo viewer ;;
    *barend*)         echo barend ;;
    *)                echo raymon ;;
  esac
}

curl() {
  local is_backend=false has_auth=false actor="" prev="" a
  for a in "$@"; do
    case "$a" in "$DURIN_BACKEND_BASE"/api/*) is_backend=true ;; esac
    if [ "$prev" = "-H" ]; then
      case "$a" in
        [Aa]uthorization:*) has_auth=true ;;
        [Xx]-durin-actor:*) actor="${a#*:}"; actor="${actor# }" ;;
      esac
    fi
    prev="$a"
  done
  if $is_backend && ! $has_auth && durin_auth_enabled; then
    local tok
    tok=$(durin_token "$(durin_actor_user "$actor")") || return 1
    command curl -H "Authorization: Bearer $tok" "$@"
  else
    command curl "$@"
  fi
}

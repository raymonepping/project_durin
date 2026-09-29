#!/usr/bin/env bash
# scripts/identity-secrets.sh — seed identity-stack secrets into Vault KV.
# prompts/security/17_02_identity_stack_completion.md
#
# Idempotent. Generates any missing value under secret/durin/identity/ and
# writes the identity-secrets-init AppRole credentials to .secrets/vault/
# (gitignored). Existing values are never overwritten unless --rotate-user.
#
# Usage:
#   ./scripts/identity-secrets.sh                    # seed (safe to re-run)
#   ./scripts/identity-secrets.sh --show-user raymon # print one login password
#   ./scripts/identity-secrets.sh --rotate-user raymon  # new password (re-run make identity-bootstrap)
#
# Needs VAULT_TOKEN with write on secret/ and read on the AppRole (defaults to
# the root token in .secrets/vault/cluster-init.json — local lab).
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18300}"
export VAULT_CACERT="${VAULT_CACERT:-$root/vault-tls/ca-chain.pem}"
export VAULT_TOKEN="${VAULT_TOKEN:-$(jq -r .root_token "$root/.secrets/vault/cluster-init.json")}"

KV=secret
BASE=durin/identity
USERS=(raymon barend security-admin viewer)

gen() { openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-28; }
exists() { vault kv get -mount="$KV" "$BASE/$1" >/dev/null 2>&1; }
put() { vault kv put -mount="$KV" "$BASE/$1" value="$2" >/dev/null; }

case "${1:-}" in
  --show-user)
    vault kv get -mount="$KV" -field=value "$BASE/users/${2:?uid}"; echo; exit 0 ;;
  --show-secret)   # platform secret, e.g. oidc-client-secret (make ui-dev)
    vault kv get -mount="$KV" -field=value "$BASE/${2:?key}"; exit 0 ;;
  --rotate-user)
    put "users/${2:?uid}" "$(gen)"
    echo "[identity-secrets] rotated users/$2 — run 'make identity-bootstrap' to apply it to LDAP"; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--show-user <uid> | --show-secret <key> | --rotate-user <uid>]" >&2; exit 64 ;;
esac

vault secrets list -format=json | jq -e '."secret/"' >/dev/null \
  || { echo "[identity-secrets] KV mount secret/ missing — run 'make tf-apply' first" >&2; exit 1; }

for key in ldap-admin-password keycloak-admin-password oidc-client-secret; do
  if exists "$key"; then echo "  = $key"; else put "$key" "$(gen)"; echo "  + $key (generated)"; fi
done
for u in "${USERS[@]}"; do
  if exists "users/$u"; then echo "  = users/$u"; else put "users/$u" "$(gen)"; echo "  + users/$u (generated)"; fi
done

# AppRole credentials for identity-secrets-init — files, not .env.
dir="$root/.secrets/vault"
umask 077
vault read -field=role_id auth/approle/role/durin-identity-secrets/role-id > "$dir/identity-role-id"
if [ -s "$dir/identity-secret-id" ] && vault write -format=json auth/approle/role/durin-identity-secrets/secret-id/lookup \
     secret_id="$(cat "$dir/identity-secret-id")" 2>/dev/null | jq -e '.data' >/dev/null; then
  echo "  = identity-secret-id (valid)"
else
  vault write -f -field=secret_id auth/approle/role/durin-identity-secrets/secret-id > "$dir/identity-secret-id"
  echo "  + identity-secret-id (issued)"
fi
chmod 644 "$dir/identity-role-id" "$dir/identity-secret-id"   # read by the init container's non-root user

# AppRole credentials for ui-secrets-init (Web Console BFF: OIDC client secret only).
if vault read auth/approle/role/durin-ui >/dev/null 2>&1; then
  vault read -field=role_id auth/approle/role/durin-ui/role-id > "$dir/ui-role-id"
  if [ -s "$dir/ui-secret-id" ] && vault write -format=json auth/approle/role/durin-ui/secret-id/lookup \
       secret_id="$(cat "$dir/ui-secret-id")" 2>/dev/null | jq -e '.data' >/dev/null; then
    echo "  = ui-secret-id (valid)"
  else
    vault write -f -field=secret_id auth/approle/role/durin-ui/secret-id > "$dir/ui-secret-id"
    echo "  + ui-secret-id (issued)"
  fi
  chmod 644 "$dir/ui-role-id" "$dir/ui-secret-id"
else
  echo "  ! AppRole durin-ui missing — run 'make tf-apply' for the Web Console"
fi

echo "[identity-secrets] ready. Login passwords: $0 --show-user <$(IFS='|'; echo "${USERS[*]}")>"

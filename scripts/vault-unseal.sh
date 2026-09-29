#!/usr/bin/env bash
# scripts/vault-unseal.sh — Prompt 03. Standalone, fully idempotent unseal
# for vault-s only.
#
# vault-s is the one node in this stack sealed with a real Shamir key
# (key-shares=1 / key-threshold=1, scripts/vault-bootstrap.sh's own
# `initialize vault-s ...` call). The main cluster (vault-1/2/3) instead
# auto-unseals against vault-s's own Transit engine — that path is already
# handled by vault-bootstrap.sh and needs no standalone script. This one
# exists for the narrower case: vault-s itself comes back sealed after a
# restart (a real Podman-machine/host restart, not just `podman compose
# stop/start`, which keeps it unsealed) and blocks the whole chain until
# someone unseals it.
#
# Loosely modeled on vault_reference/vault-s/scripts/vault_unseal.sh
# (referenced from prompts/base_project/03_01_vault_terraform_baseline.md), adapted to
# this repo's own scripts/vault-common.sh helpers and jq-based JSON
# handling rather than reimplementing status/auth logic here.
set -euo pipefail
umask 077
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/vault-common.sh
source "$SCRIPT_DIR/vault-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/vault-unseal.sh [-h|--help]

Idempotent: unseals vault-s if it is currently sealed, using the single
unseal key stored in .secrets/vault/vault-s-init.json (created by
scripts/vault-bootstrap.sh's initial `vault operator init`). If vault-s
is already unsealed, reports that and exits 0 without calling
`vault operator unseal`. Safe to run on every stack start or by hand
after a restart.

Fails (non-zero) if vault-s is unreachable, uninitialized, or the init
file is missing/unparseable — never silently no-ops on a real problem.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
"") ;;
*)
  usage >&2
  exit 64
  ;;
esac

command -v vault >/dev/null 2>&1 || {
  echo "vault-unseal: 'vault' CLI not found on PATH" >&2
  exit 127
}
command -v jq >/dev/null 2>&1 || {
  echo "vault-unseal: 'jq' not found on PATH" >&2
  exit 127
}

vault_node vault-s

INIT_FILE="$VAULT_STATE/vault-s-init.json"
[ -f "$INIT_FILE" ] || {
  echo "vault-unseal: $INIT_FILE not found — vault-s has not been initialized by scripts/vault-bootstrap.sh yet" >&2
  exit 1
}

state=$(vault_json) || {
  echo "vault-unseal: vault-s unreachable at $VAULT_ADDR" >&2
  exit 1
}

jq -e '.initialized' <<<"$state" >/dev/null || {
  echo "vault-unseal: vault-s at $VAULT_ADDR reports uninitialized — $INIT_FILE exists but storage does not match; refusing to guess. See docs/persistence.md." >&2
  exit 1
}

if jq -e '.sealed | not' <<<"$state" >/dev/null; then
  echo "vault-unseal: vault-s is already unsealed — nothing to do"
  exit 0
fi

unseal_key=$(jq -er '.unseal_keys_b64[0]' "$INIT_FILE") || {
  echo "vault-unseal: could not read unseal_keys_b64[0] from $INIT_FILE" >&2
  exit 1
}

echo "vault-unseal: vault-s is sealed — unsealing at $VAULT_ADDR"
vault operator unseal "$unseal_key" >/dev/null
unset unseal_key

state_after=$(vault_json) || {
  echo "vault-unseal: vault-s unreachable immediately after unseal attempt" >&2
  exit 1
}
if jq -e '.sealed | not' <<<"$state_after" >/dev/null; then
  echo "vault-unseal: vault-s is unsealed"
  exit 0
else
  echo "vault-unseal: unseal call completed but vault-s still reports sealed — key-threshold may not be 1, or the key is stale" >&2
  exit 1
fi

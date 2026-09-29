#!/usr/bin/env bash
# scripts/workload-credentials.sh
#
# Shared AppRole RoleID/SecretID issuance for workload identities that are
# managed by this script: arcanium-hsm-read, document-signing, and the
# vault-rotator sidecar (approle-rotator).
#
# arcanium-api is deliberately NOT in this registry. Its secret-id is now
# managed end-to-end by the vault-rotator sidecar — this script issuing one
# would create a second, independent credential pair for the same role, which
# is exactly what docs/resource-ownership.md exists to avoid. The rotator
# generates arcanium-api's secret-id itself on first startup and rotates it
# every 60 days without any operator action.
#
# What IS here:
#   - approle-rotator: the rotator sidecar's own bootstrap identity (one-time,
#     its secret_id_ttl=0 — issued once, never expires, reissued by this script
#     only if the operator explicitly wants to revoke and reissue).
#   - arcanium-hsm-read, document-signing: unchanged from before.
#
# This deliberately does NOT cover payments-workload, pki-workload,
# external-supplier, approver-1 or the pepsi/cocacola tenant roles.
# scenarios/01_onboarding/run.sh, scenarios/06_supplier_isolation/provision.sh
# and scenarios/05_approval/provision.sh already generate and idempotently
# rewrite those into .env.workloads.
#
# RoleID is an identifier (safe to read, safe to log which one was read).
# SecretID is credential material: never printed, never logged, written
# only into .env with 0600 permissions, and .env is already gitignored.
#
# Usage:
#   scripts/workload-credentials.sh issue <name>
#   scripts/workload-credentials.sh verify <name>
#   scripts/workload-credentials.sh issue-all
#   scripts/workload-credentials.sh verify-all
#   scripts/workload-credentials.sh list

set -euo pipefail
umask 077

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="$ROOT/.env"
# shellcheck source=/dev/null
source "$ROOT/scripts/vault-common.sh"

# name : vault-instance : namespace : role-path : role-id-env : secret-id-env
# vault-instance is "main" (vault-1, published :18200) or "hsm" (vault-hsm, :18300).
# namespace is "-" for the root namespace.
REGISTRY=(
  # approle-rotator: vault-rotator sidecar's own bootstrap identity.
  # secret_id_ttl=0 on this role — the secret-id never expires, so issuing a
  # new one here explicitly revokes the old one (new login = old pair still
  # works until you restart vault-rotator, at which point it will use this new
  # ROTATOR_SECRET_ID). Issued once on first rehydrate; only reissue deliberately.
  "approle-rotator:main:-:auth/approle/role/approle-rotator:ROTATOR_ROLE_ID:ROTATOR_SECRET_ID"
  "arcanium-hsm-read:hsm:-:auth/approle/role/arcanium-hsm-read:ARCANIUM_HSM_ROLE_ID:ARCANIUM_HSM_SECRET_ID"
  "document-signing:hsm:-:auth/approle/role/document-signing:DOCSIGN_VAULT_ROLE_ID:DOCSIGN_VAULT_SECRET_ID"
)

usage() {
  echo "Usage: $0 {issue|verify|issue-all|verify-all|list} [name]" >&2
  exit 1
}

find_entry() {
  local name="$1" e
  for e in "${REGISTRY[@]}"; do
    [ "${e%%:*}" = "$name" ] && {
      echo "$e"
      return 0
    }
  done
  echo "[workload-credentials] unknown workload: $name" >&2
  echo "  known: $(list_names)" >&2
  return 1
}

list_names() {
  local e names=""
  for e in "${REGISTRY[@]}"; do names="$names ${e%%:*}"; done
  echo "$names" | sed 's/^ //'
}

# Point VAULT_ADDR/VAULT_CACERT/VAULT_TOKEN at the right Vault instance and
# authenticate with its own root token from .secrets/vault — never asks the
# operator to `vault login` first (docs/local-dependency-audit.md tracks
# this as the one remaining REQUIRES_SECRET_INPUT: .secrets/vault/*.json
# must exist, which only `make vault-up` / `make hsm-init` produce).
auth_for() {
  case "$1" in
  main)
    export VAULT_ADDR=https://127.0.0.1:18200
    vault_root cluster
    ;;
  hsm)
    export VAULT_ADDR=https://127.0.0.1:18300
    vault_root vault-hsm
    ;;
  *)
    echo "[workload-credentials] unknown vault instance: $1" >&2
    return 1
    ;;
  esac
}

# Replace KEY=... in .env if present, else append. Never echoes the value.
set_env_var() {
  local key="$1" value="$2"
  [ -f "$ENV_FILE" ] || {
    echo "[workload-credentials] $ENV_FILE does not exist — run: cp .env.example .env" >&2
    return 1
  }
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # BSD/macOS sed: -i '' for in-place without a backup suffix.
    sed -i '' "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    # A missing trailing newline on the file's last line would otherwise
    # concatenate onto it instead of appending a new line — found live:
    # this corrupted ARCANIUM_OIDC_CLIENT_SECRET on a real .env the first
    # time this ran. `[ -s file ]` guards the empty-file case (tail -c1
    # on an empty file prints nothing, which would wrongly skip the guard).
    if [ -s "$ENV_FILE" ] && [ "$(tail -c1 "$ENV_FILE")" != "" ]; then
      printf '\n' >>"$ENV_FILE"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}

get_env_var() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 1
  grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

issue_one() {
  local name="$1" entry instance ns role_path role_id_var secret_id_var
  entry=$(find_entry "$name") || return 1
  IFS=: read -r _ instance ns role_path role_id_var secret_id_var <<<"$entry"

  auth_for "$instance"
  [ "$ns" = "-" ] || export VAULT_NAMESPACE="$ns"

  local role_id secret_id
  role_id=$(vault read -field=role_id "${role_path}/role-id") || {
    echo "[workload-credentials] $name: role '$role_path' not found — apply its Terraform module first" >&2
    unset VAULT_NAMESPACE
    return 1
  }
  secret_id=$(vault write -f -field=secret_id "${role_path}/secret-id")
  unset VAULT_NAMESPACE

  set_env_var "$role_id_var" "$role_id"
  set_env_var "$secret_id_var" "$secret_id"
  echo "[workload-credentials] issued $name -> $role_id_var, $secret_id_var (.env, 0600)"
}

verify_one() {
  local name="$1" entry instance ns role_path role_id_var secret_id_var
  entry=$(find_entry "$name") || return 1
  IFS=: read -r _ instance ns role_path role_id_var secret_id_var <<<"$entry"

  local role_id secret_id
  role_id=$(get_env_var "$role_id_var" || true)
  secret_id=$(get_env_var "$secret_id_var" || true)
  if [ -z "$role_id" ] || [ -z "$secret_id" ]; then
    echo "  ✗ $name: $role_id_var/$secret_id_var missing or empty in .env"
    return 1
  fi

  auth_for "$instance" >/dev/null 2>&1 || {
    echo "  ? $name: Vault ($instance) unreachable — cannot verify the pair logs in"
    return 2
  }
  [ "$ns" = "-" ] || export VAULT_NAMESPACE="$ns"
  # A real, disposable AppRole login — proves the pair is currently valid
  # without ever printing role_id/secret_id themselves. The resulting
  # client token is not persisted; approle logins don't consume the
  # secret_id unless the role sets secret_id_num_uses (none of the roles
  # in this registry do — see terraform/vault-workloads, vault-platform,
  # vault-managed-keys).
  if vault write -field=token auth/approle/login \
    role_id="$role_id" secret_id="$secret_id" >/dev/null 2>&1; then
    echo "  ✓ $name: role_id/secret_id pair logs in successfully"
    unset VAULT_NAMESPACE
    return 0
  else
    echo "  ✗ $name: role_id/secret_id pair is present but Vault rejects the login"
    unset VAULT_NAMESPACE
    return 1
  fi
}

cmd="${1:-}"
case "$cmd" in
list)
  echo "Known workload identities:"
  for e in "${REGISTRY[@]}"; do
    IFS=: read -r n instance ns role_path role_id_var secret_id_var <<<"$e"
    echo "  $n ($instance, ns=$ns) -> $role_path ; .env: $role_id_var / $secret_id_var"
  done
  ;;
issue)
  [ -n "${2:-}" ] || usage
  issue_one "$2"
  ;;
verify)
  [ -n "${2:-}" ] || usage
  verify_one "$2"
  ;;
issue-all)
  fail=0
  for e in "${REGISTRY[@]}"; do
    issue_one "${e%%:*}" || fail=1
  done
  exit "$fail"
  ;;
verify-all)
  fail=0 unk=0
  for e in "${REGISTRY[@]}"; do
    rc=0
    verify_one "${e%%:*}" || rc=$?
    [ "$rc" -eq 1 ] && fail=1
    [ "$rc" -eq 2 ] && unk=1
  done
  echo
  if [ "$fail" -eq 1 ]; then
    echo "verify-all: FAIL (one or more pairs missing/rejected)"
    exit 1
  elif [ "$unk" -eq 1 ]; then
    echo "verify-all: UNKNOWN (Vault unreachable for one or more identities)"
    exit 2
  else
    echo "verify-all: PASS"
    exit 0
  fi
  ;;
*)
  usage
  ;;
esac

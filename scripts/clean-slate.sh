#!/usr/bin/env bash
# scripts/clean-slate.sh
#
# Resets Arcanium's ACCUMULATED DEMO/BUILD-UP DATA to a clean slate, while
# deliberately leaving identity (LDAP + Keycloak: users, groups, realm,
# clients, federation) and the platform's own base infrastructure
# untouched and running:
#
#   KEPT, never touched:
#     - LDAP (openldap) and Keycloak — every demo persona, group, realm,
#       client stays exactly as it is. This script does not restart or
#       reconfigure identity at all.
#     - terraform/vault-platform — core policies, the arcanium/ namespace,
#       audit device, and arcanium-api's own AppRole. Destroying this
#       would break the running arcanium-api/arcanium-worker/vault-agent
#       immediately, not just reset demo data.
#     - The Vault-HSM-backed "document-signing-key" Managed Key (Prompt
#       14.1 custody) and its SoftHSM slot/token setup.
#     - terraform/vault-transit — the transit engine mount itself plus its
#       two baseline placeholder keys (demo-app-key, workload-key). Found
#       live, not assumed: these looked like generic per-app clutter by
#       name, but they're foundational-baseline resources (same tier as
#       vault-platform) — the transit mount every other key, including
#       document-signing-key, actually lives on.
#     - vault-1/2/3/vault-s/vault-hsm, postgres, softhsm, openldap,
#       keycloak, arcanium-api/worker/ui/vault_agent containers — none of
#       these are stopped or recreated. Only the DATA inside Postgres and
#       the DEMO artifacts inside Vault are removed.
#
#   WIPED — this is the actual "build-up data":
#     - Postgres: applications, suppliers, teams, service accounts,
#       webhooks, desired_state/reconciliation history, approvals,
#       evidence, lifecycle events, scenario_runs, sessions — everything
#       that accumulated from registering apps/suppliers and running
#       scenarios. schema_migrations (the applied-migrations ledger) and
#       controls (the seeded control CATALOGUE, not assessment results)
#       are explicitly preserved — truncating either would leave the
#       running API inconsistent with its own schema/feature set.
#     - Vault: every Terraform-managed demo workload/supplier/KMIP
#       resource (terraform/vault-workloads, vault-suppliers, vault-kmip)
#       — transit keys, AppRole roles, policies, supplier namespaces and
#       their per-tenant transit/approle mounts.
#     - Any Vault artifact NOT tracked by those Terraform modules but
#       created ad hoc during a demo/scenario run — found live, not
#       assumed: a "suppliers/fanta" namespace exists with its own
#       transit + approle mounts, entirely outside any .tf file. Handled
#       generically (enumerate, don't hardcode), so a future ad-hoc
#       supplier is caught the same way. Same treatment for any stray
#       root-namespace transit key not on the explicit keep-list below.
#     - The five demo workload containers (payments-api, pki-client,
#       kmip-client, document-signing, external-supplier) — their whole
#       reason for existing is the credentials this script just destroyed;
#       left running they would only crash-loop. Stopped and removed,
#       not just left broken. Skip with --skip-containers.
#     - Generated credential files tied to destroyed Vault objects
#       (.env.workloads) — stale otherwise.
#
# This is NOT scenarios/pre_24_persistence's restart-recovery test, and it
# is NOT `make reset-demo` (which deletes every persistent volume,
# including identity, and requires a full make rehydrate afterward). This
# script keeps the platform running; it only empties the demo data inside
# it. After running it, `make onboarding && make workloads-up` (or
# whichever scenario scripts you want) repopulate a fresh demo dataset.
#
# Usage:
#   scripts/clean-slate.sh [--skip-containers] [--include-stale-leases]
#
# Always shows a full preview of what will be destroyed before asking you
# to type the project name to confirm — same confirmation convention as
# `make reset-demo`. There is no --yes/non-interactive bypass, deliberately.

set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

SKIP_CONTAINERS=false
INCLUDE_STALE_LEASES=false
for arg in "$@"; do
  case "$arg" in
  --skip-containers) SKIP_CONTAINERS=true ;;
  --include-stale-leases) INCLUDE_STALE_LEASES=true ;;
  -h | --help)
    sed -n '2,60p' "$0"
    exit 0
    ;;
  *)
    echo "Unknown argument: $arg (see --help)" >&2
    exit 64
    ;;
  esac
done

set -a
[ -f "$REPO_ROOT/.env" ] && . "$REPO_ROOT/.env"
set +a

# shellcheck source=scripts/vault-common.sh
source "$REPO_ROOT/scripts/vault-common.sh"

PGUSER="${POSTGRES_USER:-arcanium}"
PGDB="${POSTGRES_DB:-arcanium_db}"
PGPASSWORD_VAL=$(grep -m1 "^POSTGRES_PASSWORD=" "$REPO_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)

# Vault objects deliberately kept even during the ad-hoc transit-key sweep —
# see the header comment above for why each one stays. demo-app-key and
# workload-key are NOT per-app demo data — found live: they're managed by
# terraform/vault-transit, the same foundational-baseline tier as
# vault-platform (it mounts the transit engine itself; every other transit
# key, including document-signing-key, lives on that same mount).
KEEP_TRANSIT_KEYS=(document-signing-key arcanium-webhook-signing demo-app-key workload-key)

# Postgres tables to preserve (schema/catalogue, not accumulated data).
KEEP_TABLES=(schema_migrations controls)

psql_c() {
  PGPASSWORD="$PGPASSWORD_VAL" psql -h localhost -p 5432 -U "$PGUSER" -d "$PGDB" -t -A "$@"
}

vault_root_main() {
  vault_node vault-1
  vault_root cluster
}

echo "════════════════════════════════════════════════════════════════"
echo " Arcanium clean-slate — reset demo/build-up data, keep identity"
echo "════════════════════════════════════════════════════════════════"
echo

# ── 1. Discover current state (read-only) ─────────────────────────────────
echo "▸ Discovering current state..."

if ! psql_c -c "SELECT 1" >/dev/null 2>&1; then
  echo "FATAL: cannot reach Postgres ($PGUSER@localhost:5432/$PGDB) — is arcanium-postgres running?" >&2
  exit 1
fi

vault_root_main
if ! vault token lookup >/dev/null 2>&1; then
  echo "FATAL: cannot authenticate to Vault (vault-1) with the root token in .secrets/vault/cluster-init.json" >&2
  exit 1
fi

ALL_TABLES=$(psql_c -c "SELECT tablename FROM pg_tables WHERE schemaname='public'" | sed '/^$/d')
TRUNCATE_TABLES=()
for t in $ALL_TABLES; do
  keep=false
  for k in "${KEEP_TABLES[@]}"; do [ "$t" = "$k" ] && keep=true; done
  $keep || TRUNCATE_TABLES+=("$t")
done

ROW_COUNTS=""
for t in "${TRUNCATE_TABLES[@]}"; do
  c=$(psql_c -c "SELECT count(*) FROM \"$t\"")
  [ "$c" != "0" ] && ROW_COUNTS="${ROW_COUNTS}    $t: $c row(s)\n"
done

ADHOC_SUPPLIER_NS=()
mapfile -t CHILD_NS < <(VAULT_NAMESPACE=suppliers vault namespace list -format=json 2>/dev/null | jq -r '.[]' | sed 's#/$##')
for ns in "${CHILD_NS[@]:-}"; do
  [ -z "$ns" ] && continue
  case "$ns" in
  pepsi | cocacola) continue ;; # Terraform-managed (vault-suppliers), handled by terraform destroy
  *) ADHOC_SUPPLIER_NS+=("$ns") ;;
  esac
done

# ADHOC_ROOT_KEYS is the real, full safety-net set used at execution time
# (step 4 below) — anything not on the true keep-list, so a leftover key
# is still caught even if the Terraform destroy step above it failed for
# some reason. ADHOC_ROOT_KEYS_DISPLAY is a preview-only trim of the ones
# Terraform (vault-workloads) already accounts for explicitly above, so
# the preview doesn't double-list a key as if this sweep were what
# removes it — purely cosmetic, has no effect on what actually happens.
TF_MANAGED_ROOT_KEYS=(payments-api-key external-supplier-key document-signing-key)
ROOT_TRANSIT_KEYS=$(vault list -format=json transit/keys 2>/dev/null | jq -r '.[]' || true)
ADHOC_ROOT_KEYS=()
ADHOC_ROOT_KEYS_DISPLAY=()
for k in $ROOT_TRANSIT_KEYS; do
  keep=false
  for kk in "${KEEP_TRANSIT_KEYS[@]}"; do [ "$k" = "$kk" ] && keep=true; done
  $keep && continue
  ADHOC_ROOT_KEYS+=("$k")
  tf_managed=false
  for kk in "${TF_MANAGED_ROOT_KEYS[@]}"; do [ "$k" = "$kk" ] && tf_managed=true; done
  $tf_managed || ADHOC_ROOT_KEYS_DISPLAY+=("$k")
done

WORKLOAD_CONTAINERS=(arcanium-payments-api arcanium-pki-client arcanium-kmip-client arcanium-document-signing arcanium-external-supplier)
RUNNING_WORKLOADS=()
for c in "${WORKLOAD_CONTAINERS[@]}"; do
  podman inspect "$c" >/dev/null 2>&1 && RUNNING_WORKLOADS+=("$c")
done

echo
echo "▸ Plan — this is exactly what will happen, nothing more:"
echo
echo "  KEPT (not touched at all):"
echo "    - LDAP + Keycloak: every persona, group, realm, client"
echo "    - terraform/vault-platform: core policies, arcanium/ namespace, arcanium-api's own AppRole"
echo "    - document-signing-key (Managed Key, HSM custody) and arcanium-webhook-signing"
echo "    - vault-1/2/3/vault-s/vault-hsm, postgres, softhsm, openldap, keycloak,"
echo "      arcanium-api/worker/ui/vault-agent containers (kept running throughout)"
echo
echo "  Postgres — TRUNCATE (CASCADE) ${#TRUNCATE_TABLES[@]} table(s), keeping schema_migrations + controls:"
if [ -n "$ROW_COUNTS" ]; then printf "%b" "$ROW_COUNTS"; else echo "    (all already empty)"; fi
echo
echo "  Vault — Terraform destroy:"
echo "    - terraform/vault-suppliers (pepsi, cocacola: namespaces, transit mounts, AppRoles, policies)"
echo "    - terraform/vault-workloads (payments-api-key, external-supplier-key, AppRole roles, policies —"
echo "      document-signing-key is expected to survive: deletion_allowed=false, by design)"
echo "    - terraform/vault-kmip (KMIP engine, scope, role)"
echo
if [ "${#ADHOC_SUPPLIER_NS[@]}" -gt 0 ]; then
  echo "  Vault — ad-hoc supplier namespace(s) NOT tracked by Terraform, found live:"
  for ns in "${ADHOC_SUPPLIER_NS[@]}"; do echo "    - suppliers/$ns (its own transit + auth mounts torn down, then namespace deleted)"; done
  echo
fi
if [ "${#ADHOC_ROOT_KEYS_DISPLAY[@]}" -gt 0 ]; then
  echo "  Vault — ad-hoc root-namespace transit key(s) not managed by Terraform:"
  for k in "${ADHOC_ROOT_KEYS_DISPLAY[@]}"; do echo "    - transit/keys/$k"; done
  echo
fi
if [ "$SKIP_CONTAINERS" = false ] && [ "${#RUNNING_WORKLOADS[@]}" -gt 0 ]; then
  echo "  Containers — stopped and removed (their credentials are being destroyed above):"
  for c in "${RUNNING_WORKLOADS[@]}"; do echo "    - $c"; done
  echo
fi
if [ "$INCLUDE_STALE_LEASES" = true ]; then
  echo "  Vault — also revoking stale database/creds/arcanium-api-role leases and dropping"
  echo "  orphaned v-approle-arcanium-* Postgres roles (--include-stale-leases)"
  echo
fi
echo "  Removed: .env.workloads (credentials for objects destroyed above)"
echo

read -r -p "Type 'arcanium' to confirm this clean-slate reset: " confirm
[ "$confirm" = "arcanium" ] || {
  echo "Aborted — nothing was changed."
  exit 1
}

echo
echo "▸ Executing..."

# ── 2. Ad-hoc supplier namespaces NOT tracked by Terraform ────────────────
# Must happen BEFORE `terraform destroy` on vault-suppliers: Vault refuses
# to delete a non-empty parent namespace, and the "suppliers" parent won't
# be empty if an ad-hoc child (like "fanta", found live) is still in it.
for ns in "${ADHOC_SUPPLIER_NS[@]:-}"; do
  [ -z "$ns" ] && continue
  full_ns="suppliers/$ns"
  echo "  tearing down ad-hoc namespace $full_ns ..."
  mapfile -t mounts < <(VAULT_NAMESPACE="$full_ns" vault secrets list -format=json 2>/dev/null | jq -r 'keys[]')
  for m in "${mounts[@]:-}"; do
    case "$m" in cubbyhole/ | identity/ | sys/ | agent-registry/) continue ;; esac
    [ -z "$m" ] && continue
    VAULT_NAMESPACE="$full_ns" vault secrets disable "$m" 2>/dev/null || true
  done
  mapfile -t auths < <(VAULT_NAMESPACE="$full_ns" vault auth list -format=json 2>/dev/null | jq -r 'keys[]')
  for a in "${auths[@]:-}"; do
    case "$a" in token/) continue ;; esac
    [ -z "$a" ] && continue
    VAULT_NAMESPACE="$full_ns" vault auth disable "$a" 2>/dev/null || true
  done
  vault namespace delete "$ns" -namespace=suppliers 2>&1 ||
    echo "    WARNING: could not delete namespace $full_ns — inspect and remove manually"
done

# ── 3. Terraform-managed demo modules ─────────────────────────────────────
tf_destroy() {
  local stack="$1"
  echo "  terraform destroy: $stack"
  (cd "$REPO_ROOT/terraform/$stack" &&
    terraform init -input=false -upgrade=false >/dev/null &&
    terraform destroy -input=false -auto-approve \
      -var="vault_cacert=$REPO_ROOT/vault-tls/ca-chain.pem" 2>&1) || true
}
tf_destroy vault-suppliers
tf_destroy vault-workloads
tf_destroy vault-kmip

# Verify vault-workloads' expected exception, not assumed: payments-api-key
# and external-supplier-key must actually be gone; document-signing-key
# must actually still be there (deletion_allowed=false, by design).
remaining=$(vault list -format=json transit/keys 2>/dev/null | jq -r '.[]' || true)
for should_be_gone in payments-api-key external-supplier-key; do
  if echo "$remaining" | grep -qx "$should_be_gone"; then
    echo "  WARNING: $should_be_gone still exists after terraform destroy — inspect terraform/vault-workloads manually"
  fi
done
if ! echo "$remaining" | grep -qx "document-signing-key"; then
  echo "  NOTE: document-signing-key is gone too — expected to survive (deletion_allowed=false); if this matters, restore via terraform/vault-workloads."
fi

# ── 4. Ad-hoc root-namespace transit keys (not Terraform-managed) ─────────
for k in "${ADHOC_ROOT_KEYS[@]:-}"; do
  [ -z "$k" ] && continue
  # Re-check existence — vault-workloads' own destroy may have already
  # removed a key that both this sweep and Terraform independently knew
  # about (harmless overlap, not an error).
  vault list -format=json transit/keys 2>/dev/null | jq -e --arg k "$k" 'index($k)' >/dev/null 2>&1 || continue
  echo "  destroying ad-hoc transit key: $k"
  vault write -f "transit/keys/$k/config" deletion_allowed=true >/dev/null
  vault delete "transit/keys/$k" >/dev/null
done

# ── 5. Postgres — truncate demo/build-up data, keep schema + catalogue ────
if [ "${#TRUNCATE_TABLES[@]}" -gt 0 ]; then
  echo "  truncating ${#TRUNCATE_TABLES[@]} Postgres table(s)..."
  quoted=$(printf '"%s", ' "${TRUNCATE_TABLES[@]}")
  quoted=${quoted%, }
  psql_c -c "TRUNCATE TABLE ${quoted} CASCADE;" >/dev/null
fi

# ── 6. Optional — stale dynamic DB-credential lease/role cleanup ─────────
if [ "$INCLUDE_STALE_LEASES" = true ]; then
  echo "  revoking stale database/creds/arcanium-api-role leases..."
  vault lease revoke -prefix "database/creds/arcanium-api-role" >/dev/null 2>&1 || true
  active_user=$(podman exec -i arcanium-vault_agent cat /vault/secrets/db-creds.json 2>/dev/null | jq -r '.username // empty' || true)
  mapfile -t stale_roles < <(psql_c -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'v-approle-arcanium-%'")
  for r in "${stale_roles[@]:-}"; do
    [ -z "$r" ] && continue
    [ "$r" = "$active_user" ] && continue
    psql_c -c "DROP ROLE IF EXISTS \"$r\";" >/dev/null 2>&1 || true
  done
fi

# ── 7. Generated credential files tied to now-destroyed Vault objects ────
rm -f "$REPO_ROOT/.env.workloads"

# ── 8. Workload containers (their credentials no longer exist) ───────────
if [ "$SKIP_CONTAINERS" = false ] && [ "${#RUNNING_WORKLOADS[@]}" -gt 0 ]; then
  echo "  stopping/removing workload containers..."
  podman stop "${RUNNING_WORKLOADS[@]}" >/dev/null 2>&1 || true
  podman rm "${RUNNING_WORKLOADS[@]}" >/dev/null 2>&1 || true
fi

echo
echo "════════════════════════════════════════════════════════════════"
echo " Done. Identity (LDAP/Keycloak) and the base platform were never"
echo " touched — everything else is a clean slate."
echo
echo " To repopulate a fresh demo dataset:"
echo "   make onboarding && make workloads-up   # payments-api/pki-client + app registration"
echo "   make supplier-provision                # pepsi/cocacola tenants"
echo "   make approval-provision                # external-supplier/approver-1"
echo "   ...or make rehydrate for the full sequence"
echo "════════════════════════════════════════════════════════════════"

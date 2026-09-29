#!/usr/bin/env bash
# scripts/vault-restore-drill.sh — inherited from arcanium (its Prompt 24,
# Deliverable 3, "Drill A").
#
# NOT YET FULLY ADAPTED FOR FACTORY — content, not just naming.
#
# The DRILL PATTERN below (real snapshot -> restore into an isolated
# instance -> verify real post-restore state -> measure real RTO/RPO,
# never treating "snapshot is readable" as "restore succeeded") is
# genuinely reusable and worth keeping for Factory's own Vault cluster
# (prompts/base_project/02_01_vault_ha_cluster.md). Three concrete
# dependencies are NOT part of Factory's design yet and must be replaced
# before this script can actually run, not merely renamed:
#   1. compose/vault/compose.restore-drill.yaml does not exist yet —
#      belongs with prompts/base_project/02_01_vault_ha_cluster.md.
#   2. The post-restore verification checks a Transit key
#      ("demo-app-key") and a Vault namespace ("arcanium") — Factory's
#      design uses neither Transit nor namespaces (only the Database
#      secrets engine — prompts/base_project/03_01_postgres_dynamic_creds.md).
#      Replace this check with something Factory actually has, e.g.
#      confirming `database/roles/factory-bad-role` and
#      `database/roles/factory-good-role` are present post-restore.
#   3. `restore_drill_results` is not yet a table in Factory's schema
#      (prompts/api/01_01_factory_schema_and_tools.md does not define
#      it) — add it there if this drill is adopted.
# Only the mechanical infra tokens below (project name, Postgres
# container/user/db) were renamed in this pass.
set -uo pipefail
umask 077
cd "$(dirname -- "$0")/.." # -> repo root
# shellcheck source=scripts/vault-common.sh
source scripts/vault-common.sh

PROJECT="factory-vault-restore-drill"
COMPOSE_FILE="compose/vault/compose.restore-drill.yaml"
DRILL_ADDR="https://127.0.0.1:18400"
RESULT="UNKNOWN"
DETAIL=""

# Match scripts/compose.sh's own invocation exactly (--env-file .env,
# PODMAN_COMPOSE_PROVIDER pinned) — found live: calling `podman compose`
# directly without these picked a different, unpinned compose provider
# (docker-compose, not podman-compose) and silently dropped VAULT_LICENSE
# (blank without --env-file), so the container built but Vault itself
# never came up.
: "${PODMAN_COMPOSE_PROVIDER:=podman-compose}"
export PODMAN_COMPOSE_PROVIDER
drill_compose() {
  podman compose --project-name "$PROJECT" --file "$COMPOSE_FILE" --env-file "$PWD/.env" "$@"
}

teardown() {
  echo "[restore-drill] tearing down the isolated instance"
  drill_compose down >/dev/null 2>&1 || true
  podman volume rm -f "${PROJECT}_vault-restore-drill-data" >/dev/null 2>&1 || true
}
trap teardown EXIT

record_result() {
  local started="$1" completed="$2" rto="$3" rpo="$4" verified="$5" detail="$6"
  podman exec -i factory-postgres psql -U factory -d factory_db -v ON_ERROR_STOP=1 >/dev/null <<SQL
INSERT INTO restore_drill_results (component, started_at, completed_at, rto_seconds, rpo_seconds, verified, detail)
VALUES ('vault', to_timestamp($started), to_timestamp($completed), $rto, $rpo, $verified, '$detail'::jsonb);
SQL
}

echo "[restore-drill] step 1/7: taking a fresh Vault snapshot (scripts/vault-backup.sh)"
STARTED=$(date +%s)
BACKUP_OUT=$(./scripts/vault-backup.sh)
echo "$BACKUP_OUT"
BACKUP_DIR=$(echo "$BACKUP_OUT" | grep -oE '/[^ ]*/backups/vault-[^ ]*' | head -1)
[ -n "$BACKUP_DIR" ] || {
  echo "[restore-drill] could not determine backup directory from vault-backup.sh output" >&2
  exit 1
}
SNAP="$BACKUP_DIR/cluster.snap"
[ -f "$SNAP" ] || {
  echo "[restore-drill] snapshot file not found: $SNAP" >&2
  exit 1
}
SNAP_TAKEN_AT=$(date +%s) # backup just completed — RPO baseline

echo "[restore-drill] step 2/7: bringing up the isolated Vault instance ($PROJECT)"
drill_compose up -d

echo "[restore-drill] step 3/7: waiting for the isolated instance to be reachable"
for i in $(seq 1 30); do
  curl -sk --max-time 3 "$DRILL_ADDR/v1/sys/health?standbyok=true&sealedok=true&uninitok=true" >/dev/null 2>&1 && break
  sleep 2
done

echo "[restore-drill] step 4/7: initializing the fresh instance (temporary — superseded by the restored snapshot)"
export VAULT_ADDR="$DRILL_ADDR"
export VAULT_CACERT="$PWD/vault-tls/ca-chain.pem"
TMP_INIT=$(vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
TMP_TOKEN=$(echo "$TMP_INIT" | jq -er '.root_token')

echo "[restore-drill] step 5/7: restoring the snapshot"
export VAULT_TOKEN="$TMP_TOKEN"
if ! vault operator raft snapshot restore "$SNAP"; then
  COMPLETED=$(date +%s)
  RESULT="FAILED"
  DETAIL="snapshot restore command failed"
  record_result "$STARTED" "$COMPLETED" "$((COMPLETED - STARTED))" "$((SNAP_TAKEN_AT - STARTED))" false "{\"error\":\"restore failed\"}"
  echo "[restore-drill] FAILED: $DETAIL" >&2
  exit 1
fi
unset VAULT_TOKEN TMP_TOKEN

echo "[restore-drill] step 6/7: waiting for the restored instance to auto-unseal, then verifying real state"
# `vault status -format=json` (via vault_json, already used everywhere
# else in this script family), not a raw curl against /v1/sys/health —
# found live while proving this drill: that endpoint returns different
# HTTP status codes and body shapes through the restore's own reindex/
# election window (visible in `podman logs`: "a merkle tree reindex is
# required", "heartbeat timeout reached, starting election"), and a plain
# curl+jq read doesn't handle that transition as reliably as vault_json's
# already-established exit-code handling (0 = reachable+read, 2 = sealed
# but reachable).
export VAULT_ADDR="$DRILL_ADDR"
UNSEALED=false
for i in $(seq 1 40); do
  vjout=$(vault_json 2>/dev/null) && vjcode=0 || vjcode=$?
  # Found live: `jq -r '.sealed // "unknown"'` is wrong here — jq's `//`
  # alternative operator treats a JSON `false` as falsy (same as null), so
  # it silently rewrote a genuine `"sealed": false` into the string
  # "unknown" and the loop never matched. Use `jq -e '.sealed == false'`
  # (an explicit equality test) instead of extracting-then-comparing.
  if [ "$vjcode" -eq 0 ] && echo "$vjout" | jq -e '.sealed == false' >/dev/null 2>&1; then
    UNSEALED=true
    break
  fi
  sleep 3
done

VERIFIED=false
if [ "$UNSEALED" = true ]; then
  # Authenticate with the REAL cluster root token — the restored data's
  # own auth state, not the temporary init token from step 4 (which the
  # snapshot restore already superseded).
  vault_root cluster >/dev/null 2>&1 || true
  REAL_TOKEN=$(jq -er '.root_token' .secrets/vault/cluster-init.json)
  KEY_JSON=$(curl -sk --max-time 5 -H "X-Vault-Token: $REAL_TOKEN" "$DRILL_ADDR/v1/transit/keys/demo-app-key" 2>/dev/null || echo "{}")
  KEY_VERSION=$(echo "$KEY_JSON" | jq -r '.data.latest_version // "missing"' 2>/dev/null)
  NS_JSON=$(curl -sk --max-time 5 -H "X-Vault-Token: $REAL_TOKEN" "$DRILL_ADDR/v1/sys/namespaces/arcanium" 2>/dev/null || echo "{}")
  NS_PRESENT=$(echo "$NS_JSON" | jq -e '.data.path == "arcanium/"' >/dev/null 2>&1 && echo true || echo false)
  if [ "$KEY_VERSION" != "missing" ] && [ "$KEY_VERSION" != "null" ] && [ "$NS_PRESENT" = "true" ]; then
    VERIFIED=true
    DETAIL="{\"transit_key\":\"demo-app-key\",\"key_version\":$KEY_VERSION,\"namespace_present\":true}"
  else
    DETAIL="{\"transit_key_version\":\"$KEY_VERSION\",\"namespace_present\":$NS_PRESENT,\"note\":\"restored instance unsealed but expected state not fully present\"}"
  fi
else
  DETAIL='{"error":"restored instance did not unseal within timeout"}'
fi

COMPLETED=$(date +%s)
RTO=$((COMPLETED - STARTED))
RPO=$((SNAP_TAKEN_AT - STARTED)) # near-zero by construction — the snapshot this drill restores is one it just took

echo "[restore-drill] step 7/7: recording the result"
record_result "$STARTED" "$COMPLETED" "$RTO" "$RPO" "$VERIFIED" "$DETAIL"

echo
echo "== Vault restore drill (Drill A) result =="
echo "  verified:     $VERIFIED"
echo "  rto_seconds:  $RTO"
echo "  rpo_seconds:  $RPO"
echo "  detail:       $DETAIL"

[ "$VERIFIED" = true ]

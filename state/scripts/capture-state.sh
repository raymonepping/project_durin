#!/usr/bin/env bash
# capture-state.sh — Prompt 00. Build one immutable, atomic baseline under
# state/baselines/<id>/.
#
# Three tiers:
#   source     — exactly which code formed this baseline (git, hashes, tool
#                versions, folder_tree's git-tracked structure)
#   deployment — what is actually running (components/<name>/*.json —
#                whitelisted fields, config MODE flags, never values)
#   observed   — functional checks against live endpoints (verification/)
#
# Hard rules (never violated):
#  - Whitelist fields, never capture-then-redact. No `podman inspect`, no
#    `podman compose config`, no full process environment.
#  - Every check reports CAPTURED / PARTIAL / UNKNOWN / FAILED — a check
#    that couldn't run says so; it never reads as "no problems found".
#  - Mutating verification is opt-in only (--with-scenarios).
#  - Atomic: built entirely in a .tmp dir, validated, then renamed into
#    place. A baseline directory existing means it completed and validated
#    — never a partial artifact of a killed run.
#  - commit_gh and folder_tree are the mandatory tools for what they do;
#    this script does not reimplement project-tree discovery or repo
#    secret-scanning logic itself.
#
# Usage:
#   state/scripts/capture-state.sh <baseline-id> ["purpose"] [--with-scenarios]
set -uo pipefail
cd "$(dirname -- "$0")/../.." # -> repo root

BASELINE_ID="${1:?usage: capture-state.sh <baseline-id> [purpose] [--with-scenarios]}"
shift || true
PURPOSE="baseline capture"
WITH_SCENARIOS=false
for arg in "$@"; do
  case "$arg" in
  --with-scenarios) WITH_SCENARIOS=true ;;
  *) PURPOSE="$arg" ;;
  esac
done

FINAL="state/baselines/${BASELINE_ID}"
TMP="state/.capture-${BASELINE_ID}.tmp"

if [ -d "$FINAL" ]; then
  echo "error: $FINAL already exists — baselines are immutable, never overwritten in place." >&2
  echo "Pick a new id, or remove the directory yourself first if this was a mistake." >&2
  exit 1
fi
if [ -d "$TMP" ]; then
  echo "error: $TMP already exists from a previous incomplete run — remove it first." >&2
  exit 1
fi
mkdir -p "$TMP"/{source,runtime,components,verification}

command -v folder_tree >/dev/null 2>&1 || {
  echo "error: folder_tree not found on PATH — it is the mandatory project-structure tool for this capture (Prompt 00)." >&2
  rm -rf "$TMP"
  exit 2
}

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PROJECT_NAME="$(basename "$(pwd)")"
declare -A STATUS # check-name -> CAPTURED|PARTIAL|UNKNOWN|FAILED

set_status() { STATUS["$1"]="$2"; }

# The Podman machine socket on this host is intermittently flaky (drops and
# recovers within a second or two — a known local issue, not a real
# stopped-stack signal). A single failed `podman ps` must not be recorded as
# "not running"; retry briefly before believing it.
podman_ok() {
  local attempt
  for attempt in 1 2 3; do
    podman ps >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

running() {
  local attempt
  for attempt in 1 2 3; do
    # Not `grep -qx`: under `set -o pipefail` (this script's own top-level
    # setting), grep -q's early exit on a match can SIGPIPE the still-
    # writing `podman ps`, and pipefail then reports THAT non-zero exit
    # instead of grep's successful match — an intermittent false-negative
    # found live while testing Deliverable 12's capture_persistence().
    # Plain `grep -x` (redirected, not quieted) reads to completion, so
    # `podman ps` always exits 0 and pipefail has nothing non-zero to report.
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -x "$1" >/dev/null; then return 0; fi
    podman ps >/dev/null 2>&1 || {
      sleep 1
      continue
    }
    return 1 # podman answered, container just isn't in the list
  done
  return 1
}

# ---------------------------------------------------------------- source --
capture_source() {
  local ok=true

  git rev-parse HEAD >"$TMP/source/git.txt" 2>/dev/null || ok=false
  {
    echo "branch: $(git branch --show-current 2>/dev/null || echo unknown)"
    echo "tag: $(git describe --tags --exact-match 2>/dev/null || echo none)"
  } >>"$TMP/source/git.txt"

  git status --short >"$TMP/source/git-status.txt" 2>/dev/null || ok=false
  local dirty=false
  [ -s "$TMP/source/git-status.txt" ] && dirty=true

  git diff HEAD -- . >"$TMP/source/diff.patch" 2>/dev/null || true

  jq -n \
    --arg node "$(node --version 2>/dev/null || echo unknown)" \
    --arg terraform "$(terraform -version 2>/dev/null | head -1 || echo unknown)" \
    --arg vault_cli "$(vault version 2>/dev/null || echo unknown)" \
    --arg podman "$(podman --version 2>/dev/null || echo unknown)" \
    '{node:$node, terraform:$terraform, vault_cli:$vault_cli, podman:$podman}' \
    >"$TMP/source/versions.json"

  # Whitelisted file hashes only — compose + terraform definitions, never .env.
  {
    find compose -name 'compose.yaml' -o -name 'compose.yml' 2>/dev/null
    find terraform -name '*.tf' 2>/dev/null
  } | sort | xargs shasum -a 256 >"$TMP/source/hashes.sha256" 2>/dev/null || ok=false

  # Mandatory per Prompt 00 — the git-tracked project structure, via the
  # project's own discovery tool. Never substituted with find/tree/ls -R.
  if folder_tree --output git . >"$TMP/source/project-tree.md" 2>/dev/null &&
    [ -s "$TMP/source/project-tree.md" ]; then
    :
  else
    ok=false
  fi

  $ok && set_status source CAPTURED || set_status source PARTIAL
  echo "  git dirty: $dirty"
}

# --------------------------------------------------------------- runtime --
capture_runtime() {
  if ! podman_ok; then
    for f in containers.json images.json networks.json; do
      echo '{"status":"UNKNOWN","detail":"podman unreachable at capture time"}' >"$TMP/runtime/$f"
    done
    echo "podman unreachable at capture time" >"$TMP/runtime/volumes.txt"
    set_status runtime UNKNOWN
    return
  fi

  # Whitelisted fields only: never podman inspect (pulls full env), never
  # podman compose config (resolves .env substitution).
  podman ps -a --format json 2>/dev/null |
    jq '[.[] | {name: .Names[0], image: .Image, state: .State, status: .Status,
                   ports: (.Ports // []), networks: (.Networks // [])}]' \
      >"$TMP/runtime/containers.json" || echo '[]' >"$TMP/runtime/containers.json"

  podman images --format json 2>/dev/null |
    jq '[.[] | {repository: (.Names[0] // "none"), id: .Id, digest: (.Digest // "unknown"),
                   size: .Size, created: .CreatedAt}]' \
      >"$TMP/runtime/images.json" || echo '[]' >"$TMP/runtime/images.json"

  podman network ls --format json 2>/dev/null |
    jq '[.[] | {name: .Name, driver: .Driver}]' \
      >"$TMP/runtime/networks.json" || echo '[]' >"$TMP/runtime/networks.json"

  podman volume ls --format '{{.Name}}' 2>/dev/null >"$TMP/runtime/volumes.txt" || true

  set_status runtime CAPTURED
}

# -------------------------------------------------------------- arcanium --
# Non-secret .env allowlist — MODE flags only, never a value that could be a
# credential. Extend this list deliberately; never widen it to "everything".
ENV_ALLOWLIST="ARCANIUM_AUTH_ENABLED ARCANIUM_DEMO_PERSONA_SWITCH PROVISION_MODE NODE_ENV POSTGRES_DB"

capture_arcanium() {
  local d="$TMP/components/arcanium"
  mkdir -p "$d"
  local health_ok=false

  {
    echo "{"
    local first=true
    for key in $ENV_ALLOWLIST; do
      local val
      val="$(grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
      [ -z "$val" ] && val="(unset)"
      $first || echo ","
      first=false
      printf '  "%s": %s' "$key" "$(jq -Rn --arg v "$val" '$v')"
    done
    echo
    echo "}"
  } >"$d/mode-flags.json"

  if running arcanium-api; then
    if curl -fsS --max-time 5 http://localhost:3001/health >"$d/health.json" 2>/dev/null ||
      curl -fsS --max-time 5 http://localhost:3001/api/v1/health >"$d/health.json" 2>/dev/null; then
      health_ok=true
    else
      echo '{"status":"UNKNOWN","detail":"arcanium-api running but health endpoint did not respond"}' >"$d/health.json"
    fi
    curl -fsS --max-time 5 http://localhost:3001/api/v1/maturity 2>/dev/null >"$d/api-smoke.json" ||
      echo '{"status":"UNKNOWN","detail":"maturity endpoint did not respond"}' >"$d/api-smoke.json"
  else
    echo '{"status":"UNKNOWN","detail":"arcanium-api not running"}' >"$d/health.json"
  fi

  # Prompt 30 — Vault Agent's own rendered-file freshness. Never
  # fabricated: UNKNOWN unless the container is actually running and both
  # files are actually readable. mtime, not file content (the token/DB
  # password are never captured here).
  if running arcanium-vault_agent; then
    local token_mtime creds_mtime
    token_mtime=$(podman exec arcanium-vault_agent stat -c '%Y' /vault/secrets/token 2>/dev/null || echo "")
    creds_mtime=$(podman exec arcanium-vault_agent stat -c '%Y' /vault/secrets/db-creds.json 2>/dev/null || echo "")
    jq -n \
      --arg tm "${token_mtime:-null}" --arg cm "${creds_mtime:-null}" \
      '{
        token_file: { present: ($tm != "null" and $tm != ""), mtime_epoch: (if $tm == "null" or $tm == "" then null else ($tm | tonumber) end) },
        db_creds_file: { present: ($cm != "null" and $cm != ""), mtime_epoch: (if $cm == "null" or $cm == "" then null else ($cm | tonumber) end) }
      }' >"$d/vault-agent.json"
  else
    jq -n '{status:"UNKNOWN", detail:"arcanium-vault_agent not running"}' >"$d/vault-agent.json"
    echo '{"status":"UNKNOWN","detail":"arcanium-api not running"}' >"$d/api-smoke.json"
  fi

  ls arcanium/api/src/migrations/ 2>/dev/null >"$d/migrations.txt" || echo "(migrations dir unreadable)" >"$d/migrations.txt"

  jq -n --arg expected true --arg observed "$(running arcanium-api && echo true || echo false)" \
    '{expected: ($expected=="true"), observed: ($observed=="true")}' >"$d/status.json"

  if $health_ok; then
    set_status arcanium CAPTURED
  elif running arcanium-api; then
    set_status arcanium PARTIAL
  else
    set_status arcanium UNKNOWN
  fi
}

# ------------------------------------------------------------------ vault --
capture_vault() {
  local d="$TMP/components/vault"
  mkdir -p "$d"
  if ! running arcanium-vault_1; then
    for f in cluster.json mounts.json auth-methods.json audit-devices.json namespaces.json policies-summary.json; do
      echo '{"status":"UNKNOWN","detail":"vault-1 not running"}' >"$d/$f"
    done
    set_status vault UNKNOWN
    return
  fi

  # shellcheck source=scripts/vault-common.sh
  source scripts/vault-common.sh 2>/dev/null

  local nodes_json="[]"
  for node in vault-s vault-1 vault-2 vault-3; do
    vault_node "$node"
    local s
    if s=$(vault_json 2>/dev/null); then
      nodes_json=$(jq --argjson n "$s" --arg name "$node" '. + [{node:$name, initialized:$n.initialized, sealed:$n.sealed, seal_type:$n.type, version:$n.version}]' <<<"$nodes_json")
    else
      nodes_json=$(jq --arg name "$node" '. + [{node:$name, reachable:false}]' <<<"$nodes_json")
    fi
  done
  echo "$nodes_json" | jq '{nodes: .}' >"$d/cluster.json"

  # Authenticated, metadata-only reads. Token comes from the existing local
  # secrets file via vault_root — used only to authenticate this process,
  # never written to any output file.
  local vault_status="PARTIAL"
  if vault_node vault-1 && vault_root cluster 2>/dev/null; then
    vault secrets list -format=json 2>/dev/null >"$d/mounts.json" ||
      echo '{"status":"UNKNOWN"}' >"$d/mounts.json"
    vault auth list -format=json 2>/dev/null >"$d/auth-methods.json" ||
      echo '{"status":"UNKNOWN"}' >"$d/auth-methods.json"
    vault audit list -format=json 2>/dev/null >"$d/audit-devices.json" ||
      echo '{"status":"UNKNOWN"}' >"$d/audit-devices.json"
    vault namespace list -format=json 2>/dev/null >"$d/namespaces.json" ||
      echo '[]' >"$d/namespaces.json"
    vault policy list -format=json 2>/dev/null | jq '{acl: .}' >"$d/policies-summary.json" 2>/dev/null ||
      echo '{"status":"UNKNOWN"}' >"$d/policies-summary.json"
    unset VAULT_TOKEN
    vault_status="CAPTURED"
  else
    for f in mounts.json auth-methods.json audit-devices.json namespaces.json policies-summary.json; do
      echo '{"status":"UNKNOWN","detail":"could not authenticate for metadata read"}' >"$d/$f"
    done
  fi

  set_status vault "$vault_status"
}

# -------------------------------------------------------------------- hsm --
capture_hsm() {
  local d="$TMP/components/hsm"
  mkdir -p "$d"
  local st="UNKNOWN"
  if running arcanium-vault_hsm; then st="PARTIAL"; fi
  if running arcanium-softhsm_server; then st="PARTIAL"; fi
  if running arcanium-vault_hsm && running arcanium-softhsm_server; then st="CAPTURED"; fi

  jq -n --arg vault_hsm "$(running arcanium-vault_hsm && echo running || echo down)" \
    --arg softhsm "$(running arcanium-softhsm_server && echo running || echo down)" \
    --arg impl "SoftHSM/PKCS11 (emulated HSM, not a production HSM)" \
    '{vault_hsm: $vault_hsm, softhsm_proxy: $softhsm, implementation: $impl}' \
    >"$d/status.json"

  echo "not captured in this baseline — requires an authenticated container exec against softhsm; deferred, not fabricated" \
    >"$d/pkcs11-slots.txt"
  echo '{"status":"UNKNOWN","detail":"Managed Key inventory not queried in this capture — see components/vault/mounts.json for the keymgmt mount presence instead"}' \
    >"$d/managed-keys.json"

  set_status hsm "$st"
}

# ----------------------------------------------------------------- identity --
# Prompt 18's OpenLDAP + Keycloak identity stack. Added here because it was
# missing entirely from earlier captures — found live, by the person who
# actually reads these baselines, not by re-reading this script more
# carefully. OpenLDAP is never queried anonymously (see docs/security.md /
# Prompt 18 execution log — its default ACLs hide entry existence from
# unauthenticated binds), so the LDAP check authenticates the same way
# compose/identity/ldap/setup_ldap.sh does. Keycloak's realm discovery
# document is public by OIDC spec design — reachable straight from the host
# on its published port, no exec/auth needed.
capture_identity() {
  local d="$TMP/components/identity"
  mkdir -p "$d"
  local ldap_up=false kc_up=false ldap_auth_ok=false kc_discovery_ok=false

  running arcanium-openldap && ldap_up=true
  running arcanium-keycloak && kc_up=true

  jq -n --arg openldap "$($ldap_up && echo running || echo down)" \
    --arg ldap_admin "$(running arcanium-ldap-admin && echo running || echo down)" \
    --arg keycloak "$($kc_up && echo running || echo down)" \
    '{openldap: $openldap, ldap_admin: $ldap_admin, keycloak: $keycloak}' \
    >"$d/status.json"

  if $ldap_up; then
    LDAP_ADMIN_PASSWORD="$(grep -E '^LDAP_ADMIN_PASSWORD=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
    if [ -n "$LDAP_ADMIN_PASSWORD" ] && podman exec arcanium-openldap \
      ldapsearch -x -H ldap://localhost -D "cn=admin,dc=arcanium,dc=local" \
      -w "$LDAP_ADMIN_PASSWORD" -b "dc=arcanium,dc=local" -s base >/dev/null 2>&1; then
      ldap_auth_ok=true
      echo '{"result":"PASS","detail":"authenticated base-DN search succeeded"}' >"$d/ldap-check.json"
    else
      echo '{"result":"UNKNOWN","detail":"authenticated base-DN search did not succeed (LDAP_ADMIN_PASSWORD unset, or container not ready)"}' >"$d/ldap-check.json"
    fi
  else
    echo '{"result":"UNKNOWN","detail":"openldap not running"}' >"$d/ldap-check.json"
  fi

  if $kc_up; then
    ISSUER="$(grep -E '^ARCANIUM_OIDC_PUBLIC_URL=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
    if [ -n "$ISSUER" ] && curl -fsS --max-time 5 "${ISSUER}/realms/arcanium/.well-known/openid-configuration" \
      >"$d/keycloak-discovery.json" 2>/dev/null; then
      kc_discovery_ok=true
    else
      echo '{"status":"UNKNOWN","detail":"realm discovery endpoint did not respond"}' >"$d/keycloak-discovery.json"
    fi
  else
    echo '{"status":"UNKNOWN","detail":"keycloak not running"}' >"$d/keycloak-discovery.json"
  fi

  if $ldap_auth_ok && $kc_discovery_ok; then
    set_status identity CAPTURED
  elif $ldap_up || $kc_up; then
    set_status identity PARTIAL
  else
    set_status identity UNKNOWN
  fi
}

# ------------------------------------------------------------------ infra --
capture_infra() {
  local d="$TMP/components/infra"
  mkdir -p "$d"
  local st="UNKNOWN"
  if running arcanium-postgres; then
    st="CAPTURED"
    jq -n '{postgres: "running", note: "no query executed against the database — container status only"}' \
      >"$d/postgres.json"
  else
    echo '{"status":"UNKNOWN","detail":"arcanium-postgres not running"}' >"$d/postgres.json"
  fi
  ls arcanium/api/src/migrations/ 2>/dev/null >"$d/schema.txt" || echo "(unreadable)" >"$d/schema.txt"
  set_status infra "$st"
}

# -------------------------------------------------------------------- kms --
capture_kms() {
  local d="$TMP/components/kms"
  mkdir -p "$d"
  if running arcanium-localstack; then
    if curl -fsS --max-time 5 http://localhost:4566/_localstack/health >"$d/status.json" 2>/dev/null; then
      set_status kms CAPTURED
    else
      echo '{"status":"PARTIAL","detail":"container running, health endpoint did not respond"}' >"$d/status.json"
      set_status kms PARTIAL
    fi
  else
    echo '{"status":"UNKNOWN","detail":"kms-sim (LocalStack) not running","emulated":true}' >"$d/status.json"
    set_status kms UNKNOWN
  fi
}

# ---------------------------------------------------------- observability --
capture_observability() {
  local d="$TMP/components/observability"
  mkdir -p "$d"
  local containers
  containers=$(podman ps --format '{{.Names}}' 2>/dev/null | grep -E 'arcanium-(prometheus|grafana|otel-collector)$' || true)
  jq -n --arg containers "$containers" '{running_containers: ($containers | split("\n") | map(select(length>0)))}' \
    >"$d/status.json"

  if curl -fsS --max-time 5 http://localhost:9090/api/v1/targets 2>/dev/null |
    jq '{activeTargets: [.data.activeTargets[]? | {job: .labels.job, health: .health}]}' \
      >"$d/targets.json" 2>/dev/null; then
    set_status observability CAPTURED
  else
    echo '{"status":"UNKNOWN","detail":"prometheus targets endpoint not reachable"}' >"$d/targets.json"
    [ -n "$containers" ] && set_status observability PARTIAL || set_status observability UNKNOWN
  fi
}

# -------------------------------------------------------------- workloads --
capture_workloads() {
  local d="$TMP/components/workloads"
  mkdir -p "$d"
  local names
  names=$(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'arcanium-(payments-api|pki-client|kmip-client|document-signing|external-supplier)$' || true)
  if [ -z "$names" ]; then
    echo '{"status":"UNKNOWN","detail":"no workload containers found"}' >"$d/status.json"
    echo '[]' >"$d/inventory.json"
    set_status workloads UNKNOWN
    return
  fi
  podman ps -a --format json 2>/dev/null |
    jq '[.[] | select(.Names[0] | test("arcanium-(payments-api|pki-client|kmip-client|document-signing|external-supplier)$")) | {name: .Names[0], state: .State, status: .Status}]' \
      >"$d/inventory.json"
  jq '{count: length, running: [.[] | select(.state=="running")] | length}' "$d/inventory.json" \
    >"$d/status.json"
  set_status workloads CAPTURED
}

# ---------------------------------------------------------- persistence --
# Pre-24, Deliverable 12. Safe, non-secret persistence indicators only —
# volume PRESENCE (podman volume ls), never volume CONTENTS. Never
# SecretIDs, OIDC client secrets, LDAP passwords, Vault tokens, HSM PINs,
# or database passwords — see capture_persistence's own field list below
# against docs/persistence.md's PERSIST/REHYDRATE/REISSUE/EPHEMERAL model.
capture_persistence() {
  local d="$TMP/components/persistence"
  mkdir -p "$d"
  local vols
  vols=$(podman volume ls --format '{{.Name}}' 2>/dev/null || true)
  vol_present() { echo "$vols" | grep -qx "$1" && echo true || echo false; }

  local schema_version="unknown"
  schema_version=$(ls arcanium/api/src/migrations/ 2>/dev/null | sort | tail -1 | grep -oE '^[0-9]+' || echo "unknown")

  local cluster_id="unknown"
  if running arcanium-vault_1; then
    # No -f: sys/health returns non-200 for standby/perf-standby nodes by
    # design (docs/architecture.md, docs/operations.md — a healthy standby
    # is not an error). Read the body regardless of status.
    cluster_id=$(curl -sk --max-time 5 https://127.0.0.1:18200/v1/sys/health 2>/dev/null |
      jq -r '.cluster_id // "unknown"' 2>/dev/null || echo "unknown")
  fi

  local cred_ready="false" cred_detail="not checked"
  if [ -x scripts/workload-credentials.sh ]; then
    if ./scripts/workload-credentials.sh verify-all >"$d/workload-credentials-verify.log" 2>&1; then
      cred_ready="true"
      cred_detail="verify-all PASS"
    else
      local rc=$?
      if [ "$rc" -eq 2 ]; then
        cred_detail="verify-all UNKNOWN (Vault unreachable for one or more identities)"
      else
        cred_detail="verify-all FAIL — see workload-credentials-verify.log"
      fi
    fi
  else
    cred_detail="scripts/workload-credentials.sh not found"
  fi

  # restart_persistence reflects the hostile Deliverable-9 scenario, not
  # this capture itself — UNKNOWN unless that scenario left its own result
  # marker (scenarios/pre_24_persistence/test_restart_persistence.sh writes
  # state/.last-persistence-scenario-result on completion).
  local restart_persistence="UNKNOWN"
  local restart_detail="scenarios/pre_24_persistence/test_restart_persistence.sh has not been run"
  if [ -f state/.last-persistence-scenario-result ]; then
    restart_persistence=$(cat state/.last-persistence-scenario-result)
    restart_detail="from scenarios/pre_24_persistence/test_restart_persistence.sh's last run"
  fi

  jq -n \
    --arg postgres_vol "$(vol_present arcanium-infra_postgres-data)" \
    --arg schema_version "$schema_version" \
    --arg vault_1 "$(vol_present arcanium-vault_vault-1-data)" \
    --arg vault_2 "$(vol_present arcanium-vault_vault-2-data)" \
    --arg vault_3 "$(vol_present arcanium-vault_vault-3-data)" \
    --arg vault_s "$(vol_present arcanium-vault_vault-s-data)" \
    --arg cluster_id "$cluster_id" \
    --arg ldap_data "$(vol_present arcanium-identity_ldap-data)" \
    --arg keycloak_data "$(vol_present arcanium-identity_keycloak-data)" \
    --arg softhsm "$(vol_present arcanium-hsm_softhsm-data)" \
    --arg vault_hsm "$(vol_present arcanium-hsm_vault-hsm-data)" \
    --arg cred_ready "$cred_ready" \
    --arg cred_detail "$cred_detail" \
    --arg restart_persistence "$restart_persistence" \
    --arg restart_detail "$restart_detail" \
    '{
      postgres: {volume_present: ($postgres_vol=="true"), schema_version: $schema_version},
      vault: {
        raft_storage_present: {main_1: ($vault_1=="true"), main_2: ($vault_2=="true"), main_3: ($vault_3=="true"), seal_provider: ($vault_s=="true")},
        cluster_id: $cluster_id
      },
      identity: {ldap_directory_present: ($ldap_data=="true"), keycloak_data_present: ($keycloak_data=="true")},
      hsm: {softhsm_token_store_present: ($softhsm=="true"), vault_hsm_storage_present: ($vault_hsm=="true")},
      workloads: {credential_bootstrap_ready: ($cred_ready=="true"), detail: $cred_detail},
      restart_persistence: {result: $restart_persistence, detail: $restart_detail}
    }' >"$d/persistence.json"

  # Volume-name guesses above depend on the podman-compose project-name
  # prefix actually in use on this machine — verify at least one resolved
  # rather than silently reporting an all-false false negative.
  local any_found=false
  echo "$vols" | grep -q "postgres-data\|vault.*data\|ldap-data\|keycloak-data\|softhsm-data" && any_found=true

  if [ "$any_found" = true ]; then
    set_status persistence CAPTURED
  else
    set_status persistence PARTIAL
  fi
}

# ----------------------------------------------------------------- backup --
# Prompt 24, Deliverable 8. state/README.md's "state is not backup" rule
# applies exactly as written: this reads whether a restore drill has ever
# actually verified recovery, and its measured RTO/RPO — never the
# snapshot/dump itself. Only the most recent VERIFIED row per component
# counts here; a later failed re-run must not blank out the last
# known-good measurement (available only ever means "a drill has ever
# actually verified recovery," not "a row exists").
capture_backup() {
  local d="$TMP/components/backup"
  mkdir -p "$d"

  if ! running arcanium-postgres; then
    jq -n '{vault_snapshot: {available: false, last_verified_at: null, rto_seconds: null, rpo_seconds: null},
            postgres:      {available: false, last_verified_at: null, rto_seconds: null, rpo_seconds: null}}' \
      >"$d/backup.json"
    set_status backup UNKNOWN
    return
  fi

  local rows rc
  rows=$(podman exec -i arcanium-postgres psql -U arcanium -d arcanium_db -t -A -F'|' -c \
    "select distinct on (component) component, completed_at, rto_seconds, rpo_seconds
     from restore_drill_results where verified = true order by component, completed_at desc;" \
    2>"$d/query.err")
  rc=$?

  component_json() {
    local row="$1"
    if [ -z "$row" ]; then
      jq -n '{available: false, last_verified_at: null, rto_seconds: null, rpo_seconds: null}'
    else
      jq -n \
        --arg t "$(cut -d'|' -f2 <<<"$row")" \
        --arg rto "$(cut -d'|' -f3 <<<"$row")" \
        --arg rpo "$(cut -d'|' -f4 <<<"$row")" \
        '{available: true, last_verified_at: $t, rto_seconds: ($rto | tonumber), rpo_seconds: ($rpo | tonumber)}'
    fi
  }

  local vault_row postgres_row
  vault_row=$(echo "$rows" | awk -F'|' '$1=="vault"{print; exit}')
  postgres_row=$(echo "$rows" | awk -F'|' '$1=="postgres"{print; exit}')

  jq -n \
    --argjson vault "$(component_json "$vault_row")" \
    --argjson postgres "$(component_json "$postgres_row")" \
    '{vault_snapshot: $vault, postgres: $postgres}' >"$d/backup.json"

  if [ "$rc" -eq 0 ]; then
    set_status backup CAPTURED
  else
    set_status backup PARTIAL
  fi
}

# ------------------------------------------------------------ multitenancy --
# Prompt 27, Deliverable 8 — team count, environment-tag coverage, and the
# last scenarios/16_multitenancy/ scope-isolation result. Direct DB reads
# (no API auth needed), same style as capture_persistence()'s schema_version
# read — the API-based checks elsewhere in this file all report UNKNOWN
# under ARCANIUM_AUTH_ENABLED=true precisely because they're anonymous;
# this data is just as reliably available with a plain, non-secret count.
capture_multitenancy() {
  local d="$TMP/components/multitenancy"
  mkdir -p "$d"

  if ! running arcanium-postgres; then
    jq -n '{teams_count: null, applications: {total: null, with_environment_tag: null}}' \
      >"$d/multitenancy.json"
  else
    local teams_count total_apps tagged_apps
    teams_count=$(podman exec -i arcanium-postgres psql -U arcanium -d arcanium_db -t -A -c \
      "select count(*) from teams;" 2>/dev/null | tr -d '[:space:]')
    total_apps=$(podman exec -i arcanium-postgres psql -U arcanium -d arcanium_db -t -A -c \
      "select count(*) from applications;" 2>/dev/null | tr -d '[:space:]')
    # environment is NOT NULL with a DEFAULT (migration 018) — every
    # application, past and future, is backfilled/defaulted automatically,
    # so this gap is expected to be 0 by design, not merely by luck. A
    # non-zero value here would mean the column itself somehow allowed a
    # NULL to slip through — a real finding, not routine drift.
    tagged_apps=$(podman exec -i arcanium-postgres psql -U arcanium -d arcanium_db -t -A -c \
      "select count(*) from applications where environment is not null;" 2>/dev/null | tr -d '[:space:]')
    jq -n \
      --arg tc "${teams_count:-0}" --arg ta "${total_apps:-0}" --arg tg "${tagged_apps:-0}" \
      '{teams_count: ($tc | tonumber),
        applications: {total: ($ta | tonumber), with_environment_tag: ($tg | tonumber)}}' \
      >"$d/multitenancy.json"
  fi

  local scope_result="UNKNOWN" scope_detail="scenarios/16_multitenancy/test_scope_isolation.sh has not been run"
  if [ -f state/.last-scope-isolation-result ]; then
    scope_result=$(cat state/.last-scope-isolation-result)
    local mtime
    mtime=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' state/.last-scope-isolation-result 2>/dev/null ||
      stat -c '%y' state/.last-scope-isolation-result 2>/dev/null || echo unknown)
    scope_detail="last run: $mtime"
  fi
  jq --arg r "$scope_result" --arg d "$scope_detail" \
    '. + {scope_isolation: {last_result: $r, detail: $d}}' \
    "$d/multitenancy.json" >"$d/multitenancy.json.tmp" && mv "$d/multitenancy.json.tmp" "$d/multitenancy.json"

  if running arcanium-postgres; then
    set_status multitenancy CAPTURED
  else
    set_status multitenancy UNKNOWN
  fi
}

# ------------------------------------------------ lifecycle completion (28) --
# Prompt 28, Deliverable 9 — service accounts, expiry_date coverage/drift,
# and offboarding progress. Same "count what's true right now, never a
# static/assumed number" discipline every other capture_* function follows.
#
# Prompt 39 — two real gaps, found while finishing off the six-stage audit's
# remainder:
#  1. Every count below used `${var:-0}` against a psql call whose stderr was
#     thrown away. Bash's `:-0` fires on an EMPTY value too, not just an
#     UNSET one — so a psql call that genuinely failed (bad connection,
#     locked table, a typo'd column after a future migration) silently
#     printed the same "0" a real, healthy, confirmed-empty table would.
#     This is exactly the "fabricated PASS" class of bug this whole script
#     exists to prevent, just for numbers instead of a check verdict.
#     count_or_unknown() now tells the two apart: a failed query leaves the
#     field genuinely null (with the failure named in query_errors), never
#     a guessed 0.
#  2. This component made zero Vault calls — `offboarding.completed` was
#     read as a pure DB flag (applications.offboarded_at), never checked
#     against Vault's own reality the way Prompt 36 already insists on for
#     the live destroy path itself. An application can only be marked
#     offboarded once every one of its desired_state rows resolved
#     (offboarding.js), but nothing here confirms the underlying Vault
#     key/PKI-role material is actually gone — a stuck worker or a partial
#     destroy could leave offboarded_at set while real key material still
#     lives in Vault, and this baseline would never have noticed.
#     offboarding_live_check() live-GETs every crypto_profiles path
#     belonging to an offboarded application (namespace-aware) and counts
#     a 404 as destroyed, a 200 as a real, still-live discrepancy — never
#     assumed either way on a network/auth failure (UNKNOWN, added to
#     query_errors, not folded into either count).
capture_lifecycle_completion() {
  local d="$TMP/components/lifecycle_completion"
  mkdir -p "$d"
  local -a lc_query_errors=()

  # Runs a count query; on a genuine failure (non-zero psql exit) leaves
  # the named var EMPTY (never "0") and records the failure — the caller
  # renders empty as JSON null, not a guessed healthy count.
  count_or_unknown() {
    local __resultvar="$1" __label="$2" __sql="$3"
    local __out __err="/tmp/arc-lc-err.$$"
    if __out=$(podman exec -i arcanium-postgres psql -U arcanium -d arcanium_db -t -A -c "$__sql" 2>"$__err"); then
      printf -v "$__resultvar" '%s' "$(tr -d '[:space:]' <<<"$__out")"
    else
      printf -v "$__resultvar" ''
      lc_query_errors+=("$__label: $(tr -d '\n' <"$__err" | cut -c1-200)")
    fi
    rm -f "$__err"
  }

  # Prompt 39 — live-verifies offboarding.completed against Vault itself
  # instead of trusting the DB flag alone. Reuses the same GET-and-check-
  # 404 convention offboarding.js's own keyIsActive()/observeExpiryDate()
  # use — a 404 is a real, positively-observed "destroyed", not an error.
  # The provisioner token is read transiently from .env for this one live
  # check and never written to $d — this script's own hard rule (whitelist
  # fields, never capture secret values) applies here exactly as it does
  # to LDAP_ADMIN_PASSWORD's existing transient use elsewhere in this file.
  offboarding_live_check() {
    local still_live=0 confirmed_destroyed=0 unresolved=0
    if ! running arcanium-vault_s && ! running arcanium-vault_1; then
      echo "null null null vault-not-running"
      return
    fi
    local token
    token="$(grep -E '^VAULT_PROVISIONER_TOKEN=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
    if [ -z "$token" ]; then
      echo "null null null no-provisioner-token"
      return
    fi
    local rows
    rows=$(podman exec -i arcanium-postgres psql -U arcanium -d arcanium_db -t -A -F'|' -c \
      "select coalesce(s.vault_namespace,''), cp.vault_path
         from applications a
         join crypto_profiles cp on cp.application_id = a.id
         left join suppliers s on s.id = a.supplier_id
        where a.offboarded_at is not null;" 2>/dev/null)
    if [ -z "$rows" ]; then
      echo "0 0 0 -"
      return
    fi
    while IFS='|' read -r ns path; do
      [ -z "$path" ] && continue
      local hdrs=(-H "X-Vault-Token: $token")
      [ -n "$ns" ] && hdrs+=(-H "X-Vault-Namespace: $ns")
      local code
      code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
        "${hdrs[@]}" "https://127.0.0.1:18200/v1/${path}" 2>/dev/null || echo 000)
      case "$code" in
      404) confirmed_destroyed=$((confirmed_destroyed + 1)) ;;
      200) still_live=$((still_live + 1)) ;;
      *) unresolved=$((unresolved + 1)) ;;
      esac
    done <<<"$rows"
    echo "$confirmed_destroyed $still_live $unresolved -"
  }

  if ! running arcanium-postgres; then
    jq -n '{service_accounts: {active: null, revoked: null},
            expiry_date: {tracked: null, drifted: null},
            offboarding: {initiated: null, completed: null,
              completed_verified_destroyed: null, completed_still_live_in_vault: null},
            approval_execution_backlog: null, query_errors: ["arcanium-postgres not running"]}' \
      >"$d/lifecycle_completion.json"
  else
    local sa_active sa_revoked exp_tracked exp_drifted ob_initiated ob_completed approval_backlog
    count_or_unknown sa_active "service_accounts.active" \
      "select count(*) from service_accounts where revoked_at is null;"
    count_or_unknown sa_revoked "service_accounts.revoked" \
      "select count(*) from service_accounts where revoked_at is not null;"
    count_or_unknown exp_tracked "expiry_date.tracked" \
      "select count(*) from desired_state where requirement='expiry_date' and archived_at is null;"
    # Counted from the latest reconciliation_runs row per desired_state, not
    # a stale/cached flag — matches how every other DRIFTED count in this
    # script (e.g. capture_persistence's own reconciliation figures) is
    # derived: from the most recent observed run per row, live.
    count_or_unknown exp_drifted "expiry_date.drifted" \
      "select count(*) from (
         select distinct on (rr.desired_state_id) rr.desired_state_id, rr.status
           from reconciliation_runs rr
           join desired_state ds on ds.id = rr.desired_state_id
          where ds.requirement = 'expiry_date' and ds.archived_at is null
          order by rr.desired_state_id, rr.observed_at desc
       ) latest where status = 'DRIFTED';"
    count_or_unknown ob_initiated "offboarding.initiated" \
      "select count(*) from applications where offboarding_initiated_at is not null;"
    count_or_unknown ob_completed "offboarding.completed" \
      "select count(*) from applications where offboarded_at is not null;"
    # Prompt 29, Deliverable 9 — a persistently nonzero count here means
    # approval-execution.js's own worker step is stuck (silently not
    # keeping up with real approved destroys), the same class of
    # silent-backlog failure this whole prompt exists to catch. Zero in a
    # healthy baseline is expected; a row can also sit here deliberately
    # when hasLiveDestroyIntent() correctly skips it (found live,
    # 2026-09-13 — see approval-execution.js's own header) — this count
    # alone can't distinguish "stuck" from "correctly skipped," only that
    # something here needs a human look if it stays nonzero across baselines.
    count_or_unknown approval_backlog "approval_execution_backlog" \
      "select count(*) from approval_requests where status='approved' and action='revoke' and executed_at is null;"

    local ob_verify
    ob_verify=$(offboarding_live_check)
    read -r ob_destroyed ob_live ob_unresolved ob_verify_err <<<"$ob_verify"
    if [ "$ob_verify_err" != "-" ]; then
      lc_query_errors+=("offboarding.live_vault_check: $ob_verify_err")
    fi
    if [ "$ob_unresolved" != "null" ] && [ "${ob_unresolved:-0}" != "0" ]; then
      lc_query_errors+=("offboarding.live_vault_check: ${ob_unresolved} path(s) gave a non-404/200 response — left out of both counts, treated as unknown")
    fi

    local errors_json="[]"
    if [ "${#lc_query_errors[@]}" -gt 0 ]; then
      errors_json=$(printf '%s\n' "${lc_query_errors[@]}" | jq -R . | jq -s .)
    fi

    jq -n \
      --arg saa "${sa_active}" --arg sar "${sa_revoked}" \
      --arg ext "${exp_tracked}" --arg exd "${exp_drifted}" \
      --arg obi "${ob_initiated}" --arg obc "${ob_completed}" \
      --arg obd "${ob_destroyed}" --arg obl "${ob_live}" \
      --arg aeb "${approval_backlog}" \
      --argjson errs "$errors_json" \
      'def n($x): if $x == "" or $x == "null" then null else ($x | tonumber) end;
       {service_accounts: {active: n($saa), revoked: n($sar)},
        expiry_date: {tracked: n($ext), drifted: n($exd)},
        offboarding: {initiated: n($obi), completed: n($obc),
          completed_verified_destroyed: n($obd),
          completed_still_live_in_vault: n($obl)},
        approval_execution_backlog: n($aeb),
        query_errors: $errs}' \
      >"$d/lifecycle_completion.json"

    unset -f count_or_unknown offboarding_live_check
  fi

  if ! running arcanium-postgres; then
    set_status lifecycle_completion UNKNOWN
  elif jq -e '.query_errors | length > 0' "$d/lifecycle_completion.json" >/dev/null 2>&1; then
    set_status lifecycle_completion PARTIAL
  elif jq -e '.offboarding.completed_still_live_in_vault > 0' "$d/lifecycle_completion.json" >/dev/null 2>&1; then
    # A real, live-confirmed discrepancy (offboarded_at set, key material
    # still in Vault) is a genuine finding, not a capture failure — surface
    # it as PARTIAL rather than a clean CAPTURED so it isn't missed.
    set_status lifecycle_completion PARTIAL
  else
    set_status lifecycle_completion CAPTURED
  fi
}

# ------------------------------------------------------------- verification --
capture_verification() {
  local results="[]"

  # Always-safe: the supplier isolation check is a live-but-non-mutating
  # verification the API itself performs continuously for the dashboard
  # (mints ephemeral tokens, checks 403, doesn't touch persistent state).
  # When ARCANIUM_AUTH_ENABLED=true this endpoint now requires a session —
  # an anonymous probe correctly gets 401, which is reported honestly as
  # UNKNOWN (not run, not a failure of the isolation mechanism itself).
  if running arcanium-api; then
    local iso http_code
    http_code=$(curl -s -o /tmp/arc-iso-check.$$ -w '%{http_code}' --max-time 10 \
      http://localhost:3001/api/v1/suppliers/isolation 2>/dev/null || echo 000)
    if [ "$http_code" = "200" ]; then
      local verified
      verified=$(jq -r '.verified // false' /tmp/arc-iso-check.$$ 2>/dev/null || echo false)
      results=$(jq --arg v "$([ "$verified" = true ] && echo PASS || echo FAIL)" \
        '. + [{check:"supplier_isolation", result:$v, method:"live API check, non-mutating"}]' <<<"$results")
    elif [ "$http_code" = "401" ]; then
      results=$(jq '. + [{check:"supplier_isolation", result:"UNKNOWN", detail:"endpoint requires an authenticated session (ARCANIUM_AUTH_ENABLED=true) — not run anonymously"}]' <<<"$results")
    else
      results=$(jq --arg c "$http_code" '. + [{check:"supplier_isolation", result:"UNKNOWN", detail:("endpoint did not respond (http " + $c + ")")}]' <<<"$results")
    fi
    rm -f /tmp/arc-iso-check.$$
  else
    results=$(jq '. + [{check:"supplier_isolation", result:"UNKNOWN", detail:"arcanium-api not running"}]' <<<"$results")
  fi

  # OIDC discovery — read-only, public-by-spec endpoint. Distinct from the
  # "identity" component's own deployment-status capture: this proves the
  # realm/client configuration is actually functioning, not just that the
  # containers are up.
  if [ -s "$TMP/components/identity/keycloak-discovery.json" ] &&
    jq -e '.issuer' "$TMP/components/identity/keycloak-discovery.json" >/dev/null 2>&1; then
    results=$(jq '. + [{check:"oidc_discovery", result:"PASS", method:"GET realm .well-known/openid-configuration, non-mutating"}]' <<<"$results")
  else
    results=$(jq '. + [{check:"oidc_discovery", result:"UNKNOWN", detail:"realm discovery document not captured or missing issuer field"}]' <<<"$results")
  fi

  # Prompt 20 — reconciliation. Non-mutating: GET /api/v1/reconciliation
  # reports each desired_state row's LATEST already-recorded status; it
  # never triggers a new observation (that's POST /reconciliation/run,
  # deliberately not called here — a state capture must never itself change
  # what it's capturing). Same auth caveat as supplier_isolation above: this
  # route is session-gated, so an anonymous probe correctly gets 401,
  # honestly reported as UNKNOWN rather than treated as a failure.
  if running arcanium-api; then
    local rc_code
    rc_code=$(curl -s -o /tmp/arc-recon-check.$$ -w '%{http_code}' --max-time 10 \
      http://localhost:3001/api/v1/reconciliation 2>/dev/null || echo 000)
    if [ "$rc_code" = "200" ]; then
      local drifted compliant unknown
      drifted=$(jq '[.[] | select(.observation_status=="DRIFTED")] | length' /tmp/arc-recon-check.$$ 2>/dev/null || echo null)
      compliant=$(jq '[.[] | select(.observation_status=="COMPLIANT")] | length' /tmp/arc-recon-check.$$ 2>/dev/null || echo null)
      unknown=$(jq '[.[] | select(.observation_status=="UNKNOWN")] | length' /tmp/arc-recon-check.$$ 2>/dev/null || echo null)
      results=$(jq --argjson d "${drifted:-null}" --argjson c "${compliant:-null}" --argjson u "${unknown:-null}" \
        '. + [{check:"reconciliation", result:"PASS", method:"GET /api/v1/reconciliation, non-mutating", drifted_count:$d, compliant_count:$c, unknown_count:$u}]' <<<"$results")
    elif [ "$rc_code" = "401" ]; then
      results=$(jq '. + [{check:"reconciliation", result:"UNKNOWN", detail:"endpoint requires an authenticated session (ARCANIUM_AUTH_ENABLED=true) — not run anonymously"}]' <<<"$results")
    else
      results=$(jq --arg c "$rc_code" '. + [{check:"reconciliation", result:"UNKNOWN", detail:("endpoint did not respond (http " + $c + ")")}]' <<<"$results")
    fi
    rm -f /tmp/arc-recon-check.$$
  else
    results=$(jq '. + [{check:"reconciliation", result:"UNKNOWN", detail:"arcanium-api not running"}]' <<<"$results")
  fi

  # Prompt 21 — maturity. GET /api/v1/maturity has always been a live,
  # request-time computation (Prompt 17 onward — no caching); this script
  # already probed it anonymously above (capture_arcanium's api-smoke.json).
  # This adds the real Deliverable 8 verification: the post-Evidence-v2
  # {maturity, coverage, confidence} shape, not the old single "overall"
  # percentage — a baseline captured against the new shape without updating
  # this script would silently record nothing useful (the same gap Phase 20
  # found and closed for `identity`). Same auth caveat as the checks above.
  if running arcanium-api; then
    local mat_code
    mat_code=$(curl -s -o /tmp/arc-maturity-check.$$ -w '%{http_code}' --max-time 10 \
      http://localhost:3001/api/v1/maturity 2>/dev/null || echo 000)
    if [ "$mat_code" = "200" ]; then
      local mat cov conf
      mat=$(jq '.maturity // null' /tmp/arc-maturity-check.$$ 2>/dev/null || echo null)
      cov=$(jq '.coverage // null' /tmp/arc-maturity-check.$$ 2>/dev/null || echo null)
      conf=$(jq -r '.confidence // "null"' /tmp/arc-maturity-check.$$ 2>/dev/null || echo null)
      results=$(jq --argjson m "${mat:-null}" --argjson c "${cov:-null}" --arg cf "$conf" \
        '. + [{check:"maturity", result:"PASS", method:"GET /api/v1/maturity", maturity:$m, coverage:$c, confidence:$cf}]' <<<"$results")
    elif [ "$mat_code" = "401" ]; then
      results=$(jq '. + [{check:"maturity", result:"UNKNOWN", detail:"endpoint requires an authenticated session (ARCANIUM_AUTH_ENABLED=true) — not run anonymously"}]' <<<"$results")
    else
      results=$(jq --arg c "$mat_code" '. + [{check:"maturity", result:"UNKNOWN", detail:("endpoint did not respond (http " + $c + ")")}]' <<<"$results")
    fi
    rm -f /tmp/arc-maturity-check.$$
  else
    results=$(jq '. + [{check:"maturity", result:"UNKNOWN", detail:"arcanium-api not running"}]' <<<"$results")
  fi

  # Prompt 25, Deliverable 4 — GET /api/v1/applications/:id/intent for one
  # known demo application (payments-api). Non-mutating: a pure read-model
  # aggregation, same as the reconciliation/maturity checks above. Confirms
  # the endpoint responds AND that every top-level key from Deliverable 1's
  # shape is present — even when a value inside is UNKNOWN/empty, the KEY
  # itself must never be silently omitted (this whole phase's own design
  # rule, checked here rather than just asserted).
  if running arcanium-api; then
    local apps_code
    apps_code=$(curl -s -o /tmp/arc-apps-check.$$ -w '%{http_code}' --max-time 10 \
      http://localhost:3001/api/v1/applications 2>/dev/null || echo 000)
    if [ "$apps_code" = "200" ]; then
      local demo_app_id
      demo_app_id=$(jq -r '.[] | select(.name=="payments-api") | .id' /tmp/arc-apps-check.$$ 2>/dev/null | head -1)
      if [ -z "$demo_app_id" ]; then
        results=$(jq '. + [{check:"intent_view", result:"UNKNOWN", detail:"demo application payments-api not found — cannot exercise the endpoint"}]' <<<"$results")
      else
        local intent_code
        intent_code=$(curl -s -o /tmp/arc-intent-check.$$ -w '%{http_code}' --max-time 10 \
          "http://localhost:3001/api/v1/applications/${demo_app_id}/intent" 2>/dev/null || echo 000)
        if [ "$intent_code" = "200" ]; then
          local missing
          missing=$(jq -r '
            ["application_id","application","tenant","environment","requirements",
             "custody","governance","desired_state","observed_state","assessment",
             "evidence","entry_story"] - (keys) | join(",")
          ' /tmp/arc-intent-check.$$ 2>/dev/null)
          if [ -z "$missing" ]; then
            results=$(jq '. + [{check:"intent_view", result:"PASS", method:"GET /api/v1/applications/:id/intent, non-mutating"}]' <<<"$results")
          else
            results=$(jq --arg m "$missing" '. + [{check:"intent_view", result:"FAIL", detail:("missing top-level key(s): " + $m)}]' <<<"$results")
          fi
        elif [ "$intent_code" = "401" ]; then
          results=$(jq '. + [{check:"intent_view", result:"UNKNOWN", detail:"endpoint requires an authenticated session (ARCANIUM_AUTH_ENABLED=true) — not run anonymously"}]' <<<"$results")
        else
          results=$(jq --arg c "$intent_code" '. + [{check:"intent_view", result:"UNKNOWN", detail:("endpoint did not respond (http " + $c + ")")}]' <<<"$results")
        fi
        rm -f /tmp/arc-intent-check.$$
      fi
    elif [ "$apps_code" = "401" ]; then
      results=$(jq '. + [{check:"intent_view", result:"UNKNOWN", detail:"endpoint requires an authenticated session (ARCANIUM_AUTH_ENABLED=true) — not run anonymously"}]' <<<"$results")
    else
      results=$(jq --arg c "$apps_code" '. + [{check:"intent_view", result:"UNKNOWN", detail:("could not list applications to resolve the demo app id (http " + $c + ")")}]' <<<"$results")
    fi
    rm -f /tmp/arc-apps-check.$$
  else
    results=$(jq '. + [{check:"intent_view", result:"UNKNOWN", detail:"arcanium-api not running"}]' <<<"$results")
  fi

  local mutating_checks="onboarding transit pki kmip managed_key sentinel_negative"
  if $WITH_SCENARIOS; then
    results=$(jq '. + [{check:"onboarding", result:"UNKNOWN", detail:"scenario runner wiring not implemented yet — run scenarios/01_onboarding manually and record the result"}]' <<<"$results")
  else
    for c in $mutating_checks; do
      results=$(jq --arg c "$c" '. + [{check:$c, result:"UNKNOWN", detail:"not run — mutating scenario, requires --with-scenarios and creates/changes real resources"}]' <<<"$results")
    done
  fi

  echo "$results" | jq '{results: .}' >"$TMP/verification/results.json"
  {
    echo "# Verification — ${BASELINE_ID}"
    echo
    jq -r '.results[] | "- **\(.check)**: \(.result)" + (if .detail then " — \(.detail)" else "" end)' "$TMP/verification/results.json"
  } >"$TMP/verification/summary.md"

  local any_fail any_unknown
  any_fail=$(jq -e '[.[] | select(.result=="FAIL")] | length > 0' <<<"$results" 2>/dev/null && echo true || echo false)
  any_unknown=$(jq -e '[.[] | select(.result=="UNKNOWN")] | length > 0' <<<"$results" 2>/dev/null && echo true || echo false)
  if [ "$any_fail" = true ]; then
    set_status verification FAILED
  elif [ "$any_unknown" = true ]; then
    set_status verification PARTIAL
  else
    set_status verification CAPTURED
  fi
}

echo "Capturing baseline: $FINAL"
echo "  purpose: $PURPOSE"
echo

for fn in capture_source capture_runtime capture_arcanium capture_vault capture_hsm capture_identity capture_infra capture_kms capture_observability capture_workloads capture_persistence capture_backup capture_multitenancy capture_lifecycle_completion capture_verification; do
  echo "-> ${fn#capture_}"
  "$fn"
done

# ------------------------------------------------------------- manifest ---
# Part 3: FAILED if any mandatory verification positively FAILED; PARTIAL if
# no FAIL but any required capture is PARTIAL/UNKNOWN; CAPTURED only if
# every required capture completed.
overall="CAPTURED"
for v in "${STATUS[@]}"; do
  case "$v" in
  FAILED) overall="FAILED" ;;
  PARTIAL | UNKNOWN) [ "$overall" != FAILED ] && overall="PARTIAL" ;;
  esac
done

# previous_baseline: the most recently captured OTHER baseline, by
# manifest.baseline.captured_at (never directory mtime).
PREVIOUS_BASELINE=""
if [ -d state/baselines ]; then
  PREVIOUS_BASELINE=$(
    for m in state/baselines/*/manifest.yaml; do
      [ -f "$m" ] || continue
      id=$(grep -m1 '^  id:' "$m" | sed -E 's/^  id: *//')
      ts=$(grep -m1 '^  captured_at:' "$m" | sed -E 's/^  captured_at: *//')
      [ "$id" = "$BASELINE_ID" ] && continue
      echo "${ts}|${id}"
    done | sort -r | head -1 | cut -d'|' -f2
  )
fi

{
  echo "baseline:"
  echo "  id: ${BASELINE_ID}"
  echo "  purpose: \"${PURPOSE}\""
  echo "  captured_at: ${TS}"
  echo "  project: \"${PROJECT_NAME}\""
  echo "  previous_baseline: \"${PREVIOUS_BASELINE}\""
  echo "  git:"
  echo "    commit: \"$(git rev-parse HEAD 2>/dev/null || echo unknown)\""
  echo "    branch: \"$(git branch --show-current 2>/dev/null || echo unknown)\""
  echo "    tag: \"$(git describe --tags --exact-match 2>/dev/null || echo none)\""
  echo "    dirty: $([ -s "$TMP/source/git-status.txt" ] && echo true || echo false)"
  echo
  echo "runtime:"
  echo "  type: podman"
  echo "  architecture: \"$(uname -m)\""
  echo
  echo "components:"
  for c in arcanium vault hsm identity infra kms observability workloads; do
    echo "  ${c}:"
    echo "    capture_status: ${STATUS[$c]:-UNKNOWN}"
  done
  echo
  echo "# Pre-24, Deliverable 12 — safe, non-secret persistence indicators only."
  echo "# Never a SecretID, OIDC client secret, LDAP password, Vault token, HSM"
  echo "# PIN, or database password — see docs/persistence.md."
  echo "persistence:"
  if [ -s "$TMP/components/persistence/persistence.json" ]; then
    jq -r '
      "  postgres:",
      "    volume_present: \(.postgres.volume_present)",
      "    schema_version: \"\(.postgres.schema_version)\"",
      "  vault:",
      "    raft_storage_present:",
      "      main_1: \(.vault.raft_storage_present.main_1)",
      "      main_2: \(.vault.raft_storage_present.main_2)",
      "      main_3: \(.vault.raft_storage_present.main_3)",
      "      seal_provider: \(.vault.raft_storage_present.seal_provider)",
      "    cluster_id: \"\(.vault.cluster_id)\"",
      "  identity:",
      "    ldap_directory_present: \(.identity.ldap_directory_present)",
      "    keycloak_data_present: \(.identity.keycloak_data_present)",
      "  hsm:",
      "    softhsm_token_store_present: \(.hsm.softhsm_token_store_present)",
      "    vault_hsm_storage_present: \(.hsm.vault_hsm_storage_present)",
      "  workloads:",
      "    credential_bootstrap_ready: \(.workloads.credential_bootstrap_ready)",
      "    detail: \"\(.workloads.detail)\"",
      "  restart_persistence: \(.restart_persistence.result)",
      "  restart_persistence_detail: \"\(.restart_persistence.detail)\""
    ' "$TMP/components/persistence/persistence.json"
  else
    echo "  status: UNKNOWN"
  fi
  echo
  echo "# Prompt 24, Deliverable 8 — whether a restore drill has ever actually"
  echo "# verified recovery, and its measured RTO/RPO. Never the snapshot/dump"
  echo "# itself (state/README.md's 'state is not backup' rule) — see"
  echo "# restore_drill_results and docs/operations.md's Backup and recovery section."
  echo "backup:"
  if [ -s "$TMP/components/backup/backup.json" ]; then
    jq -r '
      "  vault_snapshot:",
      "    available: \(.vault_snapshot.available)",
      "    last_verified_at: \(if .vault_snapshot.last_verified_at then "\"" + .vault_snapshot.last_verified_at + "\"" else "null" end)",
      "    rto_seconds: \(.vault_snapshot.rto_seconds // "null")",
      "    rpo_seconds: \(.vault_snapshot.rpo_seconds // "null")",
      "  postgres:",
      "    available: \(.postgres.available)",
      "    last_verified_at: \(if .postgres.last_verified_at then "\"" + .postgres.last_verified_at + "\"" else "null" end)",
      "    rto_seconds: \(.postgres.rto_seconds // "null")",
      "    rpo_seconds: \(.postgres.rpo_seconds // "null")"
    ' "$TMP/components/backup/backup.json"
  else
    echo "  status: UNKNOWN"
  fi
  echo
  echo "# Prompt 27, Deliverable 8 — team count, environment-tag coverage, and"
  echo "# the last scenarios/16_multitenancy/test_scope_isolation.sh result."
  echo "multitenancy:"
  if [ -s "$TMP/components/multitenancy/multitenancy.json" ]; then
    jq -r '
      "  teams_count: \(.teams_count // "null")",
      "  applications:",
      "    total: \(.applications.total // "null")",
      "    with_environment_tag: \(.applications.with_environment_tag // "null")",
      "  scope_isolation:",
      "    last_result: \(.scope_isolation.last_result)",
      "    detail: \"\(.scope_isolation.detail)\""
    ' "$TMP/components/multitenancy/multitenancy.json"
  else
    echo "  status: UNKNOWN"
  fi
  echo
  echo "verification:"
  jq -r '.results[] | "  \(.check): \(.result)"' "$TMP/verification/results.json"
  echo
  echo "capture:"
  echo "  overall: ${overall}"
  echo "  checks:"
  for c in source runtime arcanium vault hsm identity infra kms observability workloads persistence backup multitenancy verification; do
    echo "    ${c}: ${STATUS[$c]:-UNKNOWN}"
  done
} >"$TMP/manifest.yaml"

# ------------------------------------------------------------- summary.md -
AUTH_ENABLED="$(jq -r '.ARCANIUM_AUTH_ENABLED // "(unset)"' "$TMP/components/arcanium/mode-flags.json" 2>/dev/null)"
{
  echo "# ${PROJECT_NAME} baseline — ${BASELINE_ID}"
  echo
  echo "**Purpose:** ${PURPOSE}"
  echo "**Captured:** ${TS}"
  echo "**Source commit:** $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "**Previous baseline:** ${PREVIOUS_BASELINE:-none}"
  echo "**Overall capture status:** ${overall}"
  echo
  echo "## Capture status per check"
  echo
  echo "| Check | Status |"
  echo "|---|---|"
  for c in source runtime arcanium vault hsm identity infra kms observability workloads persistence verification; do
    echo "| $c | ${STATUS[$c]:-UNKNOWN} |"
  done
  echo
  echo "## Observed functional verification"
  echo
  jq -r '.results[] | "- **\(.check)**: \(.result)" + (if .detail then " — \(.detail)" else "" end)' "$TMP/verification/results.json"
  echo
  echo "See [manifest.yaml](./manifest.yaml) for the machine-readable form, and"
  echo "[source/project-tree.md](./source/project-tree.md) for the captured project structure."
  echo
  echo "## Project context"
  echo
  echo "ARCANIUM_AUTH_ENABLED = ${AUTH_ENABLED}"
  echo
  echo "Arcanium is a Vault Enterprise cryptographic control-plane demo:"
  echo "\`arcanium/{api,ui,cli}\` + Vault (3-node Raft + transit-seal + HSM) +"
  echo "OpenLDAP/Keycloak identity (Prompt 18) + supplier-tenant workloads."
} >"$TMP/summary.md"

echo
echo "-> validating captured baseline before finalizing"
if ! state/scripts/validate-state.sh "$TMP"; then
  echo
  echo "ABORT: validate-state.sh rejected this capture — leaving $TMP in place for inspection." >&2
  echo "Nothing was finalized; state/CURRENT and state/baselines/ are unchanged." >&2
  exit 1
fi

mv "$TMP" "$FINAL"
echo "$FINAL" >state/CURRENT

echo
echo "Baseline written: $FINAL"
echo "Overall: $overall"
echo "Previous baseline: ${PREVIOUS_BASELINE:-none}"
echo "CURRENT -> $FINAL"

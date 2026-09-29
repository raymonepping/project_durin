#!/usr/bin/env bash
# scripts/arcanium-upgrade.sh — Prompt 24, Deliverable 5.
#
# Scripts the procedure documented in docs/upgrade.md: preflight, backup,
# migrate (report only — migrations themselves apply automatically when
# arcanium-api starts), deploy, health, smoke, rollback. Each step is its
# own subcommand so an operator can run (and re-run) any one of them
# independently, exactly like Deliverable 3's restore drill is a script,
# not a single opaque "upgrade" button.
#
# "Prove it once" (input/32/34's standard applies here too): this script
# is meant to be run for a real version bump against the real running
# stack, not just read. docs/upgrade.md's execution log records one such
# real upgrade+rollback cycle.
set -uo pipefail
cd "$(dirname -- "$0")/.." # -> repo root

VERSION_FILE="VERSION"
API_PKG="arcanium/api/package.json"
UI_PKG="arcanium/ui/package.json"
ARCH="linux/$(uname -m | sed 's/x86_64/amd64/')"

usage() {
  cat <<'EOF'
Usage: scripts/arcanium-upgrade.sh <command> [args]

Commands:
  preflight             Print the compatibility matrix and take a Vault
                         snapshot as a safety net (reuses vault-restore-
                         drill's own backup step, scripts/vault-backup.sh).
  backup                Full pre-upgrade backup: Vault snapshot + pg_dump.
  migrate                Report current vs latest schema_migrations state
                         (migrations themselves apply automatically the
                         next time arcanium-api starts — this is informational).
  deploy <version>       Bump the version marker (VERSION + both
                         package.json files), rebuild arcanium-api/ui
                         images tagged with <version>, recreate the
                         containers.
  health [<version>]     Check container health + /health/live,ready — if
                         <version> given, also verify GET /health reports it.
  smoke <user> <pass>    Run scripts/verify-stack.sh as a lighter,
                         auth-aware smoke subset (see docs/upgrade.md for
                         why this replaces scenarios/01_onboarding here).
  rollback <version>     Redeploy an already-built <version> image tag
                         (no rebuild) — the documented reverse path.

Examples:
  scripts/arcanium-upgrade.sh preflight
  scripts/arcanium-upgrade.sh deploy 1.0.1
  scripts/arcanium-upgrade.sh health 1.0.1
  scripts/arcanium-upgrade.sh rollback 1.0.0
EOF
}

current_version() { cat "$VERSION_FILE" 2>/dev/null || echo unknown; }

compat_matrix() {
  local vault_version postgres_version node_version nuxt_version schema_version
  vault_version=$(grep -oE 'vault-enterprise:[^"[:space:]]+' compose/vault/compose.yaml | head -1 | cut -d: -f2-)
  postgres_version=$(grep -oE 'postgres:[^"[:space:]]+' compose/infra/compose.yaml | head -1 | cut -d: -f2-)
  node_version=$(grep -m1 'FROM docker.io/library/node' arcanium/api/Containerfile | sed -E 's#.*node:([^ ]+).*#\1#')
  nuxt_version=$(jq -r '.dependencies.nuxt // .devDependencies.nuxt // "unknown"' "$UI_PKG")
  schema_version=$(ls arcanium/api/src/migrations/ 2>/dev/null | sort | tail -1)
  cat <<EOF
  Arcanium         $(current_version)
  Vault            ${vault_version:-unknown}
  Postgres         ${postgres_version:-unknown}
  Node             ${node_version:-unknown}
  Nuxt             ${nuxt_version:-unknown}
  Schema (latest)  ${schema_version:-unknown}
EOF
}

# Set both package.json version fields to $1 — arcanium/api/package.json's
# is the one GET /health actually reports; keeping the UI's in lockstep
# avoids two different "Arcanium version" numbers existing at once.
set_version() {
  local v="$1"
  echo "$v" >"$VERSION_FILE"
  jq --arg v "$v" '.version = $v' "$API_PKG" >"$API_PKG.tmp" && mv "$API_PKG.tmp" "$API_PKG"
  jq --arg v "$v" '.version = $v' "$UI_PKG" >"$UI_PKG.tmp" && mv "$UI_PKG.tmp" "$UI_PKG"
}

# Recreate arcanium-api/ui (and arcanium-worker, which shares the api
# image) against whatever :local tag currently points at. Mirrors the
# rebuild order found live in Deliverable 3's work: arcanium-ui must be
# stopped and removed BEFORE arcanium-api, or podman refuses to remove
# arcanium-api ("has dependent containers which must be removed before it").
recreate_containers() {
  ./scripts/compose.sh arcanium stop arcanium-ui >/dev/null 2>&1 || true
  podman rm -f arcanium-ui arcanium-api >/dev/null 2>&1 || true
  ./scripts/compose.sh arcanium up -d arcanium-api arcanium-worker arcanium-ui
}

cmd_preflight() {
  echo "== preflight: compatibility matrix =="
  compat_matrix
  echo
  echo "== preflight: Vault backup (reuses scripts/vault-backup.sh, the same"
  echo "   backup step scripts/vault-restore-drill.sh takes as its step 1) =="
  ./scripts/vault-backup.sh
}

cmd_backup() {
  echo "== backup: Vault snapshot =="
  ./scripts/vault-backup.sh
  echo
  echo "== backup: PostgreSQL pg_dump =="
  mkdir -p backups
  local dumpfile="backups/pg-upgrade-$(date -u +%Y%m%dT%H%M%SZ).sql"
  # --no-acl: found live in scenarios/15_operability/test_postgres_recovery.sh
  # — Vault's Postgres dynamic-secrets-engine leaves thousands of
  # short-lived "v-approle-arcanium-<random>-<epoch>" GRANT/ALTER DEFAULT
  # PRIVILEGES entries in the schema ACL, none of which exist in a
  # freshly recreated cluster. A plain pg_dump captures them anyway,
  # which breaks restore. Ownership (OWNER TO arcanium) is unaffected.
  podman exec -i arcanium-postgres pg_dump -U arcanium --no-acl arcanium_db >"$dumpfile"
  echo "pg_dump saved: $dumpfile ($(wc -c <"$dumpfile" | tr -d ' ') bytes)"
}

cmd_migrate() {
  echo "== migrate: schema state (migrations apply automatically when"
  echo "   arcanium-api next starts — this reports state, it does not apply)"
  local latest_file applied
  latest_file=$(ls arcanium/api/src/migrations/ 2>/dev/null | sort | tail -1)
  applied=$(podman exec -i arcanium-postgres psql -U arcanium -d arcanium_db -t -A -c \
    "select filename from schema_migrations order by filename desc limit 1;" 2>/dev/null | tr -d '[:space:]')
  echo "  latest migration file:            ${latest_file:-none}"
  echo "  latest applied (schema_migrations): ${applied:-none}"
  if [ "$latest_file" = "$applied" ]; then
    echo "  schema is up to date"
  else
    echo "  schema is behind the latest migration file — will be applied on the next arcanium-api start (the deploy step)"
  fi
}

cmd_deploy() {
  local target="${1:?usage: arcanium-upgrade.sh deploy <version>}"
  echo "== deploy: bumping version marker $(current_version) -> $target =="
  set_version "$target"

  echo "== deploy: building arcanium-api:$target =="
  podman build --platform "$ARCH" --format docker \
    -t "arcanium-api:$target" -t arcanium-api:local \
    -f arcanium/api/Containerfile arcanium/api/

  echo "== deploy: building arcanium-ui:$target =="
  podman build --platform "$ARCH" --format docker \
    -t "arcanium-ui:$target" -t arcanium-ui:local \
    -f arcanium/ui/Containerfile arcanium/ui/

  echo "== deploy: recreating containers =="
  recreate_containers
}

cmd_health() {
  local expect="${1:-}"
  echo "== health: container status =="
  local svc all_healthy=true
  for svc in arcanium-api arcanium-ui arcanium-worker; do
    local status
    status=$(podman inspect "$svc" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
    echo "  $svc: $status"
    [ "$status" = healthy ] || all_healthy=false
  done

  echo "== health: /health/live, /health/ready =="
  curl -sf http://localhost:3001/health/live >/dev/null && echo "  arcanium-api /health/live: ok" || {
    echo "  arcanium-api /health/live: FAILED" >&2
    all_healthy=false
  }
  curl -sf http://localhost:3001/health/ready >/dev/null && echo "  arcanium-api /health/ready: ok" || {
    echo "  arcanium-api /health/ready: FAILED" >&2
    all_healthy=false
  }

  local reported
  reported=$(curl -sf http://localhost:3001/health | jq -r '.version // "unknown"')
  echo "  reported API version: $reported"
  if [ -n "$expect" ] && [ "$reported" != "$expect" ]; then
    echo "  MISMATCH: expected version $expect, API reports $reported" >&2
    all_healthy=false
  fi

  [ "$all_healthy" = true ]
}

cmd_smoke() {
  local user="${1:?usage: arcanium-upgrade.sh smoke <user> <password>}"
  local pass="${2:?usage: arcanium-upgrade.sh smoke <user> <password>}"
  echo "== smoke: scripts/verify-stack.sh (see docs/upgrade.md for why this"
  echo "   is used instead of scenarios/01_onboarding here) =="
  ./scripts/verify-stack.sh --user "$user" --password "$pass"
}

cmd_rollback() {
  local target="${1:?usage: arcanium-upgrade.sh rollback <version>}"
  echo "== rollback: redeploying arcanium-api:$target / arcanium-ui:$target"
  echo "   (already-built image tags — no rebuild) =="
  if ! podman image exists "arcanium-api:$target" || ! podman image exists "arcanium-ui:$target"; then
    echo "  arcanium-api:$target or arcanium-ui:$target not found locally — cannot roll back to an image that was never built here." >&2
    exit 1
  fi
  set_version "$target"
  podman tag "arcanium-api:$target" arcanium-api:local
  podman tag "arcanium-ui:$target" arcanium-ui:local
  echo "== rollback: recreating containers from the prior image tag =="
  recreate_containers
}

CMD="${1:-}"
shift || true
case "$CMD" in
preflight) cmd_preflight ;;
backup) cmd_backup ;;
migrate) cmd_migrate ;;
deploy) cmd_deploy "$@" ;;
health) cmd_health "$@" ;;
smoke) cmd_smoke "$@" ;;
rollback) cmd_rollback "$@" ;;
-h | --help | "") usage ;;
*)
  echo "Unknown command: $CMD" >&2
  usage
  exit 64
  ;;
esac

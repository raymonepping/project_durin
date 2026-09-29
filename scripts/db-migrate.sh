#!/usr/bin/env bash
# scripts/db-migrate.sh — apply Durin schema migrations as the owner role.
#
# The backend never runs DDL: its Vault-issued credential is a member of
# durin_app (DML only). Schema changes are an operator action:
#
#   1. scripts/sql/000_bootstrap_roles.sql   superuser: roles, schema privileges,
#                                            legacy ownership repair, ledger
#   2. backend/src/migrations/NNN_*.sql      as durin_owner, each once, recorded
#                                            in schema_migrations
#   3. scripts/sql/999_grants.sql            superuser: durin_app privileges
#
# Uses the management credentials that live only inside the durin-postgres
# container environment — they are never given to the application.
#
# Usage: ./scripts/db-migrate.sh [--status]
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
container="${DURIN_POSTGRES_CONTAINER:-durin-postgres}"

env_get() { grep -E "^$1=" "$root/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"; }
PGUSER_MGMT="${POSTGRES_USER:-$(env_get POSTGRES_USER)}"
PGDB="${POSTGRES_DB:-$(env_get POSTGRES_DB)}"
: "${PGUSER_MGMT:?POSTGRES_USER not set (.env)}"
: "${PGDB:?POSTGRES_DB not set (.env)}"

psql_run() {
  podman exec -i -e PGOPTIONS="-c client_min_messages=warning" "$container" psql -X -q -v ON_ERROR_STOP=1 -U "$PGUSER_MGMT" -d "$PGDB" "$@"
}

if ! podman exec "$container" pg_isready -q -U "$PGUSER_MGMT" -d "$PGDB"; then
  echo "[db-migrate] $container is not accepting connections" >&2
  exit 1
fi

if [ "${1:-}" = "--status" ]; then
  psql_run -c "SELECT version, applied_at FROM schema_migrations ORDER BY version" 2>/dev/null \
    || echo "[db-migrate] no schema_migrations table yet — run without --status"
  exit 0
fi

echo "[db-migrate] bootstrap roles + ownership repair"
psql_run -f - < "$root/scripts/sql/000_bootstrap_roles.sql"

applied=0
for file in "$root"/backend/src/migrations/[0-9][0-9][0-9]_*.sql; do
  version=$(basename "$file" .sql)
  done_already=$(psql_run -At -c "SELECT 1 FROM schema_migrations WHERE version = '$version'")
  if [ -n "$done_already" ]; then
    echo "[db-migrate] $version already applied"
    continue
  fi
  echo "[db-migrate] applying $version as durin_owner"
  {
    echo "BEGIN;"
    echo "SET LOCAL ROLE durin_owner;"
    cat "$file"
    echo ""
    echo "INSERT INTO schema_migrations (version) VALUES ('$version');"
    echo "COMMIT;"
  } | psql_run -f -
  applied=$((applied + 1))
done

echo "[db-migrate] applying durin_app grants"
psql_run -f - < "$root/scripts/sql/999_grants.sql"

echo "[db-migrate] done ($applied new migration(s))"
psql_run -At -c "SELECT 'tables owned by durin_owner: ' || count(*) FILTER (WHERE tableowner = 'durin_owner') || '/' || count(*) FROM pg_tables WHERE schemaname = 'public'"

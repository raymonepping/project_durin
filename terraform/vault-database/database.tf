# ── Database secrets engine ───────────────────────────────────────────────────
# Vault manages dynamic PostgreSQL credentials — the Durin backend never holds
# long-lived database passwords.  Each request to database/creds/durin-backend-role
# produces a unique username + password valid for 1 hour, automatically revoked
# by Vault on lease expiry.

resource "vault_mount" "database" {
  path        = "database"
  type        = "database"
  description = "Durin Database — dynamic PostgreSQL credentials for the backend service"
}

# ── PostgreSQL connection ─────────────────────────────────────────────────────
# Vault connects to PostgreSQL using the management superuser to create and
# revoke dynamic roles.  The connection_url uses Vault's {{username}}/{{password}}
# template so the password is never written to Terraform state in plaintext.
# The Vault container reaches PostgreSQL via the host-published port (5432).

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "durin-postgres"
  allowed_roles = ["durin-backend-role"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${var.postgres_host}:${var.postgres_port}/${var.postgres_db}?sslmode=disable"
    username       = var.postgres_user
    password       = var.postgres_password
  }
}

# ── Dynamic credential role ───────────────────────────────────────────────────
# The Durin backend reads this path to obtain short-lived PostgreSQL credentials.
#
# Privilege model (see docs/database.md):
#   durin_owner  NOLOGIN  owns every table; used only by scripts/db-migrate.sh
#   durin_app    NOLOGIN  SELECT/INSERT/UPDATE/DELETE on tables, USAGE on sequences
#   v-approle-*  LOGIN    Vault-issued, member of durin_app ONLY, expires with lease
#
# Dynamic users receive no direct grants, no CREATE on the schema, and no
# membership in the management superuser. They cannot run DDL and cannot own
# objects, so Vault's revocation (DROP ROLE) always succeeds. The REASSIGN /
# DROP OWNED statements are a safety net for roles issued before this model.
#
# durin_owner and durin_app are created by scripts/db-migrate.sh (make db-migrate),
# which must run before the first credential is issued.

resource "vault_database_secret_backend_role" "durin_backend" {
  backend = vault_mount.database.path
  name    = "durin-backend-role"
  db_name = vault_database_secret_backend_connection.postgres.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE durin_app;",
  ]

  revocation_statements = [
    "REASSIGN OWNED BY \"{{name}}\" TO durin_owner;",
    "DROP OWNED BY \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";",
  ]

  default_ttl = "3600"  # 1 hour
  max_ttl     = "86400" # 24 hours
}

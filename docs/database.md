# Durin Database

PostgreSQL 16 is deliberately visible: it stores metadata in plaintext and
every sensitive value as Vault Transit ciphertext (`vault:vN:…`). It holds
no key material and no Vault token.

## What is stored where

| Table | Contents | Sensitive values |
| --- | --- | --- |
| `tenants` | name, slug, `fortified_at` | none |
| `customers` | name, company, country, status | none; IBAN, tax ID and payment info are in `protected_values` |
| `documents` | name, classification, size, SHA-256 checksum | none; the payload is in `protected_values` |
| `protected_values` | `(tenant, resource, field) → ciphertext, key_name, key_version` | **ciphertext only** |
| `audit_events` | append-only evidence | none |
| `break_glass_requests` | workflow state, token **hash**, Vault token **accessor** | none |
| `compromise_snapshots` | the attacker's copy (ciphertext and metadata) | ciphertext only |
| `demo_state` | compromise and fortify flags, `last_reset_at` | none |
| `schema_migrations` | migration ledger | none |

Encryption protects values; it doesn't make them queryable. You can't search
by IBAN, sort by tax ID or join on payment info. Those queries would need a
deterministic scheme (Transit convergent encryption, or an HMAC index), which
leaks equality. Durin deliberately doesn't pretend otherwise.

## Privilege model

```text
POSTGRES_USER (superuser)   management only; lives in the postgres container env
                            and in Vault's database connection config
  ├── durin_owner  NOLOGIN  owns every table; migrations run as this role
  └── durin_app    NOLOGIN  SELECT/INSERT/UPDATE/DELETE on tables
                            audit_events: INSERT + SELECT only
                            schema_migrations: SELECT only
        └── v-approle-durin-backend-…   LOGIN, Vault-issued, 1 h lease, IN ROLE durin_app
```

Vault's role (`terraform/vault-database/database.tf`):

```sql
-- creation
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE durin_app;
-- revocation
REASSIGN OWNED BY "{{name}}" TO durin_owner;
DROP OWNED BY "{{name}}";
DROP ROLE IF EXISTS "{{name}}";
```

Dynamic users hold no direct grants and own no objects, so revocation always
succeeds.

> **History (fixed 2026-09-29):** earlier builds granted every dynamic user
> membership in the superuser (`GRANT durin TO …`) plus `CREATE` on the
> schema, and the backend ran migrations with its own short-lived credential.
> The result was that every backend credential could `SET ROLE` to a
> superuser, the tables were owned by an ephemeral role, and Vault's
> `DROP ROLE` failed with `2BP01`, which left expired users behind. The
> bootstrap script reassigns that legacy ownership.

## Migrations

The backend never runs DDL. At startup it only checks `schema_migrations` and
refuses to start (`database schema is behind … run 'make db-migrate'`) if the
schema is behind.

```bash
make db-migrate          # scripts/db-migrate.sh
make db-migrate-status
```

`scripts/db-migrate.sh` runs three stages:

1. `scripts/sql/000_bootstrap_roles.sql` as superuser: roles, schema
   privileges, legacy repair, ledger.
2. Each unapplied `backend/src/migrations/NNN_*.sql`, in one transaction, as
   `SET LOCAL ROLE durin_owner`, recorded in `schema_migrations`.
3. `scripts/sql/999_grants.sql` as superuser: the `durin_app` privileges.

Bootstrap order on a fresh stack: `infra-up` → `db-migrate` → `tf-database` →
`backend-up`. `make up` runs `db-migrate` before `backend-up`.

## Inspecting it

- API: `GET /api/v1/database/tables` and `GET /api/v1/database/tables/<table>` (raw rows, nothing decrypted).
- Adminer: <http://localhost:5050>.
- psql: `podman exec -it durin-postgres psql -U durin -d durin_db -c "select field_name, ciphertext from protected_values limit 5"`.

# Arcanium — Infrastructure Stack

PostgreSQL 16 persistent store for the Arcanium API, with Adminer on `http://localhost:5050` for local database administration. PostgreSQL is published on `127.0.0.1:5432`; both services join `arcanium-control`.

## Credential model

The `POSTGRES_USER` / `POSTGRES_PASSWORD` vars in `.env` are **Vault management
credentials only**. They are used once by Terraform (`terraform/vault-database/`)
to register the database connection with Vault's Database secrets engine.

The Arcanium API never reads these vars. It authenticates to Vault (AppRole),
then requests dynamic short-lived credentials from `database/creds/arcanium-api-role`.
No static Postgres password ever exists in application config.

## Prerequisites

```bash
make network   # creates arcanium-control if absent
```

## Start / stop

```bash
make infra-up
make infra-down
make infra-logs
```

Or directly:

```bash
./scripts/compose.sh infra up -d
./scripts/compose.sh infra down
./scripts/compose.sh infra logs -f
```

## Environment variables (repo root `.env`)

| Variable | Purpose |
|----------|---------|
| `POSTGRES_USER` | Vault management superuser (Terraform only) |
| `POSTGRES_PASSWORD` | Vault management password (Terraform only) |
| `POSTGRES_DB` | Database name |

## Validation

```bash
podman exec arcanium-postgres pg_isready -U arcanium
# arcanium-postgres:5432 - accepting connections
```

## Network

Joins the external `arcanium-control` network. Reachable from:
- `postgres:5432` (within the network)
- the host via `127.0.0.1:5432`

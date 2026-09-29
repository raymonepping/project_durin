# Compose stacks

Durin runs as separate Compose projects on one shared network,
`durin-internal`. Drive them through `scripts/compose.sh <stack> …` or the
Makefile (`make <stack>-up|-down|-logs`); both read the root `.env`, which
holds no secrets beyond the licence and the database bootstrap user.

| Stack | Containers | Host ports (127.0.0.1) | Purpose |
| --- | --- | --- | --- |
| `vault` | vault-s, vault-1..3, vault-lb, vault-agent, vault-rotator | 18190, 18200–18202, **18300**, 18404 | Transit seal, Raft HA cluster, load balancer, backend's Vault Agent and secret-id rotation |
| `infra` | postgres, adminer | 5432, 5050 | The deliberately visible database |
| `backend` | durin-backend | 3001 | API / Data Trust Gateway |
| `identity` | identity-secrets-init, openldap, keycloak, ldap-admin (+ bootstrap jobs, profile `init`) | 8083, 8084 | People, roles, tenants; secrets from Vault KV |
| `ui` | ui-secrets-init, durin-ui | 3000 | Web Console + BFF |
| `observability` (optional) | prometheus, grafana, otel-collector | 9090, 3010, 4317/4318 | Metrics and traces |

```sh
make network            # create durin-internal once
make compose-config     # validate every compose.yaml
make up                 # vault → infra → db-migrate → backend
make identity-bootstrap
make ui-rebuild
```

Rules every stack follows:

- **No secrets in compose files or `.env`.** Secrets come from Vault through
  one-shot `*-secrets-init` containers (AppRole, one read, token revoked) or
  from Vault Agent.
- **Hardened by default:** `cap_drop: ALL`, `no-new-privileges`, non-root and
  read-only where the image allows.
- **Vault is reached through `vault-lb`** (`https://vault-lb:8200`), never a
  single node.
- Healthcheck shell variables use `$$` (Compose substitutes `$` first).

`agents/`, `api/` and `workloads/` are empty placeholders.

See [docs/architecture.md](../docs/architecture.md) for how the pieces fit and
[docs/development.md](../docs/development.md) for the first bring-up.

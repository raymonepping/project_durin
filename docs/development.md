# Developing Durin

How to bring Durin up from a fresh clone, work on it, and keep it honest.
Day-to-day operations (rotation, recovery, troubleshooting) are in
[operations.md](operations.md).

## Prerequisites

- macOS or Linux with **Podman** (machine running) and a Compose provider
  (`make check` verifies both). Container names use underscores
  (`durin-vault_1`); `scripts/compose.sh` wraps the provider.
- **Terraform** ≥ 1.6, the **Vault CLI**, `jq`, `openssl`, `curl`.
- **Node.js** ≥ 22 for the Web Console (`ui/`) and Playwright.
- A **Vault Enterprise licence** (`VAULT_LICENSE` in `.env`). Control Groups,
  namespaces and performance standbys need it.

## First bring-up (fresh clone)

```bash
cp .env.example .env            # add VAULT_LICENSE and the POSTGRES_* values
make check network              # podman + compose provider; network durin-internal

# Vault: certificates, cluster, configuration
make gen-certs                  # Durin CA + server certs (vault-tls/)
make vault-up                   # vault-s, vault-1..3, vault-lb
make vault-bootstrap            # init + transit auto-unseal + Raft join + audit
make tf-apply                   # auth (AppRole, JWT), policies, KV, namespaces
./scripts/vault-admin-bootstrap.sh   # optional: scoped admin token instead of root for later admin work
make tf-transit                 # 9 tenant Transit keys

# AppRole IDs for the backend's Vault Agent and its secret-id rotator → .env
#   DURIN_VAULT_ROLE_ID = terraform -chdir=terraform/vault-platform output -raw approle_durin_backend_role_id
#   ROTATOR_ROLE_ID     = terraform -chdir=terraform/vault-platform output -raw approle_durin_rotator_role_id
#   ROTATOR_SECRET_ID   = vault write -f -field=secret_id auth/approle/role/durin-rotator/secret-id
./scripts/compose.sh vault up -d   # recreate agent + rotator with those values

# Data and API
make infra-up                   # PostgreSQL (+ Adminer)
make db-migrate                 # schema as durin_owner (the backend never runs DDL)
make tf-database                # Vault database engine → dynamic durin_app users
make backend-build backend-up   # Vault Agent + durin-backend

# People and the console
make identity-bootstrap         # secrets into Vault KV, LDAP users, Keycloak realm
make ui-rebuild                 # durin-ui → http://localhost:3000
make seed                       # demo tenants, customers, documents

make verify                     # smoke test the whole stack
```

After the first bring-up, `make up` starts vault, infra and backend in
order, then run `make identity-bootstrap` (idempotent) and `make ui-rebuild`.
`make down` stops everything; named volumes keep state.

Secrets never go into `.env` or compose files. Tokens, secret-ids, the root
token and Terraform state live under `.secrets/` (gitignored). Identity
passwords and the OIDC client secret live in Vault KV and reach containers
through one-shot `*-secrets-init` containers.

## Repository layout

```text
backend/            Node/Express API: the Data Trust Gateway
  src/gateway/        authority broker: auth/jwt login per request, Transit calls
  src/routes/         one router per API area (see docs/api/API_CONTRACTS.md)
  src/migrations/     SQL migrations (applied by make db-migrate as durin_owner)
ui/                 Web Console: Nuxt 4 SPA + Nitro BFF
  app/                pages, components, composables (browser)
  server/             BFF: OIDC, sessions, /api/v1 proxy (server)
  tests/              Playwright journeys J0–J9, a11y, narrative, screens
compose/<stack>/    vault, infra, backend, identity, ui, observability
terraform/          vault-platform, vault-transit, vault-database
scripts/            bootstrap, secrets, seed/reset, test suites (make targets wrap them)
docs/               this documentation; start at docs/index.md
prompts/            the build prompts (local, gitignored)
```

## Working on the backend

```bash
make backend-build && ./scripts/compose.sh backend up -d --force-recreate
./scripts/compose.sh backend logs -f
```

- Every protected operation goes through `backend/src/gateway`, which logs in to
  Vault **as the signed-in person** (`auth/jwt`, role `tenant-<t>`). Never add a
  code path that decrypts with the broker token; it has no such right, and
  `make authority-test` will fail.
- Errors are values: Vault's refusal (`vault`, `authority`, `auditEventId`) goes
  back to the caller unchanged. Vault unavailable means `503`, never plaintext.
- Schema changes are new files in `backend/src/migrations/` plus grants in
  `scripts/sql/999_grants.sql`, applied with `make db-migrate`.
- Every new endpoint is documented in [api/API_CONTRACTS.md](api/API_CONTRACTS.md).

## Working on the Web Console

```bash
make ui-dev        # hot reload on :3000 against the running backend + Keycloak
make ui-rebuild    # rebuild the container (signs everyone out: sessions are in memory)
cd ui && npx nuxt typecheck
```

- The design system is [frontend/config/DESIGN.md](frontend/config/DESIGN.md).
  Keep component classes in `@layer components`, and don't go below 0.8rem
  text (the root size is 15px).
- The browser never sees a token. New API calls go through `useApi()`, which
  adds `x-tenant` and CSRF. The BFF forwards only allowlisted headers.
- On macOS, `make ui-build` strips extended attributes first: podman otherwise
  tars `._*` AppleDouble files and the Nitro build fails.

## Tests

Every claim in [security-model.md](security-model.md) has a test. See
[testing.md](testing.md) for what each suite covers.

```bash
make test-all        # every backend suite (needs the identity stack)
make test-frontend   # Playwright J0–J9 + accessibility (starts with make reset)
```

Run both before handing work over. A SKIP is a finding, not a pass.

## Adding a tenant

Add the slug to the tenant lists in Terraform (`vault-transit`,
`vault-platform`), apply both, seed a `tenants` row, and give users the slug in
their LDAP `businessCategory` (→ `durin_tenants`). See the full steps in
[multi-tenancy.md § Adding a new tenant](multi-tenancy.md#adding-a-new-tenant).

## Conventions

- Commits and releases go through `commit_gh` (it stages everything, so stash
  unrelated work first). See [release-checklist.md](release-checklist.md).
- Update [CHANGELOG.md](../CHANGELOG.md) under `[Unreleased]`.
- Compose healthchecks use `$$` for shell variables (Compose substitutes `$`).

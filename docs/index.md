# Durin documentation

> The database holds the data. Vault holds the key. Authority belongs to
> people, not to the application.

Start with **Understand**, then follow the path that matches what you want to
do.

## Understand

| Document | What it answers |
| --- | --- |
| [architecture.md](architecture.md) | What the pieces are, how a request flows, and every trust boundary: who has authority, why, for how long, and how it is revoked |
| [security-model.md](security-model.md) | The authority chain in detail: broker, operator, break glass, database identity, and what is decided where |
| [threat-model.md](threat-model.md) | Compromised database, application, tenant, operator, break glass, leaked credentials, Vault down: expected outcome and test for each |
| [scenarios.md](scenarios.md) | The demo: Protect, Recover, Compromise, Shield, Isolation, Break Glass, with the cast, what to show and what to say |

## Components

| Document | Covers |
| --- | --- |
| [vault.md](vault.md) | Cluster, vault-lb, auth methods, JWT roles, policies, engines, Control Groups, namespaces, audit |
| [transit.md](transit.md) | Key naming, ciphertext format, rotation, rewrap, `min_decryption_version` |
| [database.md](database.md) | What is stored where, the privilege model (owner, app, Vault dynamic users), migrations, inspecting it |
| [multi-tenancy.md](multi-tenancy.md) | Per-tenant keys and policies, isolation matrix, adding a tenant |
| [identity.md](identity.md) | Keycloak + LDAP, users and roles, `durin_tenants`, Vault-sourced secrets |
| [break-glass.md](break-glass.md) | Emergency access as a Vault Control Group: request, approve, redeem once, deny, revoke, expire |
| [web-console.md](web-console.md) | The console: BFF sign-in, screens, design, quality |
| [api/API_CONTRACTS.md](api/API_CONTRACTS.md) | Every endpoint, request and response, error codes, and the Web Console BFF |

## Build, run, verify

| Document | For |
| --- | --- |
| [development.md](development.md) | Prerequisites, first bring-up from a fresh clone, repo layout, working on backend and console |
| [operations.md](operations.md) | Secret-id rotation, dynamic credentials, recovery, vault-lb, identity stack, Web Console troubleshooting |
| [testing.md](testing.md) | Every test suite, what it proves, and the last recorded results |
| [release-checklist.md](release-checklist.md) | Tagging a release with `commit_gh` |

## Evidence and reviews

| Document | Contents |
| --- | --- |
| [security-review.md](security-review.md) | Phase 7 hardening review (policies, credential lifetimes, isolation, failure behaviour, containers, secret hygiene) and its remediation log |
| [frontend/FRONTEND_QUALITY_GATE.md](frontend/FRONTEND_QUALITY_GATE.md) | Web Console quality gate: build, journeys, accessibility, dependencies, verdict |
| [frontend/UI_TOOLCHAIN_REPORT.md](frontend/UI_TOOLCHAIN_REPORT.md) | Design toolchain (Playwright, Impeccable, Taste), findings, changes applied and rejected |
| [frontend/BASELINE.md](frontend/BASELINE.md), [frontend/UI_AUDIT.md](frontend/UI_AUDIT.md), [frontend/UI_IMPROVEMENT_PLAN.md](frontend/UI_IMPROVEMENT_PLAN.md) | The console's first-run baseline, audit findings, and improvement steps |
| [frontend/config/DESIGN.md](frontend/config/DESIGN.md), [frontend/config/QUALITY.md](frontend/config/QUALITY.md), [frontend/config/PRODUCT.md](frontend/config/PRODUCT.md) | Design system, quality policy, product context |
| [screenshots/](screenshots/README.md) | Playwright captures of every screen (desktop, phone, viewer), with provenance |

## Quick reference

| | |
| --- | --- |
| Web Console | http://localhost:3000 |
| API | http://localhost:3001/api/v1 (`/health` is open) |
| Vault (via vault-lb) | https://127.0.0.1:18300 |
| Keycloak | http://localhost:8083 (realm `durin`) |
| Adminer (PostgreSQL) | http://localhost:5050 |
| Users | raymon (operator, all), barend (operator, ACME), viewer (viewer, ACME + Globex), security-admin |
| Passwords | `./scripts/identity-secrets.sh --show-user <name>` |
| Reset the demo | `make reset` |
| Everything green? | `make test-all && make test-frontend` |

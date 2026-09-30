# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Durin Web Console** (`ui/`, prompts/frontend/01_00–01_05): Nuxt 4 SPA + Nitro BFF, "Smart Privacy Glass" design (frost = ciphertext; a pane clears only on Vault ALLOWED). Screens: Overview, Protect, Recover, Compromise, Shield, Isolation, Break Glass, Customers, Documents, Tenants, Database Inspector, Vault, Audit, sign-in. Design system in `docs/frontend/config/DESIGN.md`.
- BFF sign-in: OIDC code + PKCE with Keycloak, server-side sessions, httpOnly cookie, header allowlist, CSRF. The OIDC client secret comes from Vault through `ui-secrets-init` (AppRole `durin-ui`, one KV path). `compose/ui` is hardened: non-root, read-only, `cap_drop: ALL`.
- Playwright journeys J0–J9 + axe accessibility (`make test-frontend`), `@narrative` timed demo run, `@failover`, `@screens`; `make ui-build|ui-rebuild|ui-dev|test-frontend-ui`.
- Frontend quality gate and toolchain reports (`docs/frontend/`), screenshots with provenance (`docs/screenshots/`).
- `docs/api/API_CONTRACTS.md`: Web Console BFF section.
- Document upload: `.md`, `.pdf` and `.docx` files (≤ 5 MB) alongside pasted text. Vault encrypts the file bytes; recovery returns them for download, and the console verifies the SHA-256 against the upload. Playwright J10.
- Documentation set per the lead prompt §29: `README.md` rewritten; new `docs/index.md`, `architecture.md` (components, request flow, trust-boundary table), `vault.md`, `scenarios.md`, `development.md` (fresh-clone bring-up), `web-console.md`; `compose/README.md` rewritten for Durin.

- `GET /api/v1/vault/status` (nodes, seal type, leader, vault-lb agreement, tenant-filtered key metadata) from unauthenticated Vault endpoints — no new Vault authority (prompts/api/01_02).
- `prompts/frontend/01_02_authentication_bff.md`: sign-in via Nuxt BFF, tokens never in the browser, client secret from Vault.
- Identity-derived Vault authority (prompts/improvements/01_04): Vault `auth/jwt` trusts Keycloak; operators get 5-minute tenant tokens issued to them; `make authority-test`.
- Break glass on Vault Control Groups (approval by identity group `durin-security-admins`, single release); redemption by requester identity (`x-break-glass-request`).
- Identity stack completed (prompts/security/17_02): Vault-sourced identity secrets (KV + one-shot AppRole init), LDAP users with Vault-generated passwords, LDAP groups → realm roles, `durin_tenants` claim, audience, `durin-cli` lab client; `make identity-bootstrap|identity-verify|rbac-test`.
- Backend runs with `DURIN_AUTH_ENABLED=true`; `/health` reports the auth mode.
- `scripts/lib/durin-auth.sh`: every test suite uses real tokens when auth is enabled.
- `vault-lb` (HAProxy 3.0, TLS passthrough, active-node routing) as the single Vault endpoint; `make vault-failover-test`, `make vault-lb-stats`.
- Backend retries idempotent Vault calls across leader failover.
- `scripts/vault-gen-certs.sh --reissue-server` (adds SANs without a new CA).
- Per-tenant Vault token roles (`durin-tenant-<t>`) and the Data Trust Gateway authority broker (`backend/src/gateway/authority.js`).
- `durin-<t>-restricted` Transit keys and Vault-enforced break glass (`durin-breakglass-<t>` token roles: single use, 15 min).
- Scenarios: `isolation-probe`, `compromise/snapshot`, attacker/application decrypt attempts, self-verifying Shield/Fortify.
- Database Inspector raw table browser (`/database/tables`).
- `make db-migrate` (owner-run migrations), `make security-test`, `make test-all`.
- Docs: `security-model.md`, `break-glass.md`, `database.md`, `testing.md`; API contract rewritten.

### Changed

- `make ui-rebuild` runs `scripts/ui-rebuild.sh` again (streamed-archive build, AppleDouble-safe, re-renders the OIDC secret, waits until healthy); the script was fixed to recreate `ui-secrets-init` + `durin-ui`.
- Isolation screen: the authority tag reads "Token issued to <user> for <tenant>", so it no longer looks like it contradicts the DENIED verdict.

- Stale docs corrected: `transit.md` (key operations run under the operator's Vault token, not the broker's), `operations.md` (`VAULT_ADDR` via vault-lb), `.env.example` and `compose/vault` (how the AppRole IDs are actually seeded).

- `prompts/api/01_01` schema brought up to the live schema; `prompts/api/API_CONTRACTS.md` is now a generated index of all 42 endpoints.
- `PRODUCT.md` moved to `docs/frontend/config/` (root path kept as a symlink, alongside `DESIGN.md`).

- Prompts reorganised: frontend prompts consolidated in `prompts/frontend/` in execution order (01_00 spec → 01_05 narrative, 02_01 Playwright, 03_0x toolchain/quality gate); `base_project/22_01_break_glass_workflow.md`, `23_01_phase7_hardening.md` renamed to match content; screen designs, console, inspector, narrative and Playwright prompts updated to identity-derived authority and Control-Group break glass.
- The backend AppRole now holds broker-only authority (`durin-backend`, `durin-database`).
- Plaintext recovery requires `durin-operator`; viewers get field descriptors.
- Reset keeps tenants and the append-only audit trail and writes `DEMO_RESET`.
- `make up` runs `db-migrate` and no longer starts the UI stack.

### Removed

- Token roles `durin-tenant-*`, `durin-breakglass-*`; broker minting, rotation and key-config authority; the `x-break-glass-token` bearer flow.
- `durin-transit` (all-tenant) policy.
- Backend-run migrations.

### Fixed

- Web Console countdowns use server time (from `meta.timestamp`); a drifted container clock no longer shows a live break-glass window as expired. The duplicate "BREAK GLASS ACTIVE" line and the payload/lock-icon overlap are fixed.

- Keycloak client `durin-backend` never received its Vault-sourced secret (`kcadm update clients/<id>/client-secret` only regenerates), so every Web Console sign-in failed; `setup_keycloak.sh` now sets it on the client and fails loudly.

- Vault standby healthcheck reported perf-standbys as unhealthy.
- Vault could not revoke dynamic DB users (`2BP01`), so expired users accumulated.
- Test suites targeted vault-s (`:18190`) and stale container names.

### Security

- Identity passwords removed from `.env`; they now live in Vault KV.
- Removed `durin-admin` from the backend's Vault identity.
- Removed superuser membership and `CREATE` from dynamic DB users.
- JWT: algorithm allowlist and audience check; authentication on all `/api` routes.

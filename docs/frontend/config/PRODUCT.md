# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Nuxt 4 / Vue 3 with Tailwind CSS (specified in `prompts/frontend/01_03_web_console.md`, consistent with Arcanium and Editors Factory). The Nuxt server is also the backend-for-frontend (`prompts/frontend/01_02_authentication_bff.md`). Runs as container `durin-ui` on `127.0.0.1:3000` via Podman (`compose/ui`).

## Users

A presenter (typically a HashiCorp solutions engineer) drives the Durin Web Console live for customer security architects and CISOs, telling one story: Protect → Recover → Compromise → Shield → Isolation → Break Glass. The presenter switches between real identities (raymon operator, barend single-tenant operator, viewer, security-admin) to show that authority differs per person. The console is viewed up close on the presenter's own laptop (retina display, arm's length), sometimes also screen-shared.

## Product Purpose

Make one question answerable at a glance: **who can turn this ciphertext back into plaintext?** Durin's answer: a verified person, for one tenant, for five minutes — decided by HashiCorp Vault Enterprise, not by the application. Success: the audience leaves understanding that Vault controls the authority that makes protected data useful, and trusting that every verdict on screen is Vault's real answer.

## Positioning

A reference application whose backend holds no cryptographic authority of its own. Every decrypt runs on a Vault token issued to the signed-in person (Vault `auth/jwt` trusting Keycloak); break glass is a Vault Control Group; the database is deliberately visible and holds only `vault:vN:` ciphertext. The console shows Vault's actual verdicts, accessors, key versions and audit evidence — nothing simulated client-side.

## Operating Context

- Scripted demo sequence (`prompts/frontend/01_05_demo_narrative_polish.md`), 10–14 minutes, reset in < 30 s (`make reset`) and repeated for the next audience.
- Personas are switched by signing out and in (Keycloak realm `durin`, LDAP users; passwords from Vault KV).
- Supporting evidence the presenter may cut to: Database Inspector (application / database / Vault views), Vault cluster page (leader, load balancer), audit log, occasionally terminal (`make vault-failover-test`).

## Capabilities and Constraints

- Backend API contract: `docs/api/API_CONTRACTS.md` (source of truth; no invented fields).
- Tenants: ACME, Globex, Initech. Roles: durin-viewer, durin-operator, durin-security-admin; tenant scope from the `durin_tenants` claim.
- Tokens never reach browser JavaScript (BFF, httpOnly session). No Vault credential in the frontend.
- Terminology to keep verbatim: Protect, Recover, Compromise, Shield (Fortify), Isolation, Break Glass, Data Trust Gateway, Transit, ciphertext, key version, min decryption version, control group, tenant.

## Brand Commitments

- Durin has its own identity; HashiCorp and Vault are named in content, not used as colours or logo treatment.
- The name evokes Durin (strength, guarded resources, controlled access) as metaphor only — no fantasy or dwarven aesthetics (lead prompt §19, `prompts/frontend/01_00_durin_design_spec.md`).
- User-pinned (2026-09-29): modern, aesthetic **glassmorphism** while maintaining a professional look and feel.

## Evidence on Hand

Real, live data from the running stack: seeded customers and documents per tenant (synthetic personas and IBANs from `backend/src/seed-data.js`), real Vault key versions, accessors, audit events and cluster state. No customer logos, testimonials, benchmarks or performance claims exist; none may be invented.

## Product Principles

1. Every verdict on screen is Vault's real answer — show it verbatim next to the human sentence.
2. Authority belongs to people: always show who Vault authorised, for which tenant, for how long.
3. Ciphertext must never be mistaken for plaintext, at a glance.
4. The database is visible on purpose.
5. The presenter is never stuck: every state (denied, pending, retired, unavailable) is explained on screen.

## Accessibility & Inclusion

WCAG 2.1 AA contrast for all text, including on translucent surfaces; full keyboard operation; reduced-motion respected.

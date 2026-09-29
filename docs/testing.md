# Durin Testing

Every claim in [security-model.md](security-model.md) has a test that asks
Vault or PostgreSQL directly. Passing tests aren't enough on their own: a
SKIP in these suites means a claim went unverified, so treat it as a finding.

## Suites

| Command | Script | Mutates? | Covers |
| --- | --- | --- | --- |
| `make identity-verify` | `scripts/identity-verify.sh` | no | every LDAP user logs in via Keycloak; roles, tenants, audience in real tokens |
| `make authority-test` | `scripts/test-authority.sh` | no | compromised backend holds nothing (real Vault calls); forged/foreign/missing identities refused at auth/jwt; 5-min scoped authority; Vault audit names the user |
| `make rbac-test` | `scripts/test-rbac.sh` | light | Prompt 17 matrix with real tokens, tenant claim, plaintext only for operators, break glass by identity, audit attribution, JWT negatives |
| `make verify` | `scripts/verify-stack.sh` | no | containers healthy, vault-lb, identity stack, OIDC enforced, backend authority, schema migrated |
| `make isolation-test` | `scripts/test-isolation.sh` | no (creates short-lived tokens) | auth/jwt login matrix (who Vault issues authority to) × keys, restricted-key denial, break glass as a Control Group (narrow, withheld until approved), API tenant boundary, namespaces |
| `make hardening-test` | `scripts/test-hardening.sh` | no | policy review, credential TTLs, key export denied, container hardening, secret hygiene |
| `make threat-model-test` | `scripts/test-threat-model.sh` | light (one break-glass request) | T1 compromise, T2 compromised application (capability matrix), T3 cross-tenant, T5 break-glass abuse, T7 Vault unavailable |
| `make security-test` | `scripts/test-security-journeys.sh` | **yes**: rotates keys, runs Shield; ends with reset + seed | every validation journey in the lead prompt §28, end to end |
| `make vault-failover-test` | `scripts/test-vault-failover.sh` | **disruptive**: stops the Vault leader, then restarts it | leader failover through vault-lb under load: new leader, interruption, fail closed, rejoin |
| `make test-all` | verify, identity, authority, rbac, isolation, hardening, threat-model, security | yes | |
| `make test-frontend` | `ui/tests/j0…j9-*.spec.ts`, `a11y.spec.ts` (Playwright) | **yes**: starts with `make reset`; runs compromise, Shield, break glass | Web Console journeys J0–J9 (prompts/frontend/02_01) with real Keycloak users signed in through the BFF; axe WCAG 2.1 A/AA on every screen |
| `cd ui && npx playwright test narrative --grep @narrative` | `ui/tests/narrative.spec.ts` | yes (run after `make reset`) | the 01_05 demo story, timed, with zero browser console errors |
| `cd ui && npx playwright test j9 --grep @failover` | `ui/tests/j9-vault.spec.ts` | no (run while `make vault-failover-test` runs) | the Vault page follows a leader change |
| `cd ui && npx playwright test screens --grep @screens` | `ui/tests/screens.spec.ts` | no | regenerates `docs/screenshots/` |

### Vault-unavailable path (T7)

T7's failure path runs only when Vault is unreachable from the backend.
Stopping a single Vault node no longer does that, because vault-lb fails over
(that's `make vault-failover-test`). Stop the load balancer instead:

```bash
podman stop durin-vault_lb
./scripts/test-threat-model.sh --t7      # expects 503 after the retry window, never plaintext
podman start durin-vault_lb
```

All suites source `scripts/lib/durin-auth.sh`. When the backend enforces
OIDC, every backend request carries a real Keycloak token (the
`x-durin-actor` persona maps to an LDAP user); in demo mode, requests pass
through unchanged.

## Last recorded run (2026-09-29)

| Suite | Result |
| --- | --- |
| verify | 28 / 28 |
| identity-verify | 14 / 14 |
| authority | 23 / 23 |
| rbac | 70 / 70 |
| isolation | 28 / 28 |
| hardening | 38 / 38 |
| threat-model | 27 pass, 2 skip (T7 failure path; run separately: 3 / 3) |
| security journeys | 74 / 74 |
| vault failover | 6 / 6, 0 of 96 requests failed, slowest 6.9 s |
| test-frontend | 30 / 30 (J0–J9 = 27, a11y = 3) |
| @narrative | 1 / 1: Inspector 858 ms, Shield 286 ms, break glass 3.6 s, 0 console errors |
| @failover (with vault-failover-test) | 1 / 1, leader card moved in ~17 s |

The frontend quality gate (typecheck, build, a11y, dependency audit, design
compliance) is recorded in [frontend/FRONTEND_QUALITY_GATE.md](frontend/FRONTEND_QUALITY_GATE.md).

Playwright signs users in through the real Keycloak page, taking passwords from
Vault KV (`scripts/identity-secrets.sh --show-user`), and stores only the
httpOnly session cookie (`ui/tests/.auth/`, gitignored). The UI tests share one
demo state, so they run with one worker in file order (J3 before J4).

## Not yet covered

- Cross-browser (Firefox/WebKit) runs of the journeys; the demo is presented in Chromium.

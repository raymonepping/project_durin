# Durin Web Console — quality policy

Durable policy for `prompts/frontend/03_02_quality_gate.md`. Each run's results
go in [../FRONTEND_QUALITY_GATE.md](../FRONTEND_QUALITY_GATE.md); this file
changes only when the policy does.

## Environment

The gate runs against the **live** stack: Vault (3-node Raft + vault-lb),
PostgreSQL, durin-backend, Keycloak/OpenLDAP and `durin-ui` (container, port
3000). Nothing is mocked. If any of these is down, the result is **BLOCKED**,
never PASS.

```bash
make up && make identity-bootstrap && make ui-rebuild
```

## Required gates

| # | Gate | Command / evidence | Pass criterion |
| --- | --- | --- | --- |
| 1 | Engineering integrity | `cd ui && npx nuxt typecheck` | exit 0 |
| 2 | Production build | `make ui-build` | image builds; `.output` produced |
| 3 | Browser runtime | `make ui-rebuild`, `GET /` 200, `/api/v1/auth/me` 401 unauthenticated | container healthy |
| 4 | Functional workflows | `make test-frontend` (J0–J9, `prompts/frontend/02_01`) | all pass from `make reset` |
| 5 | Responsive behaviour | `@screens` spec at 1440×900 and 390×844 | no page wider than the viewport; no clipped primary action |
| 6 | DESIGN.md compliance | review against [DESIGN.md](DESIGN.md) + `impeccable detect ui/app` | source scan clean; live findings triaged |
| 7 | Accessibility | `tests/a11y.spec.ts` (axe, WCAG 2.1 A/AA) on sign-in + every route as operator and viewer | 0 violations |
| 8 | Visual regression | `@screens` captures into `docs/screenshots/` compared with the previous run | differences explained by intended changes |
| 9 | Console health | `@narrative` spec collects `console.error` + `pageerror` across the whole story and three personas | 0 errors |
| 10 | Dependency sanity | `cd ui && npm audit` | 0 high/critical; no unused runtime deps |

Optional: Gate 11 (performance: 01_05 timings: Inspector < 2 s, Shield < 10 s,
break glass < 60 s, persona switch < 15 s, reset < 30 s) is run with the
`@narrative` spec and treated as required before a live demo. Gates 12–13
(cross-browser, production comparison) are not applicable: the console is a
Chromium-presented lab demo with no production deployment.

## Viewports

1440×900 (presenter laptop; primary), 390×844 (phone; must not break).

## Browser matrix

Chromium (Playwright 1.63). Firefox/WebKit: not required.

## Security invariants (always blocking)

- No JWT or Vault token in `localStorage`, `sessionStorage` or `document.cookie`
  (J0.3); the session cookie is httpOnly.
- No client-side verdicts: every ALLOWED/DENIED on screen comes from the API.
- No plaintext fallback when Vault is unavailable.

## Release decision

PASS: all required gates pass. PASS WITH WARNINGS: only LOW or advisory
findings remain, each listed. FAIL: any required gate fails. BLOCKED: the
environment could not be brought up.

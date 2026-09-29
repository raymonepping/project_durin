# Frontend Quality Gate

Run: 2026-09-29 · `durin-ui:local` (Nuxt 4.5.2) · policy
[config/QUALITY.md](config/QUALITY.md) · live stack (Vault 2.1.0-ent 3-node
Raft behind vault-lb, PostgreSQL, durin-backend, Keycloak 26.6.4 + OpenLDAP).

## Summary

```text
Overall result:
PASS WITH WARNINGS
```

Every required gate passes. The warnings are one detector finding that was
triaged as a false positive, the untested optional browsers, and the
deliberately rejected Taste recommendations listed below.

## Gate results

| Gate | Result | Blocking | Evidence |
| --- | --- | --- | --- |
| Engineering integrity | PASS | Yes | `npx nuxt typecheck` exit 0 (vue-tsc, TS 5.9) after fixing the type errors it found: untyped runtime config (`string \| undefined` into OIDC calls), missing Node types, an unchecked regex group. |
| Production build | PASS | Yes | `make ui-build` / `ui-rebuild` exit 0; multi-stage `ui/Containerfile`, non-root, `read_only`, `cap_drop: ALL`. |
| Browser runtime | PASS | Yes | `GET /` 200; `GET /api/v1/auth/me` 401 unauthenticated; login 302 → Keycloak with PKCE S256; `ui-secrets-init` renders the OIDC secret from Vault and revokes its token. |
| Functional workflows | PASS | Yes | `make test-frontend`: **30 passed** (J0–J9 = 27, a11y = 3) from `make reset`. `@failover` J9.2 passed while `make vault-failover-test` ran (6/0); leader card moved in ~17 s. |
| Responsive behaviour | PASS | Yes | `@screens` at 1440×900 and 390×844: every phone capture is 390px wide. The Inspector was 496px wide (a select sized to its longest option) and was fixed. |
| DESIGN.md compliance | PASS | Yes | `impeccable detect ui/app`: 0 findings. Live `/login`: 4 low-contrast pixel findings triaged as false positives (below). Manual review against [config/DESIGN.md](config/DESIGN.md). |
| Accessibility | PASS | Yes | axe WCAG 2.1 A/AA on sign-in + 13 routes × {raymon, viewer}: **0 violations**, after fixing teal contrast (3.7 → 5.5:1), muted ink (4.1 → 4.8:1), sub-12px text, and non-focusable scroll regions. |
| Visual regression | PASS | Yes | 45 captures in `docs/screenshots/{desktop,phone,viewer}` (first Durin baseline). Differences from the in-run captures are all intended (layer fix, teal, 12px floor, key-range chips). |
| Console health | PASS | Yes | `@narrative`: 0 `console.error` / `pageerror` across the 9-step story and 3 personas. |
| Dependency sanity | PASS | Yes | `npm audit`: 0 vulnerabilities (was 3 incl. **high** on Nuxt 4.4.5 → upgraded to 4.5.2). Runtime deps: nuxt, vue, vue-router, lucide-vue-next, 2 fontsource packages; all used. |
| Performance (optional, 01_05) | PASS | No | Inspector 858 ms (< 2 s), Shield 286 ms (< 10 s), break glass request → approve → redeem 3.6 s (< 60 s), persona switch ≤ 160 ms (< 15 s), `make reset` 0.6 s (< 30 s). |
| Cross-browser (optional) | NOT RUN | No | Chromium only by policy. |

## Required evidence

- **Routes tested:** `/login`, `/`, `/protect`, `/recover`, `/compromise`,
  `/shield`, `/isolation`, `/break-glass`, `/customers`, `/customers/:id`,
  `/documents`, `/documents/:id`, `/tenants`, `/inspector`, `/vault`, `/audit`.
- **Viewports:** 1440×900, 390×844.
- **Workflows:** J0 identity + no token in the browser; J1 protect; J2 recover
  and viewer masking; J3 compromise and replays; J4 Shield with Vault
  verification; J5 Inspector (operator, viewer, RESTRICTED); J6 break glass
  with 11 checks (Control Group request, operator can't approve, approver
  can't request, other operator can't redeem, redeem once, deny); J7 tenant
  scope; J8 isolation; J9 Vault cluster (+ failover).
- **Screenshots:** `docs/screenshots/` (provenance in its README).
- **Console:** 0 errors.
- **Impeccable:** source clean. Live login findings:
  - `low-contrast … on backdrop filter` ×3: **false positive, verified.** The
    computed colours are `#526073` / `#3e4c5f` / `#0f1a2a` on a white 88% pane
    (≥ 6:1). The detector's minimum-pixel sample hits anti-aliased glyph edges
    over the blurred mullions. axe (colour-based) reports 0 on the same page.
  - `cramped-padding 0px`: text elements without a visible boundary (headline,
    footnote), so no fix needed.
  - advisory `repeating-stripes-gradient`: the aluminium mullions and frost
    grain. Brief-pinned material, kept.
- **Taste** (`design-taste-frontend`): dials recorded in DESIGN.md
  (variance 4, motion 3, density 6). Findings are in UI_AUDIT.md; two are
  rejected with reasons.
- **DESIGN.md violations:** none open.
- **Engineering:** typecheck 0 errors; there is no ESLint config in `ui/` (lint
  was not part of the Durin prompts).
- **Build:** see gate 2.
- **Accessibility observations:** frost is visual only. Protected values
  expose their state in text ("Frosted — ciphertext only", "Cleared by
  Vault", "Denied · reason"), and LEDs are `aria-hidden`.
- **Dependencies:** see gate 10.

## Findings fixed during this run

| Severity | Finding | Fix |
| --- | --- | --- |
| High | Nuxt 4.4.5 advisories (XSS via NuxtLink/navigateTo, island RCE, …) | Nuxt 4.5.2 |
| High | Unlayered `.pane`/`.btn` overrode Tailwind utilities: the phone rail took ~800px of flow, the header wasn't sticky, the hamburger showed on desktop | component classes → `@layer components` |
| Medium | Keycloak client `durin-backend` never received the Vault-sourced secret (`kcadm update clients/<id>/client-secret` only regenerates; the failure was hidden by `2>/dev/null`), so every sign-in failed | `setup_keycloak.sh` sets `secret` on the client and fails loudly |
| Medium | Teal/white 3.7:1, muted ink 4.1:1, text at 11.25px | tokens + 12px floor |
| Medium | Phone Inspector 496px wide | select width, `minmax(0,1fr)` columns |
| Low | Break-glass card disappeared from "Active" after deny/approve, taking its confirmation with it | acted-on cards stay until you leave the page |
| Low | Retired key versions listed one by one (v1…v24) | collapsed range chip |

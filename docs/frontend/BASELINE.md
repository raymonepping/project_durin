# Frontend Baseline — Arcanium

Captured before any UI code was modified, against the actual repository
and the live, running `arcanium-ui` container (not a freshly-started dev
server, per the mission's "existing, deployed application" framing).

## Runtime

| | |
|---|---|
| Node.js (host) | v25.2.1 |
| Node.js (production image) | `node:24-slim` (`arcanium/ui/Containerfile`) |
| Package manager | npm (`package-lock.json`; `Containerfile` uses `npm ci`) |
| Nuxt | ^4.5.0 |
| Vue | ^3.5.17 |
| TypeScript | ^5.8.3, checked via `vue-tsc` (`nuxt typecheck`) |
| CSS | Tailwind v4 (`@tailwindcss/vite`) utility layer + a hand-authored token/component system in `app/assets/css/main.css` (the dominant styling mechanism — see `docs/frontend/config/DESIGN.md`) |
| Component primitives | `reka-ui` |
| Icon library | inline hand-authored SVG (no icon library dependency) |
| Animation libraries | none |
| Testing framework | `@playwright/test` present as a devDependency but unconfigured — no `playwright.config.*`, no test files, prior to this pass |
| Linting | no `lint` script, no ESLint config present |
| Formatting | none configured for `arcanium/ui` specifically |

## Project structure

- **Pages (19):** `/`, `/login`, `/onboard`, `/suppliers`, `/suppliers/[id]`,
  `/applications`, `/applications/[id]`, `/applications/[id]/intent`,
  `/keys`, `/keys/[id]`, `/reconciliation`, `/reconciliation/[id]`,
  `/approvals`, `/evidence`, `/integrations`, `/jobs`, `/cluster`,
  `/maturity`, `/observability`, `/teams`.
- **Layouts:** `default.vue` (sidebar + topbar shell), login uses
  `definePageMeta({ layout: false })`.
- **Components (4):** `AppFooter`, `ClusterTopology`, `ManagementDialog`,
  `RecordPagination`.
- **Composables:** `useArcaniumApi` (typed API client over the gateway),
  `useClusterHealth`.
- **Middleware:** `auth.global.ts` — real OIDC-session gate, runs on both
  server and client (see `UI_AUDIT.md` for a real defect found in this
  file's interaction with hydration).
- **Server routes:** `server/routes/gateway/[...path].ts` (allowlisted
  proxy to `arcanium-api`) plus dedicated OIDC login/callback relay routes.
- **API client:** `useArcaniumApi.ts`, generated types in
  `app/types/api.generated.ts` (from `openapi/arcanium.yaml`).
- **Auth:** OIDC via Keycloak, LDAP-backed groups, session cookie
  (`arc_session`), demo-persona switch when auth is disabled.
- **Shared UI primitives:** the card/badge/button/dialog patterns
  documented in `DESIGN.md`.

## Design system present before this pass

Colors, typography, spacing, radius, and shadows were already fully
tokenized in `main.css` (see `DESIGN.md`, now formalized into that file).
Accessible-contrast targets for each text token were already documented
inline in `main.css` itself — this project had already done real
accessibility engineering before this pass; it had not been captured into
a `DESIGN.md` as the project's own visual contract.

## Engineering health (BASELINE — recorded exactly as found, before any change)

```text
BASELINE
--------
Install:     PASS   (npm ci — 649 packages; EBADENGINE warnings only, no errors)
Lint:        NOT PRESENT
Typecheck:   FAIL   (11 pre-existing type errors — see below)
Tests:       NOT PRESENT
Build:       PASS   (nuxt build — 2.72 MB / 691 kB gzip total output)
```

Pre-existing typecheck failures (11, across 6 files) — **baseline
failures, not attributable to this pass**:

- `app/composables/useArcaniumApi.ts:29,33` — `unknown` not assignable to
  `BodyInit | Record<string, any> | null | undefined`.
- `app/layouts/default.vue:435` — object possibly `undefined`.
- `app/pages/approvals.vue:243` — `id` optional vs. required mismatch.
- `app/pages/evidence.vue:115` — object possibly `undefined`.
- `app/pages/reconciliation/[id].vue:42,48,53,67,85` (5 errors) —
  `string | boolean` not assignable to `Booleanish | undefined`.
- `app/pages/suppliers/[id].vue:214` — `string[] | TransitKey[]` union
  mismatch.

None of these were touched in this pass (out of scope — see
`UI_IMPROVEMENT_PLAN.md`).

## Browser baseline

Live-verified with Playwright CLI (`@playwright/cli`, project-local),
against the running `arcanium-ui` container at `http://localhost:3000`,
authenticated as the real `demo-operator` OIDC identity (LDAP-backed,
Keycloak).

**Routes tested (14, all authenticated views):** `/`, `/suppliers`,
`/applications`, `/keys`, `/reconciliation`, `/onboard`, `/approvals`,
`/evidence`, `/integrations`, `/jobs`, `/cluster`, `/maturity`,
`/observability`, `/teams`.

**Viewports:** Desktop 1440×900, Laptop 1280×800, Mobile 390×844 (42
screenshots total, `.artifacts/ui-baseline/{desktop,laptop,mobile}/`,
gitignored).

### Functional observations

All 14 routes loaded successfully and rendered real, live data from the
running API/Vault/Postgres stack (supplier counts, key inventory,
reconciliation drift status, governance approval counts) — nothing
fabricated, matching the product's own "never fabricate evidence" rule.

### Responsive observations — real defects found

1. **Topbar overlap/clipping below ~640px, on every route.** The page
   title (`.page-title`) had `white-space: nowrap` with no
   `overflow`/`text-overflow` handling, so at 390px width its text
   visually spilled outside its flex-shrunk box and overlapped the
   search trigger next to it; simultaneously the pending-approvals badge
   text was clipped at the viewport's right edge. Confirmed on the
   dashboard and `/keys` (representative of every route, since this is
   the shared layout's topbar). **Fixed this pass** — see
   `UI_IMPROVEMENT_PLAN.md` Wave 1.
2. **"Cryptographic Lifecycle Coverage" 6-column grid did not respond at
   all below 900px.** Every other grid on the dashboard (`.arc-kpi-strip`,
   `.arc-grid-2/3`, `.story-doors`) had a responsive breakpoint; this one
   (`.arc-kml`, `app/assets/css/main.css`) did not, so at 390px width
   columns 4–6 were pushed entirely off-screen with no wrap. **Fixed this
   pass.**

### Accessibility observations

- `*:focus-visible` ring, skip-link, and `prefers-reduced-motion` support
  were already present and functioning (see `DESIGN.md`).
- A real, documented-but-violated contrast rule was found on the login
  page (`--arc-text-dim`, rated large/bold-only in the project's own
  `main.css` comment, used for 10.5px body text) — **fixed this pass**,
  see `UI_AUDIT.md`.

### Existing browser errors / console warnings

- **Real, reproducible hydration-mismatch bug** on the very first
  unauthenticated page load: `Hydration completed but contains
  mismatches.` The server-side redirect (`auth.global.ts` middleware,
  `navigateTo('/login?...')`) and the client hydration briefly disagree —
  the URL bar shows `/login` while the mounted component/title is
  momentarily `Dashboard · Arcanium`, before self-correcting. Documented
  in full in `UI_AUDIT.md`; **not fixed this pass** — this exact
  middleware file's own code comments describe a past production
  incident (CPU/memory exhaustion) from a previous change to this exact
  auth-check path, so a hasty fix here carries real regression risk and
  is deferred to a dedicated pass (see `UI_IMPROVEMENT_PLAN.md`).
- All 14 authenticated-route navigations (42 route×viewport combinations)
  produced **zero** console errors or warnings.

## Screenshots captured

42 baseline screenshots (`.artifacts/ui-baseline/`), 42 after-fix
screenshots (`.artifacts/ui-after/`) — both gitignored (regenerable
visual-development artifacts, not durable evidence; see `.gitignore`).

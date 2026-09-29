# UI toolchain report — Durin Web Console

`prompts/frontend/03_01_design_toolchain.md`, run 2026-09-29 against `durin-ui`.
The Arcanium-era reports that used to live here were deleted: they described
another application. Everything below is Durin evidence.

## Tooling installed

| Tool | Package / source | Version | Scope | Files |
| --- | --- | --- | --- | --- |
| Playwright | `@playwright/test` | 1.63.0 (Chromium) | ui devDependency | `ui/playwright.config.ts`, `ui/tests/*` |
| axe-core for Playwright | `@axe-core/playwright` | ^4.13.0 | ui devDependency | `ui/tests/a11y.spec.ts` |
| Typecheck | `vue-tsc`, `typescript` ~5.9, `@types/node` ^22 | — | ui devDependency | `ui/tsconfig.json` (Nuxt 4 project references) |
| Impeccable | project skill | as installed in `.claude/skills/impeccable` | repo | `.impeccable/` (direction, brief, surface contract, `design.json`) |
| Taste | skill `design-taste-frontend` | as installed in `.agents/skills/` (symlinked into `.claude/skills/`) | repo | none written |
| Awesome DESIGN.md | reference collection | — | not installed | **not consulted** this run (see DESIGN.md) |

TypeScript is pinned to ~5.9 because `vue-tsc` cannot load TypeScript 7
(`ERR_PACKAGE_PATH_NOT_EXPORTED ./lib/tsc`).

No hooks were installed. The Impeccable detector hook is available
(`/impeccable hooks on`) but was run manually (`impeccable detect`).

Playwright agent skills (03_01 §8) were not installed: the journeys are plain
Playwright specs any agent can run with `make test-frontend`.

## Agent support

| Agent | Impeccable | Taste | Playwright |
| --- | --- | --- | --- |
| Claude | Native (`.claude/skills/impeccable`) | Native (`.claude/skills/design-taste-frontend`) | CLI only (`make test-frontend`) |
| Codex | Partial: skill files exist under `.agents/skills/` and are not verified in Codex | Partial (same) | CLI only |
| IBM Bob | Unsupported (not verified) | Unsupported (not verified) | CLI only |

## Existing frontend discovered

A new build, not inherited. It is a Nuxt 4 SPA (`ssr: false`) served by its own
Nitro server, which is also the BFF (`prompts/frontend/01_02`):

- OIDC code + PKCE S256 with the confidential client `durin-backend`. The
  access, refresh and id tokens live in a server-side session (Nitro memory
  storage); the browser holds only the httpOnly `durin_sid` cookie.
- `/api/v1/*` is proxied to `durin-backend` with the user's bearer token. The
  proxy allows only `content-type`, `x-tenant` and `x-break-glass-request`,
  strips `x-durin-actor`, and requires CSRF (`x-durin-csrf: 1` or Origin).
- The OIDC client secret comes from Vault KV through the one-shot
  `ui-secrets-init` (AppRole `durin-ui`, read on that single path). `durin-ui`
  holds no Vault token.
- 16 routes, 12 shared components, 4 composables, Tailwind v4, Hanken Grotesk +
  JetBrains Mono, Lucide icons.

## Baseline

The first complete Durin build (see [BASELINE.md](BASELINE.md)). Before the
toolchain pass: all journeys green except J6.10; phone layout broken by
unlayered component CSS; sign-in broken by the Keycloak client secret; Nuxt
4.4.5 with a high-severity advisory chain.

## Design system

[config/DESIGN.md](config/DESIGN.md) (Impeccable DESIGN.md format, symlinked
at the repo root) plus the `.impeccable/design.json` sidecar. North star:
**Smart Privacy Glass**. Frost is the encryption state, "The Clearing" is the
signature interaction, and each hue has one meaning. It also records the Taste
dials. [config/PRODUCT.md](config/PRODUCT.md) (moved from the repo root; the
root path is a symlink) holds product context.

## Findings

See [UI_AUDIT.md](UI_AUDIT.md). Summary: Playwright found 1 functional defect
and 2 layout defects, Impeccable found contrast and text-size defects, axe
found contrast and focusable-region defects, npm audit found the Nuxt chain,
and Taste agreed on dials and disagreed on em-dashes.

## Changes applied

See [UI_IMPROVEMENT_PLAN.md](UI_IMPROVEMENT_PLAN.md). Each change was
re-validated with the full journey suite.

## Changes deliberately rejected

- **Taste em-dash ban.** The specs prescribe exact strings with em-dashes
  ("NORMAL ACCESS DENIED — break glass required", "BREAK GLASS ACTIVE —
  approved in Vault"), and the journeys assert them. Product copy wins (03_01
  §18).
- **Taste `min-h-[100dvh]` over `h-screen`.** That rule targets hero sections.
  `lg:h-screen` here is the sticky desktop rail, where the viewport height is
  correct.
- **Impeccable `repeating-stripes-gradient` advisory.** The mullions and frost
  grain are the pinned material of the direction; without a structured
  backdrop, blur does not read as glass.
- **Impeccable backdrop pixel-contrast on `/login`.** Verified false positive
  (computed ≥ 6:1, axe 0 violations).

## Validation

| Check | Result |
| --- | --- |
| Lint | No linter configured in `ui/` (not part of the Durin prompts) |
| Typecheck | `npx nuxt typecheck` exit 0 |
| Tests | `make test-frontend` 30 passed; `@narrative` 1 passed; `@failover` 1 passed |
| Build | `make ui-rebuild` exit 0 |
| Browser validation | Chromium, live stack, real Keycloak users |
| Responsive | 1440×900 + 390×844, no horizontal overflow |
| Accessibility | axe WCAG 2.1 A/AA: 0 violations (sign-in + 13 routes × 2 personas) |
| Backend regression | `make test-all` all suites pass afterwards |

# UI Toolchain Report — Arcanium

Executed against `arcanium/ui` (Nuxt 4 / Vue 3), the running, deployed
`arcanium-ui` container, per `prompts/process/00_02_frontend_design_toolchain.md`.

## Tooling installed

| Tool | Package | Version | Scope | Notes |
|---|---|---|---|---|
| Playwright CLI | `@playwright/cli` | 0.1.19 (bundles `playwright-core`/`playwright` 1.63.0-alpha) | `arcanium/ui` devDependency (project-local) | Chromium already cached locally; no new browser download needed |
| Impeccable | `impeccable` (npx, not added to `package.json`) | 4.1.0 | Repo root — skills installed into `.claude/`, `.agents/`, `.github/` | See "Hooks installed" below |
| Taste (`design-taste-frontend`) | via `skills` (vercel-labs/skills) from `Leonxlnx/taste-skill` | pinned by content hash in `skills-lock.json` | Repo root — `.agents/skills/design-taste-frontend/` (symlinked for Claude Code) | Static SKILL.md only, no executable |
| Awesome DESIGN.md | reference collection, not installed | n/a | Used only to inform `docs/frontend/config/DESIGN.md`'s structure | Never copied into the app; no dependency added |

**Awesome DESIGN.md review:** browsed the collection's own index (73
entries) and read the full `DESIGN.md` for the two closest analogues to
an operational dashboard product — **Sentry** ("dark dashboard,
data-dense, pink-purple accent") and, by index description, **Kraken**
("crypto trading platform, purple-accented dark UI, data-dense
dashboards"). Used only to sanity-check structural concepts (radius/
spacing scale shape, token-file structure) — Sentry's own scale (radius
4–18px + full-pill, spacing 2–96px) validated that Arcanium's simpler
two-tier radius scale (12/16 + pill) is a reasonable, deliberate choice,
not an under-built one. No color, typography, or brand element was
copied from either reference — Arcanium's own blue/navy identity was
left untouched.

### Files added

- `arcanium/ui/.claude/skills/playwright-cli/`,
  `arcanium/ui/.agents/skills/playwright-cli/` — Playwright's own
  project-local skill (installed from within `arcanium/ui`).
- `.claude/skills/impeccable/`, `.agents/skills/impeccable/`,
  `.github/skills/impeccable/` — Impeccable's skill content, installed at
  the **repository root** (Impeccable resolves the git root, not the CWD).
- `.agents/skills/design-taste-frontend/` (+ `.claude/skills/…` symlink) —
  Taste's skill content, also repository-root-scoped.
- `.claude/agents/impeccable-*.md`, `.github/agents/impeccable-*.agent.md`
  — Impeccable's bundled sub-agent definitions (asset-producer,
  documenter, finish-reviewer, manual-edit-applier).
- `skills-lock.json` (repo root) — the `skills` tool's own lockfile,
  pinning `design-taste-frontend`'s content hash for reproducible
  installs.
- `docs/frontend/config/{DESIGN.md,PRODUCT.md}`, `docs/frontend/{BASELINE.md,UI_AUDIT.md,UI_IMPROVEMENT_PLAN.md,UI_TOOLCHAIN_REPORT.md}`.
- `arcanium/ui/.playwright-cli/`, `arcanium/ui/.artifacts/` — Playwright's
  own session state and this pass's before/after screenshots
  (gitignored — regenerable, not durable evidence).

### Skills installed

Confirmed working (see "Agent support" below): `playwright-cli` (Claude +
generic-agent skill dirs), `impeccable` (Claude, Codex, GitHub Copilot),
`design-taste-frontend` (Claude via symlink; "universal" — directly
readable by Codex, Gemini CLI, GitHub Copilot, and 15+ other tools per the
`skills` installer's own output, with no separate copy needed).

### Hooks installed — reviewed, NOT silently trusted

Impeccable's installer registered a **PostToolUse (Edit/Write) +
Stop** hook, identically, in three places:

- `.claude/settings.local.json` (Claude Code)
- `.codex/hooks.json` (Codex)
- `.github/hooks/impeccable.json` (GitHub Copilot)

All three run the same command: the locally-bundled `impeccable` binary's
own `hook` subcommand (5s timeout on Edit/Write, 30s on Stop) — Impeccable's
own built-in "immediate feedback, then a deeper pass at the end" design
check. No third-party network call, no arbitrary shell command — but it
**does** fire on every future Edit/Write in this repository (the matcher
is `Edit|Write`, not scoped to UI files, despite the hook's own
description saying "UI files"). This was inspected, not blindly approved.
**The user should decide whether to keep these hooks** — they are
low-risk (bounded timeout, local binary) but will add a small amount of
latency to every future edit in this repo, in any file, until removed.

## Agent support

| Agent | Playwright CLI | Impeccable | Taste (`design-taste-frontend`) |
|---|---|---|---|
| **Claude** | Native — project-local skill at `arcanium/ui/.claude/skills/playwright-cli/`, invoked successfully throughout this pass (42+ live browser interactions) | Native — project skill + hook installed and working | Native — symlinked project skill |
| **Codex** | CLI only — Playwright's installer only offers `claude`/`agents` skill targets; Codex reads the generic `.agents/skills/playwright-cli/` directory, not verified live in this session (no Codex session available to test) | Partial — skill + hook installed (`.codex/hooks.json`), not live-verified (no Codex session in this pass) | Partial — reads `.agents/skills/design-taste-frontend/` directly per the `skills` installer's own "universal" claim; not live-verified |
| **IBM Bob** | CLI only — Playwright's own installer has no Bob-specific target; the CLI itself (`npx playwright-cli ...`) is invocable regardless of agent, so Bob can use it via ordinary shell commands | CLI only — same reasoning; Impeccable's installer detected Bob (`GitHub Copilot .github`, `Claude Code ~/.claude`, `Codex CLI ~/.codex`) but did not name Bob among its detected harnesses at all | **Partial, with real evidence** — the `skills` installer's own target list explicitly includes "IBM Bob" alongside Claude Code/Codex/Gemini CLI/GitHub Copilot, and reported `skipped: IBM Bob, Continue (project directory not found)`. This proves Bob has a real, tool-recognized skill-directory convention — but no project-scoped Bob directory exists in this repo for it to attach to yet. Not claimed as `Native` without that directory existing; not dismissed as `Unsupported` given this direct evidence. |

No agent support claim above is asserted without the specific evidence
cited next to it, per the mission's explicit instruction not to claim
native support without evidence.

## Existing frontend discovered

Nuxt 4 / Vue 3 / TypeScript SPA with a mature, pre-existing, fully
tokenized dark design system (`app/assets/css/main.css`) already including
documented accessibility contrast targets, focus-visible handling, and
reduced-motion support. 19 routes, 4 shared components, a real OIDC auth
flow. Full detail in `BASELINE.md`.

## Baseline

```text
BASELINE
--------
Install:     PASS
Lint:        NOT PRESENT
Typecheck:   FAIL (11 pre-existing errors, unrelated to this pass)
Tests:       NOT PRESENT
Build:       PASS
```

Full detail in `BASELINE.md`.

## Design system

`docs/frontend/config/DESIGN.md` — built from direct inspection of the
existing, deployed application; not invented. Formalizes an already-mature
token system that existed in code but not as the project's own documented
visual contract.

## Findings

Nine findings across Playwright (live browser), Impeccable (static +
live-browser detector), and Taste (read as a second design perspective,
explicitly scoped against its own stated exclusion of dashboards/data
tables). Full detail, evidence, and reasoning in `UI_AUDIT.md`.

## Changes applied

1. `app/layouts/default.vue` — `.page-title` overflow/ellipsis handling;
   new `@media (max-width: 640px)` topbar rule (hide search trigger,
   cluster-status text, "pending" word); `pending-pill__label` span added
   to support that.
2. `app/assets/css/main.css` — `.arc-kml` (Cryptographic Lifecycle
   Coverage grid) responsive breakpoints at 900px (3 columns, flow-rail
   connector hidden) and 560px (1 column).
3. `app/pages/login.vue` — `.login-note` moved from `--arc-text-dim`
   10.5px to `--arc-text-muted` 12px (accessible-floor fix).
4. `scripts/ui-rebuild.sh` — excluded the new tool working directories
   (`.playwright-cli/`, `.artifacts/`, `.claude/`, `.agents/`) from the
   container build context.
5. `.gitignore` — added entries for the same working directories plus
   `test-results/`/`playwright-report/`.

All four UI-facing changes are CSS/markup-only; no route, API contract,
state-management, or authentication-logic change.

## Changes deliberately rejected

`side-tab` node-status borders, the Inter font choice, the dark-navy/cyan
palette, `width`-based transitions (documented as low-priority instead),
and Taste's marketing/landing-page-specific rule set (hero sizing,
eyebrow caps, bento grids, GSAP scroll-pin patterns, React/Tailwind-v4/
Motion stack assumptions) — none of these apply to or improve an
operational governance dashboard. Full reasoning in `UI_AUDIT.md`.

The hydration-mismatch bug (Finding 4) was intentionally **not** fixed —
real, reproducible, and evidenced, but the affected file's own comments
document a past production incident from a previous change to this exact
code path. Deferred to a dedicated pass per `UI_IMPROVEMENT_PLAN.md`.

## Validation

```text
FINAL
-----
Install:     PASS   (unchanged)
Lint:        NOT PRESENT   (unchanged)
Typecheck:   FAIL (11 pre-existing errors — identical set, byte-for-byte,
             to BASELINE; zero new errors introduced)
Tests:       NOT PRESENT   (unchanged)
Build:       PASS   (unchanged, 2.72 MB / 691 kB gzip — same as baseline)
```

- **Browser validation:** 14 primary routes + `/login`, re-verified at
  Desktop (1440×900) / Laptop (1280×800) / Mobile (390×844) after every
  change, against a freshly rebuilt container (image ID verified to match
  the new build both times, per this project's established discipline).
- **Responsive validation:** the two confirmed mobile defects (topbar
  overlap, unresponsive lifecycle grid) are fixed and re-screenshotted;
  desktop/laptop screenshots are pixel-identical to baseline (the new
  breakpoints sit below both viewport widths, so no regression risk
  there by construction — confirmed visually, not just assumed).
- **Console health:** zero console errors/warnings across all 42
  authenticated route×viewport combinations both before and after: the
  fixes did not introduce any regression, and the pre-existing errors
  (login-page 401s, the hydration mismatch on first unauthenticated
  load) are unchanged in kind and confined to exactly the same two
  circumstances documented in `BASELINE.md`/`UI_AUDIT.md`.
- **Accessibility observations:** one real fix applied (login-note
  contrast/size); existing focus-visible/skip-link/reduced-motion support
  confirmed intact (unrelated CSS, not touched).

## Outstanding work

> `prompts/process/00_03_frontend_quality_gate.md`'s own run (`FRONTEND_QUALITY_GATE.md`)
> surfaced two further items after this report was first written: a real
> logout defect (found and fixed during that pass) and a systemic
> `--arc-text-dim` contrast gap (Required, not yet fixed — see
> `UI_IMPROVEMENT_PLAN.md` Wave 3). Listed here for completeness; not
> retroactively rewritten into this section since neither was known at
> the time this report was produced.

**Required (as of this report):**
- None blocking. All changes made are complete and validated.

**Recommended:**
- Fix the hydration-mismatch bug (`UI_AUDIT.md` Finding 4) in its own
  dedicated pass, given the affected file's history.
- Convert the two `width`-based transitions to `transform`-based
  equivalents next time either component is touched.
- Fix the 11 pre-existing TypeScript errors (out of scope for this
  design-toolchain pass; none are UI/visual defects, all are type-level
  looseness in existing logic).

**Optional:**
- Establish an actual `lint`/`test` script for `arcanium/ui` (none exists
  today) if the project wants automated enforcement of the patterns this
  pass documented by hand.
- Decide whether to keep or remove the Impeccable Edit/Write+Stop hooks
  (see "Hooks installed" above) — genuinely optional, low-risk either way.

# QUALITY.md — Arcanium frontend quality-gate policy

Durable, cross-run policy for `prompts/process/00_03_frontend_quality_gate.md`. Read this
file before Section 3 of every future run; update it only when the
project's actual requirements change, never to make a failing run pass.
Written against `docs/frontend/config/DESIGN.md` as captured on
2026-09-12 (same pass that created this file).

## Required gates (block release)

```text
GATE 1   Engineering integrity      — required (lint/typecheck/test, whichever exist)
GATE 2   Application build          — required
GATE 3   Browser runtime            — required
GATE 4   Functional workflows       — required
GATE 5   Responsive behaviour       — required
GATE 6   Design-system consistency  — required
GATE 7   Accessibility              — required
GATE 8   Visual regression         — required
GATE 9   Browser-console health     — required
GATE 10  Dependency sanity          — required
```

## Optional gates (not required for this project)

```text
GATE 11  Performance                — optional; no numeric budget defined yet
                                       (no prior perf baseline exists to
                                       compare against — see Outstanding
                                       work in UI_TOOLCHAIN_REPORT.md)
GATE 12  Cross-browser validation   — optional; product targets modern
                                       Chromium-based browsers for its
                                       enterprise-console use case, no
                                       stated Firefox/WebKit requirement
GATE 13  Production comparison      — optional; local candidate IS the
                                       same image running in production
                                       for this project (no separate
                                       staging/production split), so this
                                       gate is not meaningful here
```

## Viewport list (Gate 5 / Gate 8)

```text
Desktop   1440 x 900
Laptop    1280 x 800
Mobile    390  x 844
```

Matches `DESIGN.md`'s "Responsive behaviour" breakpoints (1180 / 900 / 640
/ 560px). Add a breakpoint-specific viewport here if a future DESIGN.md
revision adds one.

## Browser matrix

```text
Chromium (via @playwright/cli) — the only browser exercised.
```

No cross-browser requirement exists for this product (see Gate 12 above).

## Route list (Gate 3 / Gate 4 / Gate 5 / Gate 8 / Gate 9)

The 19 routes in `docs/frontend/BASELINE.md`'s "Project structure"
section. The 14 primary/list routes plus `/login` are the routes actually
exercised on every quality-gate run (dynamic `[id]` detail routes are
spot-checked, not exhaustively swept, since their layout is shared with
their parent list page).

## Engineering integrity baseline (Gate 1)

```text
Lint:      NOT PRESENT — no lint script/config exists for arcanium/ui.
           This gate reports NOT PRESENT, not FAIL, until one exists.
Typecheck: 11 pre-existing errors as of 2026-09-12 (see BASELINE.md for
           the exact list). A quality-gate run FAILS Gate 1 only on a
           NEW typecheck error beyond this known set, not on the
           pre-existing 11.
Tests:     NOT PRESENT — no test files/config exist for arcanium/ui.
           This gate reports NOT PRESENT, not FAIL, until tests exist.
```

## Accessibility policy (Gate 7)

Enforce `DESIGN.md`'s documented contrast table exactly:
`--arc-text-primary`/`--arc-text-secondary`/`--arc-text-muted` are safe for
body text at any size ≥12px; `--arc-text-dim` is large/bold-only — flag
any use of `--arc-text-dim` on body-sized (<14px), non-bold text as a
Gate 7 failure.

## Dependency sanity policy (Gate 10)

Known, approved dev tooling as of this pass: `@playwright/cli`,
`@playwright/test`, plus the design-toolchain skill installs
(`impeccable`, `design-taste-frontend` — not npm dependencies, installed
as agent skills under `.claude/`/`.agents/`/`.github/`/`.codex/`, not
`package.json`). A quality-gate run should flag any *new* runtime
dependency in `arcanium/ui/package.json`'s `dependencies` (not
`devDependencies`) as requiring justification, per `DESIGN.md`'s own
"avoid unnecessary runtime dependencies" principle.

## Revision history

- 2026-09-12 — created (first run), alongside
  `docs/frontend/config/DESIGN.md`.

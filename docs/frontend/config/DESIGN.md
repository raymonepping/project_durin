# DESIGN.md — Arcanium

The project's visual contract. Derived from the existing, deployed
application (`arcanium/ui/app/assets/css/main.css`, `app/layouts/default.vue`,
and every page under `app/pages/`) — not an invented aesthetic. Where this
document prescribes a value, that value is already in production use unless
marked "(gap)".

See `PRODUCT.md` in this same folder for who the product is for and why.

## Product character

A **command-center for cryptographic governance** — serious, dense,
evidence-driven, dark by default. It should feel like an operations console
for people whose job is proving controls actually work, not a marketing
surface. Confidence comes from real numbers and real state transitions on
screen, not from decoration.

## Audience

Platform/security engineers operating Vault Enterprise day-to-day, plus
auditors and evaluators reviewing governance evidence. See `PRODUCT.md`.

## Design principles

- Clarity before decoration.
- Information hierarchy before visual effects.
- Predictable interaction — the same card/list/dialog pattern behaves the
  same way everywhere in the app.
- Accessible contrast is non-negotiable for meaning-bearing text (see
  Color below — this is already a documented, enforced rule in the
  codebase, not new policy).
- Restrained motion — reduced-motion is honored globally
  (`prefers-reduced-motion` zeroes all animation/transition durations,
  `app/assets/css/main.css`).
- Responsive by default, but optimized for desktop/laptop operational use
  first; phone width is a "must remain usable," not the primary target.

## Typography

- **Sans (UI/body):** `"Inter", ui-sans-serif, system-ui, -apple-system, sans-serif`
  at a 14px base, line-height 1.6 (`html, body` in `main.css`).
- **Mono:** used deliberately for identifiers/technical values (node
  names, key names, accessors) — e.g. `.arc-node-card__name { font-family:
  monospace }`. Never used for prose.
- **Headings/labels:** page titles ~15px/600 weight (`.page-title`); card
  titles and section labels typically 11–13px, often with
  `letter-spacing` for small-caps-style eyebrows (`.card-title`,
  `.env-badge`) — used sparingly (dashboard section headers, status
  badges), not stacked on every element.
- **Body floor:** 12px is the accessible floor for any real body/paragraph
  text. 10.5px was found in production use in one place (login page,
  see `UI_AUDIT.md`) and corrected — do not reintroduce sub-12px body text.

## Color

Semantic tokens, not scattered hex values — defined once in
`app/assets/css/main.css`'s `:root` block:

```text
background       --arc-bg-canvas       #001233
surface          --arc-bg-surface      rgba(0,40,85,0.55)
surface-elevated --arc-bg-elevated     #023e7d
card             --arc-bg-card         rgba(10,26,54,0.72)
glass panel      --arc-glass           rgba(11,27,54,0.62)

text-primary     --arc-text-primary    #f0f4f8   ~16:1 on canvas
text-secondary   --arc-text-secondary  #d4dae1   ~11:1 on canvas
text-muted       --arc-text-muted      #9aa4b3   ~6.4:1 on canvas — AA body floor
text-dim         --arc-text-dim        #7c8698   ~4.3:1 on canvas — AA LARGE/BOLD ONLY, not small body text

border           --arc-border-subtle / --arc-border-strong / --arc-glass-border
accent           --arc-action-primary #0077b6 / --arc-action-bright #00b4d8
focus            --arc-focus          #90e0ef  (>3:1 against every panel it lands on — enforced, see main.css comment)

success/healthy  --arc-healthy        #22c55e
warning/pending  --arc-governance / --arc-pending  #ffaa00 / #ffb700
error/critical   --arc-critical / --arc-denied      #dc2f02 / #d00000
```

**The contrast rule is already written into the codebase and must be
preserved, not just aspired to** (`main.css`, above the token block):
*"Never define a meaning-bearing colour below AA for its text size."*
`--arc-text-dim` is rated for **large or bold text only** — using it for
small (<14px) body copy is a violation of this project's own rule (this is
exactly the bug found and fixed in `UI_AUDIT.md`'s login-page finding).

The dark-navy + cyan/blue palette with amber/red/green status accents is
Arcanium's own established, consistent brand identity across every page —
confirmed across all 14 primary routes. It happens to resemble a
generically-flagged "AI dark-tech palette" per some generic linting
heuristics; that similarity is coincidental to a genuinely deliberate,
long-standing, consistently-applied product identity and is not evidence
of templated/generic output. Do not replace it on that basis alone (see
`UI_AUDIT.md` for the explicit tool-disagreement record).

## Spacing

No single numeric scale is centrally declared; observed practice is
predominantly **multiples of 4px** (4/6/8/10/12/14/16/20/24), with 16–24px
as the standard card padding and 12–16px as the standard grid/flex gap.
Preserve this rhythm; do not introduce arbitrary spacing values.

## Radius

`--arc-radius: 12px` (standard cards, buttons, inputs), `--arc-radius-lg:
16px` (larger surfaces — dialogs, the login card). Pills (badges, chips,
persona/status indicators) use `border-radius: 100px`. This is a two-tier
scale (12/16 + pill) — do not introduce a third arbitrary radius value.

## Shadows

`--arc-shadow-md` (elevated cards) and `--arc-shadow-lg` (dialogs,
dropdowns) — both neutral, dark, offset-down shadows (`rgba(0,8,24,…)`),
never a colored/glow shadow used for elevation. (A small number of
deliberate colored **glow** effects exist as status/liveness accents —
e.g. the pulsing cluster-health dot — distinct from elevation shadows and
used sparingly; do not expand this to general-purpose card elevation.)

## Components

- **Buttons:** `.primary-button` (solid accent-gradient fill, used for the
  one primary action per view — e.g. login's "Sign in"); pill-shaped
  status/filter chips; icon+label topbar actions.
- **Inputs:** label-above pattern, `.filter-bar`/`.form-field` inputs with
  visible `:focus-visible` rings (`--arc-focus`, enforced even where the
  mouse-hover outline is intentionally suppressed — see `main.css`
  comment referencing this exact accessibility fix).
- **Cards:** `.dash-card` / `.arc-node-card` / key-inventory cards — one
  consistent card shell (surface color + border + radius + padding) reused
  across dashboard, keys, cluster, teams.
- **Navigation:** fixed left sidebar (collapsible) + sticky topbar
  (search trigger, cluster-health pill, pending-approvals pill, persona
  menu). One navigation pattern, not a per-page bespoke nav.
- **Tables/lists:** card-per-row lists (keys, suppliers) rather than dense
  HTML tables — appropriate for this content's field count and mobile
  behaviour.
- **Dialogs:** `ManagementDialog.vue` — a single shared dialog component,
  reused rather than one-off modals per action.
- **Alerts/notices:** `.inline-notice` (error/info variants).
- **Badges:** pill badges for tier/status (`PREMIUM`, `STANDARD`,
  `DEMONSTRATED`, environment tags).

Only components that exist or are genuinely needed are documented here —
this list is not aspirational.

## Responsive behaviour

- **Desktop (1440×900) / Laptop (1280×800):** full sidebar + topbar, all
  grids at their full column count.
- **≤1180px:** topbar sheds secondary text labels (env badge, Vault-UI
  link label, persona label) to make room, icons remain.
- **≤900px:** sidebar collapses (icon rail or hidden, per
  `default.vue`/`main.css`), multi-column grids (`.arc-grid-2/3`,
  `.arc-kpi-strip`, the cryptographic-lifecycle rail) drop to fewer
  columns.
- **≤640px (mobile):** topbar hides the search trigger entirely and drops
  secondary status text (cluster label, "pending" word) to fit the
  viewport without clipping or overlap — added this pass, see
  `UI_AUDIT.md`.
- **≤560px:** the remaining multi-column grids fully stack to one column.

Every breakpoint must leave the topbar's page title, cluster/pending
status, and primary navigation legible and un-clipped — this was a real,
confirmed defect below 640px before this pass (see `UI_AUDIT.md`) and is
now the enforced minimum bar for any future topbar change.

## Motion

- Global `prefers-reduced-motion: reduce` support (zeroes all
  animation/transition durations) — already implemented, must never
  regress.
- Motion in production use is limited to: sidebar collapse width
  transition, a live-pulse dot on healthy cluster status, hover-state
  color/border transitions, and dropdown/menu open transitions. No
  scroll-hijacking, no decorative looping animation, no motion without a
  state it is communicating.
- Prohibited: adding an animation library (Motion/GSAP/etc.) for effects
  achievable in CSS; motion that fires on page load purely for spectacle;
  motion that cannot be disabled by `prefers-reduced-motion`.

## Accessibility

- Keyboard navigation and a `.skip-link` ("Skip to content") are already
  implemented — preserve.
- `*:focus-visible` shows a visible ring app-wide; several inputs
  deliberately suppress the *mouse*-hover outline but must keep the
  keyboard-visible one (`main.css`, documented inline).
- Semantic markup: real `<nav>`, `<main id="main-content">`, heading
  levels — preserve existing structure when editing a page.
- Contrast: enforce the AA table under Color above. `--arc-text-dim` is
  large/bold-only; never pair it with body-sized (<14px) text.
- Touch targets: nav items, pills, and cards already meet a reasonable
  tap-target size on the mobile screenshots reviewed this pass; keep new
  interactive elements at a comparable size (~34px+ effective height).
- ARIA only where semantic HTML is insufficient (e.g. `role="status"` on
  the live cluster-health indicator).

## Anti-patterns

Explicitly avoided, and to be reverted on sight if introduced:

- Unnecessary gradients beyond the two already-established uses (subtle
  radial glows on hero/login surfaces, the accent button gradient) —
  do not add more.
- Cards nested within cards without a real hierarchy reason.
- Decorative icon tiles with no informational purpose.
- Excessive or gratuitous animation (see Motion above).
- Low-contrast text for anything meaning-bearing (see Color above).
- Inconsistent spacing — stick to the 4px-multiple rhythm.
- Arbitrary new component variants when an existing card/badge/button
  pattern already covers the case.
- Gratuitous glassmorphism beyond the existing, restrained
  `backdrop-filter` use on the topbar and login/dialog surfaces.
- A fixed multi-column grid with no responsive fallback (the exact defect
  found and fixed this pass — see `UI_AUDIT.md`).
- Introducing a marketing-landing-page design vocabulary (hero sections
  with word-count limits, bento grids, scroll-hijacking, eyebrow labels
  on every section) — this is an operational dashboard, not a landing
  page; see `UI_AUDIT.md`'s note on `design-taste-frontend`'s own stated
  scope exclusion of dashboards.

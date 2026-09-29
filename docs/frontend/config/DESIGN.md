---
name: Durin Web Console
description: Smart privacy glass for Vault-protected data — a value clears only where Vault authorised the signed-in person.
colors:
  ground: "#e9eef3"
  ground-deep: "#dde4ec"
  mullion: "#aeb9c6"
  mullion-dark: "#7d8a99"
  ink: "#0f1a2a"
  ink-2: "#3e4c5f"
  ink-3: "#526073"
  clear: "#0f766e"
  clear-soft: "#ccfbf1"
  cipher: "#6d28d9"
  cipher-soft: "#ede9fe"
  authority: "#0369a1"
  authority-soft: "#e0f2fe"
  glass: "#b45309"
  glass-soft: "#fef3c7"
  denied: "#c81e1e"
  denied-soft: "#fee2e2"
  tenant-acme: "#2e6fd0"
  tenant-globex: "#178a66"
  tenant-initech: "#b83a6c"
typography:
  hero:
    fontFamily: "Hanken Grotesk Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "2.35rem"
    fontWeight: 800
    lineHeight: 1.05
    letterSpacing: "-0.035em"
  page:
    fontFamily: "Hanken Grotesk Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.75rem"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.022em"
  section:
    fontFamily: "Hanken Grotesk Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.08rem"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "Hanken Grotesk Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Hanken Grotesk Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.8rem"
    fontWeight: 600
    lineHeight: 1.3
  meta:
    fontFamily: "Hanken Grotesk Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.82rem"
    fontWeight: 400
    lineHeight: 1.4
  cipher:
    fontFamily: "JetBrains Mono Variable, ui-monospace, SF Mono, monospace"
    fontSize: "0.82rem"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "-0.01em"
rounded:
  control: "9px"
  frost: "10px"
  pane: "14px"
  pill: "999px"
spacing:
  gutter-phone: "16px"
  gutter-desktop: "32px"
  pane-pad: "20px"
  pane-pad-lg: "24px"
  stack: "20px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "#ffffff"
    rounded: "{rounded.control}"
    height: "2.4rem"
    padding: "0 16px"
  button-primary-hover:
    backgroundColor: "#1c2b41"
  button-glass:
    backgroundColor: "rgb(255 255 255 / 0.66)"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    height: "2.4rem"
    padding: "0 16px"
  button-amber:
    backgroundColor: "{colors.glass}"
    textColor: "#ffffff"
    rounded: "{rounded.control}"
    height: "2.4rem"
  button-danger:
    backgroundColor: "{colors.denied}"
    textColor: "#ffffff"
    rounded: "{rounded.control}"
    height: "2.4rem"
  field:
    backgroundColor: "rgb(255 255 255 / 0.72)"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    height: "2.5rem"
    padding: "0 12px"
  pane:
    backgroundColor: "rgb(255 255 255 / 0.58)"
    rounded: "{rounded.pane}"
  pane-strong:
    backgroundColor: "rgb(255 255 255 / 0.74)"
    rounded: "{rounded.pane}"
  ciphertext-well:
    backgroundColor: "{colors.cipher-soft}"
    textColor: "{colors.cipher}"
    typography: "{typography.cipher}"
    rounded: "{rounded.control}"
---

# Durin Web Console — design system

Source of truth: [ui/app/assets/css/main.css](../../../ui/app/assets/css/main.css)
(tokens in `@theme`, component classes in `@layer components`). Direction
contract: [.impeccable/surfaces/ui-app-app-vue.md](../../../.impeccable/surfaces/ui-app-app-vue.md).
Product context: [PRODUCT.md](PRODUCT.md). Derived from
`prompts/frontend/01_00_durin_design_spec.md`; where the two differ, this file
records what shipped and why.

## Overview

**North star: Smart Privacy Glass.** Durin answers one question at a glance:
*who can turn this ciphertext back into plaintext?* Every protected value is a
pane of switchable (PDLC) glass. PostgreSQL's `vault:vN:` ciphertext sits
behind the frost; the pane clears only where Vault authorised the signed-in
person, for one tenant, for five minutes. The frost is not decoration. It is
the encryption state.

The world is daylight office glazing: a pale mineral ground with thin
brushed-aluminium mullions every 180px, frosted white panes with a hairline
highlight and a soft offset shadow, graphite ink. Colour is reserved for
meaning. Teal means cleared by Vault, violet means ciphertext, azure means
who Vault authorised, amber means break glass, red means refused. Each
tenant has one tint, used everywhere that tenant appears.

Mode: **Operate**. A presenter drives it up close on a laptop while an
audience reads over their shoulder. Scanability and truthful state beat
expression, and the personality lives in the glass and in precise detail
(time drawn to scale, versions struck through, Vault's verbatim answer next
to the human sentence).

**The signature interaction: "The Clearing".** On a Vault ALLOWED, the pane's
frost wipes away top to bottom in 520ms (`clip-path`, `--ease-out`) and its
frame LED turns teal. On DENIED the pane stays frosted, the LED turns red and
Vault's verdict is etched on the glass. One clearing per result, never
ambient. Reduced motion makes it instant.

## Colors

| Token | Hex | Role |
| --- | --- | --- |
| `ground` / `ground-deep` | #e9eef3 / #dde4ec | The building behind the glass. |
| `mullion` / `mullion-dark` | #aeb9c6 / #7d8a99 | Aluminium frame lines, rails, idle LEDs. Decorative, never text. |
| `ink` | #0f1a2a | Primary text, primary button. |
| `ink-2` | #3e4c5f | Secondary text, ledes. |
| `ink-3` | #526073 | Meta, captions, placeholders. 4.8:1 on `ground-deep`, the darkest ground it sits on (raised from #5d6b7e, which failed AA). |
| `clear` (+ soft) | #0f766e | Cleared by Vault: plaintext LED, current key version, success. Darkened from the brief's #0d9488 (3.7:1) to 5.5:1 with white text (axe). |
| `cipher` (+ soft) | #6d28d9 | Ciphertext only (`vault:vN:` in mono). Never used for anything else. |
| `authority` (+ soft) | #0369a1 | Who Vault authorised: authority tags, roles, focus ring. |
| `glass` (+ soft) | #b45309 | Break glass and emergency access only. |
| `denied` (+ soft) | #c81e1e | Vault refused, compromise banner, retired versions. Darkened from the brief's #dc2626 for AA on the soft fill. |
| `tenant-*` | #2e6fd0 / #178a66 / #b83a6c | ACME / Globex / Initech: pane top rule, pill square, audit pill. |

**Rule: one meaning per hue.** A colour on screen is a claim about Vault
state. Never tint a surface for decoration, and never reuse `clear`, `cipher`,
`glass` or `denied` for chrome.

## Typography

Hanken Grotesk Variable for everything human; JetBrains Mono Variable for
anything a machine produced (ciphertext, key names, accessors, request ids,
Vault paths, raw table cells). Root size is **15px**, so rem values are
multiples of 15. The **floor is 0.8rem (12px)** for any text; the detector
flagged 0.7–0.75rem labels as sub-12px, and they were all raised.

| Role | Size | Weight | Use |
| --- | --- | --- | --- |
| hero | 2.35rem | 800, -0.035em | Overview question only. |
| page (`.h-page`) | 1.75rem | 700, -0.022em, balanced | One per screen. |
| section (`.h-section`) | 1.08rem | 700 | Pane titles. |
| body / lede (`.lede`) | 1rem, lh 1.55, max 68ch | 400 | Explanations. |
| label (`.label`) | 0.8rem | 600 | Form labels, field labels. |
| meta (`.meta`) | 0.82rem | 400, `ink-3` | Captions, timestamps. |
| cipher (`.cipher`) | 0.82rem mono, violet, break-all | 400 | Ciphertext. The `vault:vN:` prefix is never truncated (`shortCipher`). |

Numbers that change (counts, TTLs, clocks) use `.tabular`.

## Layout

- **Frame:** a 17rem frosted aluminium rail (sticky, full height) plus a 3.5rem
  frame bar (sticky; tenant switcher, Vault LED pill, person and role, sign
  out). Main content is max 84rem, padded 16px on phones and 32px on desktop.
- **Below `lg` (1024px)** the rail becomes an off-canvas sheet behind a menu
  button, and the frame bar keeps the tenant switcher and sign-out.
- **The story rail:** the six story steps sit on one mullion line with a teal
  "now" light that slides to the current step (500ms). Completed steps get teal
  dots.
- **Grids:** the tenant glass wall is 3 columns at `lg`. The Database Inspector
  uses three equal `minmax(0,1fr)` panels with direction arrows between them at
  `xl`, stacked below. Detail screens use content plus a 24rem side pane at `xl`.
- **Overflow:** only tables and code scroll horizontally, each in its own
  `overflow-auto` container. Selects never size to their longest option
  (`w-full sm:w-[22rem]`), because that once pushed the phone Inspector to 496px.

## Elevation & Depth

Depth comes from glass, not from stacked shadows.

- `.pane`: white 58%, `backdrop-filter: blur(22px) saturate(150%)`, 1px white
  inset highlight, 1px `rgb(15 26 42 / 0.09)` outline, shadow
  `0 1px 1px rgb(15 26 42/.04), 0 12px 32px -14px rgb(15 26 42/.22)`.
- `.pane-strong`: white 74% (rails, bars, login card at 88%).
- `.frost-layer`: white 42% plus `blur(7px)` plus an etched grain of 1px repeating
  lines, so frost reads as glass and not as a grey box. It covers the
  ciphertext, and `data-state="clear"` wipes it out.
- Leader card on the Vault page: 2px teal ring plus a teal-tinted shadow. It is
  the only coloured elevation.

## Shapes

`control` 9px (buttons, fields, wells) · `frost` 10px (protected values) ·
`pane` 14px · `pill` 999px (status chips, LEDs). The frame bar and rail are
square (`!rounded-none`): they are the building, not objects in it. LEDs are
7px dots with a 2px white halo. Coloured top rules (4px) mark tenant panes and
break-glass cards.

## Components

- **FrostValue:** the protected value. States are `frosted` (ciphertext behind
  frost, "Frosted" badge, grey LED), `clear` (plaintext, open-lock, pulsing teal
  LED), and `denied` (frost tinted red, "Denied" badge, the human sentence plus
  the verbatim code). Key name and version are etched above; retired versions
  are struck through in red.
- **VaultVerdict:** ALLOWED/DENIED, a title, the human sentence, and Vault's
  verbatim status, path and errors in mono. Shows "expected X" when a scenario
  predicts the result.
- **AuthorityTag:** "Vault authorised **raymon** for **ACME** · auth/jwt ·
  tenant-acme" with an optional TTL bar. The point of the demo, so it is never
  hidden in a tooltip.
- **TtlBar:** time drawn to scale. The bar's length is the exact fraction of
  seconds left (5-minute tokens, 15-minute control groups).
- **KeyChip:** versions as chips. The current version is teal and bold,
  versions below `min_decryption_version` are struck red, and runs of more than
  three retired versions collapse to one `v1–vN` range chip.
- **Buttons:** `.btn-primary` (ink) for the one primary action per view,
  `.btn-glass` for everything else, `.btn-amber` only for break glass,
  `.btn-danger` only for simulating the compromise. A disabled button always
  shows its reason beside it or in `title` ("Requires durin-operator — Vault
  only issues data authority to operators").
- **ErrorNote:** API errors are values. It shows a human sentence
  (`ERROR_SENTENCE`) plus `status · code · vault status` in mono. There is no
  generic "something went wrong".
- **Break-glass card:** amber top rule, BREAK GLASS REQUEST, status pill, a
  requested-by / reason / resource / Vault (control group · 1 approval from
  durin-security-admins · expires) grid, an amber TTL bar and the wrapping
  accessor. There is never a "copy token" affordance, because no bearer token
  exists.

## Do's and Don'ts

- **Do** show Vault's real answer (status, path, accessor, audit id) next to
  every human sentence.
- **Do** keep component classes in `@layer components`. Unlayered, they beat
  Tailwind utilities (`fixed`, `sticky`, `hidden`), which broke the phone rail
  and sticky header until they were moved.
- **Do** keep `vault:vN:` visible whenever ciphertext is shortened.
- **Do** disable, never hide, an action the current person may not take, and
  say why.
- **Don't** simulate a verdict client-side, fall back to plaintext, or animate
  a clearing without an ALLOWED behind it.
- **Don't** use HashiCorp brand colours or marks; Durin has its own identity.
- **Don't** add KPI hero cards, gradient text, glass as a decorative panel
  effect, or ambient motion. Frost means encryption and nothing else.
- **Don't** put tokens, JWTs or Vault credentials in the browser. The BFF keeps
  them, and the UI shows only identity (name, roles, tenants).

## Taste configuration

`design-taste-frontend` (Taste) controls, set conservatively for an existing
presenter-driven operations console:

| Control | Value (1–10) | Why |
| --- | --- | --- |
| `DESIGN_VARIANCE` | 4 | One strong idea (privacy glass) applied consistently. Screens vary only where the story does (Inspector's three panels, Shield's step ladder). |
| `MOTION_INTENSITY` | 3 | One meaningful motion (The Clearing, 520ms) plus 180ms state transitions and the sliding "now" light. Nothing ambient. Reduced motion is instant. |
| `VISUAL_DENSITY` | 6 | The audience reads over a shoulder, but each screen must carry evidence (key versions, accessors, audit ids). Dense tables are allowed for raw rows and audit; story screens stay airy. |

Awesome DESIGN.md (reference collection, 03_01 §15) has **not** been consulted
for this version: the system above comes from the Durin brief (01_00), the
Impeccable direction contract and the rendered console. The blur needs a
structured backdrop to read as glass, which is why the mullions exist; that is
Durin's own rule, not a borrowed one.

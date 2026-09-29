# UI audit — Durin Web Console

Audit before modification (`prompts/frontend/03_01` §17), one entry per
finding, with the source tool. Status reflects the end of the run.

| # | Tool | Finding | Severity | Status |
| --- | --- | --- | --- | --- |
| 1 | Playwright (sign-in) | Keycloak client secret never set, so every login fails | High | Fixed |
| 2 | npm audit | Nuxt 4.4.5: XSS via NuxtLink/navigateTo, island RCE/DoS, payload cache disclosure | High | Fixed (4.5.2) |
| 3 | Playwright (`@screens`) | Unlayered `.pane`/`.btn` beat Tailwind utilities: the rail wasn't fixed on phones, the header wasn't sticky, the hamburger showed on desktop | High | Fixed |
| 4 | Playwright (`@screens`) | Inspector 496px wide on a 390px phone | Medium | Fixed |
| 5 | axe | White on teal `#0d9488` 3.7:1 (current key version chips) | Medium | Fixed (`#0f766e`, 5.5:1) |
| 6 | Impeccable | Muted ink `#5d6b7e` 4.1:1 on the deep ground | Medium | Fixed (`#526073`, 4.8:1) |
| 7 | Impeccable | Text at 0.7–0.78rem = 10.5–11.7px (root 15px) | Medium | Fixed (0.8rem floor) |
| 8 | axe | Scrollable table regions not keyboard-focusable | Medium | Fixed (`tabindex=0`, labelled region) |
| 9 | vue-tsc | Untyped OIDC runtime config lets `undefined` reach URLSearchParams | Medium | Fixed |
| 10 | Playwright (J6.10) | Deny/approve removes the card, and its confirmation, from Active | Low | Fixed |
| 11 | Visual review | Retired key versions listed one by one | Low | Fixed (range chip) |
| 12 | Visual review | Story-rail hints truncated after the 12px floor | Low | Fixed (shorter copy) |
| 13 | Impeccable | Backdrop pixel-contrast on `/login` | — | False positive (computed ≥ 6:1; axe 0) |
| 14 | Impeccable | `cramped-padding` on unbounded text | — | Not applicable |
| 15 | Impeccable | Repeating-gradient stripes | Advisory | Kept: pinned material |
| 16 | Taste | Em-dashes in UI copy | Advisory | Rejected: spec-prescribed strings |
| 17 | Taste | `h-screen` | Advisory | Rejected: sticky rail, not a hero |
| 18 | Taste | Dials | — | Recorded: variance 4, motion 3, density 6 |

Taste checks that passed without change: CTA contrast (all buttons ≥ 4.5:1),
no wrapped CTAs, form contrast (placeholder `ink-3` 4.8:1+), one icon library
(Lucide; only the Durin mark is hand-drawn and it is a logo), grid over flex
math, reduced motion honoured globally.

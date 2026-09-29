# UI improvement plan — applied

`prompts/frontend/03_01` §19–20. Each step was validated with the full journey
suite before the next; functional behaviour, API contracts and auth flows are
unchanged except where a step says so.

| Step | Change | Files | Validation |
| --- | --- | --- | --- |
| 1 | Keycloak client secret applied from Vault KV; the setup fails loudly if it can't be set | `compose/identity/keycloak/setup_keycloak.sh` | sign-in for 4 users; `make identity-verify` 14/0 |
| 2 | Keep acted-on break-glass cards in view | `ui/app/pages/break-glass.vue` | J6 9/9 |
| 3 | Component classes into `@layer components` | `ui/app/assets/css/main.css` | `@screens` phone + desktop; 27/27 |
| 4 | Inspector record select and panel columns can't widen the page | `pages/inspector.vue`, `components/PageHead.vue` | phone captures 390px |
| 5 | KeyChip collapses retired runs to one range chip | `components/KeyChip.vue` | Vault, Tenants, Overview visual |
| 6 | Contrast: `ink-3` → `#526073`, `clear` → `#0f766e`; 12px text floor | `main.css`, 18 `.vue` files | axe 0, Impeccable source 0 |
| 7 | Focusable, labelled scroll regions; LEDs `aria-hidden` | audit, compromise, protect, inspector, FrostValue, AppFrameBar, vault | axe 0 |
| 8 | Nuxt 4.4.5 → 4.5.2 | `ui/package.json` | `npm audit` 0; 30/30 |
| 9 | Type safety: typed OIDC config, Node types, `tsconfig.json` | `server/utils/oidc.ts`, `utils/format.ts`, `pages/shield.vue` | `nuxt typecheck` 0 |
| 10 | Shorter story-rail hints | `components/AppRail.vue` | visual |

Not applied: see "Changes deliberately rejected" in
[UI_TOOLCHAIN_REPORT.md](UI_TOOLCHAIN_REPORT.md).

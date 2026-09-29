# Baseline — Durin Web Console (first build)

Captured 2026-09-29, before the toolchain pass (`prompts/frontend/03_01` §9–10).

## Runtime

| Item | State |
| --- | --- |
| Container | `durin-ui` on 127.0.0.1:3000, healthy; `ui-secrets-init` completed |
| Framework | Nuxt 4.4.5 (SPA + Nitro BFF), Tailwind 4, Vue 3.5 |
| Backend | durin-backend via `http://durin-backend:3001` (durin-internal) |
| Identity | Keycloak realm `durin`, users raymon / barend / viewer / security-admin |

## First sign-in

Failed at the code-for-token exchange: `CODE_TO_TOKEN_ERROR
invalid_client_credentials` in Keycloak. The BFF, the identity volume and
Vault KV held the same secret (hash-compared), but Keycloak's client never
received it. Fixed in `compose/identity/keycloak/setup_keycloak.sh`.

## First journey run (after sign-in worked)

`make test-frontend`: **25 passed, 1 failed (J6.10), 1 not run (J6.11)**.
J6.10: after Deny, the request left the "Active" view along with its
confirmation (UX defect).

## First visual pass (`@screens`, 1440×900 and 390×844)

- Desktop: coherent. The Vault page listed every retired key version (v1…v24).
- Phone: the Inspector rendered 496px wide, and every page had a blank band
  of roughly 800px above the header (the off-canvas rail was still in flow).
- The hamburger button was visible on desktop.

## First engineering checks

- `npm audit`: 3 vulnerabilities (1 high: the Nuxt ≤ 4.4.5 chain).
- `nuxt typecheck`: could not run (no tsconfig, no vue-tsc). Once added, it
  found type errors in the BFF (untyped runtime config, missing Node types)
  and in two helpers.
- axe: color-contrast (white on teal 3.7:1) on the Overview, Tenants, Vault and
  Inspector screens; a non-focusable scroll region on the Inspector.
- Impeccable (live `/login`): muted text 4.1:1, 11.25px labels.

# Durin Web Console

The console (`ui/`, http://localhost:3000) is where the story is told. It is
built to answer one question at a glance: **who can turn this ciphertext back
into plaintext?**

## How it is built

- **Nuxt 4 SPA** (`ssr: false`) served by its own **Nitro server**, which is also
  the **backend-for-frontend (BFF)**.
- **Sign-in:** OIDC authorization code + PKCE (S256) with Keycloak realm `durin`,
  confidential client `durin-backend`. The code exchange and token refresh
  happen on the server.
- **Sessions:** the server keeps the access, refresh and id tokens. The
  browser holds one opaque httpOnly cookie, `durin_sid`. Playwright J0.3 checks
  that no JWT reaches `localStorage`, `sessionStorage` or `document.cookie`.
- **API:** the browser calls `/api/v1/*` on the same origin. The BFF forwards
  those calls to `durin-backend` with the person's bearer token, allowing only
  the `content-type`, `x-tenant` and `x-break-glass-request` headers, dropping
  `x-durin-actor`, and requiring CSRF on writes. Contract:
  [API_CONTRACTS.md § Web Console BFF](api/API_CONTRACTS.md#web-console-bff-browser-facing).
- **Secret:** the OIDC client secret comes from Vault KV through the one-shot
  `ui-secrets-init` (AppRole `durin-ui`, read on that single path). The console
  never holds a Vault token.
- **Container:** multi-stage `ui/Containerfile`, non-root, read-only filesystem,
  `cap_drop: ALL` (`compose/ui/compose.yaml`).

## Screens

| Screen | Route | What it proves |
| --- | --- | --- |
| Overview | `/` | the glass wall: every tenant's values frosted, key versions, who holds Vault tokens right now |
| Protect / Recover | `/protect`, `/recover` | plaintext → Vault → ciphertext; recovery only for an authorised person |
| Compromise / Shield | `/compromise`, `/shield` | a stolen copy is ciphertext; after Shield it is worthless to everyone |
| Isolation | `/isolation` | one tenant's Vault token is refused on another tenant's key |
| Break Glass | `/break-glass`, `/documents/:id` | request → approval in Vault → released once |
| Customers, Documents, Tenants | `/customers`, `/documents`, `/tenants` | the data, with protected fields frosted by default |
| Database Inspector | `/inspector` | the same record as application, database and Vault state; raw rows |
| Vault | `/vault` | leader, standbys, load balancer, backend's metadata-only authority, keys |
| Audit | `/audit` | every event, who acted, and whether Vault or the application decided |

The story order and what to say at each step are in [scenarios.md](scenarios.md).

## Design

**Smart Privacy Glass.** A protected value is a pane of switchable glass: the
ciphertext sits behind the frost, and the pane clears only when Vault
authorised the signed-in person. Each colour has one meaning: teal cleared,
violet ciphertext, azure authority, amber break glass, red refused. The
footer's **Glass key** names them.

- Design system: [frontend/config/DESIGN.md](frontend/config/DESIGN.md)
- Product context: [frontend/config/PRODUCT.md](frontend/config/PRODUCT.md)
- Screenshots (desktop, phone, viewer): [screenshots/](screenshots/README.md)

## Quality

| Check | Command |
| --- | --- |
| Journeys J0–J9 + accessibility | `make test-frontend` |
| Timed demo story, console errors | `cd ui && npx playwright test narrative --grep @narrative` |
| Typecheck | `cd ui && npx nuxt typecheck` |
| Dependencies | `cd ui && npm audit` |

Latest results and the release verdict:
[frontend/FRONTEND_QUALITY_GATE.md](frontend/FRONTEND_QUALITY_GATE.md). Policy:
[frontend/config/QUALITY.md](frontend/config/QUALITY.md). Toolchain, audit and
applied changes: [frontend/UI_TOOLCHAIN_REPORT.md](frontend/UI_TOOLCHAIN_REPORT.md).

## Running it

```bash
make ui-rebuild   # build + start (signs everyone out: sessions live in memory)
make ui-dev       # hot reload on the host
```

Troubleshooting: [operations.md § 11](operations.md#11-web-console-durin-ui).

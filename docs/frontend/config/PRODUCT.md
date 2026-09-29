# PRODUCT.md — Arcanium

> Populated from strong repository evidence (this UI's own routes, dashboard
> copy, API contracts, and the project's `prompts/` build history), not an
> interactive interview — per Impeccable's own `init` policy ("ask only
> about material gaps the repository... does not answer with strong
> evidence"). Every fact below is directly observable in the running
> application or its source; nothing here is invented.

## What Arcanium is

A HashiCorp Vault Enterprise **cryptographic control plane**: a governance
and lifecycle-management layer over Vault's own Transit, PKI, KMIP, and
Managed Keys engines. Arcanium does not replace Vault's cryptography — it
adds the workflow, evidence, and multi-tenant governance surface an
enterprise needs on top of it (onboarding, desired-state reconciliation,
four-eyes approval, maturity scoring, audit-evidence ingestion, and now
service-account/webhook machine integration).

## Primary users

Platform engineers and security/compliance operators inside an
organization running Vault Enterprise — the personas the app itself
ships as real, switchable demo identities: **CISO** (approve/read),
**Architect** (provision/rotate/reconcile), **Operator** (day-to-day
key lifecycle), **Auditor** (read-only), and **Supplier-admin** (tenant-
scoped to one supplier's own namespace). A secondary audience is
platform-evaluation reviewers: this is also a working reference/demo
product for HashiCorp's own crypto-governance story.

## Job the product does

- Register applications and their cryptographic keys under governance.
- Declare **desired state** (rotation policy, expiry date) per key and
  reconcile it against what Vault actually observes, on a schedule and
  on demand.
- Gate destructive/sensitive actions behind a real four-eyes **approval**
  workflow, backed by Vault Control Groups.
- Prove supplier **tenant isolation** (separate Vault namespaces) live,
  not just by configuration.
- Score and report **maturity** (governance adoption) as controls that
  genuinely assess real data — never a fabricated PASS.
- Expose the same surface to machines: service-account Bearer tokens,
  webhooks, and a Terraform provider skeleton, so integration isn't
  human-only.

## Platform

`web` — a server-rendered Nuxt 4 / Vue 3 SPA, no native wrapper, no
mobile-specific build. Responsive behaviour (Section "Responsive
behaviour" in `DESIGN.md`) matters because operators do check dashboards
from a phone, but the product is designed and used primarily on desktop
class screens (1280px+); phone-width support is "usable," not the primary
design target.

## Durable constraints

- **Never fabricate evidence or governance state.** Every dashboard number,
  every control-assessment result, comes from a real observed/queried
  value or is explicitly `UNKNOWN` — this is a hard, repeatedly-enforced
  rule throughout the codebase (see `arcanium/api/src/maturity/controls.js`
  and its `assess*()` functions).
- **Vault Enterprise is the source of truth for isolation and crypto
  state.** The UI/API record decisions and desired state; they do not
  become an alternate authority Vault must trust blindly.
- **Destructive key operations are always four-eyes-gated** via a real
  approval workflow — no UI shortcut bypasses this.
- Authentication is real OIDC (Keycloak, LDAP-backed groups) when
  `ARCANIUM_AUTH_ENABLED=true`; a demo-persona switch exists only for
  environments where auth is deliberately disabled, and must never be
  confusable with (or able to grant) a real scoped/estate-wide identity.

## Stack

Delegated to the existing repository — not a choice made for this pass.
Nuxt 4 / Vue 3 / TypeScript / Tailwind v4 (utility layer only — the actual
design system is a hand-authored token layer in `app/assets/css/main.css`,
Tailwind is not the primary styling mechanism), `reka-ui` for accessible
primitives, npm as the package manager. See `DESIGN.md` for the full
token/component inventory.

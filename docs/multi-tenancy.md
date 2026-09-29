# Durin Multi-Tenancy Model

Durin supports three demo tenants — ACME, Globex, and Initech — with
cryptographic isolation enforced at the Vault layer, not just by
application-level filtering.

---

## The thesis

> The database can store the data without owning the authority to decrypt it.

The same principle extends across tenants: **ACME cannot decrypt GLOBEX's
data even if ACME's application session is fully compromised**, because
the enforcement lives in Vault's policy engine — not in the application.

---

## Transit key naming convention

Every tenant has three Transit keys, all provisioned by Terraform:

```text
durin-<tenant>-customer-data   AES-256-GCM96, non-exportable   IBAN, tax ID, payment info
durin-<tenant>-documents       AES-256-GCM96, non-exportable   PUBLIC / INTERNAL / CONFIDENTIAL payloads
durin-<tenant>-restricted      AES-256-GCM96, non-exportable   RESTRICTED payloads (break glass to recover)
```

The `durin-` prefix scopes every policy in this project to Durin's keys
only. The `<tenant>-` segment is the cryptographic boundary
between tenants.

---

## Vault policy enforcement

Each tenant has a policy, rendered from
[`tenant-policy.hcl.tftpl`](../terraform/vault-transit/templates/tenant-policy.hcl.tftpl):

```hcl
# durin-transit-acme (excerpt)
path "transit/encrypt/durin-acme-customer-data" { capabilities = ["update"] }
path "transit/decrypt/durin-acme-customer-data" { capabilities = ["update"] }
path "transit/rewrap/durin-acme-customer-data"  { capabilities = ["update"] }
# … same for durin-acme-documents …
path "transit/encrypt/durin-acme-restricted"    { capabilities = ["update"] }   # protect: yes
path "transit/rewrap/durin-acme-restricted"     { capabilities = ["update"] }   # recover: NO
```

A token bearing `durin-transit-acme` is **structurally unable** to reach
any `durin-globex-*` or `durin-initech-*` path. Vault's ACL engine rejects
the request before it reaches the Transit engine.

## How a request gets tenant authority

The backend's own Vault token has **no** Transit capabilities. For every data
operation the Data Trust Gateway presents the *caller's* Keycloak access
token to Vault (`auth/jwt/login`, role `tenant-<t>`). Vault verifies the
token itself and checks the bound claims:
`durin_tenants ∈ {<t>, *}` and `realm_access.roles ∋ durin-operator`.

```text
raymon (operator, *) x-tenant: acme ──► auth/jwt/login role=tenant-acme jwt=<raymon's token>
                                           └─► 5-minute token: [durin-transit-acme, durin-keys-acme], username=raymon
                                        ──► transit/decrypt/durin-acme-customer-data   → 200
                                        ──► transit/encrypt/durin-globex-…             → 403
barend (operator, acme) x-tenant: globex ► auth/jwt/login role=tenant-globex           → refused by Vault
```

`POST /api/v1/scenarios/isolation-probe` demonstrates the Transit boundary live.

---

## Isolation model

```
ACME tenant token (auth/jwt role tenant-acme → durin-transit-acme)
    │
    ├── ALLOWED: encrypt / decrypt / rewrap  durin-acme-customer-data, durin-acme-documents
    ├── ALLOWED: encrypt / rewrap            durin-acme-restricted
    ├── DENIED:  decrypt                     durin-acme-restricted   (break glass only)
    │
    ├── DENIED:  transit/+/durin-globex-*
    └── DENIED:  transit/+/durin-initech-*
```

### Cryptographic boundary test matrix

| Token policy | Key path | Expected | Vault result |
|---|---|---|---|
| `durin-transit-acme` | `transit/encrypt/durin-acme-customer-data` | ALLOWED | 200 |
| `durin-transit-acme` | `transit/encrypt/durin-globex-customer-data` | DENIED | 403 |
| `durin-transit-acme` | `transit/decrypt/durin-initech-documents` | DENIED | 403 |
| `durin-transit-globex` | `transit/encrypt/durin-globex-customer-data` | ALLOWED | 200 |
| `durin-transit-globex` | `transit/encrypt/durin-acme-customer-data` | DENIED | 403 |
| `durin-transit-initech` | `transit/encrypt/durin-initech-customer-data` | ALLOWED | 200 |
| `durin-transit-initech` | `transit/rewrap/durin-globex-documents` | DENIED | 403 |

Run the full matrix: `./scripts/test-isolation.sh --vault`

---

## Application boundary (defense-in-depth)

All backend routes resolve the tenant once (`backend/src/middleware/tenant.js`),
check it against the session's `durin_tenants` claim when auth is enabled,
and filter every query by `tenant_id` before the gateway call. This is defense-in-depth — it catches application
bugs before they reach Vault. The Vault policy denial is the security
guarantee.

The API returns `404` (not `403`) for cross-tenant resource accesses to
prevent resource enumeration: an attacker cannot tell whether ACME customer
ID `abc-123` exists in GLOBEX's data or simply doesn't exist at all.

Run the API-layer matrix: `./scripts/test-isolation.sh --api`

---

## What an attacker with an ACME session can access

| Resource | Access |
|---|---|
| ACME customers (list, read) | ✅ Allowed |
| ACME documents (metadata) | ✅ Allowed |
| ACME document content (operator) | ✅ Allowed |
| ACME RESTRICTED document content | ❌ 403 Vault policy denial (break glass required) |
| ACME protected field decryption (operator) | ✅ Allowed |
| GLOBEX customers | ❌ 404 (application layer) |
| GLOBEX protected field decryption | ❌ 403 Vault policy denial |
| Any Vault Transit key outside `durin-acme-*` | ❌ 403 Vault policy denial |

---

## What an attacker with an ACME session **cannot** do

- **Decrypt GLOBEX ciphertext** — even if they obtained it from PostgreSQL,
  they cannot call `transit/decrypt/durin-globex-*` with an ACME-scoped token.
  Vault denies the request. The ciphertext is useless without the key authority.

- **Export any Transit key** — all keys have `exportable = false`. Even a root
  token cannot export them once set.

- **Access Vault admin paths**: the `durin-transit-acme` policy grants no
  `sys/*`, `auth/*` or `database/*` capabilities, and neither does the
  backend's broker policy.

---

## Namespace isolation (Vault Enterprise)

Vault namespaces (`acme/`, `globex/`, `initech/`) are provisioned by
Terraform in `terraform/vault-platform/namespaces.tf`, but they are **not yet
load-bearing**. Transit, the JWT roles and the policies all live in the
root namespace, and tenant isolation comes from per-tenant tokens and policy
paths.

Moving each tenant's Transit mount into its namespace would add one more
boundary: the broker would need a separate identity per namespace, so a
compromised backend couldn't even address another tenant's keys. See
[security-model.md](security-model.md#known-residual-authority).

---

## Adding a new tenant

1. Add the slug to `local.tenants` in `terraform/vault-transit/policies.tf`
   and `terraform/vault-platform/policies.tf`. That creates the three keys
   (add `customer-data` and `documents` resources to `keys.tf`; `restricted`
   is `for_each`), the `durin-transit-<t>`, `durin-keys-<t>` and
   `durin-breakglass-request-<t>` policies, and the `tenant-<t>` and
   `breakglass-requester-<t>` JWT roles.
2. Optionally add a namespace in `terraform/vault-platform/namespaces.tf`.
3. Add the tenant and its seed data to `backend/src/seed-data.js` and the
   tenant insert in `routes/scenarios.js`.
4. Run `make tf-transit && make tf-apply && make reset`.

No gateway code changes: keys and JWT roles are resolved from the tenant
slug at runtime.

---

## Automated tests

```bash
# Full isolation matrix (Vault + API + namespace)
./scripts/test-isolation.sh

# Vault-layer only (requires VAULT_TOKEN)
./scripts/test-isolation.sh --vault

# API-layer only (requires backend running)
./scripts/test-isolation.sh --api
```

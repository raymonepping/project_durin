# Durin Architecture

Durin is a reference application for one idea:

> The database holds the data. Vault holds the key. Authority belongs to
> people, not to the application.

Every component exists to demonstrate or enforce that idea. This document
describes the pieces, how a request flows through them, and each trust
boundary: who holds authority, why, for how long, what it reaches, what a
compromise costs and how it is audited and revoked.

## Components

```text
 Browser ── http://localhost:3000 ──► durin-ui (Nuxt SPA + Nitro BFF)
                                        │  session cookie only; tokens stay here
                                        │  Bearer <user access token>
                                        ▼
 Keycloak (realm durin) ◄── OIDC ── durin-backend (Node/Express, :3001)
   ▲  LDAP users/groups                 │                      │
   │                                    │ auth/jwt login        │ SQL (dynamic creds)
 OpenLDAP                               ▼  with the user's JWT  ▼
                               vault-lb (HAProxy, TLS passthrough)   PostgreSQL
                                        │  active node only           (ciphertext +
                                        ▼                              metadata)
                          vault-1 / vault-2 / vault-3 (Raft HA, Enterprise)
                                        │ auto-unseal (transit seal)
                                        ▼
                                     vault-s
```

| Component | Container(s) | Host port | Role |
| --- | --- | --- | --- |
| Web Console | `durin-ui`, `durin-ui-secrets-init` | 3000 | SPA and backend-for-frontend: OIDC client, server-side sessions, proxy to the API |
| API | `durin-backend` | 3001 | Data Trust Gateway: protect, recover, scenarios, inspector, break glass, audit |
| Vault cluster | `durin-vault_1/_2/_3` | 18200–18202 | Transit, auth/jwt, AppRole, Control Groups, KV, database secrets |
| Load balancer | `durin-vault_lb` | 18300 (API), 18404 (stats) | TLS passthrough to the active node only |
| Seal Vault | `durin-vault_s` | 18190 | Transit auto-unseal for the cluster; nothing else |
| Vault Agent | `durin-vault_agent`, `durin-vault_rotator` | — | Backend broker token (AppRole) and its secret-id rotation |
| Identity | `durin-keycloak`, `durin-openldap`, `durin-identity-secrets-init` | 8083, 8084 (LDAP admin) | Who a person is, with roles and tenants as token claims |
| Database | `durin-postgres`, `durin-adminer` | 5432, 5050 | Deliberately visible: metadata and `vault:vN:` ciphertext |
| Observability (optional) | Prometheus, Grafana, OTel | 9090, 3010, 4317/4318 | Metrics and traces |

All containers share the `durin-internal` network. Every host port binds to
`127.0.0.1`. Stacks live in `compose/<stack>/compose.yaml` and are driven by
`scripts/compose.sh` and the Makefile ([development.md](development.md)).

## A request, end to end

"raymon recovers Alice Smith's IBAN in ACME":

1. The browser calls `POST /api/v1/scenarios/recover` on `:3000` with only the
   `durin_sid` cookie and `x-tenant: acme`.
2. The BFF looks up the session, refreshes the access token if it's near
   expiry, strips any `x-durin-actor` header, checks CSRF, and forwards the
   call to `durin-backend` with `Authorization: Bearer <raymon's token>`.
3. The backend verifies the JWT (Keycloak JWKS, issuer, audience). raymon
   has `durin-operator`, and his `durin_tenants` claim covers `acme`.
4. The gateway logs in to Vault as raymon: `auth/jwt/login`, role
   `tenant-acme`, with raymon's JWT. Vault checks the bound claims itself and
   issues a **5-minute** token with `durin-transit-acme` and `durin-keys-acme`,
   named `raymon`.
5. With that token the gateway calls `transit/decrypt/durin-acme-customer-data`
   through `vault-lb`. Vault's audit log records raymon's entity.
6. The backend writes an `audit_events` row (`RECOVER`, `ALLOWED`,
   `source: vault`, `authority.user: raymon`, token accessor) and returns the
   plaintext to the BFF, which returns it to the browser. It is never stored.

If any link refuses, whether a role, the tenant claim, Vault's bound claims,
the policy or a retired key version, the answer is Vault's (or the API's)
real verdict. There is no fallback path.

## Trust boundaries

For each boundary: who holds authority, why, for how long, what it can reach,
what happens if it is compromised, how it is audited and how it is revoked.
[security-model.md](security-model.md) is the full model and
[threat-model.md](threat-model.md) tests it.

| Boundary | Who has authority | Why | How long | What it can reach | If compromised | Audited by | Revoked by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Browser ↔ BFF | the signed-in person, via an opaque session id | the browser must not hold tokens | SSO session (1 h idle, 10 h max); access token 5 min, refreshed server-side | only the API, as that person | an XSS or stolen cookie acts as that person until sign-out; no token can be exfiltrated | Keycloak events, API audit | sign out; Keycloak session end |
| BFF ↔ Keycloak | `durin-ui` as confidential client `durin-backend` | the code exchange needs a client secret | secret rendered once per start from Vault KV | token endpoint for its own client | secret theft lets someone complete *other people's* code exchanges, not mint identities | Keycloak `CODE_TO_TOKEN` events | rotate `secret/durin/identity/oidc-client-secret`, re-run identity bootstrap and `make ui-rebuild` |
| Backend ↔ Vault (broker) | AppRole `durin-backend` via Vault Agent | the API needs key *metadata* for the Inspector and Vault pages | 1 h token (max 4 h); secret-id rotated at 60 of 90 days | read `transit/keys/*` metadata, database creds | an attacker learns key versions: **no decrypt, no encrypt, no key change** | Vault audit (broker entity) | revoke the token or accessor; destroy the secret-id |
| Person ↔ Vault Transit | an operator, via `auth/jwt` role `tenant-<t>` | recovery must be attributable to a person and limited to their tenants | **5 min**, not renewable beyond it | encrypt/decrypt/rewrap on `durin-<t>-*` (no restricted decrypt), rotate + `min_decryption_version` on that tenant's keys | one tenant's data for ≤ 5 min, and only while the stolen JWT is valid | Vault audit (named entity) + `audit_events.authority` | expiry; Shield re-issues authority (revokes outstanding tokens) |
| Break glass | the requester, after a security admin approves in Vault | RESTRICTED data needs two people and a reason | control group 15 min; answer released **once** | one decrypt of one document | nothing without an approver from `durin-security-admins`, who can't be requesters | `BREAK_GLASS_*` events + Vault audit (request and authorization) | deny, revoke, or expiry |
| Backend ↔ PostgreSQL | dynamic user `IN ROLE durin_app` | the API needs DML, never DDL | 1 h lease (max 24 h), rotated at 80 % | DML on app tables; audit INSERT only | ciphertext and metadata only; cannot delete audit history or change the schema | PostgreSQL + Vault lease audit | lease revocation (owned objects reassigned first) |
| PostgreSQL at rest | nobody holds keys here | the database is assumed breached (T1) | — | `vault:vN:` ciphertext | a stolen copy is useless without Vault authority, and **worthless for everyone** after Shield retires its versions | `DATABASE_COMPROMISE` simulation | Shield: rotate → rewrap → raise floor |

## Design decisions (and why)

- **Identity-derived authority instead of an application service account.**
  If the backend held decrypt rights, stealing the backend would equal
  stealing the data. Vault issues authority to the *person*, verified by Vault
  itself (`auth/jwt` bound claims), so a compromised backend holds nothing
  worth stealing ([security-model.md](security-model.md)).
- **Break glass as a Vault Control Group.** Emergency access must be
  approved where the key lives, by a different identity, and used once. The
  backend holds only the wrapping token, in memory, and Vault releases the
  answer ([break-glass.md](break-glass.md)).
- **A visible database.** The demo shows PostgreSQL rows directly (Adminer,
  the Database Inspector's raw tables). Protection that relies on hiding the
  database isn't protection ([database.md](database.md)).
- **One active node behind vault-lb.** The API and tests reach Vault through
  one address that follows the Raft leader, so a leader loss is a short
  interruption, not an outage ([vault.md](vault.md)).
- **A BFF in front of the API.** Tokens never reach the browser, and the
  console runs on the same origin as its API ([web-console.md](web-console.md)).
- **Fail closed.** Vault unavailable means `503`, never plaintext and never
  a cached answer (T7).

## What Durin deliberately is not

It is not a CRM, a document manager, a Vault UI clone, a cryptography
tutorial or an infrastructure showcase. Customers and documents exist only
to give protected data a realistic shape.

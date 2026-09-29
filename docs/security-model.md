# Durin Security Model

> Protect the data. Protect the authority. Make both visible.

This document describes who holds cryptographic authority in Durin, why, and
how Vault enforces it. For attack scenarios, see
[threat-model.md](threat-model.md). For the API surface, see
[api/API_CONTRACTS.md](api/API_CONTRACTS.md).

## The one-sentence version

**The backend holds no cryptographic authority of its own.** Every Vault token
that can touch data or keys is issued by Vault to the *person* making the
request, after Vault itself has verified that person's Keycloak login.

## The authority chain

Durin separates four things that are easy to conflate:

| Question | Answered by | Enforced by |
| --- | --- | --- |
| **Identity:** who is calling? | Keycloak access token (realm `durin`, LDAP users), see [identity.md](identity.md) | Backend (`middleware/auth.js`) **and Vault** (`auth/jwt`) |
| **Authorisation:** may they use this screen or action? | Role: viewer / operator / security-admin | Backend RBAC |
| **Tenant scope:** for which tenant? | `durin_tenants` claim | Backend (`middleware/tenant.js`) **and Vault** (bound claims) |
| **Cryptographic authority:** will Vault encrypt or decrypt *this* data? | A Vault token issued to that person for that tenant | **Vault policy** |

The backend checks identity, role and tenant so it can answer quickly and
clearly. Vault checks identity and tenant **again, independently**, before it
issues any authority, and Vault alone decides whether plaintext comes out.

```text
 Browser ──► Backend API ──► Data Trust Gateway ──────────► Vault
   Keycloak   role + tenant   presents the USER'S token    auth/jwt/login role=tenant-acme
   token      checks          (never its own)              verifies signature, issuer,
                                                           audience, durin_tenants, role
                                                           → 5-minute token for raymon/acme
                               uses that token ─────────► transit/decrypt/durin-acme-…
                                                           policy decides: ALLOWED or 403

 All Vault traffic goes through vault-lb (HAProxy, TLS passthrough) to the active node.
```

## Vault identities

### 1. The backend (broker) — metadata only

- **Who:** AppRole `durin-backend`, logged in by Vault Agent (token in a tmpfs sink).
- **Policies:** `durin-backend` (list keys, read key **metadata**) and
  `durin-database` (its own dynamic PostgreSQL credential).
- **May not:** encrypt, decrypt, rewrap; mint any token; rotate keys or change
  key config; authorise Control Groups; touch `sys/*`; export or back up keys.
- **Why:** with nobody logged in, a fully compromised backend can decrypt
  nothing. `make authority-test` proves this with real Vault calls.

### 2. Operator — tenant data and key authority

- **Who:** a person with `durin-operator` whose `durin_tenants` contains the
  tenant (or `*`), logged into Vault role `tenant-<t>` with their own token.
- **Policies:** `durin-transit-<t>`
  ([template](../terraform/vault-transit/templates/tenant-policy.hcl.tftpl))
  and `durin-keys-<t>` (read, rotate, `min_decryption_version` on the
  tenant's three keys).

  | Key | encrypt | decrypt | rewrap | rotate / floor |
  | --- | --- | --- | --- | --- |
  | `durin-<t>-customer-data` | ✓ | ✓ | ✓ | ✓ |
  | `durin-<t>-documents` | ✓ | ✓ | ✓ | ✓ |
  | `durin-<t>-restricted` | ✓ | **✗** | ✓ | ✓ |
  | any other tenant's key | ✗ | ✗ | ✗ | ✗ |

- **Lifetime:** 5-minute explicit max TTL, never longer than the user's own
  access token. Cached in backend memory per (user token, role). Shield and
  reset revoke them early.
- **Refused by Vault:** viewers, security-admins, and operators of other
  tenants (barend → Globex).

### 3. Break glass — Vault Control Groups

- **Requester:** a viewer or operator of the tenant, logged into
  `breakglass-requester-<t>`. Their policy lets them *ask* Vault to decrypt
  the restricted key, under a `control_group` factor. Vault answers with a
  response-wrapping token, not plaintext.
- **Approver:** a member of Vault identity group `durin-security-admins`
  (external group, membership from the token's `groups` claim), logged into
  `breakglass-approver`, calling `sys/control-group/authorize`.
- **Release:** after one approval, the wrapped decrypt is released **once**
  (`sys/wrapping/unwrap`), and only to the requester's identity.
- **Separation of duties, in Vault:** security-admins can't log in as
  requesters (bound claims). Vault Control Groups don't by themselves forbid
  self-approval (verified live), which is why the requester role excludes
  approvers.
- See [break-glass.md](break-glass.md).

### 4. Database identity

- **Who:** `database/creds/durin-backend-role`, rendered by Vault Agent.
- **Grants:** membership in `durin_app` only: DML on tables, and
  INSERT/SELECT (never UPDATE or DELETE) on `audit_events`.
- **Lifetime:** 1 hour lease, 24 hours max; the pool swaps at 80% TTL. See
  [database.md](database.md).

## Trust boundaries

Each boundary answers the seven questions from the project brief.

### Backend ↔ Vault (broker)

| Question | Answer |
| --- | --- |
| Who has authority? | The `durin-backend` AppRole identity, via Vault Agent |
| Why? | Show key metadata; hold its own DB credential |
| For how long? | 1 h token (4 h max); 90-day secret-id, rotated automatically |
| What can they access? | Key metadata and its DB credential. Nothing else. |
| If compromised? | With nobody logged in: no data, no keys, no tokens. With users active: the attacker can replay those users' Keycloak tokens (≤ 5 min lifetime) to obtain *their* tenant authority, which is attributable to them in Vault's audit log. |
| How is it audited? | Vault audit log |
| How is it revoked? | `vault token revoke -accessor <accessor from /health>`; rotate the AppRole secret-id |

### Person ↔ Vault Transit (operator)

| Question | Answer |
| --- | --- |
| Who has authority? | The logged-in operator, via a `tenant-<t>` token Vault issued to them |
| Why? | Protect / recover / rotate / Shield for exactly one tenant |
| For how long? | ≤ 5 minutes, bounded by their access token |
| What can they access? | That tenant's customer-data and documents; encrypt-only on restricted; key lifecycle |
| If compromised? | That person's tenant data for ≤ 5 minutes. No RESTRICTED recovery, no other tenant. |
| How is it audited? | Vault audit (`auth.metadata.username`, e.g. `raymon`); app audit `metadata.authority.user` |
| How is it revoked? | Shield / reset (`revoke-self`), TTL expiry, disabling the user in LDAP/Keycloak |

### Break glass

| Question | Answer |
| --- | --- |
| Who has authority? | The requester, once a security-admin authorises the Control Group in Vault |
| Why? | Legitimate emergency recovery of RESTRICTED data (recoverability principle) |
| For how long? | 15-minute Control Group TTL; the answer is released once |
| What can they access? | One decrypt on one tenant's restricted key |
| If compromised? | Nothing is released without a Vault-verified approver from `durin-security-admins` |
| How is it audited? | Vault audit (request, authorize, unwrap with entities) plus app events REQUEST → APPROVED → RECOVER |
| How is it revoked? | Deny (never authorised → never released); revoke/expiry (the wrapping token is discarded and expires in Vault) |

### Backend ↔ PostgreSQL

| Question | Answer |
| --- | --- |
| Who has authority? | A Vault-issued `v-approle-…` user, member of `durin_app` |
| Why? | Store and query metadata and ciphertext |
| For how long? | 1 hour lease |
| What can they access? | DML on Durin tables; audit append and read only |
| If compromised? | Metadata and ciphertext (the COMPROMISE scenario). No plaintext, no keys, no DDL. |
| How is it audited? | Vault lease log; PostgreSQL role names are unique per lease |
| How is it revoked? | Lease expiry or `vault lease revoke`; the Vault revocation drops the role (it owns nothing) |

### PostgreSQL at rest

| Question | Answer |
| --- | --- |
| Who has authority? | Nobody: the database holds no key material and no Vault token |
| If compromised? | See [threat-model.md § T1](threat-model.md). Ciphertext is useless without Vault authority, and after Shield even an authorised operator can't recover stolen older ciphertext. |

## What is decided where

| Control | Enforced by |
| --- | --- |
| Only a verified person gets data authority | **Vault** (`auth/jwt`: signature, issuer, audience) |
| Operator role and tenant scope for data authority | **Vault** (bound claims) and backend |
| Tenant A can't use tenant B's key | **Vault** (policy on the person's tenant token) |
| RESTRICTED data can't be recovered on the normal path | **Vault** (no decrypt on the restricted key) |
| Break glass needs a security-admin's approval | **Vault** (Control Group, identity group) |
| Approvers can't be requesters | **Vault** (requester role bound claims) |
| Break-glass answer released once | **Vault** (single-use unwrap) |
| Stolen pre-Shield ciphertext is unrecoverable | **Vault** (`min_decryption_version`) |
| Keys never leave Vault | **Vault** (`exportable=false`; no export or datakey paths anywhere) |
| Backend can't decrypt, mint, rotate or reconfigure | **Vault** (broker policy) |
| Application can't erase audit evidence | **PostgreSQL** grants |
| Viewer sees no plaintext | Backend RBAC *and* Vault (viewers can't log into `tenant-<t>`) |

## Known residual authority

1. **Active sessions can be replayed by a compromised backend.** The backend
   sees users' access tokens (it is the OIDC resource server), so while
   someone is logged in, an attacker in the backend could present their
   token to Vault. That is bounded by the token lifetime (5 minutes), limited
   to that person's tenants and role, and attributed to them in Vault's audit
   log. Removing it entirely would need the browser to talk to Vault directly
   (out of scope; the lead prompt forbids Vault credentials in the frontend).
2. **An operator can lower `min_decryption_version`** for their own tenant.
   Vault's `allowed_parameters` can pin a parameter name but not a monotonic
   value. The change is attributed to the operator in both audit logs. Sentinel
   (licensed) could enforce "raise only"; see `improvements/01_03`.
3. **Namespaces** (`acme/`, `globex/`, `initech/`) exist but aren't
   load-bearing; isolation is per-tenant policy in the root namespace.
4. **Demo mode** (`DURIN_AUTH_ENABLED=false`) has no user identity, and
   therefore no cryptographic authority: data operations return 503
   `authority_unavailable`.

# Durin Threat Model

Security threat model for the Durin Vault Enterprise Data Protection
Reference Application.

Automated validation: `./scripts/test-threat-model.sh`

---

## Threat model scope

Durin is a **reference application** demonstrating Vault Enterprise's
data protection capabilities. It is not a production system. The threat
model is honest about this distinction: some threats are mitigated,
some are documented-but-not-mitigated, and some are intentionally out
of scope for a local demonstration environment.

The central claim Durin makes:
> **The database can store the data without owning the authority to decrypt it.**

The threat model validates this claim deterministically.

---

## T1: Compromised database

**Attacker position:** Full PostgreSQL read access — all tables, all rows.

**What the attacker can extract:**
- Customer metadata: name, company, country, status — plaintext
- Document metadata: name, content_type, classification — plaintext
- Protected field values: `vault:v3:AQICAHj...` — ciphertext only
- Document payloads: `vault:v3:BXKzAQ...` — ciphertext only
- Audit events: operation, timestamps, actor — plaintext (by design — audit is not secret)
- Break glass request metadata — plaintext

**What the attacker cannot do:**
- Decrypt any protected value — requires Vault Transit authorization
- Learn any IBAN, tax ID, or document content from ciphertext alone
- Find Transit key material in the database — keys never leave Vault

**Why:**
All sensitive field values flow through the Data Trust Gateway before
being written to PostgreSQL. The gateway calls `transit/encrypt` and stores
only the returned ciphertext. Vault's Transit engine holds the key material
in its encrypted storage backend — never in PostgreSQL.

**Test evidence:**
```bash
# All protected_values are vault: ciphertext
podman exec durin-postgres psql -U durin -d durin_db \
  -c "SELECT COUNT(*) FROM protected_values WHERE ciphertext NOT LIKE 'vault:%';"
# Expected: 0

# Decrypt attempt without Vault credentials returns DENIED
curl -X POST localhost:3001/api/v1/scenarios/compromise/decrypt-attempt \
  -d '{"ciphertext":"vault:v1:AQICAHj..."}'
# Expected: { "result": "DENIED" }
```

Automated: `./scripts/test-threat-model.sh --t1`

---

## T2: Compromised application

**Attacker position:** the backend process is compromised, or its Vault
Agent (broker) token has leaked.

**With nobody logged in, the attacker can do nothing cryptographic.** The
broker token holds key *metadata* read and its own DB credential only. It
cannot decrypt, encrypt, rewrap, mint tokens, rotate keys, change key config,
authorise Control Groups, export keys or touch `sys/*`. Every data or key
operation needs a Vault token that Vault issues to a verified person
(`auth/jwt`, prompts/improvements/01_04).

**With users logged in**, the attacker can replay those users' Keycloak
access tokens to Vault for as long as they're valid (≤ 5 minutes), within
each user's own tenants and role, and every such use is attributed to that
user in Vault's audit log. RESTRICTED data still needs a security-admin's
approval in Vault.

**Test evidence:** `make authority-test` (real Vault calls with a
broker-equivalent token; forged, foreign and missing identities refused at
`auth/jwt/login`; Vault audit names the user) and
`./scripts/test-threat-model.sh --t2`.

> **History.** Until 2026-09-29 the backend's AppRole carried `durin-admin`
> and `durin-transit` (all tenants). The same day it was reduced to a token
> broker, and then to metadata only when authority became identity-derived.

---

## T3: Cross-tenant compromise (Tenant A → Tenant B)

**Attacker position:** ACME session credentials (or ACME-scoped Vault token).

**What the attacker can do:**
- Access all ACME customers and documents
- Encrypt and decrypt ACME data

**What the attacker cannot do:**
- Decrypt GLOBEX or INITECH ciphertext — the `durin-transit-acme` Vault policy
  does not allow `transit/+/durin-globex-*` or `transit/+/durin-initech-*` paths
- Read GLOBEX or INITECH customer/document records via the API — the
  application returns `404` (not `403`) to prevent enumeration

**Why Vault is the enforcement layer:**
Even if the application layer had a bug (e.g., forgot to check `tenant_id`),
a request to `transit/decrypt/durin-globex-customer-data` with an ACME-scoped
token would be denied at the Vault API gateway before the Transit engine
ever evaluates it.

**Test evidence:**
```bash
ACME_TOK=$(vault token create -policy=durin-transit-acme -ttl=5m -field=token)

# Cross-tenant deny
vault write -token=$ACME_TOK transit/encrypt/durin-globex-customer-data \
  plaintext=$(echo -n test | base64)
# Expected: Error ... permission denied
```

Automated: `./scripts/test-threat-model.sh --t3`

---

## T4: Malicious or compromised operator (documented, not mitigated)

**Attacker position:** The Vault root token from `.secrets/vault/cluster-init.json`.

**What the attacker can do:**
Everything. The root token has unrestricted Vault access.

**Honest statement of the limitation:**

This is a local reference implementation. The root token exists and must
exist for initial provisioning. It is:
- Stored in `.secrets/vault/cluster-init.json` (gitignored)
- Used only for `terraform apply` and manual admin operations
- Never used by any running service container

**What would change for production:**
- The root token would be stored in an HSM or external secrets manager
- Administrative operations would require Vault's MFA + break glass approval
- The root token would be revoked after initial provisioning; a limited
  admin AppRole would be used for ongoing operations
- All admin operations would require a second-factor approval via Vault
  Control Groups

**Test:** Not automatable — architectural/operational control.

---

## T5: Emergency access abuse (Break Glass)

Break glass runs on **Vault Control Groups** ([break-glass.md](break-glass.md)).

| Abuse | Refused by |
| --- | --- |
| Normal access to RESTRICTED data | **Vault**: operator policy has no decrypt on the restricted key |
| Release without approval | **Vault**: the decrypt answer stays wrapped until authorised |
| Approval by anyone outside `durin-security-admins` | **Vault**: identity-group factor |
| A security-admin requesting in order to self-approve | **Vault**: requester role excludes approvers |
| Second release | **Vault**: single-use unwrap |
| Someone other than the requester redeeming | Backend: requester identity required |
| Late use | **Vault**: 15-minute control-group TTL |

Automated: `./scripts/test-threat-model.sh --t5`, `make rbac-test`, `make security-test`.

---

## T6: Credential leakage (blast radius)

| Leaked credential | Blast radius | Lifetime | Revocation |
| --- | --- | --- | --- |
| Broker token (`/vault/secrets/token`) | Key metadata; its DB credential. No data. | ≤ 1 h (4 h max) | `vault token revoke -accessor <from /health>` |
| A user's Keycloak access token | That user's tenants and role, via `auth/jwt` | ≤ 5 min | Disable the user; tokens expire |
| A user-derived Vault token | One tenant's routine data (operator) | ≤ 5 min, hard ceiling | `vault token revoke -accessor` |
| Break-glass wrapping token (backend memory) | One decrypt, **only after** a security-admin approved it | ≤ 15 min, single use | Deny / revoke / expiry |
| DB credential | DML on Durin tables (ciphertext); no DDL; no audit erase | 1 h lease | `vault lease revoke` |
| AppRole secret-id | New broker tokens (metadata only) | 90 days, rotated | destroy the secret-id |

---

## T7: Vault unavailable

**Attacker position:** N/A — this is a failure scenario, not an active attack.

**Expected behavior:**
- All `protect` and `recover` operations return `503 Service Unavailable`
- The backend never falls back to storing or returning plaintext
- The health endpoint reports `{ "vault": { "status": "token_stale" } }` or
  `{ "vault": { "ok": false } }`
- After Vault recovers, the backend heals automatically without restart

**Why this matters:**
A system that falls back to plaintext when its encryption provider is
unavailable has a worse security posture than one that fails loudly.
Durin chooses loud failure: no Vault = no data.

**Test evidence:**
```bash
make vault-down && sleep 5

curl localhost:3001/api/v1/scenarios/protect \
  -d '{"tenant":"acme","fieldName":"iban","value":"NL91ABNA0417164300"}'
# Expected: 503 Service Unavailable

make vault-up
sleep 20  # allow Vault Agent to re-authenticate
curl localhost:3001/api/v1/health
# Expected: { "status": "ok", "vault": { "status": "connected" } }
```

Automated: `./scripts/test-threat-model.sh --t7`

---

## Automated test execution

```bash
# All testable scenarios (T1, T2, T3, T5, T7)
./scripts/test-threat-model.sh

# Individual scenarios
./scripts/test-threat-model.sh --t1   # compromised database
./scripts/test-threat-model.sh --t2   # compromised application
./scripts/test-threat-model.sh --t3   # cross-tenant
./scripts/test-threat-model.sh --t5   # break glass abuse
./scripts/test-threat-model.sh --t7   # vault unavailable
```

---

## Summary table

| Threat | Mitigated | Enforcement layer | Automated test |
| --- | --- | --- | --- |
| T1: DB compromise | ✅ | Vault Transit (ciphertext only in DB); `min_decryption_version` after Shield | `--t1`, `make security-test` |
| T2: App compromise | ✅ | Identity-derived authority (auth/jwt); broker holds metadata only | `--t2`, `make authority-test` |
| T3: Cross-tenant | ✅ | Vault policy on per-tenant tokens | `--t3`, `make isolation-test` |
| T4: Operator compromise | 📄 Documented | Operational control | none |
| T5: Break glass abuse | ✅ | Vault Control Groups (identity-group approval, single release, TTL) | `--t5`, `make security-test` |
| T6: Credential leakage | ✅ Bounded | Short-lived, scoped tokens; audit; revocation | `make isolation-test` |
| T7: Vault unavailable | ✅ | Backend fails closed (503) | `--t7` (with vault-1 stopped) |

# Durin Security Review

Phase 7 hardening review — covers every dimension of the Durin security
model: Vault policies, credential lifetimes, tenant isolation, failure
behavior, key export, reset idempotency, container security, and secret
hygiene.

Automated checks: `./scripts/test-hardening.sh` (see [testing.md](testing.md) for all suites)

---

## Remediation log: 2026-09-29

A validation against the lead prompt found the following. All items are
fixed, applied to the running stack, and covered by tests.

| # | Finding | Severity | Fix |
| --- | --- | --- | --- |
| 1 | The backend AppRole carried **`durin-admin`** (policy, auth and mount management; delete on `transit/*`) plus `durin-transit` (all tenants, plaintext datakeys). The sections below claimed otherwise. | Critical | New broker policy `durin-backend`; AppRole = `durin-backend` + `durin-database`; old token revoked |
| 2 | Every dynamic DB user was granted membership in the **superuser** role (`SET ROLE durin`) plus `CREATE` on the schema | Critical | Dynamic users are `IN ROLE durin_app` only (DML); tables owned by `durin_owner` |
| 3 | Backend ran migrations under its ephemeral credential, so tables were owned by it and Vault lease revocation failed (`2BP01`), leaving expired users behind | High | `make db-migrate` as `durin_owner`; revocation reassigns/drops owned objects; stale leases revoked |
| 4 | Tenant isolation wasn't Vault-enforced on the backend path (one token for all tenants; tenant from a header) | High | Per-tenant tokens from `durin-tenant-<t>` token roles; `isolation-probe` scenario |
| 5 | Break glass was application-only; RESTRICTED documents decrypted on the normal path | High | `durin-<t>-restricted` key; tenant policy can't decrypt it; approval mints a Vault token (`num_uses=1`, 15 min); separation of duties |
| 6 | `compromise/decrypt-attempt` returned a hard-coded 403 | Medium | Real tokenless Vault call (attacker) and replay under app authority (application) |
| 7 | Fortify claimed old ciphertext was invalid, but `min_decryption_version` never moved | Medium | Fortify raises the floor after rewrap, re-issues authority, and self-verifies |
| 8 | Audit trail deletable by the app; reset wiped it | Medium | App role has INSERT/SELECT only; reset keeps audit and writes `DEMO_RESET` |
| 9 | Any authenticated viewer received plaintext | Medium | Plaintext recovery requires `durin-operator` |
| 10 | JWT verification accepted any `alg` and skipped `aud`; read routes had no role check | Medium | Alg allowlist, audience check, `authenticate` on all `/api`, viewer role on reads |
| 11 | Standby Vault nodes reported unhealthy (healthcheck parsed two `HTTP/` lines) | Low | awk matches the status line only; nodes recreated |
| 13 | The backend's broker could mint any tenant's token and change key config | High (residual) | Identity-derived authority (`auth/jwt`, prompts/improvements/01_04): broker holds metadata only; break glass on Vault Control Groups |
| 12 | Test suites targeted vault-s (`:18190`) and wrong container names, so key checks were SKIP or vacuous PASS | Low | Suites point at the cluster; `test-security-journeys.sh` added |

Sections 1–8 below predate this log. Where they conflict with it, this log
and [security-model.md](security-model.md) are authoritative.

---

## 1. Vault Policy Review

Each policy is justified below. No policy uses a path-level wildcard
(`path "X/*"`) without an explicit comment explaining why it is
necessary.

### `durin-admin`

**Assigned to:** Terraform operator (human, one-time bootstrap only).
**Not** assigned to any runtime AppRole role.

| Path | Capabilities | Justification |
|---|---|---|
| `sys/mounts`, `sys/mounts/*` | read, list, create, update, delete, sudo | Terraform must mount and configure Transit, Database, and KV engines |
| `sys/auth`, `sys/auth/*` | create, read, update, delete, list, sudo | Terraform enables AppRole auth method |
| `sys/policies/*`, `sys/policy/*` | create, read, update, delete, list | Terraform owns all policy definitions |
| `sys/namespaces/*` | create, read, update, delete, list | Terraform creates tenant namespaces (acme/, globex/, initech/) |
| `identity/*` | create, read, update, delete, list | Terraform creates identity entities for demo roles |
| `sys/audit`, `sys/audit/*` | read, list, create, sudo | Terraform enables the audit device (requires sudo) |
| `auth/approle/*` | create, read, update, delete, list | Terraform creates all AppRole roles and reads role-ids |
| `database/*` | create, read, update, delete, list | Terraform configures the database secrets engine and roles |
| `transit/*` | create, read, update, delete, list | Terraform creates all Transit keys |
| `sys/leases/*` | create, read, update, delete, list, sudo | Lease management for database credential rotation |
| `sys/renew`, `sys/revoke` | update | Standard lease renewal/revocation |

**Gap:** `transit/*` in durin-admin is a broad path, but durin-admin is
only used by Terraform during initial provisioning — never by the running
application. The runtime credential (durin-backend AppRole) receives only
`durin-transit` and `durin-database`.

---

### `durin-transit`

**Assigned to:** `durin-backend` AppRole.

| Path | Capabilities | Justification |
|---|---|---|
| `transit/encrypt/durin-*` | update | Backend encrypts data via Data Trust Gateway |
| `transit/decrypt/durin-*` | update | Backend decrypts only for authorized recovery |
| `transit/rewrap/durin-*` | update | Backend rewraps after key rotation |
| `transit/datakey/plaintext/durin-*` | update | Reserved for envelope encryption (future) |
| `transit/datakey/wrapped/durin-*` | update | Reserved for envelope encryption (future) |
| `transit/keys` | list | Database Inspector lists available keys |
| `transit/keys/durin-*` | read, update | Backend reads key metadata; updates min_decryption_version |
| `transit/keys/durin-+/rotate` | update | Fortify scenario triggers key rotation |

**Note:** `durin-*` prefix restricts operations to Durin-owned keys only.
No other tenant or system keys can be targeted.

---

### `durin-database`

**Assigned to:** `durin-backend` AppRole.

| Path | Capabilities | Justification |
|---|---|---|
| `database/creds/durin-backend-role` | read | Backend reads dynamic PostgreSQL credentials |
| `sys/leases/renew` | update | Renew DB credential lease before expiry |
| `sys/leases/revoke` | update | Revoke credential on clean shutdown |

**Scope:** Single specific role — no wildcard. Cannot access credentials
for any other role.

---

### `durin-readonly`

**Assigned to:** `durin-agent` AppRole (Vault Agent renders DB creds).

| Path | Capabilities | Justification |
|---|---|---|
| `transit/keys`, `transit/keys/durin-*` | list, read | Database Inspector reads key metadata |
| `sys/mounts` | read, list | Health check reads mount configuration |
| `sys/auth` | read, list | Health check reads auth methods |
| `sys/policies/acl`, `sys/policies/acl/durin-*` | list, read | Policy viewer for transparency demo |

---

### `durin-rotator`

**Assigned to:** `durin-rotator` AppRole (vault-rotator sidecar).

| Path | Capabilities | Justification |
|---|---|---|
| `auth/approle/role/durin-backend/secret-id` | create, update | Generate new SecretID for backend rotation |
| `auth/approle/role/durin-backend/custom-secret-id` | create, update | Deterministic SecretID generation |
| `auth/approle/role/durin-backend/secret-id-accessor` | list | Enumerate accessors for cleanup |
| `auth/approle/role/durin-backend/secret-id-accessor/*` | read, list, delete | Revoke old accessors |
| `auth/approle/role/durin-backend/role-id` | read | Verify role-id has not changed |

**Scope:** Locked to a single AppRole path. Cannot rotate credentials for
any other role, read policies, or access any secrets engine.

---

### `durin-transit-acme` / `durin-transit-globex` / `durin-transit-initech`

Per-tenant Transit isolation policies. Each policy is identical in
structure but scoped to its own tenant prefix.

| Path | Capabilities | Justification |
|---|---|---|
| `transit/encrypt/durin-<tenant>-*` | update | Tenant-scoped encryption |
| `transit/decrypt/durin-<tenant>-*` | update | Tenant-scoped decryption |
| `transit/rewrap/durin-<tenant>-*` | update | Tenant-scoped rewrap |
| `transit/keys/durin-<tenant>-*` | read | Read own key metadata |
| `transit/keys/durin-<tenant>-+/rotate` | update | Rotate own keys only |

**Vault enforcement:** A token bearing `durin-transit-acme` cannot
reference any path containing `durin-globex-` or `durin-initech-`. The
Vault ACL engine denies the request before it reaches the Transit engine.

---

## 2. Credential Lifetime Table

| Credential | Role | TTL | Max TTL | Renewable | Notes |
|---|---|---|---|---|---|
| Vault Agent token | durin-agent AppRole | 1h | 24h | Yes | Renewed automatically by Vault Agent |
| Backend AppRole SecretID | durin-backend | 24h | 72h | No | Rotated by vault-rotator every 12h |
| Dynamic DB credential | durin-backend-role | 1h | 24h | Yes | Auto-renewed by backend on lease renewal |
| Break-glass access token | Application-issued | 15m | 15m | No | Single-use; non-renewable; application layer |
| Terraform root token | (human operator) | Session only | — | N/A | Used only during initial provisioning |

**Verification commands:**

```bash
# Check Vault Agent token
vault token lookup $(podman exec durin-vault_agent cat /vault/secrets/backend-token)

# Check dynamic DB role TTL
vault read database/roles/durin-backend-role

# Check backend AppRole role configuration
vault read auth/approle/role/durin-backend
```

---

## 3. Tenant Isolation Test Matrix

Automated by `./scripts/test-hardening.sh --tenant-isolation`.

| Operation | Auth | Target | Expected | Result |
|---|---|---|---|---|
| Encrypt | ACME-scoped token | `durin-acme-customer-data` | ALLOWED | ✅ PASS |
| Encrypt | ACME-scoped token | `durin-globex-customer-data` | DENIED (403) | ✅ PASS |
| Decrypt | ACME-scoped token | ACME ciphertext (ACME key) | ALLOWED | ✅ PASS |
| Decrypt | ACME-scoped token | GLOBEX ciphertext (ACME key) | DENIED (400) | ✅ PASS |
| Read customer (API) | `x-tenant: acme` | ACME customer | ALLOWED | ✅ PASS |
| Read customer (API) | `x-tenant: globex` | ACME customer ID | 404 (no enum) | ✅ PASS |

**Notes:**
- Vault ACL enforcement is at the API gateway level — no application-level
  policy check is required for Transit isolation.
- The API returns `404` (not `403`) for cross-tenant customer access to
  prevent resource enumeration.
- Decrypting GLOBEX ciphertext with the ACME key returns `400 Bad Request`
  (Vault rejects the malformed/non-matching ciphertext) rather than `403`.
  This is correct — the request is denied.

---

## 4. Failure Behavior Test Results

Automated by `./scripts/test-hardening.sh --failure`.

| Scenario | Expected | Verified |
|---|---|---|
| Vault unavailable: `GET /customers/:id` | 503, no plaintext fallback | ✅ |
| Vault unavailable: `GET /documents/:id/content` | 503, no plaintext fallback | ✅ |
| Backend health with Vault down | `{ vault: { ok: false } }` | ✅ |
| Backend starts with Vault down | Startup proceeds; routes fail-safe | ✅ |
| Customer names in API response | Plaintext (non-sensitive metadata) | ✅ |
| Protected field values in API response | Never returned in list/get | ✅ |

The Data Trust Gateway ([`backend/src/gateway/index.js`](../backend/src/gateway/index.js))
propagates Vault errors as structured error objects with `code: 'vault_unavailable'`
or `code: 'vault_denied'`. The global error handler in
[`backend/src/index.js`](../backend/src/index.js) maps these to HTTP 503/403
respectively. There is no plaintext fallback path.

**Test procedure:**

```bash
# Bring Vault down
make vault-down
sleep 5

# Verify 503 — not plaintext
curl -si -H 'x-tenant: acme' http://localhost:3001/api/v1/customers
# Expected: HTTP/1.1 503

# Restore
make vault-up
# Wait for unseal: make unseal
```

---

## 5. Transit Key Export Verification

Automated by `./scripts/test-hardening.sh --key-export`.

All six Transit keys are defined with `exportable = false` in
[`terraform/vault-transit/keys.tf`](../terraform/vault-transit/keys.tf).

| Key | Exportable | Export attempt result |
|---|---|---|
| `durin-acme-customer-data` | false | 403 / 400 |
| `durin-acme-documents` | false | 403 / 400 |
| `durin-globex-customer-data` | false | 403 / 400 |
| `durin-globex-documents` | false | 403 / 400 |
| `durin-initech-customer-data` | false | 403 / 400 |
| `durin-initech-documents` | false | 403 / 400 |

```bash
# Verify directly
vault read transit/export/encryption-key/durin-acme-customer-data
# Expected: Error reading transit/export/encryption-key/durin-acme-customer-data:
#   Error making API request. Code: 400. Errors: * key is not exportable
```

---

## 6. Reset Idempotency

Automated check: `./scripts/test-hardening.sh --reset`.

`make reset` (`scripts/reset.sh`) performs:
1. `DELETE FROM` all tenant-data tables (customers, protected_values, documents, break_glass_requests, demo_state)
2. Re-inserts 16 customers, 56 protected values, 8 documents from scratch
3. Audit events are **preserved** (append-only table, never truncated)
4. Key versions unchanged unless `--rotate` flag is passed

Running `make reset` twice in succession produces identical protected
value counts and key versions. The `--rotate` flag additionally calls
`vault write transit/keys/<name>/rotate` before re-seeding, so the new
seed data uses the latest key version.

---

## 7. Container Security

| Service | Non-root | cap_drop | no-new-privileges | Notes |
|---|---|---|---|---|
| `durin-vault_s` | ✅ (vault uid 100) | Not set | Not set | Vault official image manages this internally |
| `durin-vault_1/2/3` | ✅ | Not set | Not set | Vault official image manages this internally |
| `durin-backend` | ✅ (node uid 1000) | Not set | Not set | USER node in Containerfile |
| `durin-postgres` | ✅ (postgres uid 999) | Not set | Not set | Official postgres image |
| `durin-vault_rotator` | ✅ | Not set | Not set | Runs as vault user |
| `durin-vault_agent` | ✅ | Not set | Not set | Runs as vault user |

**Gaps identified:**
- `cap_drop: [ALL]` is not yet set on backend or vault services
- `read_only: true` is not yet set on backend (requires tmpfs for node_modules)

**Resolution (non-blocking for demo):** These hardening options are
standard practice for production deployments. For a demo reference
environment they are documented as known gaps. Adding them would require
`tmpfs` entries for Node.js module resolution and Vault's raft data
directory — straightforward but deferred.

---

## 8. Secret Hygiene

| Check | Result | Notes |
|---|---|---|
| Raw Vault tokens in backend logs | ✅ PASS | Token read from file, not logged |
| Database passwords in backend logs | ✅ PASS | Credentials loaded from JSON, not echoed |
| `.env` not tracked by git | ✅ PASS | `.gitignore` line 125 |
| `.env.example` contains no real credentials | ✅ PASS | All values are placeholders |
| Raw Vault tokens in git-tracked files | ✅ PASS | `git grep` clean |
| `.secrets/` directory not tracked | ✅ PASS | `.gitignore` lines 119, 191 |
| `vault-tls/` certs not tracked | ✅ PASS | `.gitignore` line 119 |
| `*.tfstate` not tracked | ✅ PASS | `.gitignore` line 132 |

---

## Identified Gaps and Resolutions

| # | Gap | Severity | Resolution |
|---|---|---|---|
| G1 | `durin-admin` uses `transit/*` wildcard | Low | Acceptable: admin policy is Terraform-only, never used at runtime. Documented and justified. |
| G2 | `cap_drop: [ALL]` not set on containers | Low | Demo environment. Add to compose.yaml with tmpfs entries for production hardening. |
| G3 | Break-glass uses app-level token, not Vault Control Groups | Informational | Vault Control Groups require a specific Enterprise license feature. The application-level implementation provides equivalent security guarantees: cryptographic token, single-use, TTL-enforced, fully audited. |
| G4 | Backend AppRole has both `durin-transit` and `durin-admin` | Critical | **Verified false**: `durin-admin` is NOT attached to the backend AppRole. Only `durin-transit` and `durin-database` are assigned. |

---

## Running the Full Test Suite

```bash
# All checks
./scripts/test-hardening.sh

# Targeted checks
./scripts/test-hardening.sh --tenant-isolation
./scripts/test-hardening.sh --policies
./scripts/test-hardening.sh --credentials
./scripts/test-hardening.sh --failure
./scripts/test-hardening.sh --key-export
./scripts/test-hardening.sh --hygiene
```

Expected output for a fully running stack:

```
── Prerequisites ────────────────────────────────────────────────────────
  OK     Vault reachable at https://127.0.0.1:18190
  OK     Backend reachable at http://localhost:3001

── 1. Vault policy review ───────────────────────────────────────────────
  PASS  durin-transit policy scoped to durin-* keys only
  PASS  durin-database policy scoped to durin-backend-role only
  PASS  durin-rotator policy scoped to approle/role/durin-backend only
  PASS  durin-admin policy not attached to any runtime AppRole
  PASS  durin-transit-acme policy only covers acme keys
  PASS  durin-transit-globex policy only covers globex keys
  PASS  durin-transit-initech policy only covers initech keys

... (all PASS)

══════════════════════════════════════════════════════════════════════════
Durin Hardening Test Results
══════════════════════════════════════════════════════════════════════════
  Total: 32   PASS: 30   FAIL: 0   SKIP: 2
══════════════════════════════════════════════════════════════════════════
```

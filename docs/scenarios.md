# Durin Scenarios

The demonstration is one story, told in six scenarios, each answering the
same question: **who can turn this ciphertext back into plaintext?** Every
verdict on screen is Vault's real answer, and each scenario is also an
automated test (Playwright J1–J8, `make security-test`).

A full run takes 10–14 minutes. `make reset` takes under a second and returns
the demo to baseline for the next audience.

## The cast

| Person | Keycloak role | Tenants | What Vault will give them |
| --- | --- | --- | --- |
| **raymon** | operator | all (`*`) | 5-minute tenant tokens for any tenant |
| **barend** | operator | ACME | 5-minute ACME tokens, nothing else |
| **viewer** | viewer | ACME, Globex | no data authority; may *request* break glass |
| **security-admin** | security-admin | all | may *approve* break glass; never request it |

Passwords live in Vault: `./scripts/identity-secrets.sh --show-user <name>`.
Switch persona by signing out and in (or keep one private window per person).

## 0. Setting the stage (Overview, Database Inspector)

**Say:** "Keycloak says who you are. Vault decides, separately, what each of
you may decrypt."

- **Overview**: three tenant panes. PostgreSQL's values are frosted
  `vault:vN:` ciphertext, with each tenant's key versions and the Vault
  tokens held right now (with their 5-minute bars).
- **Database Inspector**: Alice Smith (ACME) three ways. **Application**
  (what the gateway returns to you), **Database** (exactly what PostgreSQL
  stores) and **Vault State** (key version, `exportable: false`, and the
  recovery rule "operator via auth/jwt tenant-acme"). The raw-rows tab shows
  the tables as a database dump would.

## 1. PROTECT: data enters the boundary

**Proves:** plaintext is encrypted by Vault Transit before it is stored, under
authority issued to a named person.

- **Console:** Protect → ACME, Alice Smith, IBAN `NL91ABNA0417164300` → **Protect**.
- **API:** `POST /api/v1/scenarios/protect { field, value, customerId }`
- **Shows:** the flow plaintext → Vault Transit (`durin-acme-customer-data · vN`)
  → ciphertext → the row read back from PostgreSQL with `contains plaintext:
  false`, plus the tag "Vault authorised raymon for ACME · auth/jwt · tenant-acme".
- **Audit:** `PROTECT · ALLOWED · source vault · actor raymon`.

## 2. RECOVER: and "authenticated is not authorised"

**Proves:** only an authorised person gets plaintext back, and Vault's own audit
names that person, not the application.

- **Console:** Recover → Alice Smith / IBAN → **Recover**. The pane clears.
- **API:** `POST /api/v1/scenarios/recover { customerId, field }`
- **Then as viewer:** the same customer shows `●●●●●●●● protected — operator
  required`. Recover says why ("Requires durin-operator — Vault only issues
  data authority to operators") and, if tried, is refused.
- **Audit:** `RECOVER · ALLOWED · authority.user raymon`; the viewer's
  attempt is `DENIED`.

## 3. COMPROMISE: the database is stolen

**Proves:** a copy of the database is ciphertext without authority.

- **Console:** Compromise → **Simulate compromise**. A red banner appears on
  every page; the stolen copy (all protected values) is listed as ciphertext.
- **Replay as the attacker:** Vault is asked to decrypt the stolen ciphertext
  with no token → **DENIED, vault 403**.
- **Replay as the compromised application:** the app's own tenant authority
  tries the stolen copy → **ALLOWED**. *"Watch what Shield does to that."*
- **API:** `POST /scenarios/compromise`, `GET /scenarios/compromise/snapshot`,
  `POST /scenarios/compromise/decrypt-attempt { actor: attacker|application }`,
  `DELETE /scenarios/compromise` (restore; the snapshot is kept for Shield).
- **Audit:** `DATABASE_COMPROMISE`, `COMPROMISE_DECRYPT_ATTEMPT · DENIED`.

## 4. SHIELD: respond with Vault controls, then prove it

**Proves:** after a breach, Vault can make every stolen copy worthless while
legitimate access continues.

- **Console:** Shield → **Fortify ACME**. The steps appear in order:
  1. **Rotate**: each ACME key gets a new version.
  2. **Rewrap**: Vault re-encrypts every stored value to that version;
     plaintext never leaves Vault.
  3. **Raise the floor**: `min_decryption_version` = new version; older
     versions are retired for **everyone**.
  4. **Re-issue authority**: outstanding tenant tokens are revoked.
- **Verification (asked of Vault live):** legitimate recovery → ALLOWED;
  stolen pre-Shield copy → **DENIED `ciphertext_version_retired`**;
  cross-tenant → DENIED. Result: **HARDENED**.
- **Back on Compromise:** the application replay is now DENIED too.
- **API:** `POST /api/v1/scenarios/fortify`
- **Audit:** `ROTATE`, `REWRAP`, `KEY_CONFIG`, `FORTIFY`, `FORTIFY_VERIFY`.

## 5. ISOLATION: one tenant cannot borrow another's authority

**Proves:** tenant separation is Vault policy, not application code.

- **Console:** Isolation → authority of **ACME** asks for **Globex**'s key → **Probe**.
- **Shows:** two facts side by side. Vault *did* issue raymon a valid ACME
  token (the authority tag), and Vault *refused* that token on
  `transit/encrypt/durin-globex-customer-data` → **403, isolation enforced by
  Vault**. The application never makes this call in normal operation; the
  probe makes it deliberately so Vault can answer.
- **Also:** barend's tenant switcher only offers ACME; a Globex link returns
  `403 tenant_mismatch`, and Vault refuses his `tenant-globex` login.
- **API:** `POST /api/v1/scenarios/isolation-probe { targetTenant, operation }`
- **Audit:** `ISOLATION_PROBE · DENIED`.

## 6. BREAK GLASS: the controlled exception

**Proves:** RESTRICTED data needs two different people, a reason, and Vault's
approval, and the answer is released exactly once.

1. **raymon** opens *Production Incident Report #1842* → **Open content** →
   **NORMAL ACCESS DENIED**. Vault refused decrypt on `durin-acme-restricted`
   even for an operator.
2. **viewer** opens it → writes a reason → **Request break glass**. Status
   **pending**: "control group · 1 approval from durin-security-admins ·
   expires hh:mm". Vault holds the answer.
3. **security-admin** → Break Glass → **Approve**: "BREAK GLASS ACTIVE —
   approved in Vault". (security-admin cannot request; raymon cannot approve.)
4. **viewer** → **Redeem once**. The payload clears, then "Normal access
   restored". A second redeem is refused (`break_glass_used`).
5. Optional: a second request is **denied** and can never be redeemed.

- **API:** `POST /break-glass/request`, `POST /break-glass/:id/approve|deny|revoke`,
  `GET /documents/:id/content` with `x-break-glass-request: <id>`.
- **Audit:** `BREAK_GLASS_REQUEST` (viewer) → `BREAK_GLASS_APPROVED`
  (security-admin) → `BREAK_GLASS_RECOVER` (viewer).

Details: [break-glass.md](break-glass.md).

## Evidence pages

- **Vault**: leader, both standbys `performance-standby`, and vault-lb routing to
  the leader. During `make vault-failover-test` the leader card moves.
- **Audit**: every event above, filterable by tenant, operation, result and
  source (vault / application), since the last reset.

## The three sentences

If the audience remembers nothing else:

> Vault is not merely encrypting the database.
> Vault is controlling the authority required to make protected data useful.
> The database holds the data. Vault holds the key. Authority belongs to people, not to the application.

## Running it again

```bash
make reset                  # < 1 s: wipe + re-seed, keeps key versions
make reset-rotate           # same, and rotates every key to a fresh version
cd ui && npx playwright test narrative --grep @narrative   # the whole story, timed
```

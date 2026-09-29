# Durin Transit Key Lifecycle

The Transit secrets engine is Vault's cryptographic service. Durin uses it
as the sole authority for all encryption and decryption operations. This
document explains the key lifecycle, how rotation and rewrapping work, and
how `min_decryption_version` is used safely.

> **Keys per tenant:** `durin-<t>-customer-data`, `durin-<t>-documents` and
> `durin-<t>-restricted`. Every operation, data and key alike, runs under
> a 5-minute Vault token issued to the signed-in operator (`auth/jwt` role
> `tenant-<t>` → policies `durin-transit-<t>` for encrypt/decrypt/rewrap and
> `durin-keys-<t>` for read/rotate/config on that tenant's keys only). The
> backend's own broker token can read key metadata and nothing else.
> RESTRICTED payloads can be encrypted and rewrapped with the tenant token but
> decrypted only through break glass (a Vault Control Group). See
> [security-model.md](security-model.md).
> Terraform ignores `min_decryption_version` drift, because Shield raises it at
> runtime.


---

## Key naming convention

```
durin-<tenant>-<purpose>
```

| Tenant | Purpose | Key name |
|---|---|---|
| acme | Customer IBAN, tax ID, payment info | `durin-acme-customer-data` |
| acme | Document payloads | `durin-acme-documents` |
| globex | Customer data | `durin-globex-customer-data` |
| globex | Document payloads | `durin-globex-documents` |
| initech | Customer data | `durin-initech-customer-data` |
| initech | Document payloads | `durin-initech-documents` |

All keys:
- Type: `aes256-gcm96` (authenticated encryption with associated data)
- Exportable: `false` — the key material never leaves Vault
- Deletion allowed: `false` — keys cannot be accidentally deleted

---

## Ciphertext format

Vault Transit ciphertext encodes the key version in the prefix:

```
vault:v3:AQICAHjkP...
        ^^
        |└ key version used for encryption
        └ always "vault:" — identifies Vault Transit ciphertext
```

This makes key version tracking trivial: parse the prefix rather than
querying Vault on every operation.

---

## Key lifecycle stages

### Stage 1: Active (version 1)

Initial state after Terraform provisioning.

```
latest_version:       1
min_decryption_version: 1

All ciphertext: vault:v1:...
```

### Stage 2: Rotation (v1 → v2)

```bash
POST /api/v1/transit/keys/durin-acme-customer-data/rotate
```

- New encryptions produce `vault:v2:...`
- Existing `vault:v1:...` ciphertext **remains decryptable** — Vault keeps
  all key versions by default
- `min_decryption_version` is still 1 — the floor has not moved

```
latest_version:       2
min_decryption_version: 1   ← v1 still decryptable

New values:    vault:v2:...
Existing:      vault:v1:...  (still valid)
```

### Stage 3: Rewrap

Rewrap re-encrypts existing ciphertext under the current key version
**without the application ever seeing the plaintext**:

```bash
POST /api/v1/transit/keys/durin-acme-customer-data/rewrap
```

Vault's `transit/rewrap` API:
- Receives `vault:v1:...` ciphertext
- Decrypts and re-encrypts internally in a single atomic call
- Returns `vault:v2:...` ciphertext
- **The plaintext never touches the application or PostgreSQL**

After rewrap:
```
All ciphertext: vault:v2:...
Remaining at v1: 0
```

### Stage 4: min_decryption_version enforcement

After confirming all ciphertext is at `v2`, raise the floor:

```bash
POST /api/v1/transit/keys/durin-acme-customer-data/min-decryption-version
{ "version": 2 }
```

Now:
```
latest_version:       2
min_decryption_version: 2   ← v1 ciphertext can no longer be decrypted

Any vault:v1:... ciphertext → Error: ciphertext version is disallowed
```

This is a **ratchet** — it can only move forward. Once raised, old versions
are permanently excluded.

---

## When to rotate

- **Routine rotation** — periodic key rotation for compliance. Use
  `make reset-rotate` to rotate all keys and re-seed with fresh ciphertext.

- **After a suspected compromise** — if the database was accessed by an
  unauthorized party, rotate keys immediately. Old ciphertext at `v1` cannot
  be decrypted with `v2` material (they are separate key versions, not the
  same key).

- **Fortify scenario** — rotate → rewrap → raise `min_decryption_version`.
  This ensures any `vault:v1:...` ciphertext obtained by an attacker before
  the rotation is now permanently undecryptable, even if they later obtained
  Vault credentials.

---

## What happens if min_decryption_version is raised prematurely

If you raise `min_decryption_version` to `v3` before all data is rewrapped
to `v3`:

```
vault:v2:...  → Error: ciphertext version is disallowed by policy
```

The data is not lost — the key material for `v2` still exists in Vault.
But the floor prevents decryption. To recover:
1. Lower `min_decryption_version` back to 2
2. Complete the rewrap
3. Raise the floor again

**Do not raise `min_decryption_version` before confirming all ciphertext
is at the current version.** The Fortify scenario endpoint does this in
the correct order automatically.

---

## API reference

```
GET  /api/v1/transit/keys
     List all keys for the authenticated tenant. Returns version info.

GET  /api/v1/transit/keys/:keyName
     Key detail: current version, min_decryption_version, type,
     exportable, ciphertext distribution by version.

POST /api/v1/transit/keys/:keyName/rotate
     Rotate to the next version. Returns new currentVersion.

POST /api/v1/transit/keys/:keyName/rewrap
     Rewrap all protected_values for this key to the current version.
     Returns count of rewrapped values.

POST /api/v1/transit/keys/:keyName/min-decryption-version
     { "version": N }
     Set the minimum decryptable version. Irreversible unless lowered
     explicitly (requires operator action).
```

---

## Validation

```bash
# Inspect current key state
curl -sf -H 'x-tenant: acme' \
  http://localhost:3001/api/v1/transit/keys/durin-acme-customer-data \
  | python3 -m json.tool

# Rotate key
curl -sf -X POST -H 'x-tenant: acme' \
  http://localhost:3001/api/v1/transit/keys/durin-acme-customer-data/rotate

# Rewrap all ACME customer data to new version
curl -sf -X POST -H 'x-tenant: acme' \
  http://localhost:3001/api/v1/transit/keys/durin-acme-customer-data/rewrap

# Raise min_decryption_version (only after confirming all values rewrapped)
curl -sf -X POST -H 'x-tenant: acme' \
  http://localhost:3001/api/v1/transit/keys/durin-acme-customer-data/min-decryption-version \
  -H 'Content-Type: application/json' \
  -d '{"min_decryption_version": 3}'

# Full fortify sequence (rotate + rewrap + raise floor)
curl -sf -X POST http://localhost:3001/api/v1/scenarios/fortify \
  -H 'Content-Type: application/json' \
  -d '{"tenant": "acme"}'
```

# Durin API Contracts

Canonical contract between the Durin backend and the Durin Web Console. The
frontend must not rely on any field that is not listed here. Where this
document and `prompts/api/01_01_durin_schema_and_contracts.md` disagree, this
document describes what the backend actually implements.

Base URL: `http://localhost:3001/api/v1`

---

## Conventions

### Response envelope

A successful response wraps its payload in `data` and always carries
`meta.timestamp`:

```json
{ "data": { "…": "…" }, "meta": { "tenant": "acme", "timestamp": "2026-09-29T13:14:00.000Z" } }
```

An error response is never wrapped in `data`:

```json
{ "error": "vault_denied", "message": "Operation denied by Vault policy" }
```

If Vault made the decision, the error also carries `vault`, and usually
`authority` and `auditEventId`:

```json
{
  "error": "vault_denied",
  "message": "NORMAL ACCESS DENIED — Vault refused decrypt on the restricted key. Request break glass.",
  "breakGlassRequired": true,
  "vault": { "status": 403, "path": "transit/decrypt/durin-acme-restricted", "errors": ["1 error occurred:\n\t* permission denied\n\n"] },
  "authority": { "role": "tenant-acme", "user": "raymon", "accessor": "uO4RQl13MTHNrjsmO2PyxRHm", "source": "auth/jwt" },
  "auditEventId": "7f0c…"
}
```

### HTTP status codes

| Code | Meaning |
| --- | --- |
| `200` / `201` | Success / created |
| `400` | Validation error, missing tenant, malformed identifier |
| `401` | No or invalid session (only when `DURIN_AUTH_ENABLED=true`) |
| `403` | Role missing, tenant not in session, **Vault policy denial**, break-glass refusal |
| `404` | Not found in this tenant (the API never tells you a resource exists in another tenant) |
| `409` | Invalid state transition, for example approving a request that isn't pending |
| `422` | Vault refused the ciphertext itself: retired key version, or ciphertext from another key |
| `503` | Vault or the database is unavailable. There is never a plaintext fallback. |

### Error codes

| Code | Trigger |
| --- | --- |
| `validation` | Missing or invalid field |
| `tenant_required` | No `x-tenant` header |
| `invalid_tenant` / `tenant_not_found` | Malformed or unknown tenant slug |
| `tenant_mismatch` | Session isn't authorised for this tenant, or a key belongs to another tenant |
| `unauthorized` / `forbidden` | No session / role missing |
| `vault_denied` | Vault refused the operation (policy) |
| `ciphertext_version_retired` | The ciphertext's key version is below `min_decryption_version` (after Shield) |
| `ciphertext_invalid` | The ciphertext doesn't belong to this key |
| `vault_unavailable` / `authority_unavailable` | Vault unreachable, or a scoped token couldn't be minted |
| `separation_of_duties` | A break-glass requester tried to approve their own request |
| `break_glass_not_required` | A break-glass request for a non-RESTRICTED document |
| `break_glass_invalid` / `break_glass_pending` / `break_glass_not_requester` / `break_glass_used` / `break_glass_expired` / `break_glass_revoked` / `break_glass_denied` / `break_glass_authority_lost` | Break-glass redemption refused (see [break-glass.md](../break-glass.md)) |
| `authority_unavailable` | No user identity to present to Vault (demo mode), or Vault unreachable while issuing authority |
| `not_approved` | Vault recorded an authorisation but the control group isn't satisfied |
| `would_strand_data` | Raising `min_decryption_version` above values that are still stored |
| `no_compromise_snapshot` | Decrypt attempt before `POST /scenarios/compromise` |
| `invalid_state` | State-machine violation |
| `not_found` | Resource not found |
| `internal_error` | Unexpected; the message is generic, and details are in the backend log |

### Tenant context

Every tenant-scoped endpoint reads the tenant slug from the **`x-tenant`**
header. The `?tenant=` query parameter and a body `tenant` field are also
accepted, in that order of precedence. Demo slugs are `acme`, `globex` and
`initech`.

- With auth enabled, the slug must appear in the session's `durin_tenants`
  claim (or the claim is `["*"]`), or the request gets `403 tenant_mismatch`.
- In every mode, the Data Trust Gateway runs under a Vault token that is
  scoped to exactly this tenant. See [security-model.md](../security-model.md).

### Identity and roles

| Role | May |
| --- | --- |
| `durin-viewer` | every `GET`, and `POST /break-glass/request` |
| `durin-operator` | viewer + customer/document writes, scenarios, key lifecycle, **plaintext recovery** |
| `durin-security-admin` | viewer + break-glass approve, deny and revoke |

Being authenticated doesn't grant decryption. On the normal read paths
(`GET /customers/:id`, `GET /documents/:id/content`, the inspector), only
`durin-operator` receives plaintext. Viewers get `null` values plus
field-state descriptors.

**Auth mode (`DURIN_AUTH_ENABLED=true`, default).** Send
`Authorization: Bearer <access token>` from Keycloak realm `durin`
(issuer `http://localhost:8083/realms/durin`, audience `durin-backend`).
`realm_access.roles` supplies the role and `durin_tenants` the allowed
tenants. `GET /health` stays open and reports `auth: { enabled, mode, issuer }`.
See [identity.md](../identity.md).

**Demo mode (`DURIN_AUTH_ENABLED=false`).** Every request
runs as a synthetic identity that holds all roles and all tenants. The
optional **`x-durin-actor`** header names the persona that appears in the
audit log. Use it to show a requester and an approver as different people.
Demo mode isn't an access control; the Vault controls below stay fully
enforced.

---

## Web Console BFF (browser-facing)

The browser never calls `durin-backend` and never holds a token. It talks
only to the Web Console's own server on the same origin,
`http://localhost:3000` (Nuxt/Nitro, `ui/server/`, prompts/frontend/01_02),
which is the OIDC confidential client `durin-backend` and forwards API calls
with the user's access token.

| Endpoint | Purpose |
| --- | --- |
| `GET /api/v1/auth/login?returnTo=/path[&prompt=login]` | `302` to Keycloak authorize (code + PKCE S256, `state`, `nonce`). `returnTo` must be a same-origin path. |
| `GET /api/v1/auth/callback` | Exchanges the code server-side, creates the session, sets the httpOnly `durin_sid` cookie (SameSite=Lax) and redirects to `returnTo`. On failure it redirects to `/login?error=<code>`. |
| `GET /api/v1/auth/me` | `{ data: { sub, name, email, roles, tenants, accessExpiresAt } }`, identity only and never tokens. `401` without a session. Refreshes the access token when it is near expiry. |
| `POST /api/v1/auth/logout` | Ends the session; returns `{ data: { logoutUrl } }` (Keycloak end-session with `id_token_hint`). |
| `ANY /api/v1/*` (everything else) | Proxied to `http://durin-backend:3001/api/v1/*` with `Authorization: Bearer <access token>` from the session. |

Proxy rules:

- Forwarded request headers are an allowlist: `content-type`, `x-tenant`,
  `x-break-glass-request`. `x-durin-actor` is always stripped, since the actor
  comes from the verified token and never from the browser.
- Every non-GET request needs `x-durin-csrf: 1` or a same-origin `Origin`;
  anything else gets `403`.
- No session: `401 { error: "unauthorized" }`. The console redirects to
  `/login?returnTo=…`. A `401` from the backend also destroys the BFF session.
- Backend responses, including error bodies with `vault`, `authority` and
  `auditEventId`, pass through unchanged.

---

## Health

### `GET /health` (no auth)

`200` if Vault and the database are healthy, otherwise `503` with `status: "degraded"`.

```json
{
  "status": "ok",
  "vault": {
    "status": "connected",
    "ok": true,
    "accessor": "o3hlzeTSxLjbd1vPE3KTnkof",
    "token_ttl": 3049,
    "role": "durin-backend",
    "policies": ["default", "durin-backend", "durin-database"],
    "scoped_authority": {
      "acme": [ { "role": "tenant-acme", "user": "raymon", "accessor": "uO4R…", "policies": ["default", "durin-keys-acme", "durin-transit-acme"], "expiresAt": "…", "ttlRemaining": 212 } ]
    }
  },
  "db": {
    "connected": true,
    "username": "v-approle-durin-ba-rKYM…",
    "error": null,
    "credential_ttl_remaining": 2847,
    "credential_expires_at": "2026-09-29T14:36:30.539Z",
    "credential_accessor": "database/creds/durin-backend-role/RrWP…"
  }
}
```

`vault.status` is one of `connected`, `token_stale`, `unavailable`.
`vault.policies` shows the backend's *own* authority: broker only, never admin.

---

## Tenants

### `GET /tenants`

```json
{
  "data": [
    {
      "id": "uuid", "name": "ACME Corporation", "slug": "acme", "vault_namespace": "acme",
      "fortified_at": null, "created_at": "…",
      "transitKeys": ["durin-acme-customer-data", "durin-acme-documents", "durin-acme-restricted"],
      "vaultRole": "auth/jwt tenant-acme"
    }
  ],
  "meta": { "count": 3 }
}
```

### `GET /tenants/:slug`

A single tenant with the same shape.

---

## Customers

Protected fields: `iban`, `tax_id`, `payment_info` (stored only as ciphertext
in `protected_values`). Plain fields: `name`, `company`, `country`, `status`.

### `GET /customers`

Metadata only; never decrypts. Excludes soft-deleted customers.

```json
{ "data": [ { "id": "uuid", "name": "Alice Smith", "company": "ACME Corporation", "country": "NL", "status": "active", "created_at": "…", "updated_at": "…" } ],
  "meta": { "tenant": "acme", "count": 6 } }
```

### `GET /customers/:id` (application view)

```json
{
  "data": {
    "id": "uuid", "tenant_id": "uuid", "name": "Alice Smith", "company": "ACME Corporation",
    "country": "NL", "status": "active", "created_at": "…", "updated_at": "…",
    "iban": "NL91ABNA0417164300",
    "tax_id": "NL123456789B01",
    "payment_info": "SEPA Direct Debit - NL91ABNA",
    "protectedFields": {
      "iban": { "state": "recovered", "keyName": "durin-acme-customer-data", "keyVersion": 5, "updatedAt": "…" }
    }
  },
  "meta": { "tenant": "acme", "recovered": true }
}
```

- An operator gets `state: "recovered"` and plaintext. Each recovery writes a `RECOVER` audit event.
- A viewer gets `state: "protected"`, the value is `null`, and `meta.recovered` is `false`.
- A field Vault refused gets `state: "denied"` plus `reason` (for example `ciphertext_version_retired`).
- Masking such as `••••1234` is a presentation concern for the frontend.

### `POST /customers` (operator)

Body: `{ "name", "company?", "country?", "status?", "iban?", "tax_id?", "payment_info?" }`.
Fields are protected first. If Vault refuses, nothing is written.

`201` →

```json
{ "data": { "id": "uuid", "name": "…", "…": "…",
    "protectedFields": { "iban": { "state": "protected", "keyName": "durin-acme-customer-data", "keyVersion": 5, "ciphertext": "vault:v5:…" } } },
  "meta": { "tenant": "acme" } }
```

### `PUT /customers/:id` (operator)

Partial update; any protected field supplied is re-protected.
→ `{ "data": { "id", "reprotected": ["iban"] } }`

### `DELETE /customers/:id` (operator)

Soft delete. → `{ "data": { "id", "status": "deleted" } }`

---

## Documents

Classification selects the Transit key:

| Classification | Key | Normal recovery |
| --- | --- | --- |
| `PUBLIC`, `INTERNAL`, `CONFIDENTIAL` | `durin-<t>-documents` | operator |
| `RESTRICTED` | `durin-<t>-restricted` | **Vault denies**; break glass only |

Document object (used by list, detail and create):

```json
{
  "id": "uuid", "tenant_id": "uuid", "customer_id": "uuid|null", "customer_name": "Alice Smith|null",
  "name": "Production Incident Report #1842", "content_type": "text/markdown",
  "classification": "RESTRICTED", "size_bytes": 412, "checksum": "sha256 hex",
  "created_at": "…", "created_by": "security@acme.com",
  "encryption": {
    "protected": true, "keyName": "durin-acme-restricted", "keyVersion": 5,
    "protectedAt": "…", "recoveryRequires": "break-glass"
  }
}
```

`encryption.recoveryRequires` is `"operator"` or `"break-glass"`.

### `GET /documents` / `GET /documents/:id`

Metadata plus `encryption`; never decrypts.

### `POST /documents` (operator)

Body: `{ "name", "payload" (string), "classification?" (default INTERNAL), "content_type?" (default text/plain), "customer_id?" }`
→ `201` document object.

Pasted text and uploaded files use the same call. `content_type` decides how
`payload` is read:

| `content_type` | `payload` | Checked |
| --- | --- | --- |
| `text/plain`, `text/markdown` | UTF-8 text | — |
| `application/pdf` | base64 of the file | starts with `%PDF-` |
| `application/vnd.openxmlformats-officedocument.wordprocessingml.document` (.docx) | base64 of the file | ZIP header |

For binary types, Vault Transit encrypts the file's **bytes** (not a text
rendering). `size_bytes` and `checksum` (SHA-256) describe those bytes. Limit:
5 MB of file content. Errors: `415 unsupported_type`, `400 validation`
(not base64, or content that doesn't match the type), `413 too_large`.

### `GET /documents/:id/content`

The normal path requires an operator. For a RESTRICTED document the response is:

```text
403 { "error": "vault_denied", "breakGlassRequired": true, "vault": {…}, "authority": {…}, "auditEventId": "…" }
```

For any other document it is `200 { "data": { …document, "payload": "…", "encoding": "utf8" | "base64", "keyVersion": 5 }, "meta": { "authority": {…}, "auditEventId" } }`.

`encoding` is `utf8` for text types (`payload` is the text) and `base64` for
uploaded binary files (`payload` is the file's bytes). The console turns base64
into a download in the browser and checks it against `checksum`. The
break-glass path below returns the same two fields.

**Break-glass path:** the requester sends `x-break-glass-request: <request id>`
with their own session. Vault releases the approved answer once.

```json
{
  "data": { "…document": "…", "payload": "INCIDENT #1842 — RESTRICTED …", "keyVersion": 5 },
  "meta": {
    "tenant": "acme",
    "breakGlass": {
      "requestId": "uuid", "requestedBy": "viewer", "approvedBy": "security-admin",
      "mechanism": "vault-control-group", "vaultWrappingAccessor": "…",
      "status": "used", "normalAccessRestored": true
    },
    "auditEventId": "uuid"
  }
}
```

### `GET /documents/:id/raw`

The database view: `{ "data": { "ciphertext", "key_name", "key_version", "created_at", "updated_at" } }`.

---

## Database Inspector

### `GET /database/customers/:id` and `GET /database/documents/:id`

Three views of one record, plus per-field state:

```json
{
  "data": {
    "applicationView": { "id": "uuid", "name": "Alice Smith", "iban": "NL91ABNA0417164300" },
    "databaseView":    { "id": "uuid", "name": "Alice Smith", "iban": "vault:v5:fJLm…" },
    "vaultState": {
      "durin-acme-customer-data": {
        "name": "durin-acme-customer-data", "type": "aes256-gcm96",
        "currentVersion": 5, "minDecryptionVersion": 5, "minEncryptionVersion": 0,
        "minAvailableVersion": 0, "versions": [1, 2, 3, 4, 5],
        "deletionAllowed": false, "exportable": false, "allowPlaintextBackup": false,
        "recovery": { "requires": "operator", "vaultPolicy": "durin-transit-acme", "vaultRole": "auth/jwt tenant-acme", "normalPath": "allowed" },
        "keyMaterialExposed": false
      }
    },
    "fields": {
      "iban": { "protected": true, "keyName": "durin-acme-customer-data", "keyVersion": 5,
                "application": { "state": "recovered" } }
    }
  }
}
```

- `databaseView` is never decrypted.
- `applicationView` values are `null` when `fields.*.application.state` is
  `not_authorised` (viewer) or `denied` (for example a RESTRICTED payload,
  which also sets `fields.payload.breakGlassRequired: true`).

### `GET /database/tables`

`{ "data": [ { "table": "protected_values", "rows": 58, "containsCiphertext": true } ] }`

### `GET /database/tables/:table?limit=&offset=`

Raw PostgreSQL rows for the tenant, exactly as stored. The browsable tables
are `tenants`, `customers`, `documents`, `protected_values`, `audit_events`,
`break_glass_requests` and `compromise_snapshots`. `meta.representation` is
`"raw PostgreSQL rows — nothing decrypted"`.

---

## Transit keys

### `GET /transit/keys`

The tenant's three keys:

```json
{ "data": [ { "name": "durin-acme-customer-data", "keyType": "customer-data", "type": "aes256-gcm96",
    "currentVersion": 5, "minDecryptionVersion": 5, "minEncryptionVersion": 0, "minAvailableVersion": 0,
    "versions": [1,2,3,4,5], "deletionAllowed": false, "exportable": false, "allowPlaintextBackup": false,
    "ciphertextDistribution": { "v1": 0, "v2": 0, "v3": 0, "v4": 0, "v5": 18 } } ] }
```

### `GET /transit/keys/:name`

A single key, same shape. A key from another tenant returns `403 tenant_mismatch`.

### `POST /transit/keys/:name/rotate` (operator)

`{ "data": { "keyName", "fromVersion": 4, "currentVersion": 5, "auditEventId" } }`

### `POST /transit/keys/:name/rewrap` (operator)

Re-encrypts every stored value inside Vault; the backend never sees plaintext.

`{ "data": { "keyName", "rewrapped": 18, "currentVersion": 5, "before": { "v4": 18 }, "after": { "v4": 0, "v5": 18 }, "plaintextExposedToApplication": false } }`

### `POST /transit/keys/:name/min-decryption-version` (operator)

Body: `{ "min_decryption_version": 5 }`. Returns `409 would_strand_data` if
stored values are still below the requested floor.
→ `{ "data": { "keyName", "minDecryptionVersion", "previousMinDecryptionVersion", "currentVersion", "auditEventId" } }`

---

## Vault cluster

### `GET /vault/status` (viewer)

Cluster state for the Vault page. Built only from unauthenticated Vault
endpoints (`sys/health`, `sys/seal-status`, `sys/leader` on each node) and
HAProxy's read-only stats, so the backend needs no extra Vault authority.
Cached for 3 s. `transitKeys` is filtered to the caller's tenants.

```json
{
  "data": {
    "summary": { "status": "healthy|degraded|unavailable", "leader": "vault-1", "nodesUnsealed": 3, "nodesTotal": 3,
                 "haQuorum": true, "version": "2.1.0+ent", "loadBalancerAgrees": true },
    "nodes": [
      { "name": "vault-s", "role": "unseal", "reachable": true, "mode": "active", "sealed": false, "sealType": "shamir",
        "storageType": "raft", "version": "2.1.0+ent", "isLeader": null },
      { "name": "vault-1", "role": "cluster", "reachable": true, "mode": "active", "sealed": false, "sealType": "transit",
        "isLeader": true, "leaderAddress": "https://vault-1:8200" },
      { "name": "vault-2", "role": "cluster", "mode": "performance-standby", "isLeader": false }
    ],
    "loadBalancer": { "reachable": true, "endpoint": "vault-lb:8200 (TLS passthrough)", "activeNode": "vault-1",
                      "routing": "active node only — standbys report DOWN by design (health 429/473)",
                      "servers": [ { "node": "vault-1", "state": "UP", "check": "L7OK" }, { "node": "vault-2", "state": "DOWN", "check": "L7STS" } ] },
    "backend": { "vaultAddr": "https://vault-lb:8200", "status": "connected", "policies": ["default", "durin-backend", "durin-database"] },
    "authMethods": [ { "path": "auth/jwt", "purpose": "…" }, { "path": "auth/approle", "purpose": "…" } ],
    "transitKeys": { "acme": [ { "name": "durin-acme-customer-data", "keyType": "customer-data", "type": "aes256-gcm96",
                                 "currentVersion": 5, "minDecryptionVersion": 5, "exportable": false, "deletionAllowed": false } ] }
  },
  "meta": { "cachedForMs": 3000 }
}
```

`mode` is one of `active`, `standby`, `performance-standby`, `sealed`,
`uninitialized` or `unreachable`. In the load-balancer list, standbys show
`DOWN`; that's intended, because only the leader receives traffic.

---

## Scenarios

`GET /scenarios/state` is viewer-level; everything else requires an operator.

### `GET /scenarios/state`

```json
{
  "data": {
    "activeTenant": "acme",
    "tenants": ["acme", "globex", "initech"],
    "customersPerTenant": { "acme": 6, "globex": 5, "initech": 5 },
    "protectedValuesCount": 58,
    "documentsCount": 10,
    "keyVersions": { "durin-acme-customer-data": 5 },
    "keys": { "durin-acme-customer-data": { "currentVersion": 5, "minDecryptionVersion": 5 } },
    "compromiseMode": false,
    "compromiseSnapshot": { "records": 0, "capturedAt": null },
    "fortified": false,
    "fortifiedTenants": [],
    "lastResetAt": "…",
    "authority": { "acme": [ { "role": "tenant-acme", "user": "raymon", "accessor": "…", "ttlRemaining": 212 } ] }
  }
}
```

### `POST /scenarios/protect`: PROTECT

Body: `{ "field": "iban"|"tax_id"|"payment_info", "value": "NL91ABNA0417164300", "customerId?": "uuid" }`.
If no customer is given, it uses the tenant's first customer. The value is
stored, then read back from PostgreSQL.

```json
{ "data": { "operation": "protect", "tenant": "acme", "customerId": "uuid", "customerName": "Alice Smith",
    "field": "iban", "ciphertext": "vault:v5:…", "keyName": "durin-acme-customer-data", "keyVersion": 5,
    "storedAt": "…", "auditEventId": "uuid",
    "authority": { "role": "tenant-acme", "user": "raymon", "accessor": "…", "source": "auth/jwt" },
    "database": { "table": "protected_values", "row": { "id": "…", "ciphertext": "vault:v5:…", "…": "…" }, "containsPlaintext": false } } }
```

### `POST /scenarios/recover`: RECOVER

Body: `{ "field": "iban", "customerId?": "uuid" }` reads the stored value.
Alternatively, `{ "ciphertext": "vault:v…", "keyType?": "customer-data" }`
recovers a value you supply.

```json
{ "data": { "operation": "recover", "tenant": "acme", "customerId": "uuid", "field": "iban",
    "ciphertext": "vault:v5:…", "plaintext": "NL91ABNA0417164300", "keyName": "…", "keyVersion": 5,
    "auditEventId": "uuid", "authority": { "role": "tenant-acme", "user": "raymon", "accessor": "…", "source": "auth/jwt" },
    "flow": ["user", "application", "data-trust-gateway", "vault-transit", "plaintext", "authorised-ui"] } }
```

### `POST /scenarios/compromise`: COMPROMISE

Snapshots every protected value (ciphertext plus metadata) as an attacker's
database dump would contain it.

```json
{ "data": { "operation": "compromise", "compromiseMode": true,
    "attackerHas": { "postgresqlAccess": true, "customerRecords": 16, "documentMetadata": 10, "ciphertexts": 58, "plaintextSensitiveValues": 0 },
    "attackerLacks": { "transitKeys": "…", "vaultAuthorization": "…", "decryptionAuthority": "…" },
    "next": "POST /api/v1/scenarios/compromise/decrypt-attempt …", "auditEventId": "uuid" } }
```

### `DELETE /scenarios/compromise`

Ends compromise mode. The snapshot is kept so Shield can be proven against
it; reset clears it.

### `GET /scenarios/compromise/snapshot`

The attacker's view for this tenant:
`[{ id, resource_type, resource_id, field_name, ciphertext, key_name, key_version, captured_at, customer_name, company, document_name, classification }]`.

### `POST /scenarios/compromise/decrypt-attempt`

Body: `{ "actor": "attacker"|"application", "snapshotId?", "ciphertext?", "keyType?" }`.
The response is always `200`; the verdict is the payload.

- `attacker` calls Vault with **no token**, and the result is `DENIED` with `vault.status` `403`.
- `application` uses the app's own tenant authority. It returns `ALLOWED`
  before Shield, and after Shield returns `DENIED` with
  `reason: "ciphertext_version_retired"`.

```json
{ "data": { "actor": "attacker", "tenant": "acme", "snapshotId": "uuid", "keyName": "durin-acme-customer-data",
    "keyVersion": 4, "ciphertext": "vault:v4:…", "result": "DENIED", "reason": "no_vault_token",
    "vault": { "status": 403, "errors": ["permission denied"] }, "auditEventId": "uuid",
    "explanation": "The attacker holds ciphertext but no Vault token. Vault refuses to decrypt." } }
```

An `application` result never includes plaintext (`plaintextReturned: false`).

### `POST /scenarios/isolation-probe`

Body: `{ "targetTenant": "globex", "operation": "encrypt"|"decrypt" }`. Uses
this tenant's Vault authority against the other tenant's key.

```json
{ "data": { "sourceTenant": "acme", "targetTenant": "globex", "targetKey": "durin-globex-customer-data",
    "operation": "encrypt", "authority": { "role": "tenant-acme", "user": "raymon", "accessor": "…", "source": "auth/jwt" },
    "result": "DENIED", "isolationEnforced": true, "vault": { "status": 403, "errors": ["…permission denied…"] },
    "auditEventId": "uuid" } }
```

### `POST /scenarios/fortify`: SHIELD

Runs for the tenant in `x-tenant`: rotate all three keys, rewrap all
ciphertext, raise `min_decryption_version` to the current version, re-issue
tenant authority, then verify live.

```json
{ "data": {
    "operation": "fortify", "tenant": "acme",
    "before": { "durin-acme-customer-data": { "currentVersion": 4, "minDecryptionVersion": 1 } },
    "after":  { "durin-acme-customer-data": { "currentVersion": 5, "minDecryptionVersion": 5 } },
    "steps": [
      { "control": "rotate", "enforcedBy": "vault", "detail": ["durin-acme-customer-data: v4 → v5"] },
      { "control": "rewrap", "enforcedBy": "vault", "plaintextExposedToApplication": false, "detail": ["…"] },
      { "control": "min_decryption_version", "enforcedBy": "vault", "detail": ["…floor v1 → v5"] },
      { "control": "reissue_authority", "enforcedBy": "vault", "detail": ["revoked tenant token …"] }
    ],
    "verification": {
      "legitimateRecovery":  { "expected": "ALLOWED", "result": "ALLOWED" },
      "preShieldCiphertext": { "origin": "snapshot", "expected": "DENIED", "result": "DENIED", "reason": "ciphertext_version_retired" },
      "crossTenant":         { "target": "globex", "expected": "DENIED", "result": "DENIED" },
      "passed": true
    },
    "rewrapped": 22, "auditEventId": "uuid", "message": "…" } }
```

### `POST /scenarios/seed`

Idempotent. `{ "data": { "message": "Seeded", "customers": 16, "documents": 10, "protectedValues": 58 } }`
or `{ "message": "Already seeded" }`.

### `DELETE /scenarios/reset?rotate=true|false`

Wipes the demo data and revokes all outstanding scoped Vault authority.
**Tenants and the audit log are kept**; filter the audit log with
`?since=<lastResetAt>`.
→ `{ "data": { "message", "revokedAuthority": { "tenants": [], "breakGlass": [] }, "auditEventId", "rotatedKeys?" } }`

---

## Break glass

Built on Vault Control Groups; see [break-glass.md](../break-glass.md).

Request object:

```json
{ "id": "uuid", "tenant_id": "uuid", "tenant_slug": "acme", "requested_by": "viewer",
  "resource_type": "document", "resource_id": "uuid", "resource_name": "Production Incident Report #1842",
  "resource_classification": "RESTRICTED", "reason": "Production incident investigation",
  "status": "pending|approved|used|denied|revoked|expired",
  "approved_by": null, "approved_at": null, "denied_by": null, "expires_at": "…", "used_at": null,
  "revoked_at": null, "revoked_by": null, "vault_wrapping_accessor": "…",
  "vault_policy": "durin-breakglass-request-acme", "vault_mechanism": "control-group",
  "vault_holds_answer": true, "created_at": "…" }
```

| Endpoint | Role | Notes |
| --- | --- | --- |
| `GET /break-glass/pending` | viewer | Pending requests in the session's tenants |
| `GET /break-glass/all?tenant=&status=&limit=&offset=` | viewer | History |
| `GET /break-glass/:id` | viewer | A single request |
| `POST /break-glass/request` | viewer or operator | Body `{ "resource_id", "reason" (≥ 5 chars) }`, tenant from `x-tenant`. The requester's identity asks Vault; `400 break_glass_not_required` unless RESTRICTED; `403 vault_denied` for security-admins (approvers can't request) |
| `POST /break-glass/:id/approve` | security-admin | Authorises the control group in Vault under the approver's identity; `403 separation_of_duties` if approver = requester |
| `POST /break-glass/:id/deny` | security-admin | pending → denied (never authorised in Vault) |
| `POST /break-glass/:id/revoke` | security-admin | pending/approved → revoked (answer discarded) |

Request response (`201`):

```json
{ "data": { "…request": "…", "status": "pending",
    "vault": { "mechanism": "control-group", "wrappingAccessor": "…", "requesterPolicy": "durin-breakglass-request-acme",
               "approvalsRequired": 1, "approverGroup": "durin-security-admins", "ttlSeconds": 900, "expiresAt": "…" } },
  "meta": { "tenant": "acme", "message": "Awaiting approval by a security-admin in Vault." } }
```

Approve response (`200`): the request object with `status: "approved"` and
`vault: { mechanism: "control-group", approved: true, authorizations: ["entity_…"] }`.
No bearer token is issued; the requester redeems with their own session and
the request id.

---

## Audit

### `GET /audit?tenant=&operation=&result=&source=&since=&limit=&offset=`

```json
{ "data": [ {
    "id": "uuid", "timestamp": "…", "operation": "RECOVER", "tenant": "acme",
    "resourceType": "customer", "resourceId": "uuid", "fieldName": "iban", "actor": "demo-operator",
    "keyName": "durin-acme-customer-data", "keyVersion": 5, "result": "ALLOWED", "source": "vault",
    "metadata": { "source": "vault", "authority": { "role": "tenant-acme", "user": "raymon", "accessor": "…", "source": "auth/jwt" } } } ],
  "meta": { "count": 1, "limit": 100, "offset": 0 } }
```

- `result` is one of `ALLOWED`, `DENIED`, `SIMULATED` or `FAILED`.
- `source` is `vault` when the verdict came from Vault, and `application` when backend logic decided.
- Operations: `PROTECT`, `RECOVER`, `REWRAP`, `ROTATE`, `KEY_CONFIG`,
  `INSPECTOR_RECOVER`, `ISOLATION_PROBE`, `DATABASE_COMPROMISE`,
  `DATABASE_COMPROMISE_CLEARED`, `COMPROMISE_DECRYPT_ATTEMPT`,
  `COMPROMISE_REPLAY`, `FORTIFY`, `FORTIFY_VERIFY`, `BREAK_GLASS_REQUEST`,
  `BREAK_GLASS_APPROVED`, `BREAK_GLASS_DENIED`, `BREAK_GLASS_RECOVER`,
  `BREAK_GLASS_ENDED`, `BREAK_GLASS_REVOKED`, `BREAK_GLASS_EXPIRED`,
  `DEMO_SEED`, `DEMO_RESET`.
- The audit trail is append-only for the application; its database role
  can't update or delete events.

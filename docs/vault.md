# Vault in Durin

Vault Enterprise 2.1 is the only place in Durin where cryptographic authority
exists. This document describes the cluster, how clients reach it, and every
auth method, policy and engine Durin configures, and why. For key lifecycle
see [transit.md](transit.md); for the authority model as a whole see
[security-model.md](security-model.md).

## Cluster

| Node | Host port | Role |
| --- | --- | --- |
| `vault-1`, `vault-2`, `vault-3` | 18200, 18201, 18202 | Raft HA cluster. One active node; the others are performance standbys. |
| `vault-s` | 18190 | Separate Vault whose Transit engine auto-unseals the cluster (seal type `transit`). It holds no Durin data. |
| `vault-lb` | **18300** (API), 18404 (stats) | HAProxy 3.0, TLS passthrough, routes only to the node answering `sys/health` with 200 (the active node). |

- **Clients always use `vault-lb`:** `https://vault-lb:8200` inside
  `durin-internal`, `https://127.0.0.1:18300` from the host. The per-node
  ports are for administration and failover testing only.
- **Standbys show DOWN in HAProxy by design** (health 429/473). During a
  leader change the backend retries idempotent Vault calls three times (after
  0.5 s, 1.5 s and 3 s), then fails closed with `503`. Key rotation and config
  are not retried. `make vault-failover-test` proves this: it
  stops the leader under load and expects a new leader, clean `503`s at most,
  and a rejoin.
- **TLS** comes from Durin's own CA (`make gen-certs`,
  `scripts/vault-gen-certs.sh --reissue-server` to add SANs); clients trust
  `vault-tls/ca-chain.pem`.
- **Bootstrap** is `make vault-bootstrap`: initialise vault-s, unseal it,
  initialise the cluster with transit auto-unseal, join the Raft peers and
  enable the file audit device. The root token lands in
  `.secrets/vault/cluster-init.json` (gitignored; local lab only).
- **Status:** `make vault-status`, `make vault-lb-stats`, or the Web Console's
  **Vault** page (`GET /api/v1/vault/status`, built from unauthenticated
  `sys/health`, `sys/seal-status`, `sys/leader` and HAProxy stats).

## Configuration as code

Terraform in `terraform/` (state under `.secrets/terraform/`, gitignored):

| Module | Make target | Owns |
| --- | --- | --- |
| `vault-platform` | `make tf-apply` | AppRole + JWT auth, all policies, JWT roles, identity group `durin-security-admins`, KV `secret/`, namespaces, file audit |
| `vault-transit` | `make tf-transit` | `transit/` mount, 9 tenant keys, tenant Transit policies |
| `vault-database` | `make tf-database` | `database/` mount, PostgreSQL connection, role `durin-app` (after `make db-migrate`) |

Shield raises `min_decryption_version` at runtime, so Terraform ignores that
field's drift on purpose.

## Auth methods

### `auth/jwt`: people (Keycloak realm `durin`)

Trusts Keycloak's JWKS (`http://keycloak:8080/realms/durin/…`) and issuer
`http://localhost:8083/realms/durin`. Audience must be `durin-backend`.
`preferred_username` is mapped into the entity metadata, which is why Vault's
audit log names **raymon**, not the application.

| Role | Bound claims (checked by Vault) | Policies | Token TTL |
| --- | --- | --- | --- |
| `tenant-<t>` | `durin_tenants` ∋ `<t>` or `*`; `realm_access.roles` ∋ `durin-operator` | `durin-transit-<t>`, `durin-keys-<t>` | **300 s**, explicit max |
| `breakglass-requester-<t>` | `durin_tenants` ∋ `<t>` or `*`; role viewer or operator (**not** security-admin) | `durin-breakglass-request-<t>` | 900 s (the control-group wrapping token is its child) |
| `breakglass-approver` | `realm_access.roles` ∋ `durin-security-admin` | `durin-breakglass-approver` | 120 s |

`bound_claims_type = "string"` makes `*` in `durin_tenants` a literal value
that Keycloak grants only to all-tenant users. It is not a glob.

### `auth/approle`: workloads

| Role | Used by | Policies | Why |
| --- | --- | --- | --- |
| `durin-backend` / `durin-agent` | Vault Agent for the backend (the "broker") | `durin-backend` (Transit key **metadata** read), `durin-database` | Inspector and Vault pages show key versions; the API needs DB credentials. No data authority. |
| `durin-rotator` | `vault-rotator` | rotate the backend's secret-id | secret-id at 60 of 90 days, before expiry |
| `durin-identity-secrets` | `identity-secrets-init` (one-shot) | read `secret/data/durin/identity/*` | renders LDAP/Keycloak/user secrets, then revokes its token |
| `durin-ui` | `ui-secrets-init` (one-shot) | read `secret/data/durin/identity/oidc-client-secret` only | the Web Console BFF's OIDC client secret |

## Policies (least privilege)

| Policy | Grants | Does **not** grant |
| --- | --- | --- |
| `durin-transit-<t>` | `encrypt`, `decrypt`, `rewrap` on `durin-<t>-customer-data` and `-documents`; `encrypt`, `rewrap` on `-restricted` | decrypt on `-restricted`; anything of another tenant |
| `durin-keys-<t>` | read, `rotate`, `config` (only `min_decryption_version`) on `durin-<t>-*` | export, delete, `deletion_allowed`, other tenants |
| `durin-breakglass-request-<t>` | `decrypt` on `durin-<t>-restricted`, **with a control group** (15 min, 1 approval from identity group `durin-security-admins`) | anything else |
| `durin-breakglass-approver` | `sys/control-group/authorize`, `sys/control-group/request` | any data path |
| `durin-backend` | read `transit/keys/*` metadata | encrypt, decrypt, rewrap, rotate, config |
| `durin-database` | `database/creds/durin-app` | the database root credential |

Keys are `exportable = false`, `allow_plaintext_backup = false`,
`deletion_allowed = false`. Key material never leaves Vault.

## Engines

- **`transit/`**: 9 keys `durin-<tenant>-{customer-data, documents, restricted}`,
  `aes256-gcm96`. See [transit.md](transit.md).
- **`database/`**: dynamic PostgreSQL users `IN ROLE durin_app`, 1 h default
  TTL, owned objects reassigned on revocation. See [database.md](database.md).
- **`secret/`** (KV v2): identity-stack secrets under `durin/identity/*`,
  generated by `scripts/identity-secrets.sh`. See [identity.md](identity.md).

## Control Groups (break glass)

Only a requester token can ask for a restricted decrypt. When it does, Vault
returns a **response-wrapping token** instead of plaintext. A security admin
authorises that request in Vault (`sys/control-group/authorize`); the Vault
identity group decides who qualifies, not the application. The requester
then unwraps exactly once. Vault itself enforces the 15-minute window,
single release and approver membership. See [break-glass.md](break-glass.md).

## Namespaces

`acme`, `globex` and `initech` namespaces exist (Enterprise). Isolation today
is enforced by **per-tenant policies and keys in the root namespace**, not by
namespaces. Moving tenants into their own namespaces would need one JWT
mount and Transit mount per namespace. This is noted as future work (see
[multi-tenancy.md](multi-tenancy.md)).

## Audit

- **Vault:** a file audit device on every node (`/vault/logs/audit.log`, JSON,
  HMAC'd values, `hmac_accessor = true`). Because `vault-lb` routes to the
  active node, data operations appear in the leader's log.
- **Durin:** each `audit_events` row carries `metadata.authority.accessor`
  (HMAC-comparable) and the Vault entity's username, which correlates the
  application's record with Vault's.

## Licence

Enterprise features (Control Groups, namespaces, performance standbys)
need `VAULT_LICENSE` in `.env`. `scripts/vault-check-entitlement.sh` reports
what the licence covers.

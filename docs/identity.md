# Durin Identity

Who is calling, and what may they do? This page covers people. Cryptographic
authority (what Vault will do for a request) is a separate layer, described in
[security-model.md](security-model.md).

## Components

| Component | Role | Address |
| --- | --- | --- |
| OpenLDAP | identity store: users, groups, tenant scope | `ldap://openldap:389` (internal) |
| Keycloak 26.6 | OIDC provider, realm `durin`, LDAP-federated (read-only) | <http://localhost:8083> |
| phpLDAPadmin | directory browser | <http://localhost:8084> |
| Vault KV | every identity secret | `secret/durin/identity/*` |

Topology comes from Arcanium. The secrets-in-Vault pattern comes from Editors
Factory. Specs: `prompts/security/17_01` and `17_02`.

## Users

| User | Role | Tenants (`durin_tenants`) |
| --- | --- | --- |
| `raymon` | `durin-operator` | `*` |
| `barend` | `durin-operator` | `acme` |
| `security-admin` | `durin-security-admin` | `*` |
| `viewer` | `durin-viewer` | `acme`, `globex` |

- LDAP group membership → Keycloak **realm role** (`role-ldap-mapper`) → `realm_access.roles`.
- LDAP `businessCategory` → user attribute → `durin_tenants` claim (multi-valued).
- Every token carries `aud: durin-backend`, and the backend checks it.

## Secrets live in Vault

Nothing secret is in `.env`, `bootstrap.ldif` or git.

```text
scripts/identity-secrets.sh ──► Vault KV secret/durin/identity/
                                 ldap-admin-password, keycloak-admin-password,
                                 oidc-client-secret, users/<uid>
identity-secrets-init (one-shot, AppRole durin-identity-secrets, via vault-lb)
   └─► identity-secrets volume ──► openldap        (LDAP_ADMIN_PASSWORD_FILE)
                                ──► ldap-bootstrap  (ldappasswd per user)
                                ──► keycloak        (vault-entrypoint.sh → KC_BOOTSTRAP_ADMIN_*)
                                ──► keycloak-bootstrap (LDAP bind, client secret)
   └─► revokes its own token
```

The init container's AppRole credentials are two files in `.secrets/vault/`
(gitignored), mounted individually. The directory itself, which also holds
the root token, is never mounted.

## Operating it

```bash
make identity-bootstrap                          # idempotent: secrets → LDAP → passwords → realm
make identity-verify                             # every user logs in; roles, tenants, audience
./scripts/identity-secrets.sh --show-user raymon # a login password (local lab)
./scripts/identity-secrets.sh --rotate-user raymon && make identity-bootstrap
```

A browser login (the Web Console, later phase) uses client `durin-backend`
(confidential, Authorization Code + PKCE). Scripted tests use `durin-cli`
(public, password grant). That client is **local lab only**; remove it
outside the lab.

## Backend enforcement

`.env`: `DURIN_AUTH_ENABLED=true`, JWKS from `http://keycloak:8080/…/certs`,
issuer `http://localhost:8083/realms/durin`, audience `durin-backend`.

- Token checks: the signature (RS256/PS256/ES256 only; `alg: none` is refused),
  expiry, issuer and audience. Any failure is 401.
- Role checks (Prompt 17 matrix): a missing role is 403 `forbidden`.
- Tenant checks: an `x-tenant` value not in `durin_tenants` is 403 `tenant_mismatch`.
- Recovery: plaintext requires `durin-operator`. Break-glass approval
  requires `durin-security-admin`, and the approver can't be the requester.
- The `x-durin-actor` header is ignored; the actor in every audit event is
  the token's `preferred_username`.

Demo mode (`DURIN_AUTH_ENABLED=false`) still exists for running without the
identity stack. It isn't an access control.

## Vault trusts the person too

The same access token is what Vault sees. `auth/jwt` (prompts/improvements/01_04)
validates it against Keycloak's JWKS and issues authority only when the bound
claims match:

| Vault role | Who | Grants |
| --- | --- | --- |
| `tenant-<t>` | operators of tenant `<t>` (or `*`) | data + key lifecycle for `<t>`, 5 min |
| `breakglass-requester-<t>` | viewers and operators of `<t>` | ask for a RESTRICTED decrypt (Control Group) |
| `breakglass-approver` | security-admins (Vault group `durin-security-admins`) | authorise Control Groups |

Vault's audit log therefore records the person (`auth.metadata.username`) on
every decrypt.

Verified by `make identity-verify` (14 checks), `make rbac-test` (66) and
`make authority-test` (23).

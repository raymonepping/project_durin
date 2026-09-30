# Durin Operations Guide

Operational procedures for the Durin Vault Enterprise Data Protection
Reference Application.

---

## 1. AppRole SecretID Rotation

### Background

The Durin backend authenticates to Vault using AppRole. An AppRole login
requires two credentials:

- `role_id` — stable, non-secret, embeds in config
- `secret_id` — rotatable, 90-day TTL by default

**The `vault-rotator` sidecar handles rotation automatically.** It runs in
`compose/vault/compose.yaml` alongside `durin-vault-agent` and, every 12
hours, asks Vault about the secret-id on disk: it rotates when Vault says it
is invalid or has less than a third of its real lifetime left, issues exactly
one new secret-id, destroys the one it replaced, and logs a warning if Vault
issues a shorter life than the role's 90 days.

Why it reads Vault instead of counting days (2026-09-30): the AppRole mount
inherited the server-wide `max_lease_ttl = "168h"`, so every "90-day"
secret-id silently lived 7 days, and the old 60-day schedule could never
catch that (the live one was due to expire 2026-10-06 while the rotator
reported 58 days left). The mount is now tuned to 90 days in
`terraform/vault-platform/auth.tf`. The old rotator also issued two
secret-ids per rotation; three valid orphans were found and destroyed.

**Vault Agent heals a dead token on its own.** Its entrypoint runs a watchdog
that restarts the agent after three consecutive rejections of its token by
Vault (an unreachable Vault is not counted); the fresh agent logs in again and
renders new `db-creds.json`, which the backend picks up. Proven: 111 s from a
revoked token to a healthy backend, with no manual step.

The information below covers:
- How to verify the rotator is working
- How to detect impending expiry
- Emergency manual rotation when the rotator fails

---

### Verifying automatic rotation

```bash
# Check vault-rotator health and recent logs
podman logs --tail=50 durin-vault_rotator

# Expected healthy output:
# [vault-rotator] ... current secret-id is healthy (age: N days, next rotation in M days)

# Check the metadata file (contains accessor, created_at, last rotation)
podman exec durin-vault_rotator cat /run/approle/metadata.json
```

---

### Detecting upcoming expiry

The `access_token_hash` in the metadata file records `created_at_epoch`.

```bash
# Read the creation timestamp
CREATED=$(podman exec durin-vault_rotator \
  sh -c "grep created_at_epoch /run/approle/metadata.json | sed 's/[^0-9]*//g'")
NOW=$(date +%s)
AGE_DAYS=$(( (NOW - CREATED) / 86400 ))
REMAINING_DAYS=$(( 90 - AGE_DAYS ))
echo "SecretID age: ${AGE_DAYS} days, expires in: ${REMAINING_DAYS} days"
```

The rotator will automatically rotate at day 60. No action required unless
the rotator itself has stopped or failed.

---

### Detecting when SecretID has already expired

If vault-agent cannot re-authenticate:

```bash
# Signs of SecretID expiry:
podman logs durin-vault_agent | grep -i "permission denied\|secret_id"
# Expected error: "permission denied" or "invalid secret_id"

# Check the backend health endpoint
curl -sf http://localhost:3001/api/v1/health | python3 -m json.tool
# token_stale signals vault-agent has no valid token
# { "vault": { "status": "token_stale" } }
```

---

### Emergency manual rotation

Use this procedure when the rotator is down and the SecretID has expired
or is about to expire:

```bash
# 1. Get a Vault root (or admin) token
export VAULT_ADDR=https://127.0.0.1:18300        # vault-lb → the active node (18200-18202 per node; 18190 is vault-s, unseal only)
export VAULT_CACERT=vault-tls/ca-chain.pem
export VAULT_TOKEN=$(jq -r .root_token .secrets/vault/cluster-init.json)

# 2. Generate a new SecretID for durin-backend
NEW_SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/durin-backend/secret-id)
if [ -z "$NEW_SECRET_ID" ]; then
  echo "ERROR: Could not generate new secret-id"; exit 1
fi

# 3. Write it into the shared volume (vault-rotator manages this path)
# Use a temp container since vault-rotator owns the volume
podman run --rm \
  -v durin-vault_vault-approle-credentials:/run/approle \
  alpine:3.20 \
  sh -c "printf '%s' '$NEW_SECRET_ID' > /run/approle/secret-id.tmp && \
         mv /run/approle/secret-id.tmp /run/approle/secret-id && \
         chmod 600 /run/approle/secret-id && echo done"

# 4. Restart vault-agent — it will pick up the new secret-id
podman restart durin-vault_agent

# 5. Wait for vault-agent to authenticate (up to 30s)
sleep 10
curl -sf http://localhost:3001/api/v1/health | python3 -m json.tool

# 6. Update .env with the new secret-id so it survives stack restart
# Edit .env: DURIN_VAULT_SECRET_ID=<new value>
# (Regenerate via: make vault-admin-bootstrap to get a clean set)
```

---

### Shortening TTL for testing

To test rotation quickly, reduce `secret_id_ttl` in Terraform (the rotator rotates below 1/3 of the remaining life), or delete `/run/approle/metadata.json` in the rotator container and restart it to force one:

```hcl
# terraform/vault-platform/auth.tf
resource "vault_approle_auth_backend_role" "durin_backend" {
  secret_id_ttl = "10m"  # 10 minutes — testing only
  ...
}
```

```bash
make tf-apply  # applies the change

# Watch the rotator detect and rotate
podman logs -f durin-vault_rotator | grep secret-id
# Expected within ~8 minutes (80% of 10m):
# [vault-rotator] current secret-id age (480s) exceeds rotation threshold
# [vault-rotator] Successfully rotated secret-id
```

---

## 2. Dynamic Database Credential Lifecycle

Database credentials are issued by Vault on startup and automatically
rotated by `vault-agent` before expiry. The backend tracks TTL and
proactively rotates the connection pool at 80% of TTL.

### Monitoring credential health

```bash
# Check credential TTL via health endpoint
curl -sf http://localhost:3001/api/v1/health | python3 -m json.tool
# {
#   "db": {
#     "connected": true,
#     "credential_ttl_remaining": 2847,
#     "credential_expires_at": "2026-01-01T14:30:00.000Z"
#   }
# }

# Watch credential rotation in backend logs
podman logs -f durin-backend | grep db-creds
# [db-creds] issued: lease=... ttl=3600s expires=...
# [db-creds] rotating: 80% TTL elapsed
# [db-creds] rotated: new lease=... ttl=3600s
```

### Forcing a rotation for testing

```bash
# Shorten TTL in terraform/vault-database/database.tf:
# default_ttl = "5m"
# max_ttl     = "10m"
make tf-database

# Restart backend to pick up short-TTL creds
./scripts/compose.sh backend down && ./scripts/compose.sh backend up -d

# Watch logs
podman logs -f durin-backend | grep db-creds
# Expected over ~4 minutes:
# [db-creds] issued: ... ttl=300s
# [db-creds] rotating: 80% TTL elapsed
# [db-creds] rotated: new lease=...
```

---

## 3. Vault Token Staleness

### What it looks like

If vault-agent's token expires before it can renew (e.g., Vault was
unavailable for longer than `token_max_ttl = 24h`):

```bash
curl -sf http://localhost:3001/api/v1/health | python3 -m json.tool
# { "vault": { "status": "token_stale", "ok": false } }
```

Backend operations return:
```json
{ "error": "vault_unavailable", "message": "..." }
```
with HTTP 503 — **not** a misleading 403.

### Recovery

```bash
# Vault-agent will re-authenticate automatically when Vault is reachable.
# If vault-agent itself has exited (restart: on-failure handles this):
podman ps | grep vault_agent   # check if running
podman restart durin-vault_agent

# Wait for recovery
sleep 15
curl -sf http://localhost:3001/api/v1/health
```

---

## 4. Full Stack Recovery After Extended Downtime

If the entire stack has been stopped for longer than 90 days (secret-id TTL):

```bash
# 1. Start infrastructure
make vault-up
make infra-up

# 2. Unseal vault-s (Shamir-sealed)
make unseal

# 3. Emergency SecretID rotation (secret-ids have expired)
#    See Section 1 — Emergency manual rotation above

# 4. Schema (idempotent; the backend refuses to start on a stale schema)
make db-migrate

# 5. Start remaining services
make backend-up

# 6. Verify
make verify
```

---

## 5. Useful Diagnostic Commands

```bash
# Full stack status
make status

# Backend health (Vault + DB)
curl -sf http://localhost:3001/api/v1/health | python3 -m json.tool

# Vault cluster health
make vault-status

# Rotator status
podman logs --tail=20 durin-vault_rotator

# Agent token file age and content (never log the token itself)
podman exec durin-vault_agent \
  sh -c "[ -s /vault/secrets/token ] && echo 'token: present' || echo 'token: MISSING'"

# Hardening test suite
make hardening-test
```

---

## 6. Schema migrations

The backend's database role (`durin_app`) can't run DDL. Apply schema
changes as the owner role:

```bash
make db-migrate          # bootstrap roles → pending migrations as durin_owner → grants
make db-migrate-status
```

The backend fails fast at startup with `database schema is behind … run
'make db-migrate'` if a migration is missing. See [database.md](database.md).

## 7. Stuck dynamic database users

If Vault logs `failed to revoke lease … cannot be dropped because some objects
depend on it (SQLSTATE 2BP01)`, a dynamic user owns objects. The current
revocation statements (`REASSIGN OWNED … DROP OWNED … DROP ROLE`) prevent
this. For leases that are already stuck:

```bash
# Current lease — do NOT revoke this one:
curl -s localhost:3001/api/v1/health | jq -r .db.credential_accessor
vault list sys/leases/lookup/database/creds/durin-backend-role
vault lease revoke -sync database/creds/durin-backend-role/<stale-lease-id>
```

## 8. Scoped Vault authority

```bash
curl -s localhost:3001/api/v1/health | jq '.vault | {policies, scoped_authority}'
# Revoke one tenant's outstanding data token (it is re-minted on next use):
vault token revoke -accessor <accessor>
```

Vault HMACs accessors in its audit log. To find an application audit
event's accessor in the Vault log, hash it first:

```bash
vault write -field=hash sys/audit-hash/file input=<accessor>
```

## 9. Vault load balancer (vault-lb)

All Vault clients (backend, Vault Agent, vault-rotator, Terraform, test
scripts) use one endpoint:

| From | Address |
| --- | --- |
| containers | `https://vault-lb:8200` |
| host | `https://127.0.0.1:18300` |
| stats (read-only) | <http://127.0.0.1:18404/stats> |

- **TCP passthrough.** Vault terminates TLS; clients verify the Vault
  certificate (SAN `vault-lb`) against the Durin CA. HAProxy never sees tokens.
- **Active node only.** The health check `GET /v1/sys/health` passes only on
  the leader (200). In the stats page and `make vault-lb-stats`, standbys
  show **DOWN** (429/473). That's intended; it doesn't mean they're broken.
- **Failover.** When the leader stops, a standby wins the election, starts
  passing the check within about 4 s, and HAProxy cuts old sessions
  (`on-marked-down shutdown-sessions`). The backend retries idempotent Vault
  calls (0.5 s / 1.5 s / 3 s backoff), so requests slow down during the
  election instead of failing. Rotation and key config aren't retried.
- **Node names are re-resolved at runtime** (`resolvers podman`), so
  recreating a Vault container doesn't strand HAProxy on an old IP.
- **Per-node access** is unchanged for administration: `:18200/18201/18202`
  (vault-1/2/3) and `:18190` (vault-s).

```bash
make vault-lb-stats          # which node is serving
make vault-failover-test     # stop the leader under load; expects 0 failed requests
```

Adding a SAN to the Vault certificate (the CA is unchanged; nodes reload on
SIGHUP):

```bash
vi scripts/vault-tls.cnf
./scripts/vault-gen-certs.sh --reissue-server
```

SIGHUP also logs `license reload triggered but license path is empty`. This
is harmless: the license is supplied via `VAULT_LICENSE`.

## 10. Identity stack

See [identity.md](identity.md).

```bash
make identity-bootstrap        # idempotent; secrets come from Vault KV
make identity-verify
./scripts/identity-secrets.sh --show-user <raymon|barend|security-admin|viewer>
```

Keycloak's `KC_HOSTNAME` must be a full URL (`http://localhost:8083`). A bare
`localhost:8083` makes Keycloak 26.6 refuse to start ("Provided hostname is
neither a plain hostname nor a valid URL").

## 11. Web Console (durin-ui)

The console is a Nuxt 4 SPA served by its own Nitro server, which is also the
backend-for-frontend: it holds the OIDC client secret and every user's tokens
server-side. The browser gets only the httpOnly `durin_sid` cookie. Design:
[frontend/config/DESIGN.md](frontend/config/DESIGN.md). Contract:
[api/API_CONTRACTS.md § Web Console BFF](api/API_CONTRACTS.md).

```bash
make tf-apply            # once: AppRole durin-ui + policy durin-ui-secrets
make identity-bootstrap  # Keycloak client durin-backend gets its secret from Vault KV
make ui-rebuild          # build image, issue ui-secret-id, (re)start → http://localhost:3000
make test-frontend       # J0–J9 + a11y (starts with make reset)
make ui-dev              # hot reload on the host (needs backend + identity running)
```

Secret flow: `ui-secrets-init` logs in with AppRole `durin-ui` (read on
`secret/data/durin/identity/oidc-client-secret` only), writes the secret to
the `ui-secrets` volume, revokes its own token and exits. `durin-ui` mounts
that volume read-only and never holds a Vault token.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `/login?error=token_exchange_failed`; Keycloak logs `CODE_TO_TOKEN_ERROR invalid_client_credentials` | Keycloak client secret ≠ Vault KV value | `./scripts/compose.sh identity --profile init run --rm keycloak-bootstrap`, then sign in again |
| `503 oidc_client_secret_missing` | `ui-secrets-init` did not run or failed | `podman logs durin-ui-secrets-init`; `make ui-rebuild` (re-issues `ui-secret-id`) |
| Everyone signed out after a rebuild | Sessions are in the container's memory | expected; sign in again |
| Page renders but data calls return 401 | Backend rejected the token (expired refresh, realm reset) | sign out/in; the BFF drops the session on a backend 401 |

## 12. Clock drift after the laptop sleeps

> **Fixed at the root (2026-09-30):** the Podman VM's chrony now uses
> `makestep 1.0 -1` (was `1.0 3`, which forbade stepping after boot, so a
> paused VM never caught up). The VM corrects itself after sleep. The steps
> below remain for a re-initialised Podman machine, until the setting is
> re-applied there (`podman machine ssh`, edit `/etc/chrony.conf`,
> `sudo systemctl restart chronyd`).

The Podman VM's clock can stall while the Mac sleeps (seen: 9 h 41 min
behind). Vault, PostgreSQL and Keycloak share that clock, so security
decisions stay consistent, and the console keeps server time for its
countdowns. Dates and timestamps are wrong, though, and fixing the clock
expires every live lease at once.

```bash
echo "host $(date -u +%T)  vm $(podman machine ssh date -u +%T)"   # compare
podman machine ssh "sudo date -u -s @$(date +%s)"                  # set the VM clock
podman restart durin-vault_agent      # the old DB lease expired: render fresh credentials
podman restart durin-backend          # reconnect with them
make verify
```

Symptom if Vault Agent is not restarted: the backend crash-loops with
`password authentication failed for user "v-approle-durin-ba-…"`.

After a full `make down`, `vault-s` starts sealed and its healthcheck blocks
the cluster. Fixed: `make vault-up` (and so `make up`) now starts `vault-s`
alone, unseals it, then starts the rest.

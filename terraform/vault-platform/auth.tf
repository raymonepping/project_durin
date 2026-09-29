# ── AppRole auth method ───────────────────────────────────────────────────────

resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

# Role used by the Durin backend service (via Vault Agent) to authenticate.
#   durin-backend  — broker: mints per-tenant / break-glass tokens, key lifecycle
#   durin-database — reads its own dynamic PostgreSQL credential
# No Transit data authority and no administrative authority on this token.
resource "vault_approle_auth_backend_role" "durin_backend" {
  backend        = vault_auth_backend.approle.path
  role_name      = "durin-backend"
  token_policies = [vault_policy.durin_backend.name, vault_policy.durin_database.name]
  token_ttl      = 3600    # 1 hour — matches DB dynamic cred TTL
  token_max_ttl  = 14400   # 4 hours
  secret_id_ttl  = 7776000 # 90 days — vault-rotator renews at 60 days
}

# Legacy role — not used by the running stack (Vault Agent logs in as
# durin-backend, whose secret-id vault-rotator manages). Kept for existing
# role_id references; carries the same non-admin broker authority.
resource "vault_approle_auth_backend_role" "durin_agent" {
  backend        = vault_auth_backend.approle.path
  role_name      = "durin-agent"
  token_policies = [vault_policy.durin_backend.name, vault_policy.durin_database.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
  secret_id_ttl  = 7776000
}

# Role used by the vault-rotator sidecar to generate fresh secret-ids for
# durin-backend before the 90-day TTL expires.
# Periodic token so the sidecar runs indefinitely without hitting max_ttl.
# secret_id_ttl = 0: the rotator's own bootstrap secret-id is seeded once
# via .env (ROTATOR_SECRET_ID) and never expires.
resource "vault_approle_auth_backend_role" "durin_rotator" {
  backend        = vault_auth_backend.approle.path
  role_name      = "durin-rotator"
  token_policies = [vault_policy.durin_rotator.name]
  token_ttl      = 3600
  token_max_ttl  = 86400
  token_period   = 86400
  secret_id_ttl  = 0
}

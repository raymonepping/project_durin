-- migrations/003_authority_model.sql
-- Applied by scripts/db-migrate.sh as durin_owner (never by the backend).
--
-- Supports the Vault-enforced authority model:
--   - tenants.fortified_at            Shield/Fortify completed for this tenant
--   - break_glass_requests.vault_*    Vault token issued on approval (accessor only)
--   - compromise_snapshots            ciphertext "stolen" during the Compromise scenario

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS fortified_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE break_glass_requests
  ADD COLUMN IF NOT EXISTS vault_token_accessor VARCHAR(64),
  ADD COLUMN IF NOT EXISTS vault_policy         VARCHAR(100),
  ADD COLUMN IF NOT EXISTS denied_by            VARCHAR(200),
  ADD COLUMN IF NOT EXISTS revoked_at           TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS revoked_by           VARCHAR(200);

-- The attacker's copy of the database. Ciphertext and metadata only — exactly
-- what a PostgreSQL dump would contain. Used to prove, before and after
-- Shield/Fortify, what that stolen material is (not) worth.
CREATE TABLE IF NOT EXISTS compromise_snapshots (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  protected_value_id UUID,
  resource_type      VARCHAR(50)  NOT NULL,
  resource_id        UUID         NOT NULL,
  field_name         VARCHAR(100) NOT NULL,
  ciphertext         TEXT         NOT NULL,
  key_name           VARCHAR(200) NOT NULL,
  key_version        INTEGER      NOT NULL,
  captured_at        TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS compromise_snapshots_tenant_idx ON compromise_snapshots(tenant_id);

-- Demo reset marker (audit history is append-only and survives resets).
ALTER TABLE demo_state
  ADD COLUMN IF NOT EXISTS last_reset_at TIMESTAMP WITH TIME ZONE;

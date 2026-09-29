-- migrations/001_initial_schema.sql
-- Durin initial schema — applied by scripts/db-migrate.sh as durin_owner (idempotent)

-- pgcrypto is created by scripts/sql/000_bootstrap_roles.sql (needs superuser).

-- ── Tenants ───────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tenants (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name             VARCHAR(100) NOT NULL UNIQUE,
  slug             VARCHAR(50)  NOT NULL UNIQUE,
  vault_namespace  VARCHAR(100),
  created_at       TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ── Customers ─────────────────────────────────────────────────────────────────
-- Metadata in plaintext; sensitive fields (iban, tax_id, payment_info) live
-- exclusively in protected_values as vault:vX:... ciphertext.

CREATE TABLE IF NOT EXISTS customers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name        VARCHAR(200) NOT NULL,
  company     VARCHAR(200),
  country     VARCHAR(100),
  status      VARCHAR(50) DEFAULT 'active',
  created_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS customers_tenant_idx ON customers(tenant_id);

-- ── Protected values ──────────────────────────────────────────────────────────
-- All sensitive field ciphertext lives here.  Never stores plaintext.

CREATE TABLE IF NOT EXISTS protected_values (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  resource_type VARCHAR(50)  NOT NULL,
  resource_id   UUID         NOT NULL,
  field_name    VARCHAR(100) NOT NULL,
  ciphertext    TEXT         NOT NULL,
  key_name      VARCHAR(200) NOT NULL,
  key_version   INTEGER      NOT NULL,
  created_at    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE (tenant_id, resource_type, resource_id, field_name)
);

CREATE INDEX IF NOT EXISTS pv_resource_idx ON protected_values(resource_type, resource_id);
CREATE INDEX IF NOT EXISTS pv_key_name_idx ON protected_values(key_name);

-- ── Documents ─────────────────────────────────────────────────────────────────
-- Metadata plaintext; payload stored in protected_values.

CREATE TABLE IF NOT EXISTS documents (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  customer_id    UUID REFERENCES customers(id) ON DELETE SET NULL,
  name           VARCHAR(500) NOT NULL,
  content_type   VARCHAR(100),
  classification VARCHAR(50) DEFAULT 'INTERNAL',
  size_bytes     INTEGER,
  checksum       VARCHAR(64),
  created_at     TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_by     VARCHAR(200)
);

CREATE INDEX IF NOT EXISTS documents_tenant_idx ON documents(tenant_id);

-- ── Audit events ──────────────────────────────────────────────────────────────
-- Append-only.  Never updated; never deleted.

CREATE TABLE IF NOT EXISTS audit_events (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  timestamp     TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  operation     VARCHAR(100) NOT NULL,
  tenant_id     UUID REFERENCES tenants(id) ON DELETE SET NULL,
  resource_type VARCHAR(50),
  resource_id   UUID,
  field_name    VARCHAR(100),
  actor         VARCHAR(200),
  key_name      VARCHAR(200),
  key_version   INTEGER,
  result        VARCHAR(20) NOT NULL DEFAULT 'ALLOWED',
  metadata      JSONB       DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS audit_tenant_idx     ON audit_events(tenant_id);
CREATE INDEX IF NOT EXISTS audit_timestamp_idx  ON audit_events(timestamp DESC);
CREATE INDEX IF NOT EXISTS audit_operation_idx  ON audit_events(operation);

-- ── Break glass requests ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS break_glass_requests (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  requested_by  VARCHAR(200) NOT NULL,
  resource_type VARCHAR(50)  NOT NULL,
  resource_id   UUID         NOT NULL,
  reason        TEXT         NOT NULL,
  status        VARCHAR(20)  DEFAULT 'pending',
  approved_by   VARCHAR(200),
  approved_at   TIMESTAMP WITH TIME ZONE,
  expires_at    TIMESTAMP WITH TIME ZONE,
  used_at       TIMESTAMP WITH TIME ZONE,
  created_at    TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ── Demo state (single-row) ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS demo_state (
  id              INTEGER PRIMARY KEY DEFAULT 1,
  active_tenant   VARCHAR(50) DEFAULT 'acme',
  compromise_mode BOOLEAN     DEFAULT FALSE,
  fortified       BOOLEAN     DEFAULT FALSE,
  updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT single_row CHECK (id = 1)
);

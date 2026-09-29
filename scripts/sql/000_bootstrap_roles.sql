-- scripts/sql/000_bootstrap_roles.sql
--
-- Runs as the PostgreSQL management superuser (POSTGRES_USER) via
-- scripts/db-migrate.sh. Idempotent. Establishes the privilege model:
--
--   durin_owner  NOLOGIN  owns all Durin tables; migrations run as this role
--   durin_app    NOLOGIN  DML only; Vault-issued users are members of this role
--
-- Vault's dynamic users (v-approle-*) are created IN ROLE durin_app by the
-- Database secrets engine (terraform/vault-database/database.tf). They never
-- own objects, never hold direct grants and never run DDL.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'durin_owner') THEN
    CREATE ROLE durin_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'durin_app') THEN
    CREATE ROLE durin_app NOLOGIN;
  END IF;
END $$;

-- Schema privileges: only the owner role may create objects.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO durin_owner;
GRANT USAGE ON SCHEMA public TO durin_app;

-- Extensions need superuser; create here rather than inside a migration.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Repair legacy state ───────────────────────────────────────────────────────
-- Earlier builds ran migrations with the backend's own dynamic credential and
-- granted dynamic users membership in the management superuser. That left
-- tables owned by ephemeral roles (so Vault could never DROP them on lease
-- revocation) and gave every backend credential SET ROLE to a superuser.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE 'v-%' LOOP
    EXECUTE format('REASSIGN OWNED BY %I TO durin_owner', r.rolname);
    EXECUTE format('REVOKE CREATE ON SCHEMA public FROM %I', r.rolname);
    EXECUTE format('REVOKE %I FROM %I', current_user, r.rolname);
    EXECUTE format('GRANT durin_app TO %I', r.rolname);
  END LOOP;
END $$;

-- Tables created outside the owner role (e.g. by the superuser) move too.
DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND tableowner <> 'durin_owner'
  LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO durin_owner', t.tablename);
  END LOOP;
END $$;

-- Migration ledger.
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version    VARCHAR(100) PRIMARY KEY,
  applied_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
ALTER TABLE public.schema_migrations OWNER TO durin_owner;

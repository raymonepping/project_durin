-- scripts/sql/999_grants.sql
--
-- Runs as the management superuser after every migration pass. Idempotent.
-- Sets the application's data-plane privileges on the finished schema.

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO durin_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO durin_app;

ALTER DEFAULT PRIVILEGES FOR ROLE durin_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO durin_app;
ALTER DEFAULT PRIVILEGES FOR ROLE durin_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO durin_app;

-- Audit trail is append-only for the application: it may record and read
-- evidence, never rewrite or erase it. (Referential actions such as
-- ON DELETE SET NULL run with the table owner's privileges.)
REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_events FROM durin_app;

-- The migration ledger is visible to the backend (startup schema check) but
-- only the owner role may change it.
REVOKE ALL ON public.schema_migrations FROM durin_app;
GRANT SELECT ON public.schema_migrations TO durin_app;

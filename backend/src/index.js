// src/index.js — Durin backend entry point
import { readdir }      from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import express          from 'express';
import { initDbPool, query } from './db.js';
import healthRouter     from './routes/health.js';
import tenantsRouter    from './routes/tenants.js';
import customersRouter  from './routes/customers.js';
import documentsRouter  from './routes/documents.js';
import databaseRouter   from './routes/database.js';
import transitRouter    from './routes/transit.js';
import scenariosRouter  from './routes/scenarios.js';
import auditRouter      from './routes/audit.js';
import breakGlassRouter from './routes/break-glass.js';
import vaultRouter      from './routes/vault.js';
import { authenticate, requireRole, requireRoleByMethod, ROLES } from './middleware/auth.js';
import { config }       from './config.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// The backend never runs DDL — its Vault-issued database role is DML-only
// (durin_app). Migrations are applied by the operator with `make db-migrate`
// (scripts/db-migrate.sh, as durin_owner). At startup we only verify the
// schema is current and refuse to serve if it is not.
async function verifySchema() {
  const expected = (await readdir(join(__dirname, 'migrations')))
    .filter(f => /^\d{3}_.*\.sql$/.test(f))
    .map(f => f.replace(/\.sql$/, ''))
    .sort();
  let applied;
  try {
    const { rows } = await query('SELECT version FROM schema_migrations');
    applied = new Set(rows.map(r => r.version));
  } catch (err) {
    throw new Error(`schema_migrations not readable (${err.message}) — run 'make db-migrate'`);
  }
  const missing = expected.filter(v => !applied.has(v));
  if (missing.length) {
    throw new Error(`database schema is behind: missing ${missing.join(', ')} — run 'make db-migrate'`);
  }
  console.log(`[db] schema current (${expected.length} migrations)`);
}

async function main() {
  // 1. Database pool from the vault-agent-rendered dynamic credential
  await initDbPool();

  // 2. Schema must already be migrated by the owner role
  await verifySchema();

  // 3. Express app
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '10mb' }));

  app.use((req, _res, next) => {
    console.log(`[api] ${req.method} ${req.path}`);
    next();
  });

  // Inject timestamp into every success envelope's meta block.
  app.use((_req, res, next) => {
    const originalJson = res.json.bind(res);
    res.json = (body) => {
      if (body && typeof body === 'object' && body.data !== undefined && !body.error) {
        if (!body.meta) body.meta = {};
        if (!body.meta.timestamp) body.meta.timestamp = new Date().toISOString();
      }
      return originalJson(body);
    };
    next();
  });

  // ── Routes ──────────────────────────────────────────────────────────────────
  //
  // RBAC (Prompt 17) — enforced here, never only in the frontend:
  //   health                                   open (liveness for orchestration)
  //   reads: tenants/customers/documents/database/audit/transit/break-glass lists
  //                                            viewer
  //   customer + document writes               operator
  //   scenarios, key rotate/rewrap/config      operator
  //   break-glass request                      viewer (anyone signed in)
  //   break-glass approve / deny / revoke      security-admin
  //
  // Scoped Vault authority is a separate, lower layer (gateway/authority.js).

  app.use('/api/v1/health', healthRouter);
  app.use('/health', healthRouter);

  app.use('/api', authenticate);

  app.use('/api/v1/tenants',   requireRole(ROLES.VIEWER), tenantsRouter);
  app.use('/api/v1/customers', requireRoleByMethod(ROLES.OPERATOR), customersRouter);
  app.use('/api/v1/documents', requireRoleByMethod(ROLES.OPERATOR), documentsRouter);
  app.use('/api/v1/database',  requireRole(ROLES.VIEWER), databaseRouter);
  app.use('/api/v1/audit',     requireRole(ROLES.VIEWER), auditRouter);
  app.use('/api/v1/transit',   requireRoleByMethod(ROLES.OPERATOR), transitRouter);
  app.use('/api/v1/vault',     requireRole(ROLES.VIEWER), vaultRouter);

  // Scenario state is a read; everything else in /scenarios is an operator action.
  app.use('/api/v1/scenarios', (req, res, next) =>
    (req.method === 'GET' ? requireRole(ROLES.VIEWER) : requireRole(ROLES.OPERATOR))(req, res, next),
  scenariosRouter);

  app.use('/api/v1/break-glass', (req, res, next) =>
    (/^\/[^/]+\/(approve|deny|revoke)$/.test(req.path)
      ? requireRole(ROLES.SECURITY_ADMIN)
      : requireRole(ROLES.VIEWER))(req, res, next),
  breakGlassRouter);

  app.use('/api', (_req, res) => res.status(404).json({ error: 'not_found', message: 'Unknown API route' }));

  // Global error handler — consistent error envelope
  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    if (err.type === 'entity.parse.failed') {
      return res.status(400).json({ error: 'validation', message: 'Request body is not valid JSON' });
    }
    if (err.code === '22P02') {
      return res.status(400).json({ error: 'validation', message: 'Malformed identifier' });
    }
    const status  = err.status || 500;
    const errCode = err.code && typeof err.code === 'string' && !/^[0-9A-Z]{5}$/.test(err.code)
      ? err.code
      : (status === 500 ? 'internal_error' : 'error');
    if (status >= 500) console.error(`[api] error ${status} ${errCode}:`, err.message);
    const body = { error: errCode, message: status === 500 ? 'Internal error' : err.message };
    if (err.vault) body.vault = err.vault;
    if (err.authority) body.authority = err.authority;
    if (err.auditEventId) body.auditEventId = err.auditEventId;
    res.status(status).json(body);
  });

  app.listen(config.port, '0.0.0.0', () => {
    console.log(`[api] Durin backend listening on :${config.port}`);
    console.log(`[api] Vault: ${config.vault.addr}`);
    console.log(`[api] Auth: ${config.auth.enabled ? 'OIDC/JWT enforced' : 'DISABLED (demo identity)'}`);
  });
}

main().catch(err => {
  console.error('[api] fatal startup error:', err.message);
  process.exit(1);
});

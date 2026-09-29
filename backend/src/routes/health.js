// routes/health.js — liveness + the backend's own authority, made visible.
//
// `vault.policies` shows exactly what the backend's broker token can do; it
// must be [default, durin-backend, durin-database] — never durin-admin.
import { Router } from 'express';
import { vaultHealthCheck } from '../vault.js';
import { dbHealthCheck, getCredentialInfo } from '../db.js';
import { describeTenantAuthority } from '../gateway/authority.js';
import { config } from '../config.js';

const router = Router();

router.get('/', async (_req, res) => {
  const [vault, db] = await Promise.all([vaultHealthCheck(), dbHealthCheck()]);
  const cred = getCredentialInfo();

  let vaultStatus;
  if (vault.ok) vaultStatus = 'connected';
  else if (vault.tokenStale) vaultStatus = 'token_stale';
  else vaultStatus = 'unavailable';

  const status = vault.ok && db.ok ? 'ok' : 'degraded';
  res.status(status === 'ok' ? 200 : 503).json({
    status,
    auth: {
      enabled: Boolean(config.auth?.enabled),
      mode: config.auth?.enabled ? 'oidc' : 'demo',
      issuer: config.auth?.enabled ? config.auth.issuer || null : null,
    },
    vault: {
      status: vaultStatus,
      ok: vault.ok,
      accessor: vault.accessor ?? null,
      token_ttl: vault.ttl ?? null,
      role: vault.role ?? null,
      policies: vault.policies ?? [],
      scoped_authority: describeTenantAuthority(),
      ...(vault.ok ? {} : { error: vault.error }),
    },
    db: {
      connected: db.ok,
      username: db.username ?? null,
      error: db.error ?? null,
      credential_ttl_remaining: cred?.ttlRemaining ?? null,
      credential_expires_at: cred?.expiresAt ?? null,
      credential_accessor: cred?.leaseId ?? null,
    },
  });
});

export default router;

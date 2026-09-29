// src/db.js — PostgreSQL client using Vault Agent-rendered dynamic credentials.
//
// Reliability hardening (prompt hardening/02):
//
//   1. TTL awareness — reads lease_duration from db-creds.json and tracks
//      issuedAt so we always know how much time remains.
//
//   2. Pre-expiry rotation at 80% TTL — schedules a proactive pool swap
//      well before the credential expires, avoiding mid-transaction failures.
//      When vault-agent writes a new db-creds.json the fs.watch fires and
//      triggers the swap; the timer is a belt-and-suspenders fallback that
//      forces a re-read even if the watch event is missed.
//
//   3. Connection-error recovery — if a query fails with
//      "password authentication failed", we immediately obtain fresh creds
//      from vault-agent's rendered file, rebuild the pool, and retry once.
//      If the retry also fails the error is returned as-is (no infinite loop).
//
//   4. Lifecycle logging — every credential event is logged with the
//      lease accessor. The password is never logged.

import { readFile } from 'node:fs/promises';
import { watch }    from 'node:fs';
import pg           from 'pg';
import { config }   from './config.js';

const { Pool } = pg;

// ── State ─────────────────────────────────────────────────────────────────────

let pool        = null;
let credInfo    = null; // { username, leaseId, leaseDuration, issuedAt, expiresAt, ttlRemaining }
let rotateTimer = null; // handle for the pre-expiry rotation timeout

// ── Helpers ───────────────────────────────────────────────────────────────────

async function readDbCreds() {
  const raw  = await readFile(config.vault.dbCredsFile, 'utf8');
  const cred = JSON.parse(raw.trim());
  if (!cred.username || !cred.password) {
    throw new Error('db-creds.json is missing username or password');
  }
  return cred;
}

async function createPool(cred) {
  const p = new Pool({
    host:     config.postgres.host,
    port:     config.postgres.port,
    database: config.postgres.database,
    user:     cred.username,
    password: cred.password,
    max: 5,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
  });
  await p.query('SELECT 1'); // fail-fast on bad credential
  return p;
}

function buildCredInfo(cred) {
  const issuedAt  = Date.now();
  const leaseSecs = cred.lease_duration ?? 3600;
  const expiresAt = new Date(issuedAt + leaseSecs * 1000);
  return {
    username:      cred.username,
    leaseId:       cred.lease_id ?? null,
    leaseDuration: leaseSecs,
    issuedAt,
    expiresAt:     expiresAt.toISOString(),
    // ttlRemaining is computed live by getCredentialInfo()
  };
}

function schedulePreExpiryRotation(leaseDuration) {
  if (rotateTimer) clearTimeout(rotateTimer);
  // Rotate at 80% of TTL elapsed — 20% buffer before expiry
  const rotateAfterMs = Math.floor(leaseDuration * 0.8 * 1000);
  rotateTimer = setTimeout(async () => {
    const info = credInfo;
    console.log(`[db-creds] rotating: 80% TTL elapsed, lease=${info?.leaseId ?? '(unknown)'}`);
    try {
      await rotatePool();
    } catch (err) {
      console.error('[db-creds] pre-expiry rotation failed:', err.message);
    }
  }, rotateAfterMs);
  // Don't hold the process open just for the timer
  if (rotateTimer.unref) rotateTimer.unref();
}

async function rotatePool() {
  const newCred = await readDbCreds();
  if (newCred.username === credInfo?.username) {
    // vault-agent hasn't rendered new creds yet — reschedule in 30s
    console.log('[db-creds] pre-expiry check: vault-agent has not yet rendered new credentials, retrying in 30s');
    rotateTimer = setTimeout(rotatePool, 30_000);
    if (rotateTimer.unref) rotateTimer.unref();
    return;
  }
  const oldPool  = pool;
  const newPool  = await createPool(newCred);
  const newInfo  = buildCredInfo(newCred);
  pool     = newPool;
  credInfo = newInfo;
  config.dbCredentials = credInfo;
  schedulePreExpiryRotation(newInfo.leaseDuration);
  console.log(`[db-creds] rotated: new lease=${newInfo.leaseId ?? '(unknown)'} ttl=${newInfo.leaseDuration}s expires=${newInfo.expiresAt}`);
  oldPool?.end().catch(() => {});
}

// ── Public API ────────────────────────────────────────────────────────────────

export async function initDbPool() {
  const cred   = await readDbCreds();
  pool         = await createPool(cred);
  credInfo     = buildCredInfo(cred);
  config.dbCredentials = credInfo;

  console.log(`[db-creds] issued: lease=${credInfo.leaseId ?? '(unknown)'} ttl=${credInfo.leaseDuration}s expires=${credInfo.expiresAt}`);

  // Schedule pre-expiry rotation
  schedulePreExpiryRotation(credInfo.leaseDuration);

  // Watch for vault-agent writing a new db-creds.json (hot-swap on renewal)
  try {
    watch(config.vault.dbCredsFile, { persistent: false }, async (eventType) => {
      if (eventType !== 'change') return;
      try {
        const newCred = await readDbCreds();
        if (newCred.username === credInfo?.username) return; // same cred, no-op
        const oldPool = pool;
        const newPool = await createPool(newCred);
        const newInfo = buildCredInfo(newCred);
        pool     = newPool;
        credInfo = newInfo;
        config.dbCredentials = credInfo;
        schedulePreExpiryRotation(newInfo.leaseDuration);
        console.log(`[db-creds] rotated (watch): new lease=${newInfo.leaseId ?? '(unknown)'} ttl=${newInfo.leaseDuration}s`);
        oldPool?.end().catch(() => {});
      } catch (err) {
        console.error('[db-creds] watch rotation failed, keeping existing pool:', err.message);
      }
    });
  } catch {
    // fs.watch may fail in read-only container filesystems — pre-expiry timer covers this
  }

  console.log(`[db] pool initialised: ${cred.username}`);
  return pool;
}

export function getPool() {
  if (!pool) throw new Error('DB pool not initialised — call initDbPool() first');
  return pool;
}

/**
 * Execute a query with one automatic retry on credential-expiry errors.
 *
 * If PostgreSQL rejects the connection with "password authentication failed"
 * we immediately force-read fresh credentials, rebuild the pool, and retry
 * the query once.  If the retry also fails the error is propagated.
 */
export async function query(text, params) {
  try {
    return await getPool().query(text, params);
  } catch (err) {
    if (!isCredentialExpiry(err)) throw err;

    // Password auth failed — force immediate rotation
    console.error(`[db-creds] error: password auth failed, forcing rotation (lease=${credInfo?.leaseId ?? '(unknown)'})`);
    try {
      await rotatePool();
    } catch (rotErr) {
      console.error('[db-creds] forced rotation failed:', rotErr.message);
      const e = new Error('Database credential rotation failed — service unavailable');
      e.code  = 'db_credential_error';
      e.status = 503;
      throw e;
    }

    // Retry once with the new pool
    try {
      return await getPool().query(text, params);
    } catch (retryErr) {
      console.error('[db-creds] retry after rotation also failed:', retryErr.message);
      const e = new Error('Database unavailable after credential rotation');
      e.code  = 'db_unavailable';
      e.status = 503;
      throw e;
    }
  }
}

function isCredentialExpiry(err) {
  const msg = err.message?.toLowerCase() ?? '';
  return (
    msg.includes('password authentication failed') ||
    msg.includes('role') && msg.includes('does not exist') ||
    err.code === '28P01' // PostgreSQL SQLSTATE: invalid_password
  );
}

export function getCredentialInfo() {
  if (!credInfo) return null;
  const now = Date.now();
  const ttlRemaining = Math.max(0, Math.floor((new Date(credInfo.expiresAt).getTime() - now) / 1000));
  return { ...credInfo, ttlRemaining };
}

export async function dbHealthCheck() {
  if (!pool) return { ok: false, error: 'pool not initialised' };
  try {
    await getPool().query('SELECT 1');
    const info = getCredentialInfo();
    return { ok: true, username: credInfo?.username, ttlRemaining: info?.ttlRemaining };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

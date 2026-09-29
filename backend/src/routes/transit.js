// routes/transit.js — Transit key lifecycle
//
// Key metadata, rotation and the decryption floor use the backend's broker
// authority. Rewrap runs under the tenant's scoped authority (Vault re-encrypts
// internally; plaintext never reaches the backend). Key material is never
// returned — keys are exportable=false and the broker policy has no export path.
import { Router } from 'express';
import { query }  from '../db.js';
import { vaultGetKeyInfo } from '../vault.js';
import * as gateway from '../gateway/index.js';
import { resolveTenant } from '../middleware/tenant.js';
import { actorOf } from '../middleware/auth.js';

const router = Router();

function tenantKeyNames(slug) {
  return gateway.KEY_TYPES.map(t => gateway.resolveKeyName(slug, t));
}

async function distribution(tenant, keyName, currentVersion) {
  const { rows } = await query(
    `SELECT key_version, COUNT(*)::int AS count FROM protected_values
     WHERE key_name = $1 AND tenant_id = $2 GROUP BY key_version ORDER BY key_version`,
    [keyName, tenant.id],
  );
  const dist = {};
  for (let v = 1; v <= currentVersion; v++) dist[`v${v}`] = 0;
  for (const r of rows) dist[`v${r.key_version}`] = r.count;
  return dist;
}

// ── GET /keys — the tenant's keys ─────────────────────────────────────────────

router.get('/keys', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const data = [];
    for (const keyName of tenantKeyNames(tenant.slug)) {
      try {
        const info = await vaultGetKeyInfo(keyName);
        data.push({ ...info, keyType: gateway.keyTypeFromKeyName(tenant.slug, keyName),
          ciphertextDistribution: await distribution(tenant, keyName, info.currentVersion) });
      } catch (err) {
        data.push({ name: keyName, error: err.code ?? 'unavailable' });
      }
    }
    res.json({ data, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── GET /keys/:name ───────────────────────────────────────────────────────────

router.get('/keys/:name', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const keyType = gateway.keyTypeFromKeyName(tenant.slug, req.params.name);
    const info = await vaultGetKeyInfo(req.params.name);
    res.json({
      data: { ...info, keyType, ciphertextDistribution: await distribution(tenant, req.params.name, info.currentVersion) },
      meta: { tenant: tenant.slug },
    });
  } catch (err) { next(err); }
});

// ── POST /keys/:name/rotate ───────────────────────────────────────────────────

router.post('/keys/:name/rotate', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const keyType = gateway.keyTypeFromKeyName(tenant.slug, req.params.name);
    const result = await gateway.rotate({ tenantId: tenant.id, tenantSlug: tenant.slug, keyType, actor: actorOf(req) });
    res.json({ data: result, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── POST /keys/:name/rewrap — rewrap all tenant values under this key ────────

router.post('/keys/:name/rewrap', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const keyType = gateway.keyTypeFromKeyName(tenant.slug, req.params.name);
    const result = await rewrapKey(tenant, keyType, actorOf(req));
    res.json({ data: result, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

export async function rewrapKey(tenant, keyType, actor) {
  const keyName = gateway.resolveKeyName(tenant.slug, keyType);
  const { rows } = await query(
    `SELECT id, resource_type, resource_id, field_name, ciphertext, key_version
     FROM protected_values WHERE key_name = $1 AND tenant_id = $2`,
    [keyName, tenant.id],
  );
  const before = {};
  let rewrapped = 0;
  for (const pv of rows) {
    before[`v${pv.key_version}`] = (before[`v${pv.key_version}`] ?? 0) + 1;
    const { ciphertext, keyVersion } = await gateway.rewrap({
      tenantId: tenant.id, tenantSlug: tenant.slug, keyType,
      resourceType: pv.resource_type, resourceId: pv.resource_id, fieldName: pv.field_name, actor,
    }, pv.ciphertext);
    await query('UPDATE protected_values SET ciphertext=$1, key_version=$2, updated_at=NOW() WHERE id=$3',
      [ciphertext, keyVersion, pv.id]);
    rewrapped++;
  }
  const info = await vaultGetKeyInfo(keyName);
  return { keyName, rewrapped, currentVersion: info.currentVersion, before,
    after: await distribution(tenant, keyName, info.currentVersion), plaintextExposedToApplication: false };
}

// ── POST /keys/:name/min-decryption-version ───────────────────────────────────
// Raising the floor makes older ciphertext unrecoverable by ANY token —
// including a stolen copy of the database. Refuses to strand live data: every
// stored value for this key must already be at or above the requested floor.

router.post('/keys/:name/min-decryption-version', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const keyType = gateway.keyTypeFromKeyName(tenant.slug, req.params.name);
    const target = req.body?.min_decryption_version;
    if (!Number.isInteger(target) || target < 1) {
      return res.status(400).json({ error: 'validation', message: 'min_decryption_version (integer ≥ 1) is required' });
    }
    const info = await vaultGetKeyInfo(req.params.name);
    if (target > info.currentVersion) {
      return res.status(400).json({ error: 'validation', message: `cannot exceed current version ${info.currentVersion}` });
    }
    const { rows } = await query(
      'SELECT COUNT(*)::int AS c FROM protected_values WHERE key_name=$1 AND tenant_id=$2 AND key_version < $3',
      [req.params.name, tenant.id, target],
    );
    if (rows[0].c > 0) {
      return res.status(409).json({
        error: 'would_strand_data',
        message: `${rows[0].c} stored value(s) are below v${target} — rewrap first`,
      });
    }
    const result = await gateway.setMinDecryptionVersion(
      { tenantId: tenant.id, tenantSlug: tenant.slug, keyType, actor: actorOf(req) }, target);
    res.json({ data: result, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

export default router;

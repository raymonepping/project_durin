// routes/database.js — Database Inspector
//
// Three views of the same protected record:
//   applicationView — what an authorised caller gets back through the gateway
//   databaseView    — exactly what PostgreSQL stores (ciphertext, never decrypted)
//   vaultState      — the Transit key(s) involved and who may recover each field
//
// Plus a raw table browser: PostgreSQL rows as stored, for the "the database
// is visible" part of the demo. Nothing here decrypts except applicationView.
import { Router } from 'express';
import { query }  from '../db.js';
import { vaultGetKeyInfo } from '../vault.js';
import * as gateway from '../gateway/index.js';
import { resolveTenant } from '../middleware/tenant.js';
import { actorOf, canRecover } from '../middleware/auth.js';
import { isBinaryType } from './documents.js';

const router = Router();

function recoveryAuthority(keyType) {
  return keyType === 'restricted'
    ? { requires: 'break-glass', vaultPolicy: 'durin-breakglass-request-<tenant>', mechanism: 'vault-control-group', normalPath: 'denied by Vault' }
    : { requires: 'operator', vaultPolicy: 'durin-transit-<tenant>', vaultRole: 'auth/jwt tenant-<tenant>', normalPath: 'allowed' };
}

async function vaultStateFor(tenantSlug, keyNames) {
  const state = {};
  for (const keyName of keyNames) {
    try {
      const info = await vaultGetKeyInfo(keyName);
      const keyType = gateway.keyTypeFromKeyName(tenantSlug, keyName);
      state[keyName] = {
        ...info,
        recovery: {
          ...recoveryAuthority(keyType),
          vaultPolicy: recoveryAuthority(keyType).vaultPolicy.replace('<tenant>', tenantSlug),
          ...(recoveryAuthority(keyType).vaultRole && { vaultRole: recoveryAuthority(keyType).vaultRole.replace('<tenant>', tenantSlug) }),
        },
        keyMaterialExposed: false,
      };
    } catch (err) {
      state[keyName] = { error: err.code ?? 'unavailable' };
    }
  }
  return state;
}

async function applicationValue(req, ctx, ciphertext, keyType) {
  if (!canRecover(req.user)) return { value: null, state: 'not_authorised', reason: 'recovery requires durin-operator' };
  try {
    const { plaintext, authority } = await gateway.recover({ ...ctx, keyType, actor: actorOf(req) }, ciphertext,
      { operation: 'INSPECTOR_RECOVER' });
    return { value: plaintext, state: 'recovered', authority };
  } catch (err) {
    if (err.status === 503) throw err;
    return { value: null, state: 'denied', reason: err.code, vault: err.vault ?? null };
  }
}

// ── GET /customers/:id ────────────────────────────────────────────────────────

router.get('/customers/:id', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query('SELECT * FROM customers WHERE id = $1 AND tenant_id = $2', [req.params.id, tenant.id]);
    if (!rows.length) return res.status(404).json({ error: 'not_found', message: 'Customer not found' });

    const { rows: pvRows } = await query(
      `SELECT field_name, ciphertext, key_name, key_version FROM protected_values
       WHERE resource_type='customer' AND resource_id=$1 AND tenant_id=$2 ORDER BY field_name`,
      [req.params.id, tenant.id],
    );

    const applicationView = { ...rows[0] };
    const databaseView    = { ...rows[0] };
    const fields          = {};
    const ctx = { tenantId: tenant.id, tenantSlug: tenant.slug, resourceType: 'customer', resourceId: req.params.id };

    for (const pv of pvRows) {
      const keyType = gateway.keyTypeFromKeyName(tenant.slug, pv.key_name);
      databaseView[pv.field_name] = pv.ciphertext;
      const app = await applicationValue(req, { ...ctx, fieldName: pv.field_name }, pv.ciphertext, keyType);
      applicationView[pv.field_name] = app.value;
      fields[pv.field_name] = { protected: true, keyName: pv.key_name, keyVersion: pv.key_version,
        application: { state: app.state, ...(app.reason && { reason: app.reason }) } };
    }

    const vaultState = await vaultStateFor(tenant.slug, [...new Set(pvRows.map(r => r.key_name))]);
    res.json({ data: { applicationView, databaseView, vaultState, fields }, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── GET /documents/:id ────────────────────────────────────────────────────────

router.get('/documents/:id', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query('SELECT * FROM documents WHERE id = $1 AND tenant_id = $2', [req.params.id, tenant.id]);
    if (!rows.length) return res.status(404).json({ error: 'not_found', message: 'Document not found' });

    const { rows: pvRows } = await query(
      `SELECT ciphertext, key_name, key_version FROM protected_values
       WHERE resource_type='document' AND resource_id=$1 AND field_name='payload' AND tenant_id=$2`,
      [req.params.id, tenant.id],
    );
    const pv = pvRows[0];
    const databaseView    = { ...rows[0], payload: pv?.ciphertext ?? null };
    const applicationView = { ...rows[0], payload: null };
    const fields = {};
    let vaultState = {};

    if (pv) {
      const keyType = gateway.keyTypeFromKeyName(tenant.slug, pv.key_name);
      const app = await applicationValue(req, { tenantId: tenant.id, tenantSlug: tenant.slug,
        resourceType: 'document', resourceId: req.params.id, fieldName: 'payload' }, pv.ciphertext, keyType);
      // An uploaded file is bytes, not text: report that it was recovered
      // without pushing the whole file into the inspector view.
      const binary = isBinaryType(rows[0].content_type);
      applicationView.payload = binary ? null : app.value;
      fields.payload = { protected: true, keyName: pv.key_name, keyVersion: pv.key_version,
        application: { state: app.state, ...(app.reason && { reason: app.reason }) },
        ...(binary && { binary: { contentType: rows[0].content_type, sizeBytes: rows[0].size_bytes } }),
        ...(keyType === 'restricted' && { breakGlassRequired: true }) };
      vaultState = await vaultStateFor(tenant.slug, [pv.key_name]);
    }

    res.json({ data: { applicationView, databaseView, vaultState, fields }, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── Raw table browser ─────────────────────────────────────────────────────────
// Whitelisted tables only. Tenant-scoped tables are filtered to the caller's
// tenant. Secret-bearing columns (break-glass token hash) are never returned.

const TABLES = {
  tenants:              { tenantColumn: 'id',        order: 'name' },
  customers:            { tenantColumn: 'tenant_id', order: 'name' },
  documents:            { tenantColumn: 'tenant_id', order: 'created_at DESC' },
  protected_values:     { tenantColumn: 'tenant_id', order: 'resource_type, resource_id, field_name' },
  audit_events:         { tenantColumn: 'tenant_id', order: 'timestamp DESC' },
  break_glass_requests: { tenantColumn: 'tenant_id', order: 'created_at DESC', hidden: ['access_token_hash'] },
  compromise_snapshots: { tenantColumn: 'tenant_id', order: 'captured_at DESC' },
};

router.get('/tables', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const data = [];
    for (const [name, t] of Object.entries(TABLES)) {
      const { rows } = await query(`SELECT COUNT(*)::int AS c FROM ${name} WHERE ${t.tenantColumn} = $1`, [tenant.id]);
      data.push({ table: name, rows: rows[0].c, containsCiphertext: ['protected_values', 'compromise_snapshots'].includes(name) });
    }
    res.json({ data, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

router.get('/tables/:table', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const t = TABLES[req.params.table];
    if (!t) return res.status(404).json({ error: 'not_found', message: `Table not browsable: ${req.params.table}` });
    const limit = Math.min(Number(req.query.limit) || 100, 500);
    const offset = Math.max(Number(req.query.offset) || 0, 0);
    const { rows } = await query(
      `SELECT * FROM ${req.params.table} WHERE ${t.tenantColumn} = $1 ORDER BY ${t.order} LIMIT $2 OFFSET $3`,
      [tenant.id, limit, offset],
    );
    const data = rows.map(r => {
      for (const col of t.hidden ?? []) delete r[col];
      return r;
    });
    res.json({ data, meta: { tenant: tenant.slug, table: req.params.table, count: data.length, limit, offset,
      representation: 'raw PostgreSQL rows — nothing decrypted' } });
  } catch (err) { next(err); }
});

export default router;

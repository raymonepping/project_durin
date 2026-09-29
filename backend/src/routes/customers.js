// routes/customers.js — customers with field-level protection
//
// Plain metadata (name, company, country, status) lives in `customers`.
// Sensitive fields (iban, tax_id, payment_info) live only in protected_values
// as Vault Transit ciphertext under durin-<tenant>-customer-data.
import { Router } from 'express';
import { query }  from '../db.js';
import * as gateway from '../gateway/index.js';
import { resolveTenant } from '../middleware/tenant.js';
import { actorOf, canRecover } from '../middleware/auth.js';

const router = Router();

export const PROTECTED_FIELDS = ['iban', 'tax_id', 'payment_info'];

async function storeProtected(tenant, customerId, field, value, actor) {
  const ctx = { tenantId: tenant.id, tenantSlug: tenant.slug, keyType: 'customer-data',
    resourceType: 'customer', resourceId: customerId, fieldName: field, actor };
  const { ciphertext, keyName, keyVersion } = await gateway.protect(ctx, String(value));
  await query(
    `INSERT INTO protected_values (tenant_id, resource_type, resource_id, field_name, ciphertext, key_name, key_version)
     VALUES ($1,$2,$3,$4,$5,$6,$7)
     ON CONFLICT (tenant_id, resource_type, resource_id, field_name)
     DO UPDATE SET ciphertext=$5, key_name=$6, key_version=$7, updated_at=NOW()`,
    [tenant.id, 'customer', customerId, field, ciphertext, keyName, keyVersion],
  );
}

// ── GET / — list customers (metadata only, never decrypts) ───────────────────

router.get('/', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query(
      `SELECT id, name, company, country, status, created_at, updated_at
       FROM customers WHERE tenant_id = $1 AND status <> 'deleted' ORDER BY name`,
      [tenant.id],
    );
    res.json({ data: rows, meta: { tenant: tenant.slug, count: rows.length } });
  } catch (err) { next(err); }
});

// ── GET /:id — application view ──────────────────────────────────────────────
// Operators: protected fields recovered to plaintext (audited per field).
// Viewers:   protected fields are null; `protectedFields` describes them.

router.get('/:id', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query(
      `SELECT * FROM customers WHERE id = $1 AND tenant_id = $2 AND status <> 'deleted'`,
      [req.params.id, tenant.id],
    );
    if (!rows.length) return res.status(404).json({ error: 'not_found', message: 'Customer not found' });
    const customer = { ...rows[0] };

    const { rows: pvRows } = await query(
      `SELECT field_name, key_name, key_version, updated_at FROM protected_values
       WHERE resource_type = 'customer' AND resource_id = $1 AND tenant_id = $2 ORDER BY field_name`,
      [req.params.id, tenant.id],
    );
    const recover = canRecover(req.user);
    const protectedFields = {};

    if (recover) {
      const { rows: ctRows } = await query(
        `SELECT field_name, ciphertext FROM protected_values
         WHERE resource_type = 'customer' AND resource_id = $1 AND tenant_id = $2`,
        [req.params.id, tenant.id],
      );
      const ctx = { tenantId: tenant.id, tenantSlug: tenant.slug, keyType: 'customer-data',
        resourceType: 'customer', resourceId: req.params.id, actor: actorOf(req) };
      for (const pv of ctRows) {
        try {
          const { plaintext } = await gateway.recover({ ...ctx, fieldName: pv.field_name }, pv.ciphertext);
          customer[pv.field_name] = plaintext;
          protectedFields[pv.field_name] = { state: 'recovered' };
        } catch (err) {
          if (err.status === 503) throw err; // Vault down → fail the request, never degrade to plaintext
          customer[pv.field_name] = null;
          protectedFields[pv.field_name] = { state: 'denied', reason: err.code };
        }
      }
    }
    for (const pv of pvRows) {
      if (!recover) customer[pv.field_name] = null;
      protectedFields[pv.field_name] = {
        state: protectedFields[pv.field_name]?.state ?? 'protected',
        ...(protectedFields[pv.field_name]?.reason && { reason: protectedFields[pv.field_name].reason }),
        keyName: pv.key_name,
        keyVersion: pv.key_version,
        updatedAt: pv.updated_at,
      };
    }

    res.json({
      data: { ...customer, protectedFields },
      meta: { tenant: tenant.slug, recovered: recover },
    });
  } catch (err) { next(err); }
});

// ── POST / — create customer + protect sensitive fields ─────────────────────

router.post('/', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { name, company, country, status = 'active', ...rest } = req.body ?? {};
    if (!name) return res.status(400).json({ error: 'validation', message: 'name is required' });

    // Protect first: if Vault refuses, nothing is written (no half-protected rows,
    // never a plaintext fallback). The row id is generated up front so the
    // audit trail can reference the resource.
    const { rows: idRows } = await query('SELECT gen_random_uuid() AS id');
    const customerId = idRows[0].id;
    const protectedValues = [];
    for (const field of PROTECTED_FIELDS) {
      if (rest[field] == null || rest[field] === '') continue;
      const ctx = { tenantId: tenant.id, tenantSlug: tenant.slug, keyType: 'customer-data',
        resourceType: 'customer', resourceId: customerId, fieldName: field, actor: actorOf(req) };
      protectedValues.push({ field, ...(await gateway.protect(ctx, String(rest[field]))) });
    }

    const { rows } = await query(
      `INSERT INTO customers (id, tenant_id, name, company, country, status)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`,
      [customerId, tenant.id, name, company, country, status],
    );
    for (const pv of protectedValues) {
      await query(
        `INSERT INTO protected_values (tenant_id, resource_type, resource_id, field_name, ciphertext, key_name, key_version)
         VALUES ($1,'customer',$2,$3,$4,$5,$6)`,
        [tenant.id, customerId, pv.field, pv.ciphertext, pv.keyName, pv.keyVersion],
      );
    }

    res.status(201).json({
      data: {
        ...rows[0],
        protectedFields: Object.fromEntries(protectedValues.map(pv =>
          [pv.field, { state: 'protected', keyName: pv.keyName, keyVersion: pv.keyVersion, ciphertext: pv.ciphertext }])),
      },
      meta: { tenant: tenant.slug },
    });
  } catch (err) { next(err); }
});

// ── PUT /:id — update customer (re-protect changed sensitive fields) ─────────

router.put('/:id', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query(
      `SELECT id FROM customers WHERE id = $1 AND tenant_id = $2 AND status <> 'deleted'`,
      [req.params.id, tenant.id],
    );
    if (!rows.length) return res.status(404).json({ error: 'not_found', message: 'Customer not found' });

    const { name, company, country, status, ...rest } = req.body ?? {};
    await query(
      `UPDATE customers SET name=COALESCE($1,name), company=COALESCE($2,company),
       country=COALESCE($3,country), status=COALESCE($4,status), updated_at=NOW()
       WHERE id=$5 AND tenant_id=$6`,
      [name, company, country, status, req.params.id, tenant.id],
    );

    const reprotected = [];
    for (const field of PROTECTED_FIELDS) {
      if (rest[field] == null || rest[field] === '') continue;
      await storeProtected(tenant, req.params.id, field, rest[field], actorOf(req));
      reprotected.push(field);
    }

    res.json({ data: { id: req.params.id, reprotected }, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── DELETE /:id — soft delete ─────────────────────────────────────────────────

router.delete('/:id', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rowCount } = await query(
      `UPDATE customers SET status='deleted', updated_at=NOW()
       WHERE id=$1 AND tenant_id=$2 AND status <> 'deleted'`,
      [req.params.id, tenant.id],
    );
    if (!rowCount) return res.status(404).json({ error: 'not_found', message: 'Customer not found' });
    res.json({ data: { id: req.params.id, status: 'deleted' }, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

export default router;

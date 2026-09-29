// routes/audit.js — application audit trail
//
// Each event carries metadata.source: 'vault' when the verdict came from Vault
// (policy, key version, token), 'application' when backend logic decided.
// Vault's own audit log (file device on every node) is the independent record;
// metadata.authority.accessor correlates the two.
//
// Filters: tenant, operation, result, source, since (ISO timestamp), limit, offset.
import { Router } from 'express';
import { query }  from '../db.js';

const router = Router();

router.get('/', async (req, res, next) => {
  try {
    const { tenant, operation, result, source, since } = req.query;
    const limit = Math.min(Number(req.query.limit) || 100, 1000);
    const offset = Math.max(Number(req.query.offset) || 0, 0);
    const conditions = [];
    const params = [];

    // Sessions scoped to specific tenants only see those tenants (plus
    // tenant-less platform events such as DEMO_RESET).
    const scope = req.user?.tenants ?? [];
    if (!scope.includes('*')) {
      params.push(scope);
      conditions.push(`(t.slug = ANY($${params.length}) OR ae.tenant_id IS NULL)`);
    }
    if (tenant) {
      params.push(tenant);
      conditions.push(`t.slug = $${params.length}`);
    }
    if (operation) {
      params.push(String(operation).toUpperCase());
      conditions.push(`ae.operation = $${params.length}`);
    }
    if (result) {
      params.push(String(result).toUpperCase());
      conditions.push(`ae.result = $${params.length}`);
    }
    if (source) {
      params.push(String(source));
      conditions.push(`ae.metadata->>'source' = $${params.length}`);
    }
    if (since) {
      const d = new Date(since);
      if (Number.isNaN(d.getTime())) return res.status(400).json({ error: 'validation', message: 'since must be an ISO timestamp' });
      params.push(d.toISOString());
      conditions.push(`ae.timestamp >= $${params.length}`);
    }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    params.push(limit, offset);

    const { rows } = await query(
      `SELECT ae.id,
              ae.timestamp,
              ae.operation,
              t.slug                    AS tenant,
              ae.resource_type          AS "resourceType",
              ae.resource_id            AS "resourceId",
              ae.field_name             AS "fieldName",
              ae.actor,
              ae.key_name               AS "keyName",
              ae.key_version            AS "keyVersion",
              ae.result,
              COALESCE(ae.metadata->>'source', 'application') AS source,
              ae.metadata
       FROM audit_events ae
       LEFT JOIN tenants t ON ae.tenant_id = t.id
       ${where}
       ORDER BY ae.timestamp DESC
       LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    );

    res.json({ data: rows, meta: { count: rows.length, limit, offset } });
  } catch (err) { next(err); }
});

export default router;

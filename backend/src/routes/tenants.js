// routes/tenants.js — tenant metadata (filtered to the session's tenants)
import { Router } from 'express';
import { query } from '../db.js';
import { mayAccessTenant } from '../middleware/tenant.js';

const router = Router();

const COLUMNS = 'id, name, slug, vault_namespace, fortified_at, created_at';

function withKeys(t) {
  return {
    ...t,
    transitKeys: ['customer-data', 'documents', 'restricted'].map(k => `durin-${t.slug}-${k}`),
    vaultRole: `auth/jwt tenant-${t.slug}`,
  };
}

router.get('/', async (req, res, next) => {
  try {
    const { rows } = await query(`SELECT ${COLUMNS} FROM tenants ORDER BY name`);
    const data = rows.filter(t => mayAccessTenant(req.user, t.slug)).map(withKeys);
    res.json({ data, meta: { count: data.length } });
  } catch (err) { next(err); }
});

router.get('/:slug', async (req, res, next) => {
  try {
    const { rows } = await query(`SELECT ${COLUMNS} FROM tenants WHERE slug = $1`, [req.params.slug]);
    if (!rows.length || !mayAccessTenant(req.user, rows[0].slug)) {
      return res.status(404).json({ error: 'not_found', message: 'Tenant not found' });
    }
    res.json({ data: withKeys(rows[0]) });
  } catch (err) { next(err); }
});

export default router;

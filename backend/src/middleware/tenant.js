// middleware/tenant.js — tenant context resolution (single implementation).
//
// Where the tenant comes from:
//   x-tenant header  → ?tenant= query → body.tenant  (first present wins)
//
// Whether the caller may act for it:
//   auth enabled   the slug must be listed in the session's durin_tenants claim
//                  (or the claim is ["*"]) — otherwise 403 tenant_mismatch
//   auth disabled  demo identity holds ["*"]
//
// This is the application boundary (defence in depth). The security guarantee
// is one layer down: the gateway runs under a Vault token scoped to exactly
// this tenant, so a wrong tenant here still cannot reach another tenant's keys.

import { query } from '../db.js';

function fail(status, code, message) {
  return Object.assign(new Error(message), { status, code });
}

export function requestedTenantSlug(req) {
  const raw = req.headers['x-tenant'] ?? req.query?.tenant ?? req.body?.tenant;
  return typeof raw === 'string' ? raw.trim().toLowerCase() : null;
}

export function mayAccessTenant(user, slug) {
  const tenants = user?.tenants ?? [];
  return tenants.includes('*') || tenants.includes(slug);
}

export async function resolveTenant(req, { slug } = {}) {
  const wanted = slug ?? requestedTenantSlug(req);
  if (!wanted) throw fail(400, 'tenant_required', 'Tenant required: send the x-tenant header');
  if (!/^[a-z0-9-]{1,50}$/.test(wanted)) throw fail(400, 'invalid_tenant', 'Invalid tenant identifier');
  if (!mayAccessTenant(req.user, wanted)) {
    throw fail(403, 'tenant_mismatch', 'Authenticated session is not authorised for this tenant');
  }
  const { rows } = await query('SELECT * FROM tenants WHERE slug = $1', [wanted]);
  if (!rows.length) throw fail(404, 'tenant_not_found', `Tenant not found: ${wanted}`);
  return rows[0];
}

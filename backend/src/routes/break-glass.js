// routes/break-glass.js — emergency access through Vault Control Groups.
// prompts/improvements/01_04 (supersedes the token-role design of 22_01).
//
// Normal authority cannot recover RESTRICTED data: tenant policies have no
// decrypt on durin-<tenant>-restricted. Break glass is the only path, and each
// step happens in Vault, under the identity of the person doing it:
//
//   request  requester (viewer|operator) logs into auth/jwt role
//            breakglass-requester-<t> and asks Vault to decrypt. The policy
//            carries a control_group factor, so Vault answers with a
//            response-wrapping token instead of plaintext. The backend keeps
//            the wrapping token in memory; its accessor is stored.
//   approve  a security-admin logs into breakglass-approver and calls
//            sys/control-group/authorize. Vault checks that identity is in the
//            durin-security-admins group. Security-admins cannot be
//            requesters (bound claims), so approver ≠ requester is Vault-enforced.
//   redeem   the SAME requester identity, with the request id, gets the
//            unwrapped decrypt — exactly once (Vault single-use unwrap).
//   end      deny: Vault never authorised → the answer can never be released.
//            revoke / expiry: the backend forgets the wrapping token; Vault
//            expires it with the 15-minute control-group TTL.
//
// The Vault wrapping token never reaches the client.
//
// Audit events: BREAK_GLASS_REQUEST, BREAK_GLASS_APPROVED, BREAK_GLASS_DENIED,
// BREAK_GLASS_RECOVER, BREAK_GLASS_REVOKED, BREAK_GLASS_EXPIRED.

import { Router } from 'express';
import { query }  from '../db.js';
import { emitAudit } from '../audit.js';
import { resolveTenant, mayAccessTenant } from '../middleware/tenant.js';
import { actorOf } from '../middleware/auth.js';
import {
  requestBreakGlass, approveBreakGlass, redeemBreakGlassFromVault,
  holdsBreakGlass, forgetBreakGlass,
} from '../gateway/authority.js';

const router = Router();

const SELECT_COLUMNS = `
  bg.id, bg.tenant_id, t.slug AS tenant_slug, bg.requested_by, bg.resource_type,
  bg.resource_id, d.name AS resource_name, d.classification AS resource_classification,
  bg.reason, bg.status, bg.approved_by, bg.approved_at, bg.denied_by, bg.expires_at,
  bg.used_at, bg.revoked_at, bg.revoked_by,
  bg.vault_token_accessor AS vault_wrapping_accessor, bg.vault_policy, bg.created_at`;

const FROM = `
  FROM break_glass_requests bg
  JOIN tenants t ON bg.tenant_id = t.id
  LEFT JOIN documents d ON bg.resource_type = 'document' AND d.id = bg.resource_id`;

function fail(status, code, message, extra = {}) {
  return Object.assign(new Error(message), { status, code, ...extra });
}

async function loadRequest(id) {
  const { rows } = await query(`SELECT ${SELECT_COLUMNS} ${FROM} WHERE bg.id = $1`, [id]);
  return rows[0] ?? null;
}

function present(row) {
  if (!row) return row;
  return { ...row, vault_mechanism: 'control-group', vault_holds_answer: holdsBreakGlass(row.id) };
}

function assertTenantAccess(req, row) {
  if (!mayAccessTenant(req.user, row.tenant_slug)) {
    throw fail(403, 'tenant_mismatch', 'Authenticated session is not authorised for this tenant');
  }
}

// ── Background expiry sweep ───────────────────────────────────────────────────

async function expireSweep() {
  try {
    const { rows } = await query(
      `UPDATE break_glass_requests SET status = 'expired'
       WHERE status IN ('pending', 'approved') AND expires_at < NOW()
       RETURNING id, tenant_id, resource_type, resource_id, vault_token_accessor`,
    );
    for (const r of rows) {
      forgetBreakGlass(r.id);
      await emitAudit({
        operation: 'BREAK_GLASS_EXPIRED', tenantId: r.tenant_id, resourceType: r.resource_type,
        resourceId: r.resource_id, actor: 'system', result: 'ALLOWED', source: 'vault',
        metadata: { request_id: r.id, vault_wrapping_accessor: r.vault_token_accessor, normal_access_restored: true },
      });
    }
    if (rows.length) console.log(`[break-glass] expired ${rows.length} request(s)`);
  } catch (err) {
    console.error('[break-glass] expiry sweep error:', err.message);
  }
}

setTimeout(() => {
  expireSweep();
  setInterval(expireSweep, 30_000).unref();
}, 5_000).unref();

// ── Reads ─────────────────────────────────────────────────────────────────────

router.get('/pending', async (req, res, next) => {
  try {
    const { rows } = await query(`SELECT ${SELECT_COLUMNS} ${FROM} WHERE bg.status = 'pending' ORDER BY bg.created_at DESC`);
    const data = rows.filter(r => mayAccessTenant(req.user, r.tenant_slug)).map(present);
    res.json({ data, meta: { count: data.length } });
  } catch (err) { next(err); }
});

router.get('/all', async (req, res, next) => {
  try {
    const { tenant, status } = req.query;
    const limit = Math.min(Number(req.query.limit) || 50, 500);
    const offset = Math.max(Number(req.query.offset) || 0, 0);
    const conds = [];
    const params = [];
    if (tenant) { params.push(tenant); conds.push(`t.slug = $${params.length}`); }
    if (status) { params.push(status); conds.push(`bg.status = $${params.length}`); }
    const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
    params.push(limit, offset);
    const { rows } = await query(
      `SELECT ${SELECT_COLUMNS} ${FROM} ${where}
       ORDER BY bg.created_at DESC LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    );
    const data = rows.filter(r => mayAccessTenant(req.user, r.tenant_slug)).map(present);
    res.json({ data, meta: { count: data.length, limit, offset } });
  } catch (err) { next(err); }
});

router.get('/:id', async (req, res, next) => {
  try {
    const row = await loadRequest(req.params.id);
    if (!row) return res.status(404).json({ error: 'not_found', message: 'Break-glass request not found' });
    assertTenantAccess(req, row);
    res.json({ data: present(row) });
  } catch (err) { next(err); }
});

// ── POST /request — the requester asks Vault ─────────────────────────────────

router.post('/request', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { resource_type = 'document', resource_id, reason } = req.body ?? {};
    if (!resource_id || !reason || String(reason).trim().length < 5) {
      return res.status(400).json({ error: 'validation', message: 'resource_id and a reason (≥ 5 characters) are required' });
    }
    if (resource_type !== 'document') {
      return res.status(400).json({ error: 'validation', message: 'break glass applies to documents' });
    }
    const { rows: docs } = await query(
      `SELECT d.id, d.name, d.classification, pv.ciphertext, pv.key_name
       FROM documents d JOIN protected_values pv
         ON pv.resource_type='document' AND pv.resource_id=d.id AND pv.field_name='payload' AND pv.tenant_id=d.tenant_id
       WHERE d.id = $1 AND d.tenant_id = $2`,
      [resource_id, tenant.id],
    );
    if (!docs.length) return res.status(404).json({ error: 'not_found', message: 'Document not found' });
    const doc = docs[0];
    if (doc.classification !== 'RESTRICTED') {
      return res.status(400).json({
        error: 'break_glass_not_required',
        message: `Document is ${doc.classification}; normal operator authority applies. Break glass is only for RESTRICTED data.`,
      });
    }

    const requestedBy = actorOf(req);
    const reasonText = String(reason).trim();
    const { rows: idRows } = await query('SELECT gen_random_uuid() AS id');
    const id = idRows[0].id;

    let vault;
    try {
      vault = await requestBreakGlass(id, tenant.slug, doc.key_name, doc.ciphertext);
    } catch (err) {
      await emitAudit({
        operation: 'BREAK_GLASS_REQUEST', tenantId: tenant.id, resourceType: resource_type, resourceId: resource_id,
        actor: requestedBy, result: 'DENIED', source: err.vault ? 'vault' : 'application',
        metadata: { reason: err.code, vault: err.vault ?? null },
      });
      throw err;
    }

    await query(
      `INSERT INTO break_glass_requests
         (id, tenant_id, requested_by, resource_type, resource_id, reason, status, expires_at, vault_token_accessor, vault_policy)
       VALUES ($1,$2,$3,$4,$5,$6,'pending',$7,$8,$9)`,
      [id, tenant.id, requestedBy, resource_type, resource_id, reasonText, vault.expiresAt, vault.accessor, vault.requesterPolicy],
    );
    await emitAudit({
      operation: 'BREAK_GLASS_REQUEST', tenantId: tenant.id, resourceType: resource_type, resourceId: resource_id,
      actor: requestedBy, result: 'ALLOWED', source: 'vault',
      metadata: {
        request_id: id, reason: reasonText, resource: `${tenant.slug} / ${doc.name}`,
        vault_wrapping_accessor: vault.accessor, control_group_ttl: vault.ttl, requester_entity: vault.requesterEntity,
      },
    });
    res.status(201).json({
      data: {
        ...present(await loadRequest(id)),
        vault: {
          mechanism: 'control-group',
          wrappingAccessor: vault.accessor,
          requesterPolicy: vault.requesterPolicy,
          approvalsRequired: 1,
          approverGroup: 'durin-security-admins',
          ttlSeconds: vault.ttl,
          expiresAt: vault.expiresAt,
        },
      },
      meta: { tenant: tenant.slug, message: 'Awaiting approval by a security-admin in Vault.' },
    });
  } catch (err) { next(err); }
});

// ── POST /:id/approve — the approver authorises in Vault ─────────────────────

router.post('/:id/approve', async (req, res, next) => {
  try {
    const row = await loadRequest(req.params.id);
    if (!row) return res.status(404).json({ error: 'not_found', message: 'Break-glass request not found' });
    assertTenantAccess(req, row);
    const approvedBy = actorOf(req);

    if (row.status !== 'pending') {
      return res.status(409).json({ error: 'invalid_state', message: `Request is ${row.status}, not pending` });
    }
    if (approvedBy === row.requested_by) {
      await emitAudit({
        operation: 'BREAK_GLASS_APPROVED', tenantId: row.tenant_id, resourceType: row.resource_type,
        resourceId: row.resource_id, actor: approvedBy, result: 'DENIED',
        metadata: { request_id: row.id, reason: 'separation_of_duties' },
      });
      return res.status(403).json({ error: 'separation_of_duties', message: 'The requester cannot approve their own break-glass request' });
    }

    let result;
    try {
      result = await approveBreakGlass(row.vault_wrapping_accessor);
    } catch (err) {
      await emitAudit({
        operation: 'BREAK_GLASS_APPROVED', tenantId: row.tenant_id, resourceType: row.resource_type,
        resourceId: row.resource_id, actor: approvedBy, result: 'DENIED', source: err.vault ? 'vault' : 'application',
        metadata: { request_id: row.id, reason: err.code, vault: err.vault ?? null },
      });
      throw err;
    }
    if (!result.approved) {
      return res.status(409).json({ error: 'not_approved', message: 'Vault recorded the authorization but the control group is not satisfied', vault: result.status });
    }

    await query(
      `UPDATE break_glass_requests SET status='approved', approved_by=$1, approved_at=NOW() WHERE id=$2 AND status='pending'`,
      [approvedBy, row.id],
    );
    await emitAudit({
      operation: 'BREAK_GLASS_APPROVED', tenantId: row.tenant_id, resourceType: row.resource_type,
      resourceId: row.resource_id, actor: approvedBy, result: 'ALLOWED', source: 'vault',
      metadata: {
        request_id: row.id, requested_by: row.requested_by,
        vault_wrapping_accessor: row.vault_wrapping_accessor, approver_entity: result.approverEntity,
        vault_request_entity: result.status?.requestEntity ?? null,
        vault_authorizations: result.status?.authorizations ?? [],
      },
    });
    res.json({
      data: {
        ...present(await loadRequest(row.id)),
        vault: { mechanism: 'control-group', approved: true, authorizations: result.status?.authorizations ?? [] },
      },
      meta: { message: `BREAK GLASS ACTIVE — ${row.requested_by} may recover the document once, until ${new Date(row.expires_at).toISOString()}.` },
    });
  } catch (err) { next(err); }
});

// ── POST /:id/deny ────────────────────────────────────────────────────────────

router.post('/:id/deny', async (req, res, next) => {
  try {
    const row = await loadRequest(req.params.id);
    if (!row) return res.status(404).json({ error: 'not_found', message: 'Break-glass request not found' });
    assertTenantAccess(req, row);
    const deniedBy = actorOf(req);
    const { rowCount } = await query(
      `UPDATE break_glass_requests SET status='denied', denied_by=$1 WHERE id=$2 AND status='pending'`,
      [deniedBy, row.id],
    );
    if (!rowCount) return res.status(409).json({ error: 'invalid_state', message: `Request is ${row.status}, not pending` });
    forgetBreakGlass(row.id);
    await emitAudit({
      operation: 'BREAK_GLASS_DENIED', tenantId: row.tenant_id, resourceType: row.resource_type,
      resourceId: row.resource_id, actor: deniedBy, result: 'DENIED',
      metadata: { request_id: row.id, reason: 'denied_by_security_admin', vault: 'never authorised — answer can never be released' },
    });
    res.json({ data: present(await loadRequest(row.id)) });
  } catch (err) { next(err); }
});

// ── POST /:id/revoke — end emergency access before it is used ────────────────

router.post('/:id/revoke', async (req, res, next) => {
  try {
    const row = await loadRequest(req.params.id);
    if (!row) return res.status(404).json({ error: 'not_found', message: 'Break-glass request not found' });
    assertTenantAccess(req, row);
    const revokedBy = actorOf(req);
    const { rowCount } = await query(
      `UPDATE break_glass_requests SET status='revoked', revoked_at=NOW(), revoked_by=$1
       WHERE id=$2 AND status IN ('pending','approved')`,
      [revokedBy, row.id],
    );
    if (!rowCount) return res.status(409).json({ error: 'invalid_state', message: `Request is ${row.status}, not active` });
    forgetBreakGlass(row.id);
    await emitAudit({
      operation: 'BREAK_GLASS_REVOKED', tenantId: row.tenant_id, resourceType: row.resource_type,
      resourceId: row.resource_id, actor: revokedBy, result: 'ALLOWED',
      metadata: { request_id: row.id, vault_wrapping_accessor: row.vault_wrapping_accessor,
        vault_answer: 'wrapping token discarded; expires in Vault with the control-group TTL', normal_access_restored: true },
    });
    res.json({ data: present(await loadRequest(row.id)), meta: { normalAccessRestored: true } });
  } catch (err) { next(err); }
});

// ── Redemption (used by routes/documents.js) ─────────────────────────────────

async function refuse(row, tenant, resourceId, actor, code, message) {
  await emitAudit({
    operation: 'BREAK_GLASS_DENIED', tenantId: tenant.id, resourceType: 'document', resourceId,
    actor, result: 'DENIED', metadata: { request_id: row?.id ?? null, reason: code },
  });
  throw fail(403, code, message);
}

/**
 * The requester recovers the RESTRICTED document once. Identity must match the
 * requester; Vault releases the wrapped decrypt only if the control group was
 * authorised, and only once.
 */
export async function redeemBreakGlass({ requestId, tenant, resourceId, actor }) {
  const row = await loadRequest(requestId);
  if (!row || row.tenant_id !== tenant.id || row.resource_id !== resourceId) {
    return refuse(row, tenant, resourceId, actor, 'break_glass_invalid', 'No break-glass request for this document');
  }
  if (row.requested_by !== actor) {
    return refuse(row, tenant, resourceId, actor, 'break_glass_not_requester', 'Only the requester can redeem emergency access');
  }
  if (row.status === 'pending') {
    return refuse(row, tenant, resourceId, actor, 'break_glass_pending', 'Awaiting approval in Vault');
  }
  if (row.status !== 'approved') {
    return refuse(row, tenant, resourceId, actor, `break_glass_${row.status}`, `Break-glass request is ${row.status}`);
  }
  if (new Date(row.expires_at) < new Date()) {
    await query(`UPDATE break_glass_requests SET status='expired' WHERE id=$1`, [row.id]);
    forgetBreakGlass(row.id);
    return refuse(row, tenant, resourceId, actor, 'break_glass_expired', 'Emergency access has expired');
  }

  const { rowCount } = await query(
    `UPDATE break_glass_requests SET status='used', used_at=NOW() WHERE id=$1 AND status='approved'`, [row.id]);
  if (!rowCount) return refuse(row, tenant, resourceId, actor, 'break_glass_used', 'Emergency access has already been used');

  let released;
  try {
    released = await redeemBreakGlassFromVault(row.id);
  } catch (err) {
    await emitAudit({
      operation: 'BREAK_GLASS_RECOVER', tenantId: tenant.id, resourceType: 'document', resourceId,
      actor, result: 'DENIED', source: 'vault',
      metadata: { request_id: row.id, vault: { status: err.vaultStatus ?? err.status, errors: err.vaultErrors ?? [] } },
    });
    throw fail(403, 'vault_denied', 'Vault did not release the approved answer', { vault: { status: err.vaultStatus, errors: err.vaultErrors } });
  }
  if (!released) {
    return refuse(row, tenant, resourceId, actor, 'break_glass_authority_lost',
      'The backend no longer holds the Vault answer (restart?) — request again');
  }
  const auditEventId = await emitAudit({
    operation: 'BREAK_GLASS_RECOVER', tenantId: tenant.id, resourceType: 'document', resourceId,
    actor, result: 'ALLOWED', source: 'vault',
    metadata: {
      request_id: row.id, approved_by: row.approved_by, vault_wrapping_accessor: released.accessor,
      vault_release: 'sys/wrapping/unwrap (single use)', normal_access_restored: true,
    },
  });
  return { request: row, plaintext: released.plaintext, plaintextBase64: released.plaintextBase64, auditEventId };
}

export default router;

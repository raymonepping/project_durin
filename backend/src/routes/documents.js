// routes/documents.js — secure document vault
//
// Metadata is plaintext in `documents`; the payload is ciphertext in
// protected_values. Classification selects the Transit key:
//
//   PUBLIC / INTERNAL / CONFIDENTIAL → durin-<tenant>-documents
//   RESTRICTED                       → durin-<tenant>-restricted
//
// Tenant tokens may encrypt but NOT decrypt the restricted key, so recovering a
// RESTRICTED payload on the normal path is refused by Vault (403). The only way
// in is break glass: a Vault Control Group request approved by a
// security-admin (routes/break-glass.js).
import { createHash } from 'node:crypto';
import { Router } from 'express';
import { query }  from '../db.js';
import * as gateway from '../gateway/index.js';
import { resolveTenant } from '../middleware/tenant.js';
import { actorOf, canRecover } from '../middleware/auth.js';
import { redeemBreakGlass } from './break-glass.js';

const router = Router();

export const CLASSIFICATIONS = ['PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED'];

// Pasted text and uploaded files. Text types travel as UTF-8 strings; binary
// types travel as base64 of the file's bytes, and Vault encrypts those bytes
// as-is (never a text rendering of them).
export const CONTENT_TYPES = {
  'text/plain': { binary: false },
  'text/markdown': { binary: false },
  'application/pdf': { binary: true, magic: Buffer.from('%PDF-') },
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': { binary: true, magic: Buffer.from([0x50, 0x4b, 0x03, 0x04]) },
};
export const MAX_DOCUMENT_BYTES = 5 * 1024 * 1024;
export const isBinaryType = (contentType) => CONTENT_TYPES[contentType]?.binary === true;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;

async function loadDocument(tenant, id) {
  const { rows } = await query(
    `SELECT d.*, c.name AS customer_name,
            pv.key_name, pv.key_version, pv.updated_at AS protected_at
     FROM documents d
     LEFT JOIN customers c ON d.customer_id = c.id
     LEFT JOIN protected_values pv
            ON pv.resource_type = 'document' AND pv.resource_id = d.id
           AND pv.field_name = 'payload' AND pv.tenant_id = d.tenant_id
     WHERE d.id = $1 AND d.tenant_id = $2`,
    [id, tenant.id],
  );
  return rows[0] ?? null;
}

function encryptionState(doc) {
  return {
    protected: Boolean(doc.key_name),
    keyName: doc.key_name ?? null,
    keyVersion: doc.key_version ?? null,
    protectedAt: doc.protected_at ?? null,
    recoveryRequires: doc.classification === 'RESTRICTED' ? 'break-glass' : 'operator',
  };
}

/** Text documents return UTF-8; uploaded binary files return their bytes as base64. */
function payloadOf(doc, plaintext, plaintextBase64) {
  return isBinaryType(doc.content_type)
    ? { payload: plaintextBase64, encoding: 'base64' }
    : { payload: plaintext, encoding: 'utf8' };
}

function presentDocument(doc) {
  const { key_name, key_version, protected_at, ...meta } = doc;
  return { ...meta, encryption: encryptionState(doc) };
}

async function payloadCiphertext(tenant, docId) {
  const { rows } = await query(
    `SELECT ciphertext, key_name FROM protected_values
     WHERE resource_type='document' AND resource_id=$1 AND field_name='payload' AND tenant_id=$2`,
    [docId, tenant.id],
  );
  return rows[0] ?? null;
}

// ── GET / — list documents (metadata only, never decrypts) ───────────────────

router.get('/', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query(
      `SELECT d.id, d.name, d.content_type, d.classification, d.size_bytes, d.checksum,
              d.created_at, d.created_by, d.customer_id, c.name AS customer_name,
              pv.key_name, pv.key_version, pv.updated_at AS protected_at
       FROM documents d
       LEFT JOIN customers c ON d.customer_id = c.id
       LEFT JOIN protected_values pv
              ON pv.resource_type = 'document' AND pv.resource_id = d.id
             AND pv.field_name = 'payload' AND pv.tenant_id = d.tenant_id
       WHERE d.tenant_id = $1 ORDER BY d.created_at DESC`,
      [tenant.id],
    );
    const data = rows.map(presentDocument);
    res.json({ data, meta: { tenant: tenant.slug, count: data.length } });
  } catch (err) { next(err); }
});

// ── POST / — upload document + protect payload ───────────────────────────────

router.post('/', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { name, payload, customer_id } = req.body ?? {};
    const content_type = String(req.body?.content_type ?? 'text/plain');
    const classification = String(req.body?.classification ?? 'INTERNAL').toUpperCase();
    if (!name)    return res.status(400).json({ error: 'validation', message: 'name is required' });
    if (typeof payload !== 'string' || !payload) {
      return res.status(400).json({ error: 'validation', message: 'payload (string) is required' });
    }
    if (!CLASSIFICATIONS.includes(classification)) {
      return res.status(400).json({ error: 'validation', message: `classification must be one of ${CLASSIFICATIONS.join(', ')}` });
    }
    const type = CONTENT_TYPES[content_type];
    if (!type) {
      return res.status(415).json({ error: 'unsupported_type', message: `content_type must be one of ${Object.keys(CONTENT_TYPES).join(', ')}` });
    }
    // The bytes the document really consists of: UTF-8 text, or the decoded file.
    let bytes;
    if (type.binary) {
      if (!BASE64.test(payload) || payload.length % 4 !== 0) {
        return res.status(400).json({ error: 'validation', message: 'payload must be base64 for binary content types' });
      }
      bytes = Buffer.from(payload, 'base64');
      if (type.magic && !bytes.subarray(0, type.magic.length).equals(type.magic)) {
        return res.status(400).json({ error: 'validation', message: `file content does not match ${content_type}` });
      }
    } else {
      bytes = Buffer.from(payload, 'utf8');
    }
    if (bytes.length > MAX_DOCUMENT_BYTES) {
      return res.status(413).json({ error: 'too_large', message: `documents are limited to ${MAX_DOCUMENT_BYTES / 1024 / 1024} MB` });
    }
    if (customer_id) {
      const { rowCount } = await query('SELECT 1 FROM customers WHERE id=$1 AND tenant_id=$2', [customer_id, tenant.id]);
      if (!rowCount) return res.status(404).json({ error: 'not_found', message: 'Customer not found in this tenant' });
    }

    // Protect first — nothing is stored if Vault refuses.
    const { rows: idRows } = await query('SELECT gen_random_uuid() AS id');
    const docId = idRows[0].id;
    const keyType = gateway.keyTypeForClassification(classification);
    const actor = actorOf(req);
    const { ciphertext, keyName, keyVersion } = await gateway.protect({
      tenantId: tenant.id, tenantSlug: tenant.slug, keyType,
      resourceType: 'document', resourceId: docId, fieldName: 'payload', actor,
    }, payload, { encoding: type.binary ? 'base64' : 'utf8' });

    // Checksum of the plaintext bytes lets an authorised reader verify
    // integrity; it is a one-way digest and reveals nothing recoverable.
    const checksum = createHash('sha256').update(bytes).digest('hex');
    await query(
      `INSERT INTO documents (id, tenant_id, customer_id, name, content_type, classification, size_bytes, checksum, created_by)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
      [docId, tenant.id, customer_id || null, name, content_type, classification,
       bytes.length, checksum, actor],
    );
    await query(
      `INSERT INTO protected_values (tenant_id, resource_type, resource_id, field_name, ciphertext, key_name, key_version)
       VALUES ($1,'document',$2,'payload',$3,$4,$5)`,
      [tenant.id, docId, ciphertext, keyName, keyVersion],
    );

    const doc = await loadDocument(tenant, docId);
    res.status(201).json({ data: presentDocument(doc), meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── GET /:id — metadata + encryption state ───────────────────────────────────

router.get('/:id', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const doc = await loadDocument(tenant, req.params.id);
    if (!doc) return res.status(404).json({ error: 'not_found', message: 'Document not found' });
    res.json({ data: presentDocument(doc), meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── GET /:id/content — recover payload ───────────────────────────────────────
// Normal path: operator role + the operator's own Vault tenant authority.
// RESTRICTED → Vault denies. Break-glass path: `x-break-glass-request: <id>`
// by the requester's own identity, after a security-admin approved it in Vault.

router.get('/:id/content', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const doc = await loadDocument(tenant, req.params.id);
    if (!doc) return res.status(404).json({ error: 'not_found', message: 'Document not found' });
    const pv = await payloadCiphertext(tenant, doc.id);
    if (!pv) return res.status(404).json({ error: 'not_found', message: 'Document payload not found' });
    const keyType = gateway.keyTypeFromKeyName(tenant.slug, pv.key_name);
    const ctxBase = { tenantId: tenant.id, tenantSlug: tenant.slug, keyType,
      resourceType: 'document', resourceId: doc.id, fieldName: 'payload' };

    const breakGlassRequest = req.headers['x-break-glass-request'];

    if (breakGlassRequest) {
      const { request, plaintext, plaintextBase64, auditEventId } = await redeemBreakGlass({
        requestId: String(breakGlassRequest), tenant, resourceId: doc.id, actor: actorOf(req),
      });
      return res.json({
        data: { ...presentDocument(doc), ...payloadOf(doc, plaintext, plaintextBase64),
          keyVersion: gateway.ciphertextVersion(pv.ciphertext) },
        meta: {
          tenant: tenant.slug,
          breakGlass: {
            requestId: request.id,
            requestedBy: request.requested_by,
            approvedBy: request.approved_by,
            mechanism: 'vault-control-group',
            vaultWrappingAccessor: request.vault_wrapping_accessor,
            status: 'used',
            normalAccessRestored: true,
          },
          auditEventId,
        },
      });
    }

    if (!canRecover(req.user)) {
      return res.status(403).json({ error: 'forbidden', message: 'Recovering document content requires the durin-operator role' });
    }

    try {
      const { plaintext, plaintextBase64, keyVersion, auditEventId, authority } = await gateway.recover(
        { ...ctxBase, actor: actorOf(req) }, pv.ciphertext,
      );
      res.json({
        data: { ...presentDocument(doc), ...payloadOf(doc, plaintext, plaintextBase64), keyVersion },
        meta: { tenant: tenant.slug, authority, auditEventId },
      });
    } catch (err) {
      if (err instanceof gateway.VaultDeniedError && keyType === 'restricted') {
        return res.status(403).json({
          error: 'vault_denied',
          message: 'NORMAL ACCESS DENIED — Vault refused decrypt on the restricted key. Request break glass.',
          breakGlassRequired: true,
          vault: err.vault,
          authority: err.authority,
          auditEventId: err.auditEventId,
        });
      }
      throw err;
    }
  } catch (err) { next(err); }
});

// ── GET /:id/raw — database view (ciphertext) ────────────────────────────────

router.get('/:id/raw', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query(
      `SELECT ciphertext, key_name, key_version, created_at, updated_at FROM protected_values
       WHERE resource_type='document' AND resource_id=$1 AND tenant_id=$2 AND field_name='payload'`,
      [req.params.id, tenant.id],
    );
    if (!rows.length) return res.status(404).json({ error: 'not_found', message: 'Document payload not found' });
    res.json({ data: rows[0], meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

export default router;

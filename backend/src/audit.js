// src/audit.js — application audit trail (PostgreSQL audit_events).
//
// The backend's database role may INSERT and SELECT audit_events but not
// UPDATE or DELETE them (scripts/sql/999_grants.sql) — evidence is append-only.
//
// Vault keeps its own, independent audit log (file audit device on every
// node). Application events carry the Vault token accessor of the authority
// that performed the operation, so the two trails can be correlated.

import { query } from './db.js';

/**
 * result: ALLOWED | DENIED | SIMULATED | FAILED
 * source: 'application' — decided by backend logic
 *         'vault'       — the verdict came from Vault (policy, key version, ...)
 */
export async function emitAudit({
  operation, tenantId = null, resourceType = null, resourceId = null,
  fieldName = null, actor = 'system', keyName = null, keyVersion = null,
  result, source = 'application', metadata = {},
}) {
  try {
    const { rows } = await query(
      `INSERT INTO audit_events
         (operation, tenant_id, resource_type, resource_id, field_name,
          actor, key_name, key_version, result, metadata)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
       RETURNING id`,
      [operation, tenantId, resourceType, resourceId, fieldName,
       actor, keyName, keyVersion, result, JSON.stringify({ source, ...metadata })],
    );
    return rows[0]?.id ?? null;
  } catch (err) {
    // Never block the caller on audit failure, but make it loud.
    console.error(`[audit] emission failed for ${operation}/${result}:`, err.message);
    return null;
  }
}

// gateway/index.js — Data Trust Gateway
//
// The single interface for cryptographic operations. No other module calls
// Vault Transit.
//
// Design invariants:
//   - The application receives the RESULT of an authorised operation, never a key
//   - Every data and key operation runs under a Vault token issued to the
//     logged-in PERSON for exactly one tenant (auth/jwt, gateway/authority.js),
//     so Vault — not this code — refuses a cross-tenant key or a non-operator
//   - RESTRICTED data is recoverable only through a Vault Control Group
//     (routes/break-glass.js)
//   - Every operation is audited with the Vault token accessor that performed it
//   - Vault unavailable → 503; never a plaintext fallback
//
// Key naming: durin-<tenant>-<keyType>, keyType ∈ customer-data | documents | restricted

import { emitAudit } from '../audit.js';
import {
  vaultEncrypt, vaultDecrypt, vaultRewrap, vaultRotateKey,
  vaultGetKeyInfo, vaultSetMinDecryptionVersion, vaultRequest,
} from '../vault.js';
import { getTenantAuthority, refreshIfStale } from './authority.js';

export const KEY_TYPES = ['customer-data', 'documents', 'restricted'];

// ── Key resolution ────────────────────────────────────────────────────────────

export function resolveKeyName(tenantSlug, keyType) {
  if (!tenantSlug) throw new GatewayError('tenant slug is required', 'missing_tenant');
  if (!KEY_TYPES.includes(keyType)) {
    throw new GatewayError(`unknown key type: ${keyType}`, 'invalid_key_type');
  }
  return `durin-${tenantSlug}-${keyType}`;
}

export function keyTypeFromKeyName(tenantSlug, keyName) {
  const prefix = `durin-${tenantSlug}-`;
  if (!keyName?.startsWith(prefix)) {
    throw new GatewayError(`key ${keyName} does not belong to tenant ${tenantSlug}`, 'tenant_mismatch', 403);
  }
  const keyType = keyName.slice(prefix.length);
  if (!KEY_TYPES.includes(keyType)) throw new GatewayError(`unknown key type: ${keyType}`, 'invalid_key_type');
  return keyType;
}

export function keyTypeForClassification(classification) {
  return String(classification).toUpperCase() === 'RESTRICTED' ? 'restricted' : 'documents';
}

export function ciphertextVersion(ciphertext) {
  const m = ciphertext?.match(/^vault:v(\d+):/);
  return m ? Number(m[1]) : null;
}

// ── Error types ───────────────────────────────────────────────────────────────

export class GatewayError extends Error {
  constructor(message, code = 'gateway_error', status = 400) {
    super(message);
    this.name = 'GatewayError';
    this.code = code;
    this.status = status;
  }
}

/** Vault refused the operation (policy). */
export class VaultDeniedError extends Error {
  constructor(message, { vaultErrors = [], vaultPath = null, authority = null } = {}) {
    super(message);
    this.name = 'VaultDeniedError';
    this.code = 'vault_denied';
    this.status = 403;
    this.vault = { status: 403, path: vaultPath, errors: vaultErrors };
    this.authority = authority;
  }
}

/** Vault refused the ciphertext itself (retired version, wrong key, corrupt). */
export class DecryptRejectedError extends Error {
  constructor(message, reason, { vaultErrors = [], vaultPath = null } = {}) {
    super(message);
    this.name = 'DecryptRejectedError';
    this.code = reason; // ciphertext_version_retired | ciphertext_invalid
    this.status = 422;
    this.vault = { status: 400, path: vaultPath, errors: vaultErrors };
  }
}

export class VaultUnavailableError extends Error {
  constructor(message) {
    super(message);
    this.name = 'VaultUnavailableError';
    this.code = 'vault_unavailable';
    this.status = 503;
  }
}

function classifyVaultError(err, authority = null) {
  if (err instanceof GatewayError || err instanceof VaultDeniedError
      || err instanceof DecryptRejectedError || err instanceof VaultUnavailableError) return err;

  const detail = { vaultErrors: err.vaultErrors ?? [], vaultPath: err.vaultPath ?? null, authority };
  const text = (err.vaultErrors ?? []).join(' ').toLowerCase();

  if (err.status === 403) return new VaultDeniedError('Operation denied by Vault policy', detail);
  if (err.status === 400) {
    if (text.includes('disallowed by policy') || text.includes('too old')) {
      return new DecryptRejectedError(
        'Ciphertext was encrypted with a key version below the minimum decryption version',
        'ciphertext_version_retired', detail);
    }
    if (text.includes('message authentication failed') || text.includes('invalid ciphertext')
        || text.includes('unable to decode') || text.includes('too new')
        || text.includes('invalid key version')) {
      return new DecryptRejectedError('Ciphertext is not valid for this key', 'ciphertext_invalid', detail);
    }
  }
  if (err.status >= 500 || err.code === 'vault_unavailable') {
    return new VaultUnavailableError(err.message);
  }
  return err;
}

function vaultMeta(err) {
  return err?.vault ? { vault: err.vault } : {};
}

// ── Scoped execution ──────────────────────────────────────────────────────────

/**
 * Run fn(token) under the tenant's scoped authority. Retries once if the
 * tenant token itself turned out to be dead; a live token + 403 is a genuine
 * policy denial and is thrown as VaultDeniedError.
 */
async function withTenantAuthority(tenantSlug, fn) {
  let auth;
  try {
    auth = await getTenantAuthority(tenantSlug);
  } catch (err) {
    if (err.status === 403 || err.code === 'authority_unavailable') throw err; // Vault refused this identity / no identity
    const e = new VaultUnavailableError(`Could not obtain tenant authority for ${tenantSlug}: ${err.message}`);
    e.code = 'authority_unavailable';
    throw e;
  }
  try {
    return { result: await fn(auth.token), auth };
  } catch (err) {
    if (err.status === 403 && await refreshIfStale(tenantSlug, auth)) {
      auth = await getTenantAuthority(tenantSlug);
      try {
        return { result: await fn(auth.token), auth };
      } catch (retryErr) {
        throw classifyVaultError(retryErr, describe(auth));
      }
    }
    throw classifyVaultError(err, describe(auth));
  }
}

function describe(auth) {
  return auth ? { role: auth.role, user: auth.username, accessor: auth.accessor, source: 'auth/jwt' } : null;
}

function base64(plaintext) {
  return Buffer.from(plaintext, 'utf8').toString('base64');
}

// ── Gateway operations ────────────────────────────────────────────────────────

/**
 * protect — encrypt plaintext under the tenant's key.
 * context: { tenantId, tenantSlug, keyType, resourceType, resourceId, fieldName, actor }
 * Returns: { ciphertext, keyName, keyVersion, auditEventId, authority }
 */
export async function protect(context, plaintext, options = {}) {
  const { tenantId, tenantSlug, keyType = 'customer-data',
    resourceType, resourceId, fieldName, actor = 'system' } = context;
  // options.encoding === 'base64': `plaintext` is already the base64 of raw
  // bytes (an uploaded file) and goes to Transit as-is, so Vault encrypts the
  // file itself, not a text rendering of it.
  const toVault = options.encoding === 'base64' ? p => p : base64;
  if (typeof plaintext !== 'string' || plaintext.length === 0) {
    throw new GatewayError('plaintext must be a non-empty string', 'validation');
  }
  const keyName = resolveKeyName(tenantSlug, keyType);
  const auditBase = { operation: 'PROTECT', tenantId, resourceType, resourceId, fieldName, actor, keyName };

  try {
    const { result, auth } = await withTenantAuthority(tenantSlug, t => vaultEncrypt(t, keyName, toVault(plaintext)));
    const authority = describe(auth);
    const auditEventId = await emitAudit({ ...auditBase, keyVersion: result.keyVersion,
      result: 'ALLOWED', source: 'vault', metadata: { authority } });
    return { ciphertext: result.ciphertext, keyName, keyVersion: result.keyVersion, auditEventId, authority };
  } catch (err) {
    await emitAudit({ ...auditBase, result: 'DENIED', source: err.vault ? 'vault' : 'application',
      metadata: { authority: err.authority ?? null, reason: err.code, ...vaultMeta(err) } });
    throw err;
  }
}

/**
 * recover — decrypt ciphertext under the caller's tenant authority.
 */
export async function recover(context, ciphertext, options = {}) {
  const { tenantId, tenantSlug, keyType = 'customer-data',
    resourceType, resourceId, fieldName, actor = 'system' } = context;
  const keyName = resolveKeyName(tenantSlug, keyType);
  const keyVersion = ciphertextVersion(ciphertext);
  const operation = options.operation ?? 'RECOVER';
  const auditBase = { operation, tenantId, resourceType, resourceId, fieldName, actor, keyName, keyVersion };

  try {
    const r = await withTenantAuthority(tenantSlug, t => vaultDecrypt(t, keyName, ciphertext));
    const authority = describe(r.auth);
    const auditEventId = await emitAudit({ ...auditBase, result: 'ALLOWED', source: 'vault',
      metadata: { authority, ...(options.auditMetadata ?? {}) } });
    return { plaintext: r.result.plaintext, plaintextBase64: r.result.plaintextBase64, keyName, keyVersion, auditEventId, authority };
  } catch (err) {
    const auditEventId = await emitAudit({ ...auditBase, result: 'DENIED',
      source: err.vault ? 'vault' : 'application',
      metadata: { authority: err.authority ?? null, reason: err.code, ...vaultMeta(err),
        ...(options.auditMetadata ?? {}) } });
    err.auditEventId = auditEventId;
    throw err;
  }
}

/**
 * rewrap — re-encrypt under the latest key version inside Vault. The plaintext
 * never reaches the backend.
 */
export async function rewrap(context, ciphertext) {
  const { tenantId, tenantSlug, keyType = 'customer-data',
    resourceType, resourceId, fieldName, actor = 'system' } = context;
  const keyName = resolveKeyName(tenantSlug, keyType);
  const auditBase = { operation: 'REWRAP', tenantId, resourceType, resourceId, fieldName, actor, keyName };

  try {
    const { result, auth } = await withTenantAuthority(tenantSlug, t => vaultRewrap(t, keyName, ciphertext));
    const authority = describe(auth);
    const auditEventId = await emitAudit({ ...auditBase, keyVersion: result.keyVersion,
      result: 'ALLOWED', source: 'vault',
      metadata: { authority, fromVersion: ciphertextVersion(ciphertext) } });
    return { ciphertext: result.ciphertext, keyName, keyVersion: result.keyVersion, auditEventId, authority };
  } catch (err) {
    await emitAudit({ ...auditBase, keyVersion: ciphertextVersion(ciphertext), result: 'DENIED',
      source: err.vault ? 'vault' : 'application',
      metadata: { authority: err.authority ?? null, reason: err.code, ...vaultMeta(err) } });
    throw err;
  }
}

/**
 * rotate — advance the key to a new version (broker authority).
 * Existing ciphertext is untouched; rewrap is a separate operation.
 */
export async function rotate(context) {
  const { tenantId, tenantSlug, keyType = 'customer-data', actor = 'system' } = context;
  const keyName = resolveKeyName(tenantSlug, keyType);
  const auditBase = { operation: 'ROTATE', tenantId, resourceType: 'key', resourceId: null,
    fieldName: null, actor, keyName };

  try {
    const before = await vaultGetKeyInfo(keyName);
    const { auth } = await withTenantAuthority(tenantSlug, t => vaultRotateKey(t, keyName));
    const after = await vaultGetKeyInfo(keyName);
    const auditEventId = await emitAudit({ ...auditBase, keyVersion: after.currentVersion,
      result: 'ALLOWED', source: 'vault',
      metadata: { authority: describe(auth),
        fromVersion: before.currentVersion, toVersion: after.currentVersion } });
    return { keyName, fromVersion: before.currentVersion, currentVersion: after.currentVersion, auditEventId };
  } catch (err) {
    const e = classifyVaultError(err);
    await emitAudit({ ...auditBase, result: 'DENIED', source: e.vault ? 'vault' : 'application',
      metadata: { reason: e.code, ...vaultMeta(e) } });
    throw e;
  }
}

/**
 * setMinDecryptionVersion — raise (or restore) the decryption floor.
 * Ciphertext below the floor becomes unrecoverable by ANY token, including the
 * application's own — enforced by Vault.
 */
export async function setMinDecryptionVersion(context, minDecryptionVersion) {
  const { tenantId, tenantSlug, keyType, actor = 'system' } = context;
  const keyName = resolveKeyName(tenantSlug, keyType);
  const auditBase = { operation: 'KEY_CONFIG', tenantId, resourceType: 'key', resourceId: null,
    fieldName: 'min_decryption_version', actor, keyName };
  try {
    const before = await vaultGetKeyInfo(keyName);
    const { auth } = await withTenantAuthority(tenantSlug,
      t => vaultSetMinDecryptionVersion(t, keyName, minDecryptionVersion));
    const after = await vaultGetKeyInfo(keyName);
    const auditEventId = await emitAudit({ ...auditBase, keyVersion: after.currentVersion,
      result: 'ALLOWED', source: 'vault',
      metadata: { authority: describe(auth), from: before.minDecryptionVersion, to: after.minDecryptionVersion } });
    return { keyName, minDecryptionVersion: after.minDecryptionVersion,
      previousMinDecryptionVersion: before.minDecryptionVersion,
      currentVersion: after.currentVersion, auditEventId };
  } catch (err) {
    const e = classifyVaultError(err);
    await emitAudit({ ...auditBase, result: 'DENIED', source: 'vault',
      metadata: { reason: e.code, requested: minDecryptionVersion, ...vaultMeta(e) } });
    throw e;
  }
}

/**
 * probeIsolation — deliberately use tenant A's authority against tenant B's key.
 * The gateway never does this in normal operation; this exists so the security
 * boundary can be demonstrated live. Returns Vault's verdict, never throws on
 * a denial (a denial is the expected, successful outcome).
 */
export async function probeIsolation(context, targetSlug, operation = 'encrypt') {
  const { tenantId, tenantSlug, actor = 'system', keyType = 'customer-data' } = context;
  const targetKey = resolveKeyName(targetSlug, keyType);
  const auth = await getTenantAuthority(tenantSlug);
  const authority = describe(auth);

  let verdict;
  try {
    if (operation === 'decrypt') {
      await vaultDecrypt(auth.token, targetKey, 'vault:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    } else {
      await vaultEncrypt(auth.token, targetKey, base64('durin-isolation-probe'));
    }
    verdict = { result: 'ALLOWED', vault: { status: 200 } };
  } catch (err) {
    if (err.status === 403) verdict = { result: 'DENIED', vault: { status: 403, errors: err.vaultErrors ?? [] } };
    else if (err.status === 400) {
      // Policy let the request through to the key — isolation is broken even
      // though the dummy ciphertext failed to decrypt.
      verdict = { result: 'ALLOWED', vault: { status: 400, errors: err.vaultErrors ?? [] } };
    } else throw classifyVaultError(err, authority);
  }

  const auditEventId = await emitAudit({
    operation: 'ISOLATION_PROBE', tenantId, resourceType: 'key', actor,
    keyName: targetKey, result: verdict.result, source: 'vault',
    metadata: { authority, operation, sourceTenant: tenantSlug, targetTenant: targetSlug, vault: verdict.vault },
  });

  return {
    sourceTenant: tenantSlug,
    targetTenant: targetSlug,
    targetKey,
    operation,
    authority,
    result: verdict.result,
    isolationEnforced: verdict.result === 'DENIED',
    vault: verdict.vault,
    auditEventId,
  };
}

/**
 * attackerDecrypt — what someone holding only database contents gets from
 * Vault: the request is sent with NO token. Returns Vault's actual response.
 */
export async function attackerDecrypt(context, keyName, ciphertext) {
  const { tenantId, resourceType, resourceId, fieldName } = context;
  let vault;
  let result;
  try {
    await vaultRequest('POST', `transit/decrypt/${keyName}`, { token: null, body: { ciphertext } });
    vault = { status: 200 };
    result = 'ALLOWED';
  } catch (err) {
    if (err.code === 'vault_unavailable') throw new VaultUnavailableError(err.message);
    vault = { status: err.status, errors: err.vaultErrors ?? [] };
    result = 'DENIED';
  }
  const auditEventId = await emitAudit({
    operation: 'COMPROMISE_DECRYPT_ATTEMPT', tenantId, resourceType, resourceId, fieldName,
    actor: 'compromised-db', keyName, keyVersion: ciphertextVersion(ciphertext),
    result, source: 'vault', metadata: { authority: null, vault },
  });
  return { result, vault, auditEventId };
}

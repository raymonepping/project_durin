// gateway/authority.js — identity-derived Vault authority.
// prompts/improvements/01_04
//
// The backend has no cryptographic authority of its own. For every data or key
// operation it presents the caller's Keycloak access token to Vault
// (auth/jwt/login); Vault validates the token and the role's bound claims and
// issues a short-lived token for that PERSON:
//
//   tenant-<t>                 durin_tenants ∋ t|*, role durin-operator
//                              → durin-transit-<t> + durin-keys-<t>, 5 min
//   breakglass-requester-<t>   durin_tenants ∋ t|*, role viewer|operator
//                              → decrypt restricted key under a Control Group, 15 min
//   breakglass-approver        role durin-security-admin
//                              → sys/control-group/authorize, 2 min
//
// No user token → no authority (fail closed). Vault tokens live in process
// memory only, keyed by (user token, role), and never outlive the user's own
// access token. Break-glass wrapping tokens are held here too — Vault
// credentials never reach the frontend.

import { createHash } from 'node:crypto';
import {
  vaultJwtLogin, vaultRevokeSelf, vaultLookupSelf,
  vaultControlGroupDecrypt, vaultControlGroupAuthorize, vaultControlGroupStatus, vaultUnwrapDecrypt,
} from '../vault.js';
import { currentIdentity } from '../request-context.js';

const SLUG_RE = /^[a-z0-9-]{1,50}$/;
const MARGIN_MS = 30_000;

// `${jwtHash}:${role}` → { token, accessor, role, tenant, username, policies, expiresAt }
const userTokens = new Map();
const inflight = new Map();
// break-glass request id → { wrapToken, accessor, expiresAt, tenant }
const pendingBreakGlass = new Map();

function assertSlug(slug) {
  if (!SLUG_RE.test(slug ?? '')) {
    throw Object.assign(new Error(`invalid tenant slug: ${slug}`), { status: 400, code: 'invalid_tenant' });
  }
}

function noIdentity() {
  return Object.assign(
    new Error('No user identity to present to Vault — cryptographic authority is issued to people, not to the backend'),
    { status: 503, code: 'authority_unavailable' },
  );
}

function loginDenied(role, err) {
  const e = new Error(`Vault refused ${role} for this identity`);
  e.status = 403;
  e.code = 'vault_denied';
  e.vault = { status: err.vaultStatus ?? 400, path: 'auth/jwt/login', role, errors: err.vaultErrors ?? [] };
  return e;
}

function jwtHash(jwt) {
  return createHash('sha256').update(jwt).digest('hex').slice(0, 32);
}

function purgeExpired() {
  const now = Date.now();
  for (const [k, v] of userTokens) if (v.expiresAt <= now) userTokens.delete(k);
  for (const [k, v] of pendingBreakGlass) if (v.expiresAt <= now) pendingBreakGlass.delete(k);
}
setInterval(purgeExpired, 60_000).unref();

/** Log the current request's user into a Vault JWT role (cached). */
async function loginAs(role, { tenant = null } = {}) {
  const id = currentIdentity();
  if (!id?.jwt) throw noIdentity();
  const key = `${jwtHash(id.jwt)}:${role}`;
  const cached = userTokens.get(key);
  if (cached && cached.expiresAt - Date.now() > MARGIN_MS) return cached;

  if (!inflight.has(key)) {
    inflight.set(key, (async () => {
      let t;
      try {
        t = await vaultJwtLogin(role, id.jwt);
      } catch (err) {
        if (err.code === 'vault_unavailable') throw err;
        throw loginDenied(role, err);
      }
      const jwtExpMs = (id.user?.exp ?? Infinity) * 1000;
      const entry = {
        token: t.token,
        accessor: t.accessor,
        role,
        tenant,
        username: t.username ?? id.user?.name ?? null,
        policies: t.policies,
        entityId: t.entityId,
        expiresAt: Math.min(Date.now() + t.ttl * 1000, jwtExpMs),
      };
      userTokens.set(key, entry);
      console.log(`[authority] vault login — role=${role} user=${entry.username} accessor=${t.accessor} ttl=${t.ttl}s`);
      return entry;
    })().finally(() => inflight.delete(key)));
  }
  return inflight.get(key);
}

// ── Tenant data + key authority ───────────────────────────────────────────────

export function tenantRole(slug) {
  assertSlug(slug);
  return `tenant-${slug}`;
}

export async function getTenantAuthority(slug) {
  return loginAs(tenantRole(slug), { tenant: slug });
}

/**
 * After a 403 under a user token: true if the token itself was dead (replaced,
 * caller retries once); false if it is alive — a genuine policy denial.
 */
export async function refreshIfStale(_slug, entry) {
  try {
    await vaultLookupSelf(entry.token);
    return false;
  } catch {
    for (const [k, v] of userTokens) if (v.accessor === entry.accessor) userTokens.delete(k);
    return true;
  }
}

/** Revoke every cached user token for a tenant (Shield/Fortify re-issues authority). */
export async function revokeTenantAuthority(slug) {
  const role = tenantRole(slug);
  const revoked = [];
  for (const [k, v] of [...userTokens]) {
    if (v.role !== role) continue;
    userTokens.delete(k);
    try { await vaultRevokeSelf(v.token); } catch { /* already gone */ }
    revoked.push(v.accessor);
  }
  if (revoked.length) console.log(`[authority] revoked ${revoked.length} user token(s) for ${role}`);
  return revoked;
}

export function describeTenantAuthority() {
  const out = {};
  for (const e of userTokens.values()) {
    if (!e.tenant) continue;
    (out[e.tenant] ??= []).push({
      role: e.role,
      user: e.username,
      accessor: e.accessor,
      policies: e.policies,
      expiresAt: new Date(e.expiresAt).toISOString(),
      ttlRemaining: Math.max(0, Math.floor((e.expiresAt - Date.now()) / 1000)),
    });
  }
  return out;
}

// ── Break glass (Vault Control Groups) ───────────────────────────────────────

/**
 * The REQUESTER asks Vault to decrypt RESTRICTED data. Vault holds the answer
 * behind a control group and returns a wrapping token, kept here (never sent
 * to the client). The wrapping token is a child of the requester's 15-minute
 * Vault token, which is therefore left alive (it can only ask, never read).
 */
export async function requestBreakGlass(requestId, slug, keyName, ciphertext) {
  assertSlug(slug);
  const auth = await loginAs(`breakglass-requester-${slug}`);
  let wrapped;
  try {
    wrapped = await vaultControlGroupDecrypt(auth.token, keyName, ciphertext);
  } catch (err) {
    if (err.status === 403) throw loginDenied(`breakglass-requester-${slug}`, err);
    throw err;
  }
  pendingBreakGlass.set(requestId, {
    wrapToken: wrapped.wrapToken,
    accessor: wrapped.accessor,
    tenant: slug,
    expiresAt: Date.now() + wrapped.ttl * 1000,
  });
  console.log(`[authority] control-group request — request=${requestId} user=${auth.username} wrap_accessor=${wrapped.accessor} ttl=${wrapped.ttl}s`);
  return {
    accessor: wrapped.accessor,
    ttl: wrapped.ttl,
    expiresAt: new Date(Date.now() + wrapped.ttl * 1000).toISOString(),
    requesterPolicy: `durin-breakglass-request-${slug}`,
    requesterEntity: auth.entityId,
    requester: auth.username,
  };
}

/** The APPROVER authorises in Vault with their own identity. */
export async function approveBreakGlass(accessor) {
  const auth = await loginAs('breakglass-approver');
  let result;
  try {
    result = await vaultControlGroupAuthorize(auth.token, accessor);
  } catch (err) {
    if (err.status === 403) throw loginDenied('breakglass-approver', err);
    throw err;
  }
  let status = null;
  try { status = await vaultControlGroupStatus(auth.token, accessor); } catch { /* informational */ }
  return { approved: result.approved, approver: auth.username, approverEntity: auth.entityId, status };
}

/** Release the approved decrypt (single use in Vault) and forget the wrapping token. */
export async function redeemBreakGlassFromVault(requestId) {
  const entry = pendingBreakGlass.get(requestId);
  if (!entry) return null;
  pendingBreakGlass.delete(requestId);
  const { plaintext, plaintextBase64 } = await vaultUnwrapDecrypt(entry.wrapToken);
  return { plaintext, plaintextBase64, accessor: entry.accessor };
}

export function holdsBreakGlass(requestId) {
  return pendingBreakGlass.has(requestId);
}

/** Deny / revoke / expiry: forget the wrapping token so nobody can unwrap it. */
export function forgetBreakGlass(requestId) {
  const had = pendingBreakGlass.delete(requestId);
  return had;
}

export async function revokeAllAuthority() {
  const revoked = { tenants: [], breakGlass: [] };
  for (const [k, v] of [...userTokens]) {
    userTokens.delete(k);
    try { await vaultRevokeSelf(v.token); } catch { /* gone */ }
    revoked.tenants.push(v.accessor);
  }
  for (const id of [...pendingBreakGlass.keys()]) {
    pendingBreakGlass.delete(id);
    revoked.breakGlass.push(id);
  }
  return revoked;
}

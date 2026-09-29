// src/vault.js — Vault API client.
//
// Two kinds of token are used, and they carry very different authority:
//
//   Broker token  — the Vault Agent sink (/vault/secrets/token), AppRole
//                   durin-backend. Policies: durin-backend + durin-database.
//                   Key METADATA only. Cannot mint tokens, touch data or keys.
//
//   User token    — issued by Vault to the logged-in PERSON (auth/jwt login
//                   with their Keycloak access token, gateway/authority.js)
//                   and passed explicitly to the data / key functions below.
//
// The broker token is read from disk on every request — never held in memory —
// so token renewal by the agent is transparent.
//
// TLS trust: NODE_EXTRA_CA_CERTS is set to the Durin CA chain in
// compose/backend/compose.yaml, so native fetch() trusts vault-1/2/3.
//
// Reliability hardening (prompt hardening/01):
//   - Distinguishes 403 policy-denied vs 403 token-stale on the broker token;
//     token-stale triggers a one-time re-read of the sink + retry.
//   - Every operation logs the token accessor (never the token itself).
//   - vaultHealthCheck() validates the broker token before reporting "connected".

import { readFile } from 'node:fs/promises';
import { config } from './config.js';

// ── Token management ──────────────────────────────────────────────────────────

let _cachedAccessor = null;

async function readAgentToken() {
  const raw = await readFile(config.vault.tokenFile, 'utf8');
  const token = raw.trim();
  if (!token) throw new Error(`Vault Agent token file is empty: ${config.vault.tokenFile}`);
  return token;
}

/**
 * Heuristically determine whether a Vault 403 is token-stale vs policy-denied.
 * Vault answers both with "permission denied"; an invalid/expired token adds
 * "invalid token" / "bad token" / "token not found", or nothing at all.
 */
export function isTokenStale(vaultErrors = []) {
  const joined = vaultErrors.join(' ').toLowerCase();
  if (joined.includes('token not found')) return true;
  if (joined.includes('missing client token')) return true;
  if (joined.includes('bad token')) return true;
  if (joined.includes('invalid token')) return true;
  return false;
}

async function resolveAccessor(token) {
  try {
    const data = await vaultRequest('GET', 'auth/token/lookup-self', { token });
    return data?.data?.accessor ?? null;
  } catch {
    return null;
  }
}

// ── Core request ──────────────────────────────────────────────────────────────

const FAILOVER_BACKOFF_MS = [500, 1500, 3000];

function isFailoverError(err) {
  // No response at all (connection refused/reset while vault-lb switches to
  // the new leader), or Vault/HAProxy answering 502/503/504 mid-election.
  return err.code === 'vault_unavailable' || [502, 503, 504].includes(err.vaultStatus);
}

async function sendOnce(method, path, { token, body }) {
  const url = `${config.vault.addr}/v1/${path}`;
  const headers = {};
  if (token) headers['X-Vault-Token'] = token;
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  let res;
  try {
    res = await fetch(url, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(5_000),
    });
  } catch (cause) {
    const err = new Error(`Vault unreachable: ${cause.cause?.code ?? cause.name ?? cause.message}`);
    err.status = 503;
    err.code = 'vault_unavailable';
    err.vaultPath = path;
    throw err;
  }

  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = null; }

  if (!res.ok) {
    const errors = data?.errors ?? [];
    const errMsg = errors.join('; ') || res.statusText;
    const err = new Error(`Vault ${method} ${path} → ${res.status} ${errMsg}`);
    err.status = res.status;
    err.vaultStatus = res.status;
    err.vaultErrors = errors;
    err.vaultPath = path;
    throw err;
  }
  return data;
}

/**
 * Raw Vault request. `token` may be null to make an unauthenticated call —
 * used deliberately by the Compromise scenario to show what an attacker who
 * holds only database contents gets back from Vault.
 *
 * Leader failover: vault-lb routes to the active node only, so a leader loss
 * is a few seconds without a backend. Idempotent requests (`retry: true`, the
 * default) are retried with backoff across that window. Non-idempotent ones
 * (key rotation, key config) pass `retry: false` and fail fast. Either way the
 * caller gets a result or a 503 — never a plaintext fallback.
 */
export async function vaultRequest(method, path, { token, body, retry = true } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await sendOnce(method, path, { token, body });
    } catch (err) {
      if (!retry || !isFailoverError(err) || attempt >= FAILOVER_BACKOFF_MS.length) throw err;
      const wait = FAILOVER_BACKOFF_MS[attempt];
      console.warn(`[vault] ${err.message} — retrying ${method} ${path} in ${wait} ms (failover?)`);
      await new Promise(r => setTimeout(r, wait));
    }
  }
}

/**
 * Broker-token request with one automatic retry on a token-stale 403.
 */
async function brokerRequest(method, path, { body, retry = true } = {}) {
  let token = await readAgentToken();
  if (!_cachedAccessor) {
    resolveAccessor(token).then(a => { if (a) _cachedAccessor = a; }).catch(() => {});
  }

  try {
    return await vaultRequest(method, path, { token, body, retry });
  } catch (err) {
    if (err.status !== 403) throw err;

    if (isTokenStale(err.vaultErrors)) {
      const accessor = _cachedAccessor ?? '(unknown)';
      console.warn(`[vault] broker token stale — accessor=${accessor} path=${path} — re-reading sink and retrying`);
      _cachedAccessor = null;
      token = await readAgentToken();
      try {
        const result = await vaultRequest(method, path, { token, body, retry });
        resolveAccessor(token).then(a => { if (a) _cachedAccessor = a; }).catch(() => {});
        console.log(`[vault] retry succeeded after token refresh — path=${path}`);
        return result;
      } catch (retryErr) {
        retryErr.code = 'vault_unavailable';
        retryErr.status = 503;
        retryErr.tokenStale = true;
        throw retryErr;
      }
    }

    err.code = 'vault_denied';
    console.warn(`[vault] policy denial — broker accessor=${_cachedAccessor ?? '(unknown)'} path=${path}`);
    throw err;
  }
}

// ── Identity-derived authority (auth/jwt) ────────────────────────────────────

/**
 * Exchange the user's Keycloak access token for a Vault token. Vault itself
 * validates signature, issuer, audience and the role's bound claims (tenant,
 * Durin role). Unauthenticated endpoint — the backend lends no authority.
 */
export async function vaultJwtLogin(role, jwt) {
  if (!/^[a-z0-9-]+$/.test(role)) throw new Error(`invalid jwt role: ${role}`);
  const data = await vaultRequest('POST', 'auth/jwt/login', { token: null, body: { role, jwt } });
  return {
    token:     data.auth.client_token,
    accessor:  data.auth.accessor,
    policies:  data.auth.token_policies ?? data.auth.policies ?? [],
    ttl:       data.auth.lease_duration,
    entityId:  data.auth.entity_id ?? null,
    username:  data.auth.metadata?.username ?? null,
  };
}

/** Revoke a user-derived token using the token itself (default policy: revoke-self). */
export async function vaultRevokeSelf(token) {
  await vaultRequest('POST', 'auth/token/revoke-self', { token, retry: false });
}

/** Look up a token (cheap validity check). */
export async function vaultLookupSelf(token) {
  const data = await vaultRequest('GET', 'auth/token/lookup-self', { token });
  return data.data;
}

// ── Control Groups (break glass) ─────────────────────────────────────────────

/**
 * Ask Vault to decrypt RESTRICTED data under a control-group policy. Vault
 * answers with a response-wrapping token instead of plaintext; the answer is
 * released only after an approver authorises it.
 */
export async function vaultControlGroupDecrypt(token, keyName, ciphertext) {
  const data = await vaultRequest('POST', `transit/decrypt/${keyName}`, {
    token, body: { ciphertext }, retry: false,
  });
  if (!data?.wrap_info?.token) {
    const err = new Error('Vault returned no control-group wrapping token');
    err.status = 500; err.code = 'control_group_missing';
    throw err;
  }
  return {
    wrapToken:    data.wrap_info.token,
    accessor:     data.wrap_info.accessor,
    ttl:          data.wrap_info.ttl,
    creationTime: data.wrap_info.creation_time,
  };
}

export async function vaultControlGroupAuthorize(token, accessor) {
  const data = await vaultRequest('POST', 'sys/control-group/authorize', {
    token, body: { accessor }, retry: false,
  });
  return { approved: Boolean(data?.data?.approved) };
}

export async function vaultControlGroupStatus(token, accessor) {
  const data = await vaultRequest('POST', 'sys/control-group/request', { token, body: { accessor } });
  const d = data?.data ?? {};
  return {
    approved: Boolean(d.approved),
    requestPath: d.request_path ?? null,
    requestEntity: d.request_entity?.name ?? null,
    authorizations: (d.authorizations ?? []).map(a => a.entity_name ?? a.entity_id),
  };
}

/** Release the approved, wrapped decrypt. Single use — enforced by Vault. */
export async function vaultUnwrapDecrypt(wrapToken) {
  const data = await vaultRequest('POST', 'sys/wrapping/unwrap', { token: wrapToken, retry: false });
  return { plaintext: Buffer.from(data.data.plaintext, 'base64').toString('utf8') };
}

// ── Transit data operations (require a scoped token) ──────────────────────────

export async function vaultEncrypt(token, keyName, base64Plaintext) {
  const data = await vaultRequest('POST', `transit/encrypt/${keyName}`, {
    token, body: { plaintext: base64Plaintext },
  });
  return { ciphertext: data.data.ciphertext, keyVersion: data.data.key_version };
}

export async function vaultDecrypt(token, keyName, ciphertext) {
  const data = await vaultRequest('POST', `transit/decrypt/${keyName}`, {
    token, body: { ciphertext },
  });
  return {
    plaintext: Buffer.from(data.data.plaintext, 'base64').toString('utf8'),
    keyVersion: data.data.key_version ?? null,
  };
}

export async function vaultRewrap(token, keyName, ciphertext) {
  const data = await vaultRequest('POST', `transit/rewrap/${keyName}`, {
    token, body: { ciphertext },
  });
  return { ciphertext: data.data.ciphertext, keyVersion: data.data.key_version };
}

// ── Key metadata (broker token) and lifecycle (user token) ──────────────────────────────────────────────

/** Rotation runs under the operator's Vault token (policy durin-keys-<t>). */
export async function vaultRotateKey(token, keyName) {
  await vaultRequest('POST', `transit/keys/${keyName}/rotate`, { token, retry: false });
}

export async function vaultGetKeyInfo(keyName) {
  const data = await brokerRequest('GET', `transit/keys/${keyName}`);
  const k = data.data;
  return {
    name: k.name,
    type: k.type,
    currentVersion: k.latest_version,
    minDecryptionVersion: k.min_decryption_version,
    minEncryptionVersion: k.min_encryption_version,
    minAvailableVersion: k.min_available_version,
    versions: Object.keys(k.keys ?? {}).map(Number).sort((a, b) => a - b),
    deletionAllowed: k.deletion_allowed,
    exportable: k.exportable,
    allowPlaintextBackup: k.allow_plaintext_backup,
  };
}

/** Operator's Vault token; policy durin-keys-<t> allows min_decryption_version only. */
export async function vaultSetMinDecryptionVersion(token, keyName, minDecryptionVersion) {
  await vaultRequest('POST', `transit/keys/${keyName}/config`, {
    token, body: { min_decryption_version: minDecryptionVersion }, retry: false,
  });
}

export async function vaultListKeys() {
  const data = await brokerRequest('LIST', 'transit/keys');
  return data.data.keys ?? [];
}

// ── Health ────────────────────────────────────────────────────────────────────

/**
 * Validates the broker token by calling lookup-self.
 * A stale token is reported as { ok: false, tokenStale: true } so callers can
 * emit {"vault":"token_stale"} rather than a misleading 403.
 */
export async function vaultHealthCheck() {
  try {
    const token = await readAgentToken();
    const data = await vaultRequest('GET', 'auth/token/lookup-self', { token, retry: false });
    const accessor = data?.data?.accessor ?? null;
    if (accessor) _cachedAccessor = accessor;
    return {
      ok: true,
      accessor,
      ttl: data?.data?.ttl ?? null,
      policies: data?.data?.policies ?? [],
      role: data?.data?.meta?.role_name ?? null,
    };
  } catch (err) {
    const stale = err.status === 403 || isTokenStale(err.vaultErrors ?? []) || err.message.includes('empty');
    return { ok: false, tokenStale: stale, error: err.message };
  }
}

/** Returns the cached broker token accessor (safe to log). */
export function getTokenAccessor() {
  return _cachedAccessor;
}

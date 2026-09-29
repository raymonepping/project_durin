// middleware/auth.js — Durin backend identity + RBAC
//
// Identity, authentication and authorisation are separate from cryptographic
// authority. A valid session with the right role lets a request REACH the Data
// Trust Gateway; whether Vault then performs the operation is decided by the
// scoped Vault token the gateway uses (gateway/authority.js).
//
// Roles (Prompt 17):
//   durin-viewer         — read-only: dashboard, audit, customers, documents, inspector
//   durin-operator       — viewer + scenarios, key lifecycle, customer/document writes
//   durin-security-admin — viewer + break-glass approve / deny / revoke
//
// Modes:
//   DURIN_AUTH_ENABLED=true   Bearer JWT required (Keycloak realm "durin").
//                             Signature via JWKS, alg allowlist, exp/nbf, iss, aud.
//                             Tenant access from the `durin_tenants` claim
//                             (array of slugs, or ["*"] for platform operators).
//   DURIN_AUTH_ENABLED=false  Local demo without the identity stack. Every request
//                             runs as a synthetic identity holding all roles and
//                             all tenants. The optional `x-durin-actor` header names
//                             the demo persona for audit attribution (e.g. the
//                             requester vs the approver in break glass). This mode
//                             is NOT an access control — it exists so the Vault
//                             controls can be demonstrated before Keycloak is up.

import { config } from '../config.js';
import { runWithIdentity } from '../request-context.js';

export const ROLES = {
  VIEWER:         'durin-viewer',
  OPERATOR:       'durin-operator',
  SECURITY_ADMIN: 'durin-security-admin',
};

const ROLE_HIERARCHY = {
  [ROLES.VIEWER]:         [ROLES.VIEWER],
  [ROLES.OPERATOR]:       [ROLES.OPERATOR, ROLES.VIEWER],
  [ROLES.SECURITY_ADMIN]: [ROLES.SECURITY_ADMIN, ROLES.VIEWER],
};

const ALGORITHMS = {
  RS256: { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
  PS256: { name: 'RSA-PSS', hash: 'SHA-256', saltLength: 32 },
  ES256: { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' },
};

// ── JWT validation ────────────────────────────────────────────────────────────

let _jwks = null;
let _jwksLoadedAt = 0;

async function fetchJwks(force = false) {
  const jwksUri = config.auth?.jwksUri;
  if (!jwksUri) throw new Error('DURIN_JWKS_URI not configured');
  if (!force && _jwks && Date.now() - _jwksLoadedAt < 300_000) return _jwks;

  const res = await fetch(jwksUri, { signal: AbortSignal.timeout(5000) });
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  _jwks = await res.json();
  _jwksLoadedAt = Date.now();
  return _jwks;
}

async function verifyJwt(token) {
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('invalid JWT structure');

  const header  = JSON.parse(Buffer.from(parts[0], 'base64url').toString());
  const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());

  const algorithm = ALGORITHMS[header.alg];
  if (!algorithm) throw new Error(`invalid JWT algorithm: ${header.alg}`);

  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp !== 'number' || payload.exp < now) throw new Error('JWT expired');
  if (typeof payload.nbf === 'number' && payload.nbf > now + 30) throw new Error('JWT not yet valid');

  const expectedIssuer = config.auth?.issuer;
  if (expectedIssuer && payload.iss !== expectedIssuer) throw new Error('JWT issuer invalid');

  const expectedAudience = config.auth?.audience;
  if (expectedAudience) {
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.includes(expectedAudience) && payload.azp !== expectedAudience) {
      throw new Error('JWT audience invalid');
    }
  }

  let jwks = await fetchJwks();
  let key = jwks.keys?.find(k => k.kid === header.kid);
  if (!key) {
    jwks = await fetchJwks(true); // key rotation at the IdP
    key = jwks.keys?.find(k => k.kid === header.kid);
  }
  if (!key) throw new Error('JWT signing key invalid (unknown kid)');

  const cryptoKey = await crypto.subtle.importKey('jwk', key, algorithm, false, ['verify']);
  const signature = Buffer.from(parts[2], 'base64url');
  const valid = await crypto.subtle.verify(algorithm, cryptoKey, signature, Buffer.from(`${parts[0]}.${parts[1]}`));
  if (!valid) throw new Error('JWT signature invalid');

  return payload;
}

function extractRoles(payload) {
  return payload?.realm_access?.roles ?? payload?.roles ?? [];
}

function extractTenants(payload) {
  const claim = payload?.durin_tenants ?? payload?.tenants ?? [];
  return Array.isArray(claim) ? claim : String(claim).split(/[\s,]+/).filter(Boolean);
}

export function hasRole(user, requiredRole) {
  for (const userRole of user?.roles ?? []) {
    const included = ROLE_HIERARCHY[userRole] ?? [userRole];
    if (included.includes(requiredRole)) return true;
  }
  return false;
}

// ── Middleware ────────────────────────────────────────────────────────────────

/**
 * authenticate — global. Populates req.user (or leaves it null) and never
 * rejects on its own; requireRole() decides.
 */
export async function authenticate(req, res, next) {
  if (!config.auth?.enabled) {
    const persona = String(req.headers['x-durin-actor'] ?? '').trim().slice(0, 100);
    req.user = {
      sub: 'demo',
      name: persona || 'demo-operator',
      roles: Object.values(ROLES),
      tenants: ['*'],
      demo: true,
    };
    // No JWT → no identity-derived Vault authority (data operations fail closed).
    return runWithIdentity({ jwt: null, user: req.user }, next);
  }

  req.user = null;
  const authHeader = req.headers.authorization ?? '';
  if (!authHeader.startsWith('Bearer ')) return next();

  try {
    const jwt = authHeader.slice(7);
    const payload = await verifyJwt(jwt);
    req.user = {
      sub:     payload.sub,
      name:    payload.preferred_username ?? payload.email ?? payload.sub,
      email:   payload.email,
      roles:   extractRoles(payload),
      tenants: extractTenants(payload),
      exp:     payload.exp,
      demo:    false,
    };
    // The verified token is what the gateway presents to Vault (auth/jwt).
    runWithIdentity({ jwt, user: req.user }, next);
  } catch (err) {
    res.status(401).json({ error: 'unauthorized', message: err.message });
  }
}

/** requireRole(role) — 401 without identity, 403 without the role. */
export function requireRole(role) {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'unauthorized', message: 'Authorization: Bearer <token> required' });
    }
    if (!hasRole(req.user, role)) {
      return res.status(403).json({ error: 'forbidden', message: `Role required: ${role}` });
    }
    next();
  };
}

/** Viewer for safe methods, `writeRole` for anything that changes state. */
export function requireRoleByMethod(writeRole) {
  const read = requireRole(ROLES.VIEWER);
  const write = requireRole(writeRole);
  return (req, res, next) => (['GET', 'HEAD', 'OPTIONS'].includes(req.method) ? read : write)(req, res, next);
}

export function actorOf(req) {
  return req.user?.name ?? 'anonymous';
}

/**
 * Being authenticated is not decryption authority (lead prompt §17). Only
 * operators may cause the gateway to recover plaintext on the normal path;
 * viewers see metadata and ciphertext descriptors. RESTRICTED data needs a
 * break-glass token regardless of role.
 */
export function canRecover(user) {
  return hasRole(user, ROLES.OPERATOR);
}

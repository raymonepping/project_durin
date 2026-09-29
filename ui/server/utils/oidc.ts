// server/utils/oidc.ts — OIDC (Keycloak realm durin) for the BFF.
// prompts/frontend/01_02_authentication_bff.md
//
// Authorization Code + PKCE (S256) with the confidential client durin-backend.
// The browser only ever sees the authorize/logout redirects; the code
// exchange and refresh happen here, server-to-server. Tokens never leave the
// server-side session.
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';

let cachedSecret: string | null = null;

export function oidcConfig() {
  const c = useRuntimeConfig().oidc as {
    publicIssuer: string; internalIssuer: string; clientId: string; clientSecretFile: string;
    clientSecret: string; redirectUri: string; postLogoutRedirectUri: string;
  };
  if (cachedSecret === null) {
    cachedSecret = c.clientSecret || '';
    if (!cachedSecret) {
      try { cachedSecret = readFileSync(c.clientSecretFile, 'utf8').trim(); } catch { cachedSecret = ''; }
    }
  }
  return {
    publicIssuer: c.publicIssuer,
    internalIssuer: c.internalIssuer,
    clientId: c.clientId,
    clientSecret: cachedSecret,
    redirectUri: c.redirectUri,
    postLogoutRedirectUri: c.postLogoutRedirectUri,
  };
}

export const b64url = (buf: Buffer) => buf.toString('base64url');
export const randomToken = (bytes = 32) => b64url(randomBytes(bytes));
export const pkceChallenge = (verifier: string) => b64url(createHash('sha256').update(verifier).digest());

export function decodeJwt(token: string): Record<string, any> {
  const part = token.split('.')[1] ?? '';
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

export interface TokenSet {
  access_token: string;
  refresh_token?: string;
  id_token?: string;
  expires_in: number;
}

async function tokenRequest(params: Record<string, string>): Promise<TokenSet> {
  const cfg = oidcConfig();
  if (!cfg.clientSecret) {
    throw createError({ statusCode: 503, statusMessage: 'oidc_client_secret_missing' });
  }
  const body = new URLSearchParams({ client_id: cfg.clientId, client_secret: cfg.clientSecret, ...params });
  const res = await fetch(`${cfg.internalIssuer}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
    signal: AbortSignal.timeout(8000),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw createError({ statusCode: 401, statusMessage: json.error ?? 'token_request_failed' });
  }
  return json as TokenSet;
}

export const exchangeCode = (code: string, verifier: string) =>
  tokenRequest({ grant_type: 'authorization_code', code, code_verifier: verifier, redirect_uri: oidcConfig().redirectUri });

export const refreshTokens = (refreshToken: string) =>
  tokenRequest({ grant_type: 'refresh_token', refresh_token: refreshToken });

/** The identity the UI may know about — never the tokens themselves. */
export function identityFrom(accessToken: string) {
  const c = decodeJwt(accessToken);
  const roles: string[] = (c.realm_access?.roles ?? []).filter((r: string) => r.startsWith('durin-'));
  const tenants: string[] = Array.isArray(c.durin_tenants) ? c.durin_tenants : (c.durin_tenants ? [c.durin_tenants] : []);
  return {
    sub: c.sub as string,
    name: (c.preferred_username ?? c.email ?? c.sub) as string,
    email: (c.email ?? null) as string | null,
    roles,
    tenants,
  };
}

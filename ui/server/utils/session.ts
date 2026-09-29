// server/utils/session.ts — server-side sessions for the BFF.
//
// The browser holds only an opaque, httpOnly session id. Keycloak tokens
// (access, refresh, ID) live here, in Nitro storage (memory): a UI restart
// simply signs everyone out — fail closed.
import type { H3Event } from 'h3';
import { identityFrom, randomToken, refreshTokens, type TokenSet } from './oidc';

export const SESSION_COOKIE = 'durin_sid';
export const LOGIN_COOKIE = 'durin_login';
const SESSION_TTL_S = 10 * 60 * 60; // matches Keycloak SSO max lifespan (10 h)

export interface DurinSession {
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  expiresAt: number; // ms
  user: ReturnType<typeof identityFrom>;
  createdAt: number;
}

const store = () => useStorage<DurinSession>('sessions');

function cookieOpts(maxAge: number) {
  return { httpOnly: true, sameSite: 'lax' as const, secure: false, path: '/', maxAge };
}

export async function createSession(event: H3Event, tokens: TokenSet) {
  const id = randomToken(32);
  const session: DurinSession = {
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token,
    idToken: tokens.id_token,
    expiresAt: Date.now() + tokens.expires_in * 1000,
    user: identityFrom(tokens.access_token),
    createdAt: Date.now(),
  };
  await store().setItem(id, session);
  setCookie(event, SESSION_COOKIE, id, cookieOpts(SESSION_TTL_S));
  return session;
}

export async function findSession(event: H3Event): Promise<{ id: string; session: DurinSession } | null> {
  const id = getCookie(event, SESSION_COOKIE);
  if (!id) return null;
  const session = await store().getItem(id);
  if (!session) return null;
  return { id, session };
}

export async function destroySession(event: H3Event) {
  const id = getCookie(event, SESSION_COOKIE);
  if (id) await store().removeItem(id);
  deleteCookie(event, SESSION_COOKIE, { path: '/' });
}

/**
 * A session whose access token has at least 60 s left, refreshing it when
 * needed. Returns null when the user must sign in again.
 */
export async function activeSession(event: H3Event): Promise<DurinSession | null> {
  const found = await findSession(event);
  if (!found) return null;
  const { id, session } = found;
  if (session.expiresAt - Date.now() > 60_000) return session;
  if (!session.refreshToken) { await destroySession(event); return null; }
  try {
    const t = await refreshTokens(session.refreshToken);
    const next: DurinSession = {
      ...session,
      accessToken: t.access_token,
      refreshToken: t.refresh_token ?? session.refreshToken,
      idToken: t.id_token ?? session.idToken,
      expiresAt: Date.now() + t.expires_in * 1000,
      user: identityFrom(t.access_token),
    };
    await store().setItem(id, next);
    return next;
  } catch {
    await destroySession(event);
    return null;
  }
}

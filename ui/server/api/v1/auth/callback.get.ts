// GET /api/v1/auth/callback ← Keycloak (code) → server-side exchange → session
import { decodeJwt, exchangeCode } from '../../../utils/oidc';
import { LOGIN_COOKIE, createSession } from '../../../utils/session';

export default defineEventHandler(async (event) => {
  const q = getQuery(event);
  const raw = getCookie(event, LOGIN_COOKIE);
  deleteCookie(event, LOGIN_COOKIE, { path: '/api/v1/auth' });

  const fail = (reason: string) => sendRedirect(event, `/login?error=${encodeURIComponent(reason)}`, 302);
  if (q.error) return fail(String(q.error));
  if (!raw) return fail('login_expired');

  let pending: { state: string; nonce: string; verifier: string; returnTo: string };
  try { pending = JSON.parse(raw); } catch { return fail('login_invalid'); }
  if (!q.code || typeof q.code !== 'string' || q.state !== pending.state) return fail('state_mismatch');

  let tokens;
  try {
    tokens = await exchangeCode(q.code, pending.verifier);
  } catch {
    return fail('token_exchange_failed');
  }
  if (tokens.id_token && decodeJwt(tokens.id_token).nonce !== pending.nonce) return fail('nonce_mismatch');

  await createSession(event, tokens);
  return sendRedirect(event, pending.returnTo || '/', 302);
});

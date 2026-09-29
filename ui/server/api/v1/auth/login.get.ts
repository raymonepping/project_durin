// GET /api/v1/auth/login → Keycloak authorize (code + PKCE S256, state, nonce)
import { oidcConfig, pkceChallenge, randomToken } from '../../../utils/oidc';
import { LOGIN_COOKIE } from '../../../utils/session';

export default defineEventHandler((event) => {
  const cfg = oidcConfig();
  const state = randomToken(24);
  const nonce = randomToken(24);
  const verifier = randomToken(48);
  const q = getQuery(event);
  const returnTo = typeof q.returnTo === 'string' && q.returnTo.startsWith('/') && !q.returnTo.startsWith('//')
    ? q.returnTo : '/';

  // Short-lived, httpOnly binding of this browser to this login attempt.
  setCookie(event, LOGIN_COOKIE, JSON.stringify({ state, nonce, verifier, returnTo }), {
    httpOnly: true, sameSite: 'lax', secure: false, path: '/api/v1/auth', maxAge: 600,
  });

  const url = new URL(`${cfg.publicIssuer}/protocol/openid-connect/auth`);
  url.search = new URLSearchParams({
    client_id: cfg.clientId,
    response_type: 'code',
    scope: 'openid profile email',
    redirect_uri: cfg.redirectUri,
    state,
    nonce,
    code_challenge: pkceChallenge(verifier),
    code_challenge_method: 'S256',
    ...(q.prompt === 'login' ? { prompt: 'login' } : {}),
  }).toString();
  return sendRedirect(event, url.toString(), 302);
});

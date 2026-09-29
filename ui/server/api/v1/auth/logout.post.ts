// POST /api/v1/auth/logout → end the local session, return Keycloak's end-session URL
import { oidcConfig } from '../../../utils/oidc';
import { destroySession, findSession } from '../../../utils/session';

export default defineEventHandler(async (event) => {
  const cfg = oidcConfig();
  const found = await findSession(event);
  await destroySession(event);
  const url = new URL(`${cfg.publicIssuer}/protocol/openid-connect/logout`);
  url.searchParams.set('client_id', cfg.clientId);
  url.searchParams.set('post_logout_redirect_uri', cfg.postLogoutRedirectUri);
  if (found?.session.idToken) url.searchParams.set('id_token_hint', found.session.idToken);
  return { data: { logoutUrl: url.toString() } };
});

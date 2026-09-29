// /api/v1/** (except /auth/*) → durin-backend, with the session's access token.
// prompts/frontend/01_02_authentication_bff.md § Proxy rules
//
// - Authorization: Bearer <access token> added here; the browser never has it.
// - Header allowlist: content-type, x-tenant, x-break-glass-request.
//   x-durin-actor (demo-mode persona header) is never forwarded.
// - State-changing requests must be same-origin (CSRF for cookie auth).
// - 401 from the backend clears the session.
import { activeSession, destroySession } from '../../utils/session';

const FORWARD_HEADERS = ['content-type', 'x-tenant', 'x-break-glass-request'];

export default defineEventHandler(async (event) => {
  const method = event.method.toUpperCase();
  const cfg = useRuntimeConfig();
  const path = getRouterParam(event, 'path') ?? '';

  if (!['GET', 'HEAD'].includes(method)) {
    const origin = getRequestHeader(event, 'origin');
    const csrf = getRequestHeader(event, 'x-durin-csrf');
    if (!(csrf === '1' || origin === cfg.appOrigin)) {
      throw createError({ statusCode: 403, statusMessage: 'csrf_rejected' });
    }
  }

  const session = path === 'health' ? null : await activeSession(event);
  if (path !== 'health' && !session) {
    setResponseStatus(event, 401);
    return { error: 'unauthorized', message: 'Sign in required' };
  }

  const headers: Record<string, string> = {};
  for (const h of FORWARD_HEADERS) {
    const v = getRequestHeader(event, h);
    if (v) headers[h] = v;
  }
  if (session) headers.authorization = `Bearer ${session.accessToken}`;

  const query = getRequestURL(event).search;
  const body = ['GET', 'HEAD'].includes(method) ? undefined : await readRawBody(event, 'utf8');

  let res: Response;
  try {
    res = await fetch(`${cfg.apiInternalUrl}/api/v1/${path}${query}`, {
      method, headers, body: body ?? undefined, signal: AbortSignal.timeout(60_000),
    });
  } catch {
    setResponseStatus(event, 503);
    return { error: 'backend_unavailable', message: 'The Durin backend is not reachable' };
  }

  if (res.status === 401) await destroySession(event);
  setResponseStatus(event, res.status);
  setResponseHeader(event, 'cache-control', 'no-store');
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { error: 'bad_gateway', message: text.slice(0, 200) }; }
});

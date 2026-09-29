// API client through the BFF proxy. Errors are values, never exceptions:
// every page renders Vault's verdict instead of a generic failure.
export interface ApiError {
  status: number;
  error: string;
  message: string;
  vault?: { status?: number; path?: string; role?: string; errors?: string[] } | null;
  authority?: { role?: string; user?: string; accessor?: string; source?: string } | null;
  auditEventId?: string;
  breakGlassRequired?: boolean;
  [k: string]: unknown;
}

export interface ApiResult<T> {
  ok: boolean;
  status: number;
  data: T | null;
  meta: Record<string, any> | null;
  error: ApiError | null;
}

export function useTenant() {
  const tenant = useState<string>('tenant', () => {
    if (import.meta.client) {
      try { return localStorage.getItem('durin.tenant') || 'acme'; } catch { /* ignore */ }
    }
    return 'acme';
  });
  function setTenant(slug: string) {
    tenant.value = slug;
    try { localStorage.setItem('durin.tenant', slug); } catch { /* ignore */ }
  }
  return { tenant, setTenant };
}

export function useApi() {
  const { tenant } = useTenant();

  async function call<T = any>(path: string, opts: {
    method?: 'GET' | 'POST' | 'PUT' | 'DELETE';
    body?: unknown;
    tenant?: string | null;
    headers?: Record<string, string>;
    query?: Record<string, any>;
  } = {}): Promise<ApiResult<T>> {
    const method = opts.method ?? 'GET';
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    const t = opts.tenant === undefined ? tenant.value : opts.tenant;
    if (t) headers['x-tenant'] = t;
    if (method !== 'GET') headers['x-durin-csrf'] = '1';
    try {
      const res = await $fetch.raw<any>(`/api/v1${path}`, {
        method, headers, query: opts.query,
        body: opts.body as any,
        ignoreResponseError: true,
      });
      const json = res._data ?? {};
      if (res.status === 401) {
        const route = useRoute();
        if (route.path !== '/login') await navigateTo(`/login?returnTo=${encodeURIComponent(route.fullPath)}`);
      }
      if (res.status >= 400 || json.error) {
        return { ok: false, status: res.status, data: null, meta: null,
          error: { status: res.status, error: json.error ?? 'error', message: json.message ?? res.statusText, ...json } };
      }
      return { ok: true, status: res.status, data: json.data ?? null, meta: json.meta ?? null, error: null };
    } catch (e: any) {
      return { ok: false, status: 0, data: null, meta: null,
        error: { status: 0, error: 'network', message: e?.message ?? 'Network error' } };
    }
  }

  return { call, tenant };
}

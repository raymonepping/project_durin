// Direct calls through the BFF with the page's own session — used to fetch
// ids and to prove the API refuses what the UI hides. Never a mocked backend.
import type { Page } from '@playwright/test';

export async function api(page: Page, path: string, opts: { method?: 'GET' | 'POST'; tenant?: string; headers?: Record<string, string>; data?: unknown } = {}) {
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.tenant) headers['x-tenant'] = opts.tenant;
  if ((opts.method ?? 'GET') !== 'GET') headers['x-durin-csrf'] = '1';
  const res = await page.request.fetch(`/api/v1${path}`, { method: opts.method ?? 'GET', headers, data: opts.data });
  return { status: res.status(), json: await res.json().catch(() => ({})) as any };
}

export async function customerId(page: Page, name: string, tenant = 'acme') {
  const { json } = await api(page, '/customers', { tenant });
  const c = (json.data ?? []).find((x: any) => x.name === name);
  if (!c) throw new Error(`customer ${name} not found in ${tenant}`);
  return c.id as string;
}

export async function documentId(page: Page, name: string, tenant = 'acme') {
  const { json } = await api(page, '/documents', { tenant });
  const d = (json.data ?? []).find((x: any) => x.name === name);
  if (!d) throw new Error(`document ${name} not found in ${tenant}`);
  return d.id as string;
}

/** Filter the audit page to one operation; returns the first row. */
export async function auditRow(page: Page, operation: string) {
  await page.goto('/audit');
  await page.getByTestId('audit-operation').selectOption(operation);
  const row = page.getByTestId(`audit-${operation}`).first();
  await row.waitFor();
  return row;
}

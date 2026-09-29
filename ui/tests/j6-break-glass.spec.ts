// J6 — Break glass through Vault Control Groups.
import { test, expect, type Page } from '@playwright/test';
import { pageAs } from './auth';
import { api, auditRow, documentId } from './api';

const DOC = 'Production Incident Report #1842';
test.describe.configure({ mode: 'serial' });

let docId = '';
let requestId = '';
const REASON = `Production incident investigation ${Date.now()}`;

async function card(page: Page, reason: string) {
  await page.goto('/break-glass');
  const c = page.getByTestId('break-glass-requests').locator('article').filter({ hasText: reason });
  await c.waitFor();
  return c;
}

test('J6.1 raymon: NORMAL ACCESS DENIED with Vault evidence', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  docId = await documentId(page, DOC);
  await page.goto(`/documents/${docId}?tenant=acme`);
  await page.getByTestId('open-content').click();
  const denied = page.getByTestId('normal-access-denied');
  await expect(denied).toContainText('NORMAL ACCESS DENIED');
  await expect(denied).toContainText('vault 403');
  await expect(denied).toContainText('tenant-acme');
  await context.close();
});

test('J6.2–3 viewer requests; the pending request cannot be redeemed', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'viewer');
  await page.goto(`/documents/${docId}?tenant=acme`);
  await page.getByTestId('break-glass-reason').fill(REASON);
  await page.getByTestId('request-break-glass').click();
  const panel = page.getByTestId('break-glass-panel');
  await expect(panel.getByTestId('break-glass-status')).toHaveText('pending');
  await expect(panel).toContainText('control group · 1 approval from durin-security-admins');
  await expect(panel).toContainText('expires');
  await expect(panel.getByTestId('break-glass-pending')).toContainText('Awaiting approval in Vault');

  const { json } = await api(page, '/break-glass/all');
  requestId = (json.data ?? []).find((r: any) => r.reason === REASON)?.id;
  expect(requestId).toBeTruthy();
  const early = await api(page, `/documents/${docId}/content`, { tenant: 'acme', headers: { 'x-break-glass-request': requestId } });
  expect(early.status).toBe(403);
  expect(early.json.error).toBe('break_glass_pending');
  await context.close();
});

test('J6.4 raymon (operator) cannot approve — control disabled, API 403', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  const c = await card(page, REASON);
  await expect(c.getByTestId('approve')).toBeDisabled();
  const forced = await api(page, `/break-glass/${requestId}/approve`, { method: 'POST', tenant: 'acme', data: {} });
  expect(forced.status).toBe(403);
  await context.close();
});

test('J6.5 security-admin cannot request — approvers cannot be requesters', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'security-admin');
  await page.goto(`/documents/${docId}?tenant=acme`);
  await expect(page.getByTestId('break-glass-panel')).toContainText('Approvers cannot be requesters — enforced by Vault');
  await expect(page.getByTestId('request-break-glass')).toHaveCount(0);
  const forced = await api(page, '/break-glass/request', { method: 'POST', tenant: 'acme', data: { resource_id: docId, reason: 'approver tries to request' } });
  expect(forced.status).toBe(403);
  await context.close();
});

test('J6.6 security-admin approves in Vault', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'security-admin');
  const c = await card(page, REASON);
  await c.getByTestId('approve').click();
  await expect(c).toContainText('BREAK GLASS ACTIVE — approved in Vault');
  await expect(c.getByTestId('bg-status')).toHaveText('approved');
  await context.close();
});

test('J6.7 barend cannot redeem viewer\'s request', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'barend');
  const r = await api(page, `/documents/${docId}/content`, { tenant: 'acme', headers: { 'x-break-glass-request': requestId } });
  expect(r.status).toBe(403);
  expect(r.json.error).toBe('break_glass_not_requester');
  await context.close();
});

test('J6.8–9 viewer redeems once; a second redemption is refused', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'viewer');
  await page.goto(`/documents/${docId}?tenant=acme`);
  await page.getByTestId('redeem').click();
  await expect(page.getByTestId('document-payload')).toContainText('INCIDENT #1842');
  await expect(page.getByTestId('normal-access-restored')).toHaveText('Normal access restored');
  await expect(page.getByTestId('break-glass-status')).toHaveText('used');
  const again = await api(page, `/documents/${docId}/content`, { tenant: 'acme', headers: { 'x-break-glass-request': requestId } });
  expect(again.status).toBe(403);
  expect(again.json.error).toBe('break_glass_used');
  await context.close();
});

test('J6.10 a second request is denied and never redeemable', async ({ browser }) => {
  const reason2 = `Second look ${Date.now()}`;
  const v = await pageAs(browser, 'viewer');
  await v.page.goto(`/documents/${docId}?tenant=acme`);
  await v.page.getByTestId('break-glass-reason').fill(reason2);
  await v.page.getByTestId('request-break-glass').click();
  await expect(v.page.getByTestId('break-glass-status')).toHaveText('pending');

  const s = await pageAs(browser, 'security-admin');
  const c = await card(s.page, reason2);
  await c.getByTestId('deny').click();
  await expect(c.getByTestId('bg-status')).toHaveText('denied');
  await s.context.close();

  const { json } = await api(v.page, '/break-glass/all');
  const id2 = (json.data ?? []).find((r: any) => r.reason === reason2)?.id;
  const r = await api(v.page, `/documents/${docId}/content`, { tenant: 'acme', headers: { 'x-break-glass-request': id2 } });
  expect(r.status).toBe(403);
  expect(r.json.error).toBe('break_glass_denied');
  await v.context.close();
});

test('J6.11 audit: request → approved → recover by viewer / security-admin / viewer', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  for (const [op, actor] of [['BREAK_GLASS_REQUEST', 'viewer'], ['BREAK_GLASS_APPROVED', 'security-admin'], ['BREAK_GLASS_RECOVER', 'viewer']]) {
    const rows = (await auditRow(page, op!)).page().getByTestId(`audit-${op}`).filter({ has: page.getByTestId('audit-result').getByText('ALLOWED') });
    await expect(rows.first().getByTestId('audit-actor')).toHaveText(actor!);
  }
  await context.close();
});

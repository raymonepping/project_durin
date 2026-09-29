// @narrative — prompts/frontend/01_05: the demo story, timed, with zero
// browser console errors. Run after `make reset`:
//   npx playwright test narrative --grep @narrative
import { test, expect, type Page, type BrowserContext } from '@playwright/test';
import { pageAs } from './auth';
import { api, customerId, documentId } from './api';
import type { User } from './users';

const timings: Record<string, number> = {};
const consoleErrors: string[] = [];

async function as(browser: any, u: User): Promise<{ context: BrowserContext; page: Page }> {
  const t0 = Date.now();
  const s = await pageAs(browser, u);
  s.page.on('console', m => { if (m.type() === 'error') consoleErrors.push(`${u} ${s.page.url()}: ${m.text()}`); });
  s.page.on('pageerror', e => consoleErrors.push(`${u} ${s.page.url()}: ${e.message}`));
  await s.page.goto('/');
  await expect(s.page.getByTestId('user-name')).toHaveText(u);
  timings[`persona switch → ${u}`] = Date.now() - t0;
  return s;
}

test('@narrative the story, end to end, timed', async ({ browser }) => {
  test.setTimeout(240_000);
  const start = Date.now();

  // 1 Overview + 2 Inspector
  const r = await as(browser, 'raymon');
  await expect(r.page.getByTestId('tenant-pane-acme')).toBeVisible();
  const alice = await customerId(r.page, 'Alice Smith');
  let t = Date.now();
  await r.page.goto(`/inspector?type=customer&id=${alice}`);
  await expect(r.page.getByTestId('panel-application')).toContainText('NL91ABNA0417164300');
  await expect(r.page.getByTestId('panel-vault')).toContainText('Recovery:');
  timings['Database Inspector load'] = Date.now() - t;

  // 3 Protect, 4 Recover
  await r.page.goto('/protect');
  await r.page.getByTestId('protect-submit').click();
  await expect(r.page.getByTestId('protect-ciphertext')).toHaveText(/^vault:v\d+:/);
  await r.page.goto('/recover');
  await r.page.getByTestId('recover-submit').click();
  await expect(r.page.getByTestId('recover-pane')).toContainText('Cleared by Vault');

  // 5 viewer: authenticated is not authorised
  const v = await as(browser, 'viewer');
  await v.page.goto(`/customers/${alice}?tenant=acme`);
  await expect(v.page.getByText('protected — operator required')).toBeVisible();

  // 6 Compromise
  await r.page.goto('/compromise');
  await r.page.getByTestId('simulate-compromise').click();
  await expect(r.page.getByTestId('compromise-banner')).toBeVisible();
  await r.page.getByTestId('replay-attacker').click();
  await expect(r.page.getByTestId('verdict-attacker')).toContainText('DENIED');

  // 7 Shield
  await r.page.goto('/shield');
  t = Date.now();
  await r.page.getByTestId('fortify').click();
  await expect(r.page.getByTestId('hardened')).toContainText('HARDENED', { timeout: 30_000 });
  timings['Shield (fortify ACME)'] = Date.now() - t;
  await r.page.goto('/compromise');
  await r.page.getByTestId('replay-application').click();
  await expect(r.page.getByTestId('verdict-application')).toContainText('ciphertext_version_retired');
  await r.page.getByTestId('restore-compromise').click();

  // 8 Isolation
  await r.page.goto('/isolation');
  await r.page.getByTestId('isolation-probe').click();
  await expect(r.page.getByTestId('isolation-verdict')).toContainText('Isolation enforced by Vault');

  // 9 Break glass: request → approve in Vault → redeem once
  const doc = await documentId(r.page, 'Production Incident Report #1842');
  t = Date.now();
  await v.page.goto(`/documents/${doc}?tenant=acme`);
  const reason = `Narrative run ${Date.now()}`;
  await v.page.getByTestId('break-glass-reason').fill(reason);
  await v.page.getByTestId('request-break-glass').click();
  await expect(v.page.getByTestId('break-glass-status')).toHaveText('pending');
  const s = await as(browser, 'security-admin');
  await s.page.goto('/break-glass');
  const card = s.page.getByTestId('break-glass-requests').locator('article').filter({ hasText: reason });
  await card.getByTestId('approve').click();
  await expect(card).toContainText('BREAK GLASS ACTIVE');
  await expect(v.page.getByTestId('redeem')).toBeVisible({ timeout: 10_000 });   // viewer's panel polls
  await v.page.getByTestId('redeem').click();
  await expect(v.page.getByTestId('normal-access-restored')).toBeVisible();
  timings['Break glass request → approve → redeem'] = Date.now() - t;

  // Vault page: leader and vault-lb agree
  await r.page.goto('/vault');
  await expect(r.page.getByTestId('vault-summary')).toContainText('routes to the leader');

  // Audit with 100+ events renders
  t = Date.now();
  await r.page.goto('/audit');
  await r.page.getByLabel('Since last reset').uncheck();
  await expect(r.page.getByTestId('audit-table').locator('tbody tr').nth(99)).toBeAttached();
  timings['Audit (100+ events) render'] = Date.now() - t;

  timings['Automated story, total'] = Date.now() - start;
  for (const x of [r, v, s]) await x.context.close();

  console.log('\n01_05 timings (ms)\n' + Object.entries(timings).map(([k, ms]) => `  ${k.padEnd(42)} ${ms}`).join('\n'));
  console.log(`console errors: ${consoleErrors.length}\n${consoleErrors.join('\n')}`);
  expect(timings['Database Inspector load']).toBeLessThan(2_000);
  expect(timings['Shield (fortify ACME)']).toBeLessThan(10_000);
  expect(timings['Break glass request → approve → redeem']).toBeLessThan(60_000);
  for (const u of ['raymon', 'viewer', 'security-admin']) expect(timings[`persona switch → ${u}`]).toBeLessThan(15_000);
  expect(consoleErrors).toEqual([]);
});

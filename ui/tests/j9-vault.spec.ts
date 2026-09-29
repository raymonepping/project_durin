// J9 — Vault page
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';

test('J9.1 leader, two performance standbys, load balancer on the leader, backend metadata only', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/vault');
  const leader = (await page.getByTestId('vault-leader').innerText()).trim();
  expect(leader).toMatch(/^vault-[123]$/);
  await expect(page.getByTestId(`node-${leader}`).getByTestId('node-mode')).toHaveText('active');
  const standbys = ['vault-1', 'vault-2', 'vault-3'].filter(n => n !== leader);
  for (const n of standbys) await expect(page.getByTestId(`node-${n}`).getByTestId('node-mode')).toHaveText('performance-standby');
  await expect(page.getByTestId('lb-active')).toHaveText(leader);
  await expect(page.getByTestId('vault-backend')).toContainText('backend: metadata only');
  await context.close();
});

test('J9.2 @failover the leader card follows a failover without errors', async ({ browser }) => {
  test.setTimeout(180_000);
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/vault');
  const before = (await page.getByTestId('vault-leader').innerText()).trim();
  await expect.poll(async () => (await page.getByTestId('vault-leader').innerText()).trim(), { timeout: 150_000, intervals: [2000] }).not.toBe(before);
  await context.close();
});

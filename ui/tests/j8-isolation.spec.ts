// J8 — isolation (raymon)
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';

test('J8 ACME authority on a Globex key → Vault 403, isolation enforced', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/isolation');
  await page.getByTestId('isolation-target').selectOption('globex');
  await page.locator('#i-op').selectOption('encrypt');
  await page.getByTestId('isolation-probe').click();
  const v = page.getByTestId('isolation-verdict');
  await expect(v).toContainText('DENIED');
  await expect(v).toContainText('Isolation enforced by Vault');
  await expect(v).toContainText('vault 403');
  await expect(page.locator('main')).toContainText('tenant-acme');
  await expect(page.locator('main')).toContainText('Token issued to raymon');
  await expect(page.locator('main')).not.toContainText('Vault authorised raymon');
  await context.close();
});

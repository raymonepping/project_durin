// J4 — SHIELD (raymon, after J3)
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';

test('J4 fortify ACME: steps in order, verified by Vault, stolen copy now retired', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/shield');
  await page.getByTestId('fortify').click();

  const steps = page.getByTestId('fortify-steps').locator(':scope > li');
  await expect(steps).toHaveCount(4, { timeout: 45_000 });
  await expect(steps.nth(0)).toContainText('Rotate');
  await expect(steps.nth(1)).toContainText('Rewrap');
  await expect(steps.nth(2)).toContainText('Raise the floor');
  await expect(steps.nth(3)).toContainText('Re-issue authority');

  const v = page.getByTestId('fortify-verification');
  await expect(v.locator('li').filter({ hasText: 'Legitimate recovery' })).toContainText('ALLOWED');
  await expect(v.locator('li').filter({ hasText: 'Pre-Shield' }).or(v.locator('li').filter({ hasText: 'Stolen copy' }))).toContainText('DENIED');
  await expect(v.locator('li').filter({ hasText: 'Cross-tenant' })).toContainText('DENIED');
  await expect(page.getByTestId('hardened')).toContainText('HARDENED');

  await page.goto('/compromise');
  await page.getByTestId('replay-application').click();
  const app = page.getByTestId('verdict-application');
  await expect(app).toContainText('DENIED');
  await expect(app).toContainText('ciphertext_version_retired');

  await page.goto('/vault');
  const acme = page.getByTestId('keys-acme');
  await expect(acme).toContainText('floor v');
  await expect(acme.locator('.line-through').first()).toBeVisible();
  await context.close();
});

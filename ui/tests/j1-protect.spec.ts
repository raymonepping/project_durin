// J1 — PROTECT (raymon)
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';
import { auditRow } from './api';

test('J1 protect an IBAN: ciphertext, Vault authority, no plaintext stored, audited', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/protect');
  await page.getByTestId('protect-value').fill('NL91ABNA0417164300');
  await page.getByTestId('protect-submit').click();
  await expect(page.getByTestId('protect-ciphertext')).toHaveText(/^vault:v\d+:/);
  const flow = page.getByTestId('protect-flow');
  await expect(flow).toContainText('Vault authorised raymon');
  await expect(flow).toContainText('tenant-acme');
  await expect(flow).toContainText('auth/jwt');
  await expect(page.getByTestId('contains-plaintext')).toHaveText('contains plaintext: false');

  const row = await auditRow(page, 'PROTECT');
  await expect(row.getByTestId('audit-result')).toHaveText('ALLOWED');
  await expect(row.getByTestId('audit-source')).toHaveText('vault');
  await expect(row.getByTestId('audit-actor')).toHaveText('raymon');
  await context.close();
});

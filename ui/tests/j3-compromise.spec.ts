// J3 — COMPROMISE (raymon). The stolen snapshot survives RESTORE, so J4 can
// prove Shield against it.
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';
import { auditRow } from './api';

test('J3 simulate the breach, replay the stolen copy, restore', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/compromise');
  await page.getByTestId('simulate-compromise').click();
  await expect(page.getByTestId('compromise-banner')).toBeVisible();

  // globally visible
  await page.goto('/customers');
  await expect(page.getByTestId('compromise-banner')).toBeVisible();
  await page.goto('/compromise');

  // the stolen data is ciphertext only
  const cells = page.getByTestId('snapshot-table').locator('.cipher');
  await expect(cells.first()).toHaveText(/^vault:v\d+:/);
  await expect(page.getByTestId('snapshot-table')).not.toContainText('NL91ABNA0417164300');

  await page.getByTestId('replay-attacker').click();
  const attacker = page.getByTestId('verdict-attacker');
  await expect(attacker).toContainText('DENIED');
  await expect(attacker).toContainText('vault 403');

  await page.getByTestId('replay-application').click();
  await expect(page.getByTestId('verdict-application')).toContainText('ALLOWED');

  const row = await auditRow(page, 'COMPROMISE_DECRYPT_ATTEMPT');
  await expect(row.getByTestId('audit-result')).toHaveText('DENIED');

  await page.goto('/compromise');
  await page.getByTestId('restore-compromise').click();
  await expect(page.getByTestId('compromise-banner')).toBeHidden();
  await context.close();
});

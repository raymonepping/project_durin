// J2 — RECOVER, and "authenticated is not authorised"
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';
import { auditRow, customerId } from './api';

test('J2.1 raymon recovers Alice Smith\'s IBAN; audit names raymon as the authorised person', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/recover');
  await page.locator('#r-customer').selectOption({ label: 'Alice Smith — ACME Corporation' });
  await page.getByTestId('recover-submit').click();
  await expect(page.getByTestId('recover-pane')).toContainText('NL91ABNA0417164300');
  const row = await auditRow(page, 'RECOVER');
  await expect(row.getByTestId('audit-result')).toHaveText('ALLOWED');
  await expect(row).toContainText('raymon');
  await row.click();
  await expect(page.locator('pre')).toContainText('"user": "raymon"');
  await context.close();
});

test('J2.2 viewer sees protected values masked; recovery is not offered', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'viewer');
  const id = await customerId(page, 'Alice Smith');
  await page.goto(`/customers/${id}?tenant=acme`);
  await expect(page.getByText('protected — operator required')).toBeVisible();
  await expect(page.getByTestId('customer-fields')).not.toContainText('NL91ABNA0417164300');
  await page.goto('/recover');
  await expect(page.getByText('Requires durin-operator')).toBeVisible();
  await context.close();
});

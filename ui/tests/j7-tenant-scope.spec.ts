// J7 — tenant scope (barend: ACME only)
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';
import { customerId } from './api';

test('J7 barend sees only ACME; a Globex deep link renders no data', async ({ browser }) => {
  const r = await pageAs(browser, 'raymon');
  const globexId = await customerId(r.page, (await (await r.page.request.get('/api/v1/customers', { headers: { 'x-tenant': 'globex' } })).json()).data[0].name, 'globex');
  await r.context.close();

  const { context, page } = await pageAs(browser, 'barend');
  await page.goto('/');
  await expect(page.getByTestId('tenant-switcher').locator('option')).toHaveText(['ACME']);
  await page.goto(`/customers/${globexId}?tenant=globex`);
  await expect(page.getByRole('alert')).toContainText(/not authorised for this tenant/i);
  await expect(page.getByRole('alert')).toContainText('tenant_mismatch');
  await expect(page.getByTestId('customer-fields')).toHaveCount(0);
  await context.close();
});

// J5 — Database Inspector
import { test, expect } from '@playwright/test';
import { pageAs } from './auth';
import { customerId, documentId } from './api';

test('J5.1 raymon: three panels — plaintext, ciphertext, Vault state', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  const id = await customerId(page, 'Alice Smith');
  await page.goto(`/inspector?type=customer&id=${id}`);
  await expect(page.getByTestId('panel-application')).toContainText('NL91ABNA0417164300');
  await expect(page.getByTestId('db-iban')).toHaveText(/^vault:v\d+:/);
  await expect(page.getByTestId('panel-database')).not.toContainText('NL91ABNA0417164300');
  const vault = page.getByTestId('panel-vault');
  await expect(vault).toContainText('durin-acme-customer-data');
  await expect(vault.getByTestId('key-exportable')).toHaveText('false');
  await expect(vault.getByTestId('recovery-rule')).toContainText('operator via auth/jwt tenant-acme');
  await context.close();
});

test('J5.2 viewer: application panel is masked (not_authorised)', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'viewer');
  const id = await customerId(page, 'Alice Smith');
  await page.goto(`/inspector?type=customer&id=${id}`);
  const app = page.getByTestId('panel-application');
  await expect(app.getByTestId('app-iban')).toContainText('protected — operator required');
  await expect(app).toContainText('not_authorised');
  await expect(app).not.toContainText('NL91ABNA0417164300');
  await context.close();
});

test('J5.3 RESTRICTED document: normal access denied — break glass required', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  const id = await documentId(page, 'Production Incident Report #1842');
  await page.goto(`/inspector?type=document&id=${id}`);
  await expect(page.getByTestId('inspector-break-glass-required')).toContainText('NORMAL ACCESS DENIED — break glass required');
  await expect(page.getByTestId('recovery-rule')).toContainText('break-glass');
  await context.close();
});

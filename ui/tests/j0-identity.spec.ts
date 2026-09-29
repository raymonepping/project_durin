// J0 — sign-in and identity (prompts/frontend/01_02)
import { test, expect } from '@playwright/test';
import { pageAs, signIn } from './auth';
import { USERS } from './users';

const ROLE: Record<string, string> = { raymon: 'operator', barend: 'operator', viewer: 'viewer', 'security-admin': 'security admin' };

for (const u of USERS) {
  test(`J0.1 ${u}: header shows name and role`, async ({ browser }) => {
    const { context, page } = await pageAs(browser, u);
    await page.goto('/');
    await expect(page.getByTestId('user-name')).toHaveText(u);
    await expect(page.getByTestId('user-role')).toHaveText(ROLE[u]!);
    await context.close();
  });
}

test('J0.2 tenant switcher lists only the tenants in the token', async ({ browser }) => {
  for (const [u, expected] of [['barend', ['ACME']], ['viewer', ['ACME', 'Globex']], ['raymon', ['ACME', 'Globex', 'Initech']]] as const) {
    const { context, page } = await pageAs(browser, u);
    await page.goto('/');
    await expect(page.getByTestId('tenant-switcher').locator('option')).toHaveText([...expected]);
    await context.close();
  }
});

test('J0.3 no token reaches the browser; the session cookie is httpOnly', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  await page.goto('/customers');
  await expect(page.getByTestId('customers-table')).toBeVisible();
  const leaked = await page.evaluate(() => {
    const jwt = /eyJ[\w-]+\.[\w-]+\.[\w-]+/;
    const values = [
      ...Object.keys(localStorage).map(k => localStorage.getItem(k) ?? ''),
      ...Object.keys(sessionStorage).map(k => sessionStorage.getItem(k) ?? ''),
      document.cookie,
    ];
    return values.filter(v => jwt.test(v));
  });
  expect(leaked).toEqual([]);
  expect(await page.evaluate(() => document.cookie)).not.toContain('durin_sid');
  const sid = (await context.cookies()).find(c => c.name === 'durin_sid');
  expect(sid?.httpOnly).toBe(true);
  expect(sid?.value).not.toMatch(/^eyJ/);
  await context.close();
});

test('J0.4 sign out → protected pages redirect to /login', async ({ browser }) => {
  // A fresh session: signing out must not end the shared storageState sessions.
  const context = await browser.newContext();
  const page = await context.newPage();
  await signIn(page, 'barend');
  await page.getByTestId('sign-out').click();
  await page.waitForURL(u => u.origin === 'http://localhost:3000');
  await page.goto('/customers');
  await expect(page).toHaveURL(/\/login/);
  await context.close();
});

// @screens — full-page screenshots of every screen (desktop + phone) into
// docs/screenshots/. Not part of `make test-frontend`; run with
//   npx playwright test screens --grep @screens
import { test } from '@playwright/test';
import { resolve } from 'node:path';
import { pageAs } from './auth';
import { ROOT, type User } from './users';

const OUT = resolve(ROOT, 'docs/screenshots');
const ROUTES = ['/', '/protect', '/recover', '/compromise', '/shield', '/isolation', '/break-glass',
  '/customers', '/documents', '/tenants', '/inspector', '/vault', '/audit'];
const name = (r: string) => (r === '/' ? 'overview' : r.slice(1).replace(/\//g, '-'));

for (const [user, width, height, tag] of [
  ['raymon', 1440, 900, 'desktop'], ['raymon', 390, 844, 'phone'], ['viewer', 1440, 900, 'viewer'],
] as [User, number, number, string][]) {
  test(`@screens ${user} ${tag}`, async ({ browser }) => {
    test.setTimeout(180_000);
    const { context, page } = await pageAs(browser, user);
    await page.setViewportSize({ width, height });
    for (const r of ROUTES) {
      await page.goto(r);
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(700);
      await page.screenshot({ path: `${OUT}/${tag}/${name(r)}.png`, fullPage: true });
    }
    // detail screens
    await page.goto('/customers');
    await page.getByTestId('customers-table').locator('tbody a').first().click();
    await page.waitForLoadState('networkidle'); await page.waitForTimeout(900);
    await page.screenshot({ path: `${OUT}/${tag}/customer-detail.png`, fullPage: true });
    await page.goto('/documents');
    await page.getByRole('link', { name: /Incident Report/ }).first().click();
    await page.waitForLoadState('networkidle'); await page.waitForTimeout(500);
    await page.screenshot({ path: `${OUT}/${tag}/document-detail.png`, fullPage: true });
    await context.close();
  });
}

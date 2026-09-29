// @a11y — axe-core WCAG 2.1 A/AA scan of every screen (prompts/frontend/03_02 Gate 7).
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { pageAs } from './auth';
import type { User } from './users';

const ROUTES = ['/', '/protect', '/recover', '/compromise', '/shield', '/isolation', '/break-glass',
  '/customers', '/documents', '/tenants', '/inspector', '/vault', '/audit'];

async function scan(page: import('@playwright/test').Page) {
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(600);   // let The Clearing finish; frost is not an a11y state
  const r = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  return r.violations.map(v => `${v.id} (${v.impact}) ×${v.nodes.length}: ${v.nodes.slice(0, 3).map(n => n.target.join(' ')).join(' | ')}`);
}

test('@a11y sign-in page', async ({ page }) => {
  await page.goto('/login');
  expect(await scan(page)).toEqual([]);
});

for (const u of ['raymon', 'viewer'] as User[]) {
  test(`@a11y every screen as ${u}`, async ({ browser }) => {
    test.setTimeout(180_000);
    const { context, page } = await pageAs(browser, u);
    const found: string[] = [];
    for (const r of ROUTES) {
      await page.goto(r);
      for (const v of await scan(page)) found.push(`${r}: ${v}`);
    }
    expect(found).toEqual([]);
    await context.close();
  });
}

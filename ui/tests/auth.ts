import { expect, type Page, type Browser } from '@playwright/test';
import { passwordOf, stateFile, type User } from './users';

/** Sign in through the real Keycloak login page. */
export async function signIn(page: Page, user: User, returnTo = '/') {
  await page.goto(`/login?returnTo=${encodeURIComponent(returnTo)}`);
  await page.getByTestId('sign-in').click();
  await page.waitForURL(/\/realms\/durin\//);
  await page.locator('#username').fill(user);
  await page.locator('#password').fill(passwordOf(user));
  await page.locator('#kc-login').click();
  await page.waitForURL((u) => u.origin === 'http://localhost:3000' && !u.pathname.startsWith('/login'));
  await expect(page.getByTestId('user-name')).toHaveText(user);
}

/** A page already signed in as `user` (storageState from global-setup). */
export async function pageAs(browser: Browser, user: User) {
  const context = await browser.newContext({ storageState: stateFile(user) });
  const page = await context.newPage();
  return { context, page };
}

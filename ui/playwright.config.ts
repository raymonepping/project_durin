// playwright.config.ts — prompts/frontend/02_01
// Real users, real Keycloak, real Vault. Nothing is mocked.
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  globalSetup: './tests/global-setup.ts',
  fullyParallel: false,
  workers: 1,               // journeys share one demo state (compromise, shield, break glass)
  timeout: 60_000,
  expect: { timeout: 12_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: process.env.DURIN_UI_URL ?? 'http://localhost:3000',
    ...devices['Desktop Chrome'],
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
});

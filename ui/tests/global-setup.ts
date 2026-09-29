// Start from baseline (make reset), then sign in every user once and save the
// session cookie as storageState. Only the httpOnly durin_sid cookie is stored —
// the tokens never leave the BFF.
import { chromium, type FullConfig } from '@playwright/test';
import { execSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { signIn } from './auth';
import { ROOT, USERS, stateFile } from './users';

export default async function globalSetup(config: FullConfig) {
  if (!process.env.DURIN_SKIP_RESET) execSync('make reset', { cwd: ROOT, stdio: 'inherit' });
  const baseURL = config.projects[0]!.use.baseURL!;
  const browser = await chromium.launch();
  for (const u of USERS) {
    const context = await browser.newContext({ baseURL });
    const page = await context.newPage();
    await signIn(page, u);
    mkdirSync(dirname(stateFile(u)), { recursive: true });
    await context.storageState({ path: stateFile(u) });
    await context.close();
  }
  await browser.close();
}

// Test identities (docs/identity.md). Passwords come from Vault, never from here.
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

export const USERS = ['raymon', 'barend', 'viewer', 'security-admin'] as const;
export type User = (typeof USERS)[number];

export const ROOT = resolve(HERE, '..', '..');
export const stateFile = (u: User) => resolve(HERE, '.auth', `${u}.json`);

export function passwordOf(u: User): string {
  return execFileSync(resolve(ROOT, 'scripts/identity-secrets.sh'), ['--show-user', u], { encoding: 'utf8' }).trim();
}

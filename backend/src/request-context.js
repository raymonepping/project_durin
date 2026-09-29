// src/request-context.js — per-request identity for the Data Trust Gateway.
//
// Since prompts/improvements/01_04 every Vault token that can touch data is
// issued by Vault to the *person* making the request (auth/jwt login with their
// Keycloak access token). The verified token travels here, via
// AsyncLocalStorage, so the gateway can present it to Vault without threading
// it through every route. It is never logged and never stored.
import { AsyncLocalStorage } from 'node:async_hooks';

const store = new AsyncLocalStorage();

export function runWithIdentity(identity, fn) {
  return store.run(identity, fn);
}

/** { jwt, user } for the current request, or null (demo mode / no identity). */
export function currentIdentity() {
  return store.getStore() ?? null;
}

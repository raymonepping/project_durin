// src/config.js — reads and validates all env vars once at startup.

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function optional(name, fallback = '') {
  return process.env[name] || fallback;
}

export const config = {
  port: Number(optional('PORT', '3001')),

  vault: {
    addr:      optional('VAULT_ADDR', 'https://vault-lb:8200'),
    tokenFile: optional('VAULT_AGENT_TOKEN_FILE', '/vault/secrets/token'),
    dbCredsFile: optional('VAULT_DB_CREDS_FILE', '/vault/secrets/db-creds.json'),
  },

  postgres: {
    host:     optional('POSTGRES_HOST', 'postgres'),
    port:     Number(optional('POSTGRES_PORT', '5432')),
    database: required('POSTGRES_DB'),
  },

  // RBAC — set DURIN_AUTH_ENABLED=true once the identity stack (Keycloak) is
  // running.  Until then all auth checks pass with a synthetic demo identity.
  auth: {
    enabled:  optional('DURIN_AUTH_ENABLED', 'false') === 'true',
    jwksUri:  optional('DURIN_JWKS_URI', ''),
    issuer:   optional('DURIN_OIDC_ISSUER', ''),
    audience: optional('DURIN_OIDC_AUDIENCE', 'durin-api'),
  },

  // Resolved from vault-agent-rendered db-creds.json at startup.
  // Set by db.js after reading the agent-rendered file.
  dbCredentials: null,
};

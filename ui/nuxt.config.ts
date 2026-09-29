// nuxt.config.ts — Durin Web Console
//
// SPA (ssr: false) served by the Nuxt/Nitro server, which is also the
// backend-for-frontend (prompts/frontend/01_02): OIDC with Keycloak happens
// server-side, tokens stay in a server-side session, and the browser only
// talks to /api/v1/* on this origin.
import tailwindcss from '@tailwindcss/vite';

export default defineNuxtConfig({
  compatibilityDate: '2025-09-01',
  ssr: false,
  devtools: { enabled: false },
  css: ['~/assets/css/main.css'],
  vite: {
    plugins: [tailwindcss()],
  },
  app: {
    head: {
      title: 'Durin',
      htmlAttrs: { lang: 'en' },
      meta: [
        { name: 'viewport', content: 'width=device-width, initial-scale=1' },
        { name: 'color-scheme', content: 'light' },
        { name: 'description', content: 'Durin — who can turn this ciphertext back into plaintext?' },
      ],
      link: [{ rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    },
  },
  runtimeConfig: {
    // Server-only. Every value can be overridden with NUXT_<NAME> env vars.
    apiInternalUrl: 'http://durin-backend:3001',        // NUXT_API_INTERNAL_URL
    oidc: {
      publicIssuer: 'http://localhost:8083/realms/durin', // browser-facing (authorize, logout)
      internalIssuer: 'http://keycloak:8080/realms/durin', // server-to-server (token, refresh)
      clientId: 'durin-backend',
      clientSecretFile: '/run/secrets/oidc-client-secret', // rendered from Vault by ui-secrets-init
      clientSecret: '',                                     // local dev override only
      redirectUri: 'http://localhost:3000/api/v1/auth/callback',
      postLogoutRedirectUri: 'http://localhost:3000',
    },
    appOrigin: 'http://localhost:3000',
  },
  nitro: {
    storage: {
      sessions: { driver: 'memory' },
    },
  },
});

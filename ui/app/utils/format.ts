// Presentation helpers shared across screens.

export const TENANT_NAMES: Record<string, string> = { acme: 'ACME', globex: 'Globex', initech: 'Initech' };
export const tenantName = (slug?: string | null) => (slug ? TENANT_NAMES[slug] ?? slug : '—');
export const tenantVar = (slug?: string | null) => `var(--color-t-${slug ?? 'acme'})`;

export const FIELD_LABEL: Record<string, string> = {
  iban: 'IBAN', tax_id: 'Tax identifier', payment_info: 'Payment information', payload: 'Document payload',
};

/** vault:v5:AQICAHj4+…rMnQ== — prefix always kept (prompts/frontend/01_04). */
export function shortCipher(ct?: string | null, head = 12, tail = 4) {
  if (!ct) return '';
  const m = ct.match(/^(vault:v\d+:)(.*)$/);
  if (!m) return ct;
  const body = m[2] ?? '';
  return body.length <= head + tail + 1 ? ct : `${m[1]}${body.slice(0, head)}…${body.slice(-tail)}`;
}

export const cipherVersion = (ct?: string | null) => {
  const m = ct?.match(/^vault:v(\d+):/);
  return m ? Number(m[1]) : null;
};

export function maskTail(v?: string | null) {
  if (!v) return '';
  return `${'•'.repeat(Math.max(4, Math.min(12, v.length - 4)))}${v.slice(-4)}`;
}

export function clock(ts?: string | null) {
  if (!ts) return '—';
  return new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

export function dateTime(ts?: string | null) {
  if (!ts) return '—';
  return new Date(ts).toLocaleString([], { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}

/** A human sentence for the API's error codes; the verbatim code is shown beside it. */
export const ERROR_SENTENCE: Record<string, string> = {
  vault_denied: 'Vault refused this identity for that operation.',
  ciphertext_version_retired: 'This ciphertext predates the minimum decryption version — no one can recover it.',
  ciphertext_invalid: 'This ciphertext does not belong to this key.',
  tenant_mismatch: 'Your session is not authorised for this tenant.',
  forbidden: 'Your role does not allow this.',
  unauthorized: 'Sign in required.',
  authority_unavailable: 'Vault could not issue authority right now.',
  vault_unavailable: 'Vault is unreachable. Durin fails closed — no plaintext fallback.',
  separation_of_duties: 'The requester cannot approve their own request.',
  break_glass_not_required: 'This document is not RESTRICTED — normal operator access applies.',
  break_glass_pending: 'Awaiting approval in Vault.',
  break_glass_used: 'This emergency access has already been used.',
  break_glass_revoked: 'This emergency access was revoked.',
  break_glass_denied: 'This request was denied.',
  break_glass_expired: 'This emergency access expired.',
  break_glass_not_requester: 'Only the requester can redeem emergency access.',
  break_glass_invalid: 'No break-glass request exists for this document.',
  break_glass_authority_lost: 'The backend no longer holds the Vault answer — request again.',
  no_compromise_snapshot: 'Simulate the compromise first.',
  would_strand_data: 'Stored values are below that version — rewrap first.',
  not_found: 'Not found in this tenant.',
  validation: 'The request was incomplete.',
  network: 'The console could not reach its server.',
  backend_unavailable: 'The Durin backend is not reachable.',
};

// Who is signed in (from the BFF — never the tokens) and what they may do.
export interface Identity {
  sub: string;
  name: string;
  email: string | null;
  roles: string[];
  tenants: string[];
  accessExpiresAt: string;
}

export type Capability =
  | 'recover' | 'protect' | 'scenario' | 'keys' | 'write'
  | 'approve' | 'request-break-glass';

const ROLE_LABEL: Record<string, string> = {
  'durin-operator': 'operator',
  'durin-security-admin': 'security admin',
  'durin-viewer': 'viewer',
};

export function useIdentity() {
  const me = useState<Identity | null>('identity', () => null);
  const loaded = useState<boolean>('identity-loaded', () => false);

  async function load(force = false) {
    if (loaded.value && !force) return me.value;
    try {
      const res = await $fetch<{ data: Identity }>('/api/v1/auth/me');
      me.value = res.data;
    } catch {
      me.value = null;
    }
    loaded.value = true;
    return me.value;
  }

  const has = (role: string) => me.value?.roles.includes(role) ?? false;
  const isOperator = computed(() => has('durin-operator'));
  const isSecurityAdmin = computed(() => has('durin-security-admin'));
  const isViewer = computed(() => has('durin-viewer'));

  const roleLabel = computed(() => {
    const r = me.value?.roles.find(x => ROLE_LABEL[x]);
    return r ? ROLE_LABEL[r] : 'no role';
  });

  /** A UI courtesy only — the backend and Vault enforce. */
  function can(cap: Capability): boolean {
    switch (cap) {
      case 'recover': case 'protect': case 'scenario': case 'keys': case 'write':
        return isOperator.value;
      case 'approve':
        return isSecurityAdmin.value;
      case 'request-break-glass':
        return isOperator.value || isViewer.value;
    }
  }

  const reason = (cap: Capability) =>
    cap === 'approve' ? 'Requires durin-security-admin'
      : cap === 'request-break-glass' ? 'Approvers cannot be requesters — enforced by Vault'
        : 'Requires durin-operator — Vault only issues data authority to operators';

  async function signOut() {
    const res = await $fetch<{ data: { logoutUrl: string } }>('/api/v1/auth/logout', {
      method: 'POST', headers: { 'x-durin-csrf': '1' },
    });
    me.value = null;
    loaded.value = false;
    window.location.href = res.data.logoutUrl;
  }

  return { me, load, can, reason, isOperator, isSecurityAdmin, isViewer, roleLabel, signOut };
}

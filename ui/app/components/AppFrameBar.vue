<script setup lang="ts">
// The frame bar: tenant (only the signed-in person's tenants), Vault health
// LED, who is signed in and how long their session's access token lives.
import { LogOut, Menu, ChevronDown } from 'lucide-vue-next';

defineEmits<{ menu: [] }>();
const { me, roleLabel, signOut } = useIdentity();
const { tenant, setTenant } = useTenant();
const { vault, refreshVault } = useConsoleState();
const { call } = useApi();

const allTenants = ref<string[]>(['acme', 'globex', 'initech']);
onMounted(async () => {
  const r = await call<any[]>('/tenants', { tenant: null });
  if (r.ok && r.data) allTenants.value = r.data.map(t => t.slug);
});
usePoll(refreshVault, 10_000);

const tenants = computed(() => {
  const mine = me.value?.tenants ?? [];
  return mine.includes('*') ? allTenants.value : allTenants.value.filter(t => mine.includes(t));
});
const vaultTone = computed(() => {
  const s = vault.value?.summary?.status;
  return s === 'healthy' ? 'var(--color-clear)' : s === 'degraded' ? 'var(--color-glass)' : s ? 'var(--color-denied)' : 'var(--color-mullion-dark)';
});
const initials = computed(() => (me.value?.name ?? '?').slice(0, 2).toUpperCase());
</script>

<template>
  <div class="flex h-14 items-center gap-3 px-4 lg:px-6">
    <button class="btn btn-glass !h-9 !px-2.5 lg:hidden" aria-label="Open navigation" @click="$emit('menu')">
      <Menu class="size-4.5" :stroke-width="1.75" />
    </button>

    <label class="relative flex items-center gap-2">
      <span class="sr-only">Tenant</span>
      <span class="hidden text-[0.8rem] font-semibold text-[var(--color-ink-3)] sm:inline">Tenant</span>
      <span class="pointer-events-none absolute left-[3.9rem] hidden size-2.5 rounded-[3px] sm:block" :style="{ background: tenantVar(tenant) }" />
      <select
        class="field !h-9 !w-auto min-w-36 font-semibold sm:!pl-7"
        :value="tenant"
        :disabled="tenants.length < 2"
        data-testid="tenant-switcher"
        @change="setTenant(($event.target as HTMLSelectElement).value)"
      >
        <option v-for="t in tenants" :key="t" :value="t">{{ tenantName(t) }}</option>
      </select>
    </label>

    <NuxtLink
      to="/vault"
      class="hidden items-center gap-2 rounded-full bg-white/60 px-3 py-1.5 text-[0.8rem] font-semibold shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)] transition-colors hover:bg-white/85 md:flex"
      data-testid="vault-pill"
    >
      <span aria-hidden="true" class="led led-live" :style="{ background: vaultTone }" />
      Vault {{ vault?.summary?.status ?? '…' }}
      <span v-if="vault?.summary?.leader" class="mono font-medium text-[var(--color-ink-3)]">{{ vault.summary.leader }}</span>
    </NuxtLink>

    <div class="ml-auto flex items-center gap-3">
      <div v-if="me" class="hidden text-right sm:block">
        <p class="text-[0.9rem] font-semibold leading-tight" data-testid="user-name">{{ me.name }}</p>
        <p class="text-[0.8rem] font-medium leading-tight text-[var(--color-authority)]" data-testid="user-role">{{ roleLabel }}</p>
      </div>
      <span class="grid size-9 place-items-center rounded-full bg-[var(--color-ink)] text-[0.8rem] font-bold text-white shadow-[inset_0_0_0_2px_rgb(255_255_255/0.2)]" aria-hidden="true">{{ initials }}</span>
      <button class="btn btn-glass !h-9 !px-3" data-testid="sign-out" @click="signOut">
        <LogOut class="size-4" :stroke-width="1.75" /><span class="hidden md:inline">Sign out</span>
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ShieldCheck, KeyRound } from 'lucide-vue-next';

const { call, setTenant } = { ...useApi(), ...useTenant() };
const { vault, refreshVault } = useConsoleState();
const tenants = ref<any[]>([]);
const error = ref<any>(null);
const loading = ref(true);

onMounted(async () => {
  const [r] = await Promise.all([call<any[]>('/tenants', { tenant: null }), refreshVault()]);
  tenants.value = r.data ?? []; error.value = r.error; loading.value = false;
});

const keyInfo = (slug: string, name: string) => (vault.value?.transitKeys?.[slug] ?? []).find((k: any) => k.name === name);
const PURPOSE: Record<string, string> = {
  'customer-data': 'IBAN, tax identifier, payment information',
  documents: 'PUBLIC, INTERNAL, CONFIDENTIAL payloads',
  restricted: 'RESTRICTED payloads — decrypt only through break glass',
};
</script>

<template>
  <div>
    <PageHead title="Tenants" lede="Each tenant has its own Transit keys and its own Vault role. A token issued for one tenant opens nothing of another's — Vault policy, not application code." />
    <ErrorNote v-if="error" :error="error" />
    <SkeletonRows v-else-if="loading" :rows="3" />
    <div v-else class="grid gap-5 lg:grid-cols-3" data-testid="tenants">
      <article v-for="t in tenants" :key="t.id" class="pane overflow-hidden" :data-testid="`tenant-${t.slug}`">
        <div class="h-1" :style="{ background: tenantVar(t.slug) }" />
        <div class="p-5">
          <div class="flex items-center justify-between gap-3">
            <TenantPill :slug="t.slug" class="!text-[1.05rem]" />
            <span v-if="t.fortified_at" class="inline-flex items-center gap-1 rounded-full bg-[var(--color-clear-soft)] px-2 py-0.5 text-[0.8rem] font-semibold text-[var(--color-clear)]">
              <ShieldCheck class="size-3.5" :stroke-width="2" /> Shielded {{ dateTime(t.fortified_at) }}
            </span>
          </div>
          <p class="mono mt-1 text-[0.8rem] text-[var(--color-ink-3)]">{{ t.slug }}</p>

          <div class="mt-4 flex items-center gap-2 rounded-lg bg-[var(--color-authority-soft)]/60 px-3 py-2 text-[0.82rem] text-[var(--color-authority)] shadow-[inset_0_0_0_1px_rgb(3_105_161/0.15)]">
            <KeyRound class="size-3.5 shrink-0" :stroke-width="2" />
            <span>Operators log in as <span class="mono font-semibold">{{ t.vaultRole }}</span></span>
          </div>

          <h2 class="mt-5 text-[0.8rem] font-semibold text-[var(--color-ink-2)]">Transit keys</h2>
          <ul class="mt-2 space-y-3">
            <li v-for="k in t.transitKeys" :key="k">
              <div class="flex items-center justify-between gap-2">
                <span class="mono text-[0.8rem] font-medium">{{ k }}</span>
                <KeyChip
                  v-if="keyInfo(t.slug, k)?.currentVersion"
                  :current="keyInfo(t.slug, k).currentVersion"
                  :floor="keyInfo(t.slug, k).minDecryptionVersion"
                  :versions="[Math.max(1, keyInfo(t.slug, k).minDecryptionVersion - 1), keyInfo(t.slug, k).currentVersion].filter((v, i, a) => a.indexOf(v) === i)"
                />
              </div>
              <p class="meta mt-0.5 !text-[0.8rem]">{{ PURPOSE[k.replace(`durin-${t.slug}-`, '')] }}</p>
            </li>
          </ul>

          <button class="btn btn-glass mt-5 w-full justify-center" @click="setTenant(t.slug); navigateTo('/customers')">Work in {{ tenantName(t.slug) }}</button>
        </div>
      </article>
    </div>
  </div>
</template>

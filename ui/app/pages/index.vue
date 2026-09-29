<script setup lang="ts">
import { ArrowRight, ShieldCheck, EyeOff } from 'lucide-vue-next';

const { me } = useIdentity();
const { call } = useApi();
const { scenario, refreshScenario } = useConsoleState();
const now = useNow();

const samples = ref<Record<string, any[]>>({});
const loading = ref(true);

const tenants = computed<string[]>(() => scenario.value?.tenants ?? ['acme', 'globex', 'initech']);
const mayAccess = (t: string) => (me.value?.tenants ?? []).some(x => x === '*' || x === t);

async function load() {
  loading.value = true;
  await refreshScenario();
  const out: Record<string, any[]> = {};
  await Promise.all(tenants.value.filter(mayAccess).map(async (t) => {
    const r = await call<any[]>('/database/tables/protected_values', { tenant: t, query: { limit: 3 } });
    out[t] = r.ok ? (r.data ?? []) : [];
  }));
  samples.value = out;
  loading.value = false;
}
onMounted(load);

const keysFor = (t: string) => ['customer-data', 'documents', 'restricted'].map((p) => {
  const name = `durin-${t}-${p}`;
  return { name, purpose: p, ...(scenario.value?.keys?.[name] ?? {}) };
});
const holders = (t: string) => (scenario.value?.authority?.[t] ?? []) as any[];
const fortified = (t: string) => (scenario.value?.fortifiedTenants ?? []).includes(t);
</script>

<template>
  <div>
    <section class="mb-8 flex flex-wrap items-end justify-between gap-6">
      <div class="max-w-[44rem]">
        <h1 class="text-[2.35rem] font-extrabold leading-[1.05] tracking-[-0.035em] text-balance">
          Who can turn this ciphertext back into plaintext?
        </h1>
        <p class="lede mt-3">
          Every value below is frosted glass: PostgreSQL holds only <span class="cipher !text-[0.92rem]">vault:vN:</span> ciphertext.
          A pane clears only where Vault authorised a person — for one tenant, for five minutes.
        </p>
      </div>
      <NuxtLink v-if="scenario" to="/protect" class="btn btn-primary !h-11 !px-5" data-testid="start-story">
        Start the story: Protect <ArrowRight class="size-4" />
      </NuxtLink>
    </section>

    <!-- The glass wall -->
    <section class="grid gap-5 lg:grid-cols-3" aria-label="Tenants">
      <article
        v-for="t in tenants"
        :key="t"
        class="pane flex flex-col overflow-hidden"
        :data-testid="`tenant-pane-${t}`"
      >
        <div class="h-1" :style="{ background: tenantVar(t) }" />
        <div class="flex items-center justify-between gap-3 px-5 pt-4">
          <TenantPill :slug="t" class="!text-[1.02rem]" />
          <span v-if="fortified(t)" class="inline-flex items-center gap-1 rounded-full bg-[var(--color-clear-soft)] px-2 py-0.5 text-[0.8rem] font-semibold text-[var(--color-clear)]">
            <ShieldCheck class="size-3.5" :stroke-width="2" /> Shielded
          </span>
        </div>

        <template v-if="mayAccess(t)">
          <dl class="grid grid-cols-2 gap-3 px-5 pt-4">
            <div>
              <dt class="meta">Customers</dt>
              <dd class="tabular text-[1.5rem] font-bold tracking-[-0.02em]">{{ scenario?.customersPerTenant?.[t] ?? '—' }}</dd>
            </div>
            <div>
              <dt class="meta">Vault tokens held now</dt>
              <dd class="tabular text-[1.5rem] font-bold tracking-[-0.02em]">{{ holders(t).length }}</dd>
            </div>
          </dl>

          <div class="mt-4 space-y-2 px-5">
            <p class="text-[0.8rem] font-semibold text-[var(--color-ink-2)]">What PostgreSQL holds</p>
            <SkeletonRows v-if="loading" :rows="2" />
            <template v-else>
              <FrostValue
                v-for="row in samples[t]?.slice(0, 2)"
                :key="row.id"
                compact
                :ciphertext="shortCipher(row.ciphertext, 22, 6)"
                state="frosted"
              />
              <p v-if="!samples[t]?.length" class="meta">No protected values — run <span class="mono">make seed</span>.</p>
            </template>
          </div>

          <div class="mt-4 px-5">
            <p class="mb-1.5 text-[0.8rem] font-semibold text-[var(--color-ink-2)]">Transit keys</p>
            <ul class="space-y-1.5">
              <li v-for="k in keysFor(t)" :key="k.name" class="flex items-center justify-between gap-3">
                <span class="text-[0.84rem] text-[var(--color-ink-2)]">{{ k.purpose }}</span>
                <KeyChip :current="k.currentVersion" :floor="k.minDecryptionVersion" :versions="k.currentVersion ? Array.from({ length: Math.min(k.currentVersion, 5) }, (_, i) => k.currentVersion - Math.min(k.currentVersion, 5) + i + 1) : []" />
              </li>
            </ul>
          </div>

          <div class="mt-auto px-5 pb-5 pt-5">
            <p class="mb-1.5 text-[0.8rem] font-semibold text-[var(--color-ink-2)]">Who Vault has authorised</p>
            <ul v-if="holders(t).length" class="space-y-1.5">
              <li v-for="h in holders(t)" :key="h.accessor" class="flex items-center gap-3 text-[0.84rem]">
                <span class="w-24 shrink-0 font-semibold text-[var(--color-authority)]">{{ h.user }}</span>
                <TtlBar class="flex-1" :expires-at="h.expiresAt" :total="300" />
              </li>
            </ul>
            <p v-else class="meta">No one right now — authority is issued per request and expires in five minutes.</p>
          </div>
        </template>

        <!-- tenants outside the session's durin_tenants stay frosted -->
        <div v-else class="relative m-5 mt-4 flex-1 overflow-hidden rounded-xl">
          <div class="space-y-2 p-4 opacity-70" aria-hidden="true">
            <div v-for="i in 5" :key="i" class="h-6 rounded bg-[var(--color-ink-3)]/20" :style="{ width: `${90 - i * 9}%` }" />
          </div>
          <div class="frost-layer grid place-items-center">
            <div class="flex flex-col items-center gap-2 text-center">
              <EyeOff class="size-5 text-[var(--color-ink-2)]" :stroke-width="1.75" />
              <p class="max-w-[16rem] text-[0.86rem] font-semibold text-[var(--color-ink-2)]">Not in your tenants</p>
              <p class="max-w-[16rem] text-[0.8rem] text-[var(--color-ink-3)]">Your token's durin_tenants claim — and Vault's bound claims — keep this pane frosted.</p>
            </div>
          </div>
        </div>
      </article>
    </section>

    <!-- The story in one line -->
    <section class="mt-8 pane p-5">
      <h2 class="h-section">The story</h2>
      <ol class="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
        <li v-for="(s, i) in [
          { to: '/protect', t: 'Protect', d: 'A value enters the boundary. The key never leaves Vault.' },
          { to: '/recover', t: 'Recover', d: 'Vault authorises a person; the pane clears.' },
          { to: '/compromise', t: 'Compromise', d: 'The database is stolen. Ciphertext, no authority.' },
          { to: '/shield', t: 'Shield', d: 'Rotate, rewrap, retire old versions — live-verified.' },
          { to: '/isolation', t: 'Isolation', d: 'ACME authority asks for Globex keys. Vault: 403.' },
          { to: '/break-glass', t: 'Break Glass', d: 'Requested, approved in Vault, released once.' },
        ]" :key="s.to">
          <NuxtLink :to="s.to" class="group block rounded-lg p-2 transition-colors hover:bg-white/60">
            <span class="tabular text-[0.8rem] font-semibold text-[var(--color-ink-3)]">{{ i + 1 }}</span>
            <span class="block font-semibold">{{ s.t }}</span>
            <span class="mt-0.5 block text-[0.82rem] leading-snug text-[var(--color-ink-2)]">{{ s.d }}</span>
          </NuxtLink>
        </li>
      </ol>
    </section>
  </div>
</template>

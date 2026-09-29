<script setup lang="ts">
// The application audit trail. Each row says whether the verdict came from
// Vault (policy, key version, token) or from application logic; the Vault
// accessor correlates it with Vault's own audit device.
import { RefreshCw, ChevronDown } from 'lucide-vue-next';

const { call } = useApi();
const { me } = useIdentity();
const { scenario, refreshScenario } = useConsoleState();

const OPERATIONS = [
  'PROTECT', 'RECOVER', 'INSPECTOR_RECOVER', 'DATABASE_COMPROMISE', 'DATABASE_COMPROMISE_CLEARED',
  'COMPROMISE_DECRYPT_ATTEMPT', 'COMPROMISE_REPLAY', 'ROTATE', 'REWRAP', 'KEY_CONFIG', 'FORTIFY', 'FORTIFY_VERIFY',
  'ISOLATION_PROBE', 'BREAK_GLASS_REQUEST', 'BREAK_GLASS_APPROVED', 'BREAK_GLASS_DENIED', 'BREAK_GLASS_RECOVER',
  'BREAK_GLASS_REVOKED', 'BREAK_GLASS_EXPIRED', 'DEMO_RESET', 'DEMO_SEED',
];

const f = reactive({ tenant: '', operation: '', result: '', source: '', sinceReset: true });
const events = ref<any[]>([]);
const error = ref<any>(null);
const loading = ref(true);
const open = ref<string | null>(null);

const tenantOptions = computed(() => {
  const ts = me.value?.tenants ?? [];
  return ts.includes('*') ? ['acme', 'globex', 'initech'] : ts;
});

async function load() {
  if (!scenario.value) await refreshScenario();
  const q: Record<string, any> = { limit: 200 };
  for (const k of ['tenant', 'operation', 'result', 'source'] as const) if (f[k]) q[k] = f[k];
  if (f.sinceReset && scenario.value?.lastResetAt) q.since = scenario.value.lastResetAt;
  const r = await call<any[]>('/audit', { tenant: null, query: q });
  if (r.ok) events.value = r.data ?? [];
  error.value = r.error; loading.value = false;
}
usePoll(load, 6000);
watch(f, load);

function tone(e: any) {
  if (e.operation === 'DATABASE_COMPROMISE') return 'font-extrabold text-[var(--color-denied)]';
  if (e.operation.startsWith('BREAK_GLASS')) return 'font-semibold text-[var(--color-glass)]';
  if (e.result === 'SIMULATED') return 'text-[var(--color-ink-3)]';
  return 'font-semibold text-[var(--color-ink)]';
}
const resultTone = (r: string) => (r === 'DENIED' ? 'text-[var(--color-denied)] font-bold' : r === 'SIMULATED' ? 'text-[var(--color-ink-3)]' : 'text-[var(--color-ink-2)]');
const authorityUser = (e: any) => e.metadata?.authority?.user ?? null;
const resource = (e: any) => [e.resourceType, e.fieldName].filter(Boolean).join(' · ') || '—';
</script>

<template>
  <div>
    <PageHead title="Audit" lede="Every protect, recover, refusal and emergency access — with who acted, what Vault decided, and which Vault token it was.">
      <button class="btn btn-glass" @click="load"><RefreshCw class="size-4" /> Refresh</button>
    </PageHead>

    <section class="pane mb-5 flex flex-wrap items-end gap-3 p-4" aria-label="Filters">
      <div>
        <label class="label" for="a-tenant">Tenant</label>
        <select id="a-tenant" v-model="f.tenant" class="field !w-36"><option value="">All</option><option v-for="t in tenantOptions" :key="t" :value="t">{{ tenantName(t) }}</option></select>
      </div>
      <div>
        <label class="label" for="a-op">Operation</label>
        <select id="a-op" v-model="f.operation" class="field !w-60" data-testid="audit-operation"><option value="">All</option><option v-for="o in OPERATIONS" :key="o">{{ o }}</option></select>
      </div>
      <div>
        <label class="label" for="a-result">Result</label>
        <select id="a-result" v-model="f.result" class="field !w-36"><option value="">All</option><option>ALLOWED</option><option>DENIED</option><option>SIMULATED</option></select>
      </div>
      <div>
        <label class="label" for="a-source">Decided by</label>
        <select id="a-source" v-model="f.source" class="field !w-40"><option value="">Either</option><option value="vault">Vault</option><option value="application">Application</option></select>
      </div>
      <label class="flex h-10 items-center gap-2 text-[0.86rem] font-medium text-[var(--color-ink-2)]">
        <input v-model="f.sinceReset" type="checkbox" class="size-4 accent-[var(--color-ink)]" /> Since last reset
        <span v-if="scenario?.lastResetAt" class="meta">({{ dateTime(scenario.lastResetAt) }})</span>
      </label>
      <span class="meta tabular ml-auto">{{ events.length }} events</span>
    </section>

    <section class="pane overflow-hidden">
      <ErrorNote v-if="error" :error="error" class="m-5" />
      <div v-else-if="loading" class="p-5"><SkeletonRows :rows="8" /></div>
      <div v-else class="overflow-x-auto" tabindex="0" role="region" aria-label="Audit events">
        <table class="w-full min-w-[56rem] text-left text-[0.84rem]" data-testid="audit-table">
          <thead class="text-[0.8rem] text-[var(--color-ink-3)]">
            <tr class="border-b border-[rgb(15_26_42/0.06)]">
              <th class="px-4 py-2.5 font-semibold">Time</th><th class="px-3 py-2.5 font-semibold">Operation</th>
              <th class="px-3 py-2.5 font-semibold">Tenant</th><th class="px-3 py-2.5 font-semibold">Resource</th>
              <th class="px-3 py-2.5 font-semibold">Actor</th><th class="px-3 py-2.5 font-semibold">Result</th>
              <th class="px-3 py-2.5 font-semibold">Decided by</th><th class="px-3 py-2.5 font-semibold">Vault authorised</th><th class="w-8" />
            </tr>
          </thead>
          <tbody>
            <template v-for="e in events" :key="e.id">
              <tr class="cursor-pointer border-b border-[rgb(15_26_42/0.04)] transition-colors hover:bg-white/50" :data-testid="`audit-${e.operation}`" @click="open = open === e.id ? null : e.id">
                <td class="tabular whitespace-nowrap px-4 py-2.5 text-[var(--color-ink-3)]">{{ clock(e.timestamp) }}</td>
                <td class="mono whitespace-nowrap px-3 py-2.5 !text-[0.8rem]" :class="tone(e)">{{ e.operation }}</td>
                <td class="px-3 py-2.5"><TenantPill v-if="e.tenant" :slug="e.tenant" /><span v-else class="meta">platform</span></td>
                <td class="px-3 py-2.5 text-[var(--color-ink-2)]">{{ resource(e) }}</td>
                <td class="px-3 py-2.5 font-medium" data-testid="audit-actor">{{ e.actor }}</td>
                <td class="px-3 py-2.5" :class="resultTone(e.result)" data-testid="audit-result">{{ e.result }}</td>
                <td class="px-3 py-2.5">
                  <span class="rounded-md px-1.5 py-0.5 text-[0.8rem] font-semibold" :class="e.source === 'vault' ? 'bg-[var(--color-authority-soft)] text-[var(--color-authority)]' : 'bg-white/70 text-[var(--color-ink-3)] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]'" data-testid="audit-source">{{ e.source }}</span>
                </td>
                <td class="px-3 py-2.5 font-semibold text-[var(--color-authority)]">{{ authorityUser(e) ?? '' }}</td>
                <td class="pr-3"><ChevronDown class="size-4 text-[var(--color-ink-3)] transition-transform" :class="open === e.id && 'rotate-180'" /></td>
              </tr>
              <tr v-if="open === e.id" class="bg-white/40">
                <td colspan="9" class="px-4 py-3">
                  <div class="flex flex-wrap gap-x-6 gap-y-1 text-[0.8rem]">
                    <span v-if="e.keyName" class="mono">{{ e.keyName }} · v{{ e.keyVersion }}</span>
                    <span v-if="e.resourceId" class="mono text-[var(--color-ink-3)]">{{ e.resourceId }}</span>
                    <span class="mono text-[var(--color-ink-3)]">event {{ e.id }}</span>
                  </div>
                  <pre class="mono mt-2 max-h-72 overflow-auto rounded-lg bg-[var(--color-ink)] p-3 !text-[0.8rem] leading-relaxed text-[#dbe4ee]">{{ JSON.stringify(e.metadata, null, 2) }}</pre>
                </td>
              </tr>
            </template>
            <tr v-if="!events.length"><td colspan="9" class="meta px-5 py-8 text-center">No events match these filters.</td></tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>

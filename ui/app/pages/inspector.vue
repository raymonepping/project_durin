<script setup lang="ts">
// The Database Inspector — the proof of the thesis: the database stores the
// data without owning the authority to decrypt it. Three equal panels for the
// same record: what the application gets back, what PostgreSQL holds, and
// what Vault says about who may turn one into the other.
import { ArrowRight, ArrowLeft, AppWindow, Database, Server, ShieldX, TriangleAlert, Table2 } from 'lucide-vue-next';

const route = useRoute();
const router = useRouter();
const { call, tenant } = useApi();
const { me } = useIdentity();

const type = computed<'customer' | 'document'>(() => (route.query.type === 'document' ? 'document' : 'customer'));
const recordId = computed(() => (route.query.id ? String(route.query.id) : ''));

const customers = ref<any[]>([]);
const documents = ref<any[]>([]);
const view = ref<any>(null);
const error = ref<any>(null);
const loading = ref(false);
const cleared = ref(false);

async function loadLists() {
  const [c, d] = await Promise.all([call<any[]>('/customers'), call<any[]>('/documents')]);
  customers.value = c.data ?? []; documents.value = d.data ?? [];
  if (!recordId.value && customers.value[0]) select('customer', customers.value[0].id);
}

async function loadRecord() {
  if (!recordId.value) { view.value = null; return; }
  loading.value = true; cleared.value = false; error.value = null;
  const r = await call<any>(`/database/${type.value}s/${recordId.value}`);
  view.value = r.data; error.value = r.error; loading.value = false;
  setTimeout(() => { cleared.value = true; }, 260);
}

function select(t: string, id: string) {
  router.replace({ query: { type: t, id } });
}

onMounted(() => { loadLists(); loadRecord(); loadTables(); });
watch(() => route.query, loadRecord);
watch(tenant, () => { router.replace({ query: {} }); view.value = null; loadLists(); loadTables(); });

const fields = computed(() => Object.entries(view.value?.fields ?? {}) as [string, any][]);
const keys = computed(() => Object.entries(view.value?.vaultState ?? {}) as [string, any][]);
const PLAIN_COLUMNS: Record<string, string[]> = {
  customer: ['name', 'company', 'country'],
  document: ['name', 'classification', 'content_type', 'size_bytes'],
};
const plainColumns = computed(() => PLAIN_COLUMNS[type.value]!);
const title = computed(() => view.value?.databaseView?.name ?? '—');
const keyOf = (name: string) => view.value?.vaultState?.[name];
const outdated = (f: any, name: string) => {
  const ct = view.value?.databaseView?.[name];
  const v = cipherVersion(ct);
  const cur = keyOf(f.keyName)?.currentVersion;
  return v && cur && v < cur ? { v, cur, retired: v < (keyOf(f.keyName)?.minDecryptionVersion ?? 0) } : null;
};
const authorityUser = computed(() => (fields.value.some(([, f]) => f.application.state === 'recovered') ? me.value?.name : null));

// ── Raw tables ────────────────────────────────────────────────────────────
const tables = ref<any[]>([]);
const table = ref('protected_values');
const rows = ref<any[]>([]);
const rowsMeta = ref<any>(null);
const rowsError = ref<any>(null);

async function loadTables() {
  const r = await call<any[]>('/database/tables');
  tables.value = r.data ?? [];
  loadRows();
}
async function loadRows() {
  const r = await call<any[]>(`/database/tables/${table.value}`, { query: { limit: 25 } });
  rows.value = r.data ?? []; rowsMeta.value = r.meta; rowsError.value = r.error;
}
watch(table, loadRows);
const columns = computed(() => (rows.value[0] ? Object.keys(rows.value[0]) : []));
const isCipher = (v: unknown) => typeof v === 'string' && /^vault:v\d+:/.test(v);
const cell = (v: unknown) => {
  if (v === null || v === undefined) return '∅';
  if (typeof v === 'object') return JSON.stringify(v);
  const s = String(v);
  if (isCipher(s)) return shortCipher(s);
  return s.length > 48 ? `${s.slice(0, 45)}…` : s;
};
</script>

<template>
  <div>
    <PageHead title="Database Inspector" lede="The same record three ways. PostgreSQL holds ciphertext it cannot open; only Vault decides who may turn it back into plaintext.">
      <div class="flex w-full flex-wrap gap-2 sm:w-auto">
        <select class="field w-full sm:!w-[22rem]" aria-label="Record" data-testid="inspector-record" :value="`${type}:${recordId}`" @change="(e: any) => { const [t, i] = e.target.value.split(':'); select(t, i); }">
          <optgroup label="Customers">
            <option v-for="c in customers" :key="c.id" :value="`customer:${c.id}`">{{ c.name }}</option>
          </optgroup>
          <optgroup label="Documents">
            <option v-for="d in documents" :key="d.id" :value="`document:${d.id}`">{{ d.name }} · {{ d.classification }}</option>
          </optgroup>
        </select>
      </div>
    </PageHead>

    <ErrorNote v-if="error" :error="error" class="mb-5" />
    <div v-else-if="loading && !view" class="pane p-5"><SkeletonRows :rows="5" /></div>

    <template v-if="view">
      <!-- direction of travel -->
      <div class="mb-3 hidden items-center gap-3 text-[0.8rem] font-semibold text-[var(--color-ink-3)] xl:flex">
        <span class="flex items-center gap-1.5 text-[var(--color-cipher)]">protect <ArrowRight class="size-3.5" /> plaintext → Vault → ciphertext stored</span>
        <span class="ml-auto flex items-center gap-1.5 text-[var(--color-clear)]"><ArrowLeft class="size-3.5" /> recover: stored ciphertext → Vault → plaintext, if authorised</span>
      </div>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto_minmax(0,1fr)]" data-testid="inspector-panels">
        <!-- Application -->
        <section class="pane flex flex-col p-5" data-testid="panel-application">
          <header class="flex items-center gap-2">
            <AppWindow class="size-4.5 text-[var(--color-clear)]" :stroke-width="1.75" />
            <h2 class="h-section">Application</h2>
          </header>
          <p class="meta mt-1">What the gateway returns to <strong>{{ me?.name }}</strong>.</p>
          <dl class="mt-4 space-y-2 text-[0.88rem]">
            <div v-for="c in plainColumns" :key="c" class="flex justify-between gap-3">
              <dt class="meta">{{ c }}</dt><dd class="truncate font-medium">{{ view.applicationView[c] ?? '—' }}</dd>
            </div>
          </dl>
          <div class="mt-5 space-y-4">
            <template v-for="[name, f] in fields" :key="name">
              <div v-if="f.breakGlassRequired && f.application.state !== 'recovered'" class="rounded-xl bg-[var(--color-denied-soft)]/60 p-3.5 shadow-[inset_0_0_0_1px_rgb(200_30_30/0.2)]" data-testid="inspector-break-glass-required">
                <p class="flex items-center gap-2 text-[0.86rem] font-bold text-[var(--color-denied)]"><ShieldX class="size-4" /> NORMAL ACCESS DENIED — break glass required</p>
                <p class="mt-1 text-[0.8rem] text-[var(--color-ink-2)]">{{ FIELD_LABEL[name] ?? name }}: the restricted key refuses decrypt on the normal path{{ f.application.reason ? ` (${f.application.reason})` : '' }}.</p>
                <NuxtLink :to="`/documents/${view.databaseView.id}`" class="mt-2 inline-block text-[0.8rem] font-semibold text-[var(--color-glass)] hover:underline">Request break glass →</NuxtLink>
              </div>
              <div v-else-if="f.application.state === 'not_authorised'">
                <p class="mb-1.5 text-[0.8rem] font-semibold text-[var(--color-ink-2)]">{{ FIELD_LABEL[name] ?? name }}</p>
                <p class="rounded-lg bg-white/60 px-3 py-2.5 text-[0.84rem] text-[var(--color-ink-2)] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]" :data-testid="`app-${name}`">
                  <span class="tracking-[0.12em]">●●●●●●●●</span> protected — operator required
                </p>
                <p class="mono mt-1 text-[0.8rem] text-[var(--color-ink-3)]">not_authorised</p>
              </div>
              <FrostValue
                v-else
                :label="FIELD_LABEL[name] ?? name"
                :state="f.application.state === 'recovered' ? (cleared ? 'clear' : 'frosted') : 'denied'"
                :plaintext="view.applicationView[name]"
                :ciphertext="shortCipher(view.databaseView[name])"
                :reason="f.application.reason ?? null"
                :data-testid="`app-${name}`"
              />
            </template>
          </div>
          <p v-if="authorityUser" class="mt-auto pt-4 text-[0.8rem] text-[var(--color-authority)]">Vault authorised <strong>{{ authorityUser }}</strong> · auth/jwt tenant-{{ tenant }} · audited INSPECTOR_RECOVER</p>
        </section>

        <div class="hidden items-center xl:flex" aria-hidden="true">
          <span class="flex flex-col items-center gap-1 text-[var(--color-mullion-dark)]"><ArrowRight class="size-4" /><ArrowLeft class="size-4" /></span>
        </div>

        <!-- Database -->
        <section class="pane flex flex-col p-5" data-testid="panel-database">
          <header class="flex items-center gap-2">
            <Database class="size-4.5 text-[var(--color-cipher)]" :stroke-width="1.75" />
            <h2 class="h-section">Database</h2>
          </header>
          <p class="meta mt-1">Exactly what PostgreSQL stores. Nothing here is decrypted.</p>
          <dl class="mt-4 space-y-2 text-[0.88rem]">
            <div v-for="c in plainColumns" :key="c" class="flex justify-between gap-3">
              <dt class="meta">{{ c }}</dt><dd class="truncate font-medium">{{ view.databaseView[c] ?? '—' }}</dd>
            </div>
          </dl>
          <div class="mt-5 space-y-4">
            <div v-for="[name, f] in fields" :key="name">
              <div class="mb-1.5 flex items-center justify-between gap-2">
                <span class="text-[0.8rem] font-semibold text-[var(--color-ink-2)]">{{ FIELD_LABEL[name] ?? name }}</span>
                <span class="mono text-[0.8rem] text-[var(--color-ink-3)]">protected_values</span>
              </div>
              <p class="cipher rounded-lg bg-[var(--color-cipher-soft)]/50 px-3 py-2.5 shadow-[inset_0_0_0_1px_rgb(109_40_217/0.14)]" :title="view.databaseView[name]" :data-testid="`db-${name}`">{{ shortCipher(view.databaseView[name]) || '∅' }}</p>
              <p v-if="outdated(f, name)" class="mt-1 flex items-center gap-1 text-[0.8rem] font-semibold" :class="outdated(f, name)!.retired ? 'text-[var(--color-denied)]' : 'text-[var(--color-glass)]'">
                <TriangleAlert class="size-3.5" /> v{{ outdated(f, name)!.v }} {{ outdated(f, name)!.retired ? 'retired — unrecoverable by anyone' : `outdated (current: v${outdated(f, name)!.cur})` }}
              </p>
            </div>
          </div>
        </section>

        <div class="hidden items-center xl:flex" aria-hidden="true">
          <span class="flex flex-col items-center gap-1 text-[var(--color-mullion-dark)]"><ArrowRight class="size-4" /><ArrowLeft class="size-4" /></span>
        </div>

        <!-- Vault State -->
        <section class="pane flex flex-col p-5" data-testid="panel-vault">
          <header class="flex items-center gap-2">
            <Server class="size-4.5 text-[var(--color-authority)]" :stroke-width="1.75" />
            <h2 class="h-section">Vault State</h2>
          </header>
          <p class="meta mt-1">Who can turn this ciphertext back into plaintext?</p>
          <div v-for="[name, k] in keys" :key="name" class="mt-4 rounded-xl bg-white/55 p-3.5 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.07)]">
            <p class="mono text-[0.8rem] font-semibold">{{ name }}</p>
            <ErrorNote v-if="k.error" :error="{ status: 0, error: k.error, message: k.error }" class="mt-2" />
            <template v-else>
              <KeyChip class="mt-2" :versions="k.versions" :current="k.currentVersion" :floor="k.minDecryptionVersion" />
              <dl class="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5 text-[0.8rem]">
                <dt class="meta">type</dt><dd class="mono">{{ k.type }}</dd>
                <dt class="meta">decryption floor</dt><dd class="mono">v{{ k.minDecryptionVersion }}</dd>
                <dt class="meta">exportable</dt><dd class="mono" data-testid="key-exportable">{{ k.exportable }}</dd>
                <dt class="meta">deletion allowed</dt><dd class="mono">{{ k.deletionAllowed }}</dd>
              </dl>
              <div class="mt-3 rounded-lg px-3 py-2 text-[0.8rem]" :class="k.recovery?.requires === 'break-glass' ? 'bg-[var(--color-glass-soft)]/70 text-[var(--color-glass)]' : 'bg-[var(--color-authority-soft)]/70 text-[var(--color-authority)]'" data-testid="recovery-rule">
                <p class="font-semibold">Recovery: {{ k.recovery?.requires }} via {{ k.recovery?.vaultRole ?? k.recovery?.vaultPolicy }}</p>
                <p class="mt-0.5 text-[var(--color-ink-2)]">Normal path: {{ k.recovery?.normalPath }}<template v-if="k.recovery?.mechanism"> · {{ k.recovery.mechanism }}</template></p>
              </div>
              <p class="meta mt-2 !text-[0.8rem]">Key material never leaves Vault.</p>
            </template>
          </div>
        </section>
      </div>
      <p class="meta mt-3">{{ title }} · {{ tenantName(tenant) }}</p>
    </template>

    <!-- Raw tables -->
    <section class="pane mt-8 overflow-hidden" data-testid="raw-tables">
      <div class="flex flex-wrap items-center gap-3 px-5 pt-4">
        <Table2 class="size-4.5 text-[var(--color-ink-2)]" :stroke-width="1.75" />
        <h2 class="h-section">Raw PostgreSQL rows</h2>
        <span class="meta">{{ rowsMeta?.representation ?? 'raw PostgreSQL rows — nothing decrypted' }}</span>
      </div>
      <div class="flex flex-wrap gap-1.5 px-5 pt-3" role="tablist">
        <button
          v-for="t in tables" :key="t.table" role="tab" :aria-selected="table === t.table"
          class="rounded-lg px-2.5 py-1 text-[0.8rem] font-semibold transition-colors"
          :class="table === t.table ? 'bg-[var(--color-ink)] text-white' : 'bg-white/60 text-[var(--color-ink-2)] hover:bg-white/90'"
          @click="table = t.table"
        >
          {{ t.table }} <span class="tabular opacity-70">{{ t.rows }}</span>
        </button>
      </div>
      <ErrorNote v-if="rowsError" :error="rowsError" class="m-5" />
      <div v-else class="mt-3 max-h-[28rem] overflow-auto" tabindex="0" role="region" :aria-label="`Raw rows of ${table}`">
        <table class="w-full text-left text-[0.8rem]">
          <thead class="sticky top-0 bg-[var(--color-ground)]/95 backdrop-blur">
            <tr><th v-for="c in columns" :key="c" class="mono whitespace-nowrap px-3 py-2 font-semibold text-[var(--color-ink-3)]">{{ c }}</th></tr>
          </thead>
          <tbody>
            <tr v-for="(r, i) in rows" :key="i" class="border-t border-[rgb(15_26_42/0.05)]">
              <td v-for="c in columns" :key="c" class="mono whitespace-nowrap px-3 py-1.5" :class="isCipher(r[c]) ? 'text-[var(--color-cipher)]' : 'text-[var(--color-ink-2)]'" :title="typeof r[c] === 'string' ? r[c] : undefined">{{ cell(r[c]) }}</td>
            </tr>
            <tr v-if="!rows.length"><td class="meta px-5 py-6">No rows for {{ tenantName(tenant) }}.</td></tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>

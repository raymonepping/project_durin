<script setup lang="ts">
import { Plus, Search } from 'lucide-vue-next';

const { call, tenant } = useApi();
const { can, reason } = useIdentity();
const customers = ref<any[]>([]);
const loading = ref(true);
const error = ref<any>(null);
const q = ref('');
const showNew = ref(false);
const form = reactive({ name: '', company: '', country: '', iban: '', tax_id: '', payment_info: '' });
const saving = ref(false);
const created = ref<any>(null);

async function load() {
  loading.value = true;
  const r = await call<any[]>('/customers');
  customers.value = r.data ?? []; error.value = r.error; loading.value = false;
}
onMounted(load);
watch(tenant, load);

const filtered = computed(() => customers.value.filter(c =>
  [c.name, c.company, c.country].some(v => (v ?? '').toLowerCase().includes(q.value.toLowerCase()))));

async function create() {
  saving.value = true;
  const body = Object.fromEntries(Object.entries(form).filter(([, v]) => v));
  const r = await call('/customers', { method: 'POST', body });
  saving.value = false;
  if (!r.ok) { error.value = r.error; return; }
  created.value = r.data; showNew.value = false;
  Object.assign(form, { name: '', company: '', country: '', iban: '', tax_id: '', payment_info: '' });
  load();
}
</script>

<template>
  <div>
    <PageHead :title="`Customers — ${tenantName(tenant)}`" lede="Names, companies and countries are plain metadata. IBAN, tax identifier and payment information exist only as ciphertext.">
      <button class="btn btn-primary" :disabled="!can('write')" :title="can('write') ? '' : reason('write')" @click="showNew = !showNew">
        <Plus class="size-4" /> New customer
      </button>
    </PageHead>

    <form v-if="showNew" class="pane mb-5 grid gap-4 p-5 md:grid-cols-3" @submit.prevent="create">
      <div><label class="label" for="c-name">Name</label><input id="c-name" v-model="form.name" class="field" required /></div>
      <div><label class="label" for="c-company">Company</label><input id="c-company" v-model="form.company" class="field" /></div>
      <div><label class="label" for="c-country">Country</label><input id="c-country" v-model="form.country" class="field" maxlength="2" placeholder="NL" /></div>
      <div><label class="label" for="c-iban">IBAN (protected)</label><input id="c-iban" v-model="form.iban" class="field mono" /></div>
      <div><label class="label" for="c-tax">Tax identifier (protected)</label><input id="c-tax" v-model="form.tax_id" class="field mono" /></div>
      <div><label class="label" for="c-pay">Payment information (protected)</label><input id="c-pay" v-model="form.payment_info" class="field mono" /></div>
      <div class="flex items-center gap-3 md:col-span-3">
        <button class="btn btn-primary" :disabled="saving">{{ saving ? 'Protecting and saving…' : 'Protect and save' }}</button>
        <span class="meta">Fields are protected by Vault first; if Vault refuses, nothing is written.</span>
      </div>
    </form>
    <div v-if="created" class="pane mb-5 flex flex-wrap items-center gap-3 p-4 text-[0.9rem]">
      <span class="font-semibold">{{ created.name }}</span> saved — {{ Object.keys(created.protectedFields ?? {}).length }} fields stored as ciphertext.
      <NuxtLink :to="`/customers/${created.id}`" class="btn btn-glass ml-auto">Open</NuxtLink>
    </div>

    <section class="pane overflow-hidden">
      <div class="flex items-center gap-3 px-5 py-3.5">
        <div class="relative w-full max-w-xs">
          <Search class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-[var(--color-ink-3)]" />
          <input v-model="q" class="field !pl-9" placeholder="Search name, company, country" aria-label="Search customers" />
        </div>
        <span class="meta ml-auto tabular">{{ filtered.length }} customers</span>
      </div>
      <ErrorNote v-if="error" :error="error" class="mx-5 mb-5" />
      <div v-else-if="loading" class="px-5 pb-5"><SkeletonRows :rows="5" /></div>
      <table v-else class="w-full text-left text-[0.9rem]" data-testid="customers-table">
        <thead class="text-[0.8rem] text-[var(--color-ink-3)]">
          <tr class="border-y border-[rgb(15_26_42/0.06)]">
            <th class="px-5 py-2 font-semibold">Name</th><th class="px-3 py-2 font-semibold">Company</th>
            <th class="px-3 py-2 font-semibold">Country</th><th class="px-3 py-2 font-semibold">Protected fields</th><th class="px-5 py-2" />
          </tr>
        </thead>
        <tbody>
          <tr v-for="c in filtered" :key="c.id" class="border-b border-[rgb(15_26_42/0.04)] transition-colors hover:bg-white/50">
            <td class="px-5 py-3 font-semibold"><NuxtLink :to="`/customers/${c.id}?tenant=${tenant}`" class="hover:underline underline-offset-4">{{ c.name }}</NuxtLink></td>
            <td class="px-3 py-3 text-[var(--color-ink-2)]">{{ c.company }}</td>
            <td class="px-3 py-3 text-[var(--color-ink-2)]">{{ c.country }}</td>
            <td class="px-3 py-3">
              <span class="inline-flex gap-1.5">
                <span v-for="f in ['IBAN', 'Tax ID', 'Payment']" :key="f" class="rounded-md bg-white/70 px-1.5 py-0.5 text-[0.8rem] font-semibold text-[var(--color-ink-3)] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]">
                  {{ f }} <span class="text-[var(--color-ink-3)]/80">••••</span>
                </span>
              </span>
            </td>
            <td class="px-5 py-3 text-right"><NuxtLink :to="`/inspector?type=customer&id=${c.id}`" class="text-[0.82rem] font-semibold text-[var(--color-authority)] hover:underline underline-offset-4">Inspect</NuxtLink></td>
          </tr>
          <tr v-if="!filtered.length"><td colspan="5" class="px-5 py-8 text-center meta">No customers match. Seed demo data with <span class="mono">make seed</span>.</td></tr>
        </tbody>
      </table>
    </section>
  </div>
</template>

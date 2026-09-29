<script setup lang="ts">
import { LockOpen, ArrowUp } from 'lucide-vue-next';

const route = useRoute();
const { call, tenant } = useApi();
const { can, reason, me } = useIdentity();

const customers = ref<any[]>([]);
const form = reactive({ customerId: '', field: 'iban' });
const stored = ref<any>(null);     // what PostgreSQL holds (inspector database view)
const result = ref<any>(null);
const error = ref<any>(null);
const busy = ref(false);
const state = ref<'frosted' | 'clear' | 'denied'>('frosted');

async function loadCustomers() {
  const r = await call<any[]>('/customers');
  customers.value = r.data ?? [];
  const q = typeof route.query.customer === 'string' ? route.query.customer : null;
  form.customerId = customers.value.find(c => c.id === q)?.id ?? customers.value[0]?.id ?? '';
  if (typeof route.query.field === 'string') form.field = route.query.field;
}
async function loadStored() {
  result.value = null; error.value = null; state.value = 'frosted'; stored.value = null;
  if (!form.customerId) return;
  const r = await call<any>(`/database/customers/${form.customerId}`);
  stored.value = r.data;
}
onMounted(async () => { await loadCustomers(); await loadStored(); });
watch(tenant, async () => { await loadCustomers(); await loadStored(); });
watch(() => [form.customerId, form.field], loadStored);

const ciphertext = computed(() => stored.value?.databaseView?.[form.field] ?? null);
const keyInfo = computed(() => stored.value?.fields?.[form.field] ?? null);

async function recover() {
  busy.value = true; error.value = null; result.value = null; state.value = 'frosted';
  const r = await call('/scenarios/recover', { method: 'POST', body: { ...form } });
  busy.value = false;
  if (!r.ok) { error.value = r.error; state.value = 'denied'; return; }
  result.value = r.data;
  requestAnimationFrame(() => { state.value = 'clear'; });
}
</script>

<template>
  <div>
    <PageHead title="Recover" lede="An authorised person asks for the value back. Vault checks their login itself, issues a five-minute token for this tenant, and decrypts. The pane clears only for them." />

    <div class="grid gap-6 xl:grid-cols-[22rem_1fr]">
      <form class="pane h-fit p-5" @submit.prevent="recover">
        <div class="space-y-4">
          <div>
            <label class="label" for="r-customer">Customer ({{ tenantName(tenant) }})</label>
            <select id="r-customer" v-model="form.customerId" class="field">
              <option v-for="c in customers" :key="c.id" :value="c.id">{{ c.name }} — {{ c.company }}</option>
            </select>
          </div>
          <div>
            <label class="label" for="r-field">Field</label>
            <select id="r-field" v-model="form.field" class="field">
              <option value="iban">IBAN</option>
              <option value="tax_id">Tax identifier</option>
              <option value="payment_info">Payment information</option>
            </select>
          </div>
          <button class="btn btn-primary w-full justify-center" :disabled="busy || !form.customerId" data-testid="recover-submit">
            <LockOpen class="size-4" /> {{ busy ? 'Asking Vault…' : can('recover') ? 'Recover' : `Try as ${me?.name}` }}
          </button>
          <p v-if="!can('recover')" class="meta">{{ reason('recover') }} — try it to see the refusal.</p>
        </div>
      </form>

      <section class="pane p-6" aria-live="polite">
        <p class="mb-1.5 text-[0.8rem] font-semibold text-[var(--color-ink-3)]">PostgreSQL — {{ FIELD_LABEL[form.field] }}</p>
        <FrostValue
          :state="state"
          :ciphertext="ciphertext"
          :plaintext="result?.plaintext"
          :reason="error?.error"
          :key-name="keyInfo?.keyName"
          :key-version="keyInfo?.keyVersion"
          data-testid="recover-pane"
        />

        <div v-if="result" class="mt-5 space-y-3">
          <div class="flex items-center gap-2 text-[0.86rem]">
            <ArrowUp class="size-4 text-[var(--color-mullion-dark)]" />
            <span class="font-semibold">Recovered through</span>
            <span class="mono text-[0.8rem]">{{ result.flow?.join(' → ') }}</span>
          </div>
          <AuthorityTag :authority="result.authority" />
          <p class="meta">Audit event <span class="mono">{{ result.auditEventId }}</span> · RECOVER · ALLOWED · Vault's own audit log records <strong>{{ result.authority?.user }}</strong> as the person.</p>
        </div>
        <div v-else-if="error" class="mt-5"><ErrorNote :error="error" /></div>
        <p v-else class="meta mt-5">Before recovery the pane shows exactly what the database holds. Only Vault can clear it.</p>
      </section>
    </div>
  </div>
</template>

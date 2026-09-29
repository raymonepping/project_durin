<script setup lang="ts">
import { ArrowDown, Database, Lock } from 'lucide-vue-next';

const { call, tenant } = useApi();
const { can, reason } = useIdentity();

const customers = ref<any[]>([]);
const form = reactive({ customerId: '', field: 'iban', value: 'NL91ABNA0417164300' });
const busy = ref(false);
const result = ref<any>(null);
const error = ref<any>(null);
const paneState = ref<'clear' | 'frosted'>('clear');

async function loadCustomers() {
  const r = await call<any[]>('/customers');
  customers.value = r.data ?? [];
  form.customerId = customers.value[0]?.id ?? '';
  result.value = null; error.value = null; paneState.value = 'clear';
}
onMounted(loadCustomers);
watch(tenant, loadCustomers);

async function protect() {
  busy.value = true; error.value = null; result.value = null; paneState.value = 'clear';
  const r = await call('/scenarios/protect', { method: 'POST', body: { ...form } });
  busy.value = false;
  if (!r.ok) { error.value = r.error; return; }
  result.value = r.data;
  // The value enters the glass: the clear pane frosts over its ciphertext.
  requestAnimationFrame(() => setTimeout(() => { paneState.value = 'frosted'; }, 350));
}
const customerName = computed(() => customers.value.find(c => c.id === form.customerId)?.name ?? '');
</script>

<template>
  <div>
    <PageHead title="Protect" lede="A sensitive value enters the protected boundary. Vault Transit encrypts it under this tenant's key — the application receives ciphertext, never the key, and PostgreSQL stores only ciphertext." />

    <div class="grid gap-6 xl:grid-cols-[22rem_1fr]">
      <form class="pane h-fit p-5" @submit.prevent="protect">
        <div class="space-y-4">
          <div>
            <label class="label" for="p-customer">Customer ({{ tenantName(tenant) }})</label>
            <select id="p-customer" v-model="form.customerId" class="field">
              <option v-for="c in customers" :key="c.id" :value="c.id">{{ c.name }} — {{ c.company }}</option>
            </select>
          </div>
          <div>
            <label class="label" for="p-field">Field</label>
            <select id="p-field" v-model="form.field" class="field">
              <option value="iban">IBAN</option>
              <option value="tax_id">Tax identifier</option>
              <option value="payment_info">Payment information</option>
            </select>
          </div>
          <div>
            <label class="label" for="p-value">Plaintext value</label>
            <input id="p-value" v-model="form.value" class="field mono !text-[0.9rem]" required autocomplete="off" data-testid="protect-value" />
          </div>
          <button class="btn btn-primary w-full justify-center" :disabled="busy || !can('protect') || !form.value" data-testid="protect-submit">
            <Lock class="size-4" /> {{ busy ? 'Protecting…' : 'Protect' }}
          </button>
          <p v-if="!can('protect')" class="meta">{{ reason('protect') }}</p>
        </div>
      </form>

      <section class="pane p-6" aria-live="polite">
        <ErrorNote v-if="error" :error="error" />

        <div v-else-if="!result" class="grid min-h-[20rem] place-items-center text-center">
          <div class="max-w-md">
            <p class="h-section">Plaintext → Vault Transit → ciphertext → PostgreSQL</p>
            <p class="meta mt-2">Protect a value to watch it enter the glass. The flow and the stored database row appear here.</p>
          </div>
        </div>

        <ol v-else class="space-y-3" data-testid="protect-flow">
          <li>
            <p class="mb-1.5 text-[0.8rem] font-semibold text-[var(--color-ink-3)]">Plaintext — {{ customerName }}, {{ FIELD_LABEL[result.field] }}</p>
            <FrostValue :state="paneState" :plaintext="form.value" :ciphertext="shortCipher(result.ciphertext, 28, 8)" compact />
          </li>
          <li class="flex items-center gap-3 pl-3">
            <ArrowDown class="size-4 text-[var(--color-mullion-dark)]" />
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-[0.86rem] font-semibold">Vault Transit</span>
              <span class="mono rounded bg-white/70 px-1.5 py-0.5 text-[0.8rem]">{{ result.keyName }} · v{{ result.keyVersion }}</span>
              <AuthorityTag :authority="result.authority" />
            </div>
          </li>
          <li>
            <p class="mb-1.5 text-[0.8rem] font-semibold text-[var(--color-ink-3)]">Ciphertext returned to the application</p>
            <div class="rounded-lg bg-[var(--color-cipher-soft)]/60 px-3.5 py-3"><span class="cipher" data-testid="protect-ciphertext">{{ result.ciphertext }}</span></div>
          </li>
          <li class="flex items-center gap-3 pl-3">
            <ArrowDown class="size-4 text-[var(--color-mullion-dark)]" />
            <span class="text-[0.86rem] font-semibold">PostgreSQL</span>
            <span class="meta">row read back after the write</span>
          </li>
          <li tabindex="0" aria-label="Stored database row" class="overflow-x-auto rounded-lg bg-white/60 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]">
            <div class="flex items-center gap-2 border-b border-[rgb(15_26_42/0.06)] px-3.5 py-2 text-[0.8rem] font-semibold">
              <Database class="size-4 text-[var(--color-ink-3)]" /> protected_values
              <span
                class="ml-auto rounded-full px-2 py-0.5 text-[0.8rem]"
                :class="result.database.containsPlaintext ? 'bg-[var(--color-denied)] text-white' : 'bg-[var(--color-clear-soft)] text-[var(--color-clear)]'"
                data-testid="contains-plaintext"
              >contains plaintext: {{ result.database.containsPlaintext }}</span>
            </div>
            <table class="w-full text-left text-[0.8rem]">
              <tbody>
                <tr v-for="(v, k) in result.database.row" :key="k" class="border-b border-[rgb(15_26_42/0.04)] last:border-0">
                  <th class="mono w-44 px-3.5 py-1.5 font-medium text-[var(--color-ink-3)]">{{ k }}</th>
                  <td class="px-3.5 py-1.5" :class="k === 'ciphertext' ? 'cipher' : 'mono'">{{ v }}</td>
                </tr>
              </tbody>
            </table>
          </li>
          <li class="flex flex-wrap items-center justify-between gap-3 pt-2">
            <p class="meta">Audit event <span class="mono">{{ result.auditEventId }}</span> · PROTECT · ALLOWED · source vault</p>
            <NuxtLink :to="`/recover?customer=${result.customerId}&field=${result.field}`" class="btn btn-glass">Next: Recover it</NuxtLink>
          </li>
        </ol>
      </section>
    </div>
  </div>
</template>

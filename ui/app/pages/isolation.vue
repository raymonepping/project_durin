<script setup lang="ts">
import { Split, ArrowRight } from 'lucide-vue-next';

const { call, tenant } = useApi();
const { can, reason } = useIdentity();
const others = computed(() => ['acme', 'globex', 'initech'].filter(t => t !== tenant.value));
const form = reactive({ targetTenant: '', operation: 'encrypt' as 'encrypt' | 'decrypt' });
watchEffect(() => { if (!others.value.includes(form.targetTenant)) form.targetTenant = others.value[0]!; });

const busy = ref(false);
const result = ref<any>(null);
const error = ref<any>(null);

async function probe() {
  busy.value = true; error.value = null; result.value = null;
  const r = await call('/scenarios/isolation-probe', { method: 'POST', body: { ...form } });
  busy.value = false;
  if (!r.ok) error.value = r.error; else result.value = r.data;
}
</script>

<template>
  <div>
    <PageHead title="Isolation" lede="Deliberately use one tenant's Vault authority against another tenant's key. The application never does this in normal operation — here it asks, so Vault can answer." />

    <div class="grid gap-6 xl:grid-cols-[22rem_1fr]">
      <form class="pane h-fit p-5" @submit.prevent="probe">
        <div class="space-y-4">
          <div>
            <span class="label">Authority of</span>
            <TenantPill :slug="tenant" />
          </div>
          <div>
            <label class="label" for="i-target">asks for the key of</label>
            <select id="i-target" v-model="form.targetTenant" class="field" data-testid="isolation-target">
              <option v-for="t in others" :key="t" :value="t">{{ tenantName(t) }}</option>
            </select>
          </div>
          <div>
            <label class="label" for="i-op">Operation</label>
            <select id="i-op" v-model="form.operation" class="field">
              <option value="encrypt">encrypt</option>
              <option value="decrypt">decrypt</option>
            </select>
          </div>
          <button class="btn btn-primary w-full justify-center" :disabled="busy || !can('scenario')" data-testid="isolation-probe">
            <Split class="size-4" /> {{ busy ? 'Asking Vault…' : 'Probe the boundary' }}
          </button>
          <p v-if="!can('scenario')" class="meta">{{ reason('scenario') }}</p>
        </div>
      </form>

      <section class="pane p-6" aria-live="polite">
        <ErrorNote v-if="error" :error="error" />
        <div v-else-if="!result" class="grid min-h-[14rem] place-items-center text-center">
          <p class="meta max-w-md">A request running for {{ tenantName(tenant) }} carries a Vault token issued for {{ tenantName(tenant) }} only. Probe to see Vault's answer.</p>
        </div>
        <div v-else class="space-y-5">
          <div class="flex flex-wrap items-center gap-3 text-[1.05rem] font-semibold">
            <TenantPill :slug="result.sourceTenant" class="!text-[1.05rem]" />
            <span class="meta">authority</span>
            <ArrowRight class="size-4 text-[var(--color-mullion-dark)]" />
            <span class="mono rounded bg-white/70 px-2 py-0.5 text-[0.82rem]">transit/{{ result.operation }}/{{ result.targetKey }}</span>
          </div>
          <AuthorityTag :authority="result.authority" />
          <VaultVerdict
            :result="result.result"
            :title="result.isolationEnforced ? 'Isolation enforced by Vault' : 'Isolation NOT enforced'"
            :explanation="result.isolationEnforced
              ? `Vault refused ${tenantName(result.sourceTenant)}'s token on ${tenantName(result.targetTenant)}'s key — policy, not application code.`
              : 'Vault allowed a cross-tenant operation. This is a configuration defect.'"
            :vault="result.vault"
            expected="DENIED"
            data-testid="isolation-verdict"
          />
          <p class="meta">Audit event <span class="mono">{{ result.auditEventId }}</span> · ISOLATION_PROBE</p>
        </div>
      </section>
    </div>
  </div>
</template>

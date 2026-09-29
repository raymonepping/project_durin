<script setup lang="ts">
import { ArrowLeft, Database } from 'lucide-vue-next';

const route = useRoute();
const { call, tenant } = useApi();
const { me } = useIdentity();
const view = ref<any>(null);
const error = ref<any>(null);
const loading = ref(true);
const cleared = ref(false);

async function load() {
  loading.value = true; cleared.value = false;
  // The inspector endpoint returns the database view (ciphertext) for every
  // role and the application view only where Vault authorised this person.
  const r = await call<any>(`/database/customers/${route.params.id}`, { tenant: route.query.tenant ? String(route.query.tenant) : undefined });
  view.value = r.data; error.value = r.error; loading.value = false;
  setTimeout(() => { cleared.value = true; }, 260);
}
onMounted(load);
watch(tenant, () => navigateTo('/customers'));

const fields = computed(() => Object.entries(view.value?.fields ?? {}) as [string, any][]);
const stateOf = (f: any) => (f.application.state === 'recovered' ? (cleared.value ? 'clear' : 'frosted') : f.application.state === 'denied' ? 'denied' : 'frosted');
const keyInfo = (name: string) => view.value?.vaultState?.[name];
</script>

<template>
  <div>
    <NuxtLink to="/customers" class="mb-4 inline-flex items-center gap-1.5 text-[0.85rem] font-semibold text-[var(--color-ink-2)] hover:text-[var(--color-ink)]"><ArrowLeft class="size-4" /> Customers</NuxtLink>
    <ErrorNote v-if="error" :error="error" />
    <SkeletonRows v-else-if="loading" :rows="4" />
    <template v-else-if="view">
      <PageHead :title="view.applicationView.name" :lede="`${view.applicationView.company ?? ''} · ${view.applicationView.country ?? ''} · ${tenantName(tenant)}`">
        <NuxtLink :to="`/inspector?type=customer&id=${view.applicationView.id}`" class="btn btn-glass"><Database class="size-4" /> Open in Database Inspector</NuxtLink>
      </PageHead>

      <section class="pane p-6">
        <div class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="h-section">Protected information</h2>
          <p class="meta">
            <template v-if="fields.some(([, f]) => f.application.state === 'recovered')">Cleared for <strong class="text-[var(--color-authority)]">{{ me?.name }}</strong> by Vault — each field audited as RECOVER.</template>
            <template v-else>Frosted for <strong>{{ me?.name }}</strong>: Vault issues decrypt authority to operators only.</template>
          </p>
        </div>
        <div class="mt-5 grid gap-5 md:grid-cols-3" data-testid="customer-fields">
          <FrostValue
            v-for="[name, f] in fields"
            :key="name"
            :label="FIELD_LABEL[name] ?? name"
            :state="stateOf(f)"
            :plaintext="view.applicationView[name]"
            :ciphertext="shortCipher(view.databaseView[name], 20, 6)"
            :reason="f.application.state === 'denied' ? f.application.reason : null"
            :key-name="f.keyName"
            :key-version="f.keyVersion"
            :retired="keyInfo(f.keyName)?.minDecryptionVersion > f.keyVersion"
            :data-testid="`field-${name}`"
          />
        </div>
        <p v-if="fields.some(([, f]) => f.application.state === 'not_authorised')" class="mt-5 rounded-lg bg-white/60 px-4 py-3 text-[0.88rem] text-[var(--color-ink-2)] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.06)]">
          ●●●●●●●● protected — operator required. Being signed in is not the same as being authorised to decrypt.
        </p>
      </section>
    </template>
  </div>
</template>

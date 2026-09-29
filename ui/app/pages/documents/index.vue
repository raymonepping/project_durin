<script setup lang="ts">
import { Upload, FileLock2, FileText } from 'lucide-vue-next';

const { call, tenant } = useApi();
const { can, reason } = useIdentity();
const docs = ref<any[]>([]);
const loading = ref(true);
const error = ref<any>(null);
const showNew = ref(false);
const form = reactive({ name: '', classification: 'CONFIDENTIAL', content_type: 'text/plain', payload: '' });
const saving = ref(false);

async function load() {
  loading.value = true;
  const r = await call<any[]>('/documents');
  docs.value = r.data ?? []; error.value = r.error; loading.value = false;
}
onMounted(load);
watch(tenant, load);

async function upload() {
  saving.value = true;
  const r = await call('/documents', { method: 'POST', body: { ...form } });
  saving.value = false;
  if (!r.ok) { error.value = r.error; return; }
  showNew.value = false; Object.assign(form, { name: '', payload: '' });
  load();
}

const CLASS_TONE: Record<string, string> = {
  PUBLIC: 'text-[var(--color-ink-3)]', INTERNAL: 'text-[var(--color-ink-2)]',
  CONFIDENTIAL: 'text-[var(--color-authority)]', RESTRICTED: 'text-[var(--color-glass)]',
};
</script>

<template>
  <div>
    <PageHead :title="`Documents — ${tenantName(tenant)}`" lede="Metadata stays queryable; the payload is Transit ciphertext. RESTRICTED documents use their own key that no one can decrypt on the normal path.">
      <button class="btn btn-primary" :disabled="!can('write')" :title="can('write') ? '' : reason('write')" @click="showNew = !showNew">
        <Upload class="size-4" /> Upload document
      </button>
    </PageHead>

    <form v-if="showNew" class="pane mb-5 grid gap-4 p-5 md:grid-cols-3" @submit.prevent="upload">
      <div class="md:col-span-2"><label class="label" for="d-name">Name</label><input id="d-name" v-model="form.name" class="field" required /></div>
      <div>
        <label class="label" for="d-class">Classification</label>
        <select id="d-class" v-model="form.classification" class="field">
          <option>PUBLIC</option><option>INTERNAL</option><option>CONFIDENTIAL</option><option>RESTRICTED</option>
        </select>
      </div>
      <div class="md:col-span-3"><label class="label" for="d-payload">Content (protected)</label><textarea id="d-payload" v-model="form.payload" class="field mono" rows="5" required /></div>
      <div class="flex items-center gap-3 md:col-span-3">
        <button class="btn btn-primary" :disabled="saving">{{ saving ? 'Protecting…' : 'Protect and upload' }}</button>
        <span class="meta">{{ form.classification === 'RESTRICTED' ? 'Encrypted under the restricted key: recovery will need break glass.' : 'Encrypted under the documents key.' }}</span>
      </div>
    </form>

    <section class="pane overflow-hidden">
      <ErrorNote v-if="error" :error="error" class="m-5" />
      <div v-else-if="loading" class="p-5"><SkeletonRows :rows="5" /></div>
      <table v-else class="w-full text-left text-[0.9rem]" data-testid="documents-table">
        <thead class="text-[0.8rem] text-[var(--color-ink-3)]">
          <tr class="border-b border-[rgb(15_26_42/0.06)]">
            <th class="px-5 py-2.5 font-semibold">Document</th><th class="px-3 py-2.5 font-semibold">Classification</th>
            <th class="px-3 py-2.5 font-semibold">Encryption</th><th class="px-3 py-2.5 font-semibold">Recovery requires</th><th class="px-5 py-2.5 font-semibold">Created</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="d in docs" :key="d.id" class="border-b border-[rgb(15_26_42/0.04)] transition-colors hover:bg-white/50">
            <td class="px-5 py-3">
              <NuxtLink :to="`/documents/${d.id}`" class="flex items-center gap-2.5 font-semibold hover:underline underline-offset-4">
                <component :is="d.classification === 'RESTRICTED' ? FileLock2 : FileText" class="size-4 shrink-0 text-[var(--color-ink-3)]" :stroke-width="1.75" />
                {{ d.name }}
              </NuxtLink>
              <span v-if="d.customer_name" class="meta pl-6.5">{{ d.customer_name }}</span>
            </td>
            <td class="px-3 py-3 text-[0.8rem] font-bold tracking-[0.02em]" :class="CLASS_TONE[d.classification]">{{ d.classification }}</td>
            <td class="mono px-3 py-3 text-[0.8rem] text-[var(--color-ink-2)]">{{ d.encryption.keyName?.replace(/^durin-[a-z]+-/, '') }} · v{{ d.encryption.keyVersion }}</td>
            <td class="px-3 py-3 text-[0.84rem]">
              <span :class="d.encryption.recoveryRequires === 'break-glass' ? 'font-semibold text-[var(--color-glass)]' : 'text-[var(--color-ink-2)]'">{{ d.encryption.recoveryRequires }}</span>
            </td>
            <td class="px-5 py-3 text-[0.82rem] text-[var(--color-ink-3)]">{{ dateTime(d.created_at) }}</td>
          </tr>
        </tbody>
      </table>
    </section>
  </div>
</template>

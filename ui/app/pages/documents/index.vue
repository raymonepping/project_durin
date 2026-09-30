<script setup lang="ts">
import { Upload, FileLock2, FileText, FileUp, ClipboardType, X } from 'lucide-vue-next';

const { call, tenant } = useApi();
const { can, reason } = useIdentity();
const docs = ref<any[]>([]);
const loading = ref(true);
const error = ref<any>(null);
const showNew = ref(false);
const form = reactive({ name: '', classification: 'CONFIDENTIAL', content_type: 'text/plain', payload: '' });
const saving = ref(false);

// Two ways in: upload a file (.md, .pdf, .docx) or paste text. The browser
// reads the file and sends its bytes (base64); the API has Vault encrypt them.
const mode = ref<'file' | 'text'>('file');
const MAX_BYTES = 5 * 1024 * 1024;
const FILE_TYPES: Record<string, string> = {
  md: 'text/markdown', markdown: 'text/markdown',
  pdf: 'application/pdf',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};
const file = ref<{ name: string; size: number; type: string } | null>(null);
const fileError = ref<string | null>(null);
const fileInput = ref<HTMLInputElement | null>(null);
const dragging = ref(false);

function toBase64(buf: ArrayBuffer) {
  const bytes = new Uint8Array(buf);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

async function pick(f: File | undefined) {
  fileError.value = null; file.value = null; form.payload = '';
  if (!f) return;
  const ext = f.name.split('.').pop()?.toLowerCase() ?? '';
  const type = FILE_TYPES[ext];
  if (!type) { fileError.value = 'Upload a .md, .pdf or .docx file.'; return; }
  if (f.size > MAX_BYTES) { fileError.value = `${f.name} is ${formatBytes(f.size)}; the limit is 5 MB.`; return; }
  form.content_type = type;
  form.payload = type.startsWith('text/') ? await f.text() : toBase64(await f.arrayBuffer());
  if (!form.name) form.name = f.name;
  file.value = { name: f.name, size: f.size, type };
}
function onDrop(e: DragEvent) { dragging.value = false; pick(e.dataTransfer?.files?.[0]); }
function clearFile() { file.value = null; form.payload = ''; if (fileInput.value) fileInput.value.value = ''; }
watch(mode, () => { clearFile(); fileError.value = null; form.content_type = 'text/plain'; });

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
  showNew.value = false; Object.assign(form, { name: '', payload: '', content_type: 'text/plain' }); clearFile();
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

    <form v-if="showNew" class="pane mb-5 grid gap-4 p-5 md:grid-cols-3" data-testid="document-form" @submit.prevent="upload">
      <div class="flex rounded-lg bg-white/60 p-0.5 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)] md:col-span-3 md:w-fit" role="tablist" aria-label="How to add the document">
        <button v-for="m in ([['file', 'Upload a file', FileUp], ['text', 'Paste text', ClipboardType]] as const)" :key="m[0]" type="button" role="tab" :aria-selected="mode === m[0]" :data-testid="`mode-${m[0]}`"
          class="flex items-center gap-1.5 rounded-md px-3 py-1.5 text-[0.85rem] font-semibold" :class="mode === m[0] ? 'bg-[var(--color-ink)] text-white' : 'text-[var(--color-ink-2)]'" @click="mode = m[0]">
          <component :is="m[2]" class="size-4" /> {{ m[1] }}
        </button>
      </div>
      <div class="md:col-span-2"><label class="label" for="d-name">Name</label><input id="d-name" v-model="form.name" class="field" required /></div>
      <div>
        <label class="label" for="d-class">Classification</label>
        <select id="d-class" v-model="form.classification" class="field">
          <option>PUBLIC</option><option>INTERNAL</option><option>CONFIDENTIAL</option><option>RESTRICTED</option>
        </select>
      </div>
      <div v-if="mode === 'text'" class="md:col-span-3"><label class="label" for="d-payload">Content (protected)</label><textarea id="d-payload" v-model="form.payload" class="field mono" rows="5" required /></div>
      <div v-else class="md:col-span-3">
        <span class="label">File (protected)</span>
        <label
          v-if="!file"
          class="flex cursor-pointer flex-col items-center justify-center gap-1.5 rounded-xl border-2 border-dashed px-4 py-7 text-center transition-colors"
          :class="dragging ? 'border-[var(--color-authority)] bg-[var(--color-authority-soft)]/50' : 'border-[var(--color-mullion)] bg-white/40 hover:bg-white/70'"
          @dragover.prevent="dragging = true" @dragleave="dragging = false" @drop.prevent="onDrop"
        >
          <FileUp class="size-6 text-[var(--color-ink-3)]" :stroke-width="1.5" />
          <span class="font-semibold">Choose a file or drop it here</span>
          <span class="meta">.md, .pdf or .docx · up to 5 MB · encrypted by Vault before it is stored</span>
          <input ref="fileInput" type="file" accept=".md,.markdown,.pdf,.docx" class="sr-only" data-testid="file-input" @change="pick(($event.target as HTMLInputElement).files?.[0])" />
        </label>
        <div v-else class="flex items-center gap-3 rounded-xl bg-white/70 px-4 py-3 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]" data-testid="picked-file">
          <FileText class="size-5 text-[var(--color-ink-2)]" :stroke-width="1.75" />
          <span class="min-w-0 flex-1"><span class="block truncate font-semibold">{{ file.name }}</span><span class="meta">{{ formatBytes(file.size) }} · {{ FILE_KIND[file.type] ?? file.type }}</span></span>
          <button type="button" class="btn btn-glass !h-8 !px-2" aria-label="Remove file" @click="clearFile"><X class="size-4" /></button>
        </div>
        <p v-if="fileError" class="mt-2 text-[0.85rem] font-semibold text-[var(--color-denied)]" role="alert">{{ fileError }}</p>
      </div>
      <div class="flex items-center gap-3 md:col-span-3">
        <button class="btn btn-primary" :disabled="saving || !form.payload" data-testid="document-submit">{{ saving ? 'Protecting…' : 'Protect and upload' }}</button>
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

<script setup lang="ts">
import { ArrowLeft, Database, Eye, Siren, ShieldX, KeyRound, Ban } from 'lucide-vue-next';

const route = useRoute();
const id = computed(() => String(route.params.id));
const { call, tenant } = useApi();
const { me, can, reason, isSecurityAdmin } = useIdentity();
const now = useNow();

const doc = ref<any>(null);
const raw = ref<any>(null);
const error = ref<any>(null);
const loading = ref(true);

// Result of "Open content": plaintext, or Vault's refusal.
const content = ref<any>(null);
const contentMeta = ref<any>(null);
const contentError = ref<any>(null);
const opening = ref(false);
const cleared = ref(false);

// Break glass for this document, requested by the signed-in person.
const bg = ref<any>(null);
const bgReason = ref('');
const bgBusy = ref(false);
const bgError = ref<any>(null);

const restricted = computed(() => doc.value?.classification === 'RESTRICTED');

async function load() {
  loading.value = true; error.value = null;
  const t = route.query.tenant ? String(route.query.tenant) : undefined;
  const [d, r] = await Promise.all([call<any>(`/documents/${id.value}`, { tenant: t }), call<any>(`/documents/${id.value}/raw`, { tenant: t })]);
  doc.value = d.data; raw.value = r.data; error.value = d.error ?? r.error;
  loading.value = false;
  if (restricted.value) await loadBreakGlass();
}

async function loadBreakGlass() {
  const r = await call<any[]>('/break-glass/all', { query: { tenant: tenant.value, limit: 100 } });
  const mine = (r.data ?? []).filter(x => x.resource_id === id.value && x.requested_by === me.value?.name);
  bg.value = mine.find(x => ['pending', 'approved'].includes(x.status)) ?? mine[0] ?? null;
}

onMounted(load);
watch(tenant, () => navigateTo('/documents'));

// While Vault waits for the approver, look again every 3 s.
let poll: ReturnType<typeof setInterval> | null = null;
watch(() => bg.value?.status, (s) => {
  if (poll) { clearInterval(poll); poll = null; }
  if (s === 'pending') poll = setInterval(loadBreakGlass, 3000);
}, { immediate: true });
onBeforeUnmount(() => { if (poll) clearInterval(poll); });

function reveal(r: any) {
  content.value = r.data; contentMeta.value = r.meta; cleared.value = false;
  setTimeout(() => { cleared.value = true; }, 260);
}

async function openContent() {
  opening.value = true; contentError.value = null; content.value = null;
  const r = await call<any>(`/documents/${id.value}/content`);
  opening.value = false;
  if (r.ok) reveal(r); else contentError.value = r.error;
}

async function requestBreakGlass() {
  bgBusy.value = true; bgError.value = null;
  const r = await call<any>('/break-glass/request', { method: 'POST', body: { resource_type: 'document', resource_id: id.value, reason: bgReason.value } });
  bgBusy.value = false;
  if (!r.ok) { bgError.value = r.error; return; }
  bg.value = r.data; bgReason.value = '';
}

async function redeem() {
  bgBusy.value = true; bgError.value = null;
  const r = await call<any>(`/documents/${id.value}/content`, { headers: { 'x-break-glass-request': bg.value.id } });
  bgBusy.value = false;
  if (!r.ok) { bgError.value = r.error; await loadBreakGlass(); return; }
  contentError.value = null;
  reveal(r);
  await loadBreakGlass();
}

async function revoke() {
  bgBusy.value = true; bgError.value = null;
  const r = await call<any>(`/break-glass/${bg.value.id}/revoke`, { method: 'POST', body: {} });
  bgBusy.value = false;
  if (!r.ok) bgError.value = r.error;
  await loadBreakGlass();
}

const frostState = computed(() => (content.value ? (cleared.value ? 'clear' : 'frosted') : contentError.value ? 'denied' : 'frosted'));
const normalDenied = computed(() => contentError.value?.breakGlassRequired === true);
const bgActive = computed(() => bg.value && ['pending', 'approved'].includes(bg.value.status));
const bgLeft = computed(() => secondsLeft(bg.value?.expires_at, now.value));

const STATUS_TONE: Record<string, string> = {
  pending: 'bg-[var(--color-glass-soft)] text-[var(--color-glass)]',
  approved: 'bg-[var(--color-glass)] text-white',
  used: 'bg-[var(--color-clear-soft)] text-[var(--color-clear)]',
  denied: 'bg-[var(--color-denied-soft)] text-[var(--color-denied)]',
  revoked: 'bg-white/70 text-[var(--color-ink-2)]',
  expired: 'bg-white/70 text-[var(--color-ink-3)]',
};
</script>

<template>
  <div>
    <NuxtLink to="/documents" class="mb-4 inline-flex items-center gap-1.5 text-[0.85rem] font-semibold text-[var(--color-ink-2)] hover:text-[var(--color-ink)]"><ArrowLeft class="size-4" /> Documents</NuxtLink>
    <ErrorNote v-if="error" :error="error" />
    <SkeletonRows v-else-if="loading" :rows="4" />
    <template v-else-if="doc">
      <PageHead :title="doc.name" :lede="`${doc.classification} · ${doc.content_type} · ${doc.size_bytes ?? '—'} bytes · ${tenantName(tenant)}`">
        <NuxtLink :to="`/inspector?type=document&id=${doc.id}`" class="btn btn-glass"><Database class="size-4" /> Open in Database Inspector</NuxtLink>
      </PageHead>

      <div class="grid gap-5 xl:grid-cols-[1fr_24rem]">
        <section class="pane p-6">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="h-section">Payload</h2>
            <button class="btn btn-primary" :disabled="opening || !can('recover')" :title="can('recover') ? '' : reason('recover')" data-testid="open-content" @click="openContent">
              <Eye class="size-4" /> {{ opening ? 'Asking Vault…' : 'Open content' }}
            </button>
          </div>
          <p v-if="!can('recover')" class="meta mt-1">{{ reason('recover') }}</p>

          <div class="mt-5">
            <FrostValue
              label="Document payload"
              :state="frostState"
              :plaintext="content?.payload"
              :ciphertext="shortCipher(raw?.ciphertext, 36, 8)"
              :reason="contentError && !normalDenied ? contentError.error : null"
              :key-name="doc.encryption.keyName"
              :key-version="content?.keyVersion ?? doc.encryption.keyVersion"
              data-testid="document-payload"
            />
          </div>

          <div v-if="content" class="mt-4 flex flex-wrap items-center gap-3">
            <AuthorityTag v-if="contentMeta?.authority" :authority="contentMeta.authority" />
            <span v-if="contentMeta?.breakGlass" class="inline-flex items-center gap-1.5 rounded-lg bg-[var(--color-glass-soft)] px-2.5 py-1.5 text-[0.8rem] font-semibold text-[var(--color-glass)]">
              <Siren class="size-3.5" /> Released once by Vault — approved by {{ contentMeta.breakGlass.approvedBy }}
            </span>
            <span v-if="contentMeta?.breakGlass?.normalAccessRestored" class="text-[0.8rem] font-semibold text-[var(--color-clear)]" data-testid="normal-access-restored">Normal access restored</span>
            <span class="meta">audit <span class="mono">{{ contentMeta?.auditEventId }}</span></span>
          </div>

          <!-- Vault refused the normal path on the restricted key -->
          <div v-if="normalDenied" class="mt-5 rounded-xl bg-[var(--color-denied-soft)]/60 p-4 shadow-[inset_0_0_0_1px_rgb(200_30_30/0.2)]" data-testid="normal-access-denied">
            <div class="flex items-start gap-3">
              <ShieldX class="mt-0.5 size-5 shrink-0 text-[var(--color-denied)]" :stroke-width="2" />
              <div class="min-w-0">
                <p class="font-bold tracking-[-0.01em] text-[var(--color-denied)]">NORMAL ACCESS DENIED</p>
                <p class="mt-1 text-[0.9rem] text-[var(--color-ink-2)]">
                  Vault refused decrypt on <span class="mono">{{ doc.encryption.keyName }}</span> — even for an operator. Tenant policies carry no decrypt on the restricted key. The only way in is break glass, approved by a security admin in Vault.
                </p>
                <div class="mono mt-2 flex flex-wrap gap-x-3 text-[0.8rem] text-[var(--color-ink-3)]">
                  <span v-if="contentError.vault?.status">vault {{ contentError.vault.status }}</span>
                  <span v-if="contentError.authority?.role">{{ contentError.authority.role }}</span>
                  <span v-if="contentError.auditEventId">audit {{ contentError.auditEventId }}</span>
                </div>
              </div>
            </div>
          </div>
          <ErrorNote v-else-if="contentError && contentError.error !== 'vault_denied'" :error="contentError" class="mt-5" />

          <dl class="mt-6 grid gap-x-6 gap-y-3 text-[0.86rem] sm:grid-cols-2">
            <div><dt class="meta">Recovery requires</dt><dd class="font-semibold" :class="restricted && 'text-[var(--color-glass)]'">{{ doc.encryption.recoveryRequires }}</dd></div>
            <div><dt class="meta">Created by</dt><dd>{{ doc.created_by }} · {{ dateTime(doc.created_at) }}</dd></div>
            <div v-if="doc.customer_name"><dt class="meta">Customer</dt><dd>{{ doc.customer_name }}</dd></div>
            <div class="min-w-0"><dt class="meta">SHA-256 of plaintext</dt><dd class="mono truncate text-[0.8rem]" :title="doc.checksum">{{ doc.checksum }}</dd></div>
          </dl>
        </section>

        <!-- Break glass: only for RESTRICTED documents -->
        <section v-if="restricted" class="pane h-fit overflow-hidden" data-testid="break-glass-panel">
          <div class="h-1 bg-[var(--color-glass)]" />
          <div class="p-5">
            <h2 class="h-section flex items-center gap-2"><Siren class="size-4.5 text-[var(--color-glass)]" /> Break glass</h2>
            <p class="meta mt-1">A Vault Control Group: Vault holds the answer until a security admin approves, then releases it to you once.</p>

            <div v-if="bg" class="mt-4 space-y-3">
              <div class="flex items-center justify-between gap-3">
                <span class="rounded-full px-2.5 py-0.5 text-[0.8rem] font-bold uppercase tracking-[0.04em]" :class="STATUS_TONE[bg.status]" data-testid="break-glass-status">{{ bg.status }}</span>
                <span class="mono text-[0.8rem] text-[var(--color-ink-3)]">{{ bg.id.slice(0, 8) }}</span>
              </div>
              <p class="text-[0.86rem] text-[var(--color-ink-2)]">“{{ bg.reason }}”</p>
              <p class="mono text-[0.8rem] text-[var(--color-ink-2)]">control group · 1 approval from durin-security-admins · expires {{ clock(bg.expires_at) }}</p>
              <TtlBar v-if="bgActive" :expires-at="bg.expires_at" :total="900" tone="glass" />
              <p v-if="bg.status === 'pending'" class="meta" data-testid="break-glass-pending">Awaiting approval in Vault — a member of <span class="mono">durin-security-admins</span> must authorise.</p>
              <p v-if="bg.status === 'approved'" class="text-[0.86rem] font-semibold text-[var(--color-glass)]">Approved by {{ bg.approved_by }} — redeem once, within {{ formatDuration(bgLeft) }}.</p>
              <p v-if="bg.status === 'used'" class="meta">Used {{ dateTime(bg.used_at) }}. Vault's wrapping token is spent; normal access rules apply again.</p>
              <div v-if="bgActive" class="flex flex-wrap gap-2">
                <button v-if="bg.status === 'approved'" class="btn btn-amber" :disabled="bgBusy" data-testid="redeem" @click="redeem">
                  <KeyRound class="size-4" /> {{ bgBusy ? 'Unwrapping…' : 'Redeem once' }}
                </button>
                <button class="btn btn-glass" :disabled="bgBusy" @click="revoke"><Ban class="size-4" /> Revoke</button>
              </div>
            </div>

            <form v-if="!bgActive && can('request-break-glass')" class="mt-4 space-y-3" @submit.prevent="requestBreakGlass">
              <div>
                <label class="label" for="bg-reason">Reason (recorded in the audit trail)</label>
                <textarea id="bg-reason" v-model="bgReason" class="field" rows="3" minlength="5" required placeholder="Incident INC-2291: regulator request for contract terms" data-testid="break-glass-reason" />
              </div>
              <button class="btn btn-amber w-full justify-center" :disabled="bgBusy || bgReason.trim().length < 5" data-testid="request-break-glass">
                <Siren class="size-4" /> {{ bgBusy ? 'Asking Vault…' : 'Request break glass' }}
              </button>
            </form>
            <p v-else-if="!bgActive && isSecurityAdmin" class="meta mt-4">
              {{ reason('request-break-glass') }}: security admins approve, and Vault's bound claims refuse them the requester role.
              <NuxtLink to="/break-glass" class="font-semibold text-[var(--color-authority)] hover:underline">Review requests</NuxtLink>
            </p>
            <ErrorNote v-if="bgError" :error="bgError" class="mt-3" />
          </div>
        </section>
      </div>
    </template>
  </div>
</template>

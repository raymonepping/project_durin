<script setup lang="ts">
// Break glass through Vault Control Groups. The requester asks Vault; Vault
// holds the answer; a security admin authorises in Vault; the requester
// redeems exactly once on the document page. No bearer token exists in this
// flow — there is nothing to copy.
import { Siren, Check, X, Ban, FileLock2 } from 'lucide-vue-next';

const { call } = useApi();
const { setTenant } = useTenant();
const { me, can, reason } = useIdentity();
const now = useNow();

const requests = ref<any[]>([]);
const error = ref<any>(null);
const loading = ref(true);
const busy = ref<string | null>(null);
const flash = ref<Record<string, { ok: boolean; text: string; error?: any }>>({});
const filter = ref<'active' | 'all'>('active');

async function load() {
  const r = await call<any[]>('/break-glass/all', { tenant: null, query: { limit: 100 } });
  if (r.ok) requests.value = r.data ?? [];
  error.value = r.error; loading.value = false;
}
usePoll(load, 4000);

// A card you just acted on stays in view with its outcome until you leave the page.
const shown = computed(() => requests.value.filter(r => filter.value === 'all' || ['pending', 'approved'].includes(r.status) || flash.value[r.id]));
const counts = computed(() => ({
  pending: requests.value.filter(r => r.status === 'pending').length,
  approved: requests.value.filter(r => r.status === 'approved').length,
}));

async function act(r: any, action: 'approve' | 'deny' | 'revoke') {
  busy.value = `${r.id}:${action}`;
  const res = await call<any>(`/break-glass/${r.id}/${action}`, { method: 'POST', body: {}, tenant: r.tenant_slug });
  busy.value = null;
  flash.value[r.id] = res.ok
    ? { ok: true, text: action === 'approve' ? `BREAK GLASS ACTIVE — approved in Vault by ${me.value?.name}` : action === 'deny' ? 'Denied — Vault will never release this answer.' : 'Revoked — normal access restored.' }
    : { ok: false, text: '', error: res.error };
  await load();
}

const STATUS_TONE: Record<string, string> = {
  pending: 'bg-[var(--color-glass-soft)] text-[var(--color-glass)]',
  approved: 'bg-[var(--color-glass)] text-white',
  used: 'bg-[var(--color-clear-soft)] text-[var(--color-clear)]',
  denied: 'bg-[var(--color-denied-soft)] text-[var(--color-denied)]',
  revoked: 'bg-white/70 text-[var(--color-ink-2)]',
  expired: 'bg-white/70 text-[var(--color-ink-3)]',
};
const mine = (r: any) => r.requested_by === me.value?.name;
</script>

<template>
  <div>
    <PageHead title="Break Glass" lede="Emergency access to RESTRICTED documents. Vault holds the decrypted answer until a security admin authorises it, then releases it to the requester — once.">
      <div class="flex rounded-lg bg-white/60 p-0.5 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]" role="tablist">
        <button v-for="f in (['active', 'all'] as const)" :key="f" role="tab" :aria-selected="filter === f" class="rounded-md px-3 py-1 text-[0.82rem] font-semibold" :class="filter === f ? 'bg-[var(--color-ink)] text-white' : 'text-[var(--color-ink-2)]'" @click="filter = f">
          {{ f === 'active' ? `Active (${counts.pending + counts.approved})` : 'History' }}
        </button>
      </div>
    </PageHead>

    <!-- how it works, in one line -->
    <ol class="mb-6 grid gap-3 text-[0.84rem] md:grid-cols-4">
      <li v-for="(s, i) in [
        ['Request', 'viewer or operator asks Vault; Vault answers with a wrapped response'],
        ['Hold', 'the backend keeps the wrapping token; Vault waits for 1 approval'],
        ['Authorise', 'a member of durin-security-admins approves in Vault'],
        ['Redeem once', 'the requester unwraps; the answer is gone after one use'],
      ]" :key="s[0]" class="pane-strong flex gap-3 rounded-xl px-3.5 py-3 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.06)]">
        <span class="grid size-6 shrink-0 place-items-center rounded-full bg-[var(--color-glass)] text-[0.8rem] font-bold text-white">{{ i + 1 }}</span>
        <span><strong class="block">{{ s[0] }}</strong><span class="text-[var(--color-ink-2)]">{{ s[1] }}</span></span>
      </li>
    </ol>

    <ErrorNote v-if="error" :error="error" class="mb-5" />
    <SkeletonRows v-else-if="loading" :rows="4" />
    <div v-else-if="!shown.length" class="pane grid min-h-[12rem] place-items-center p-8 text-center">
      <div class="max-w-md">
        <FileLock2 class="mx-auto size-6 text-[var(--color-ink-3)]" :stroke-width="1.5" />
        <p class="mt-2 font-semibold">{{ filter === 'active' ? 'No active emergency access' : 'No break-glass history yet' }}</p>
        <p class="meta mt-1">Open a RESTRICTED document to request it. Normal access to RESTRICTED data is refused by Vault for everyone.</p>
        <NuxtLink to="/documents" class="btn btn-glass mt-4">Documents</NuxtLink>
      </div>
    </div>

    <div v-else class="grid gap-5 xl:grid-cols-2" data-testid="break-glass-requests">
      <article v-for="r in shown" :key="r.id" class="pane overflow-hidden" :data-testid="`bg-${r.id}`">
        <div class="h-1" :class="['pending', 'approved'].includes(r.status) ? 'bg-[var(--color-glass)]' : 'bg-[var(--color-mullion)]'" />
        <div class="p-5">
          <div class="flex items-center justify-between gap-3">
            <p class="flex items-center gap-2 font-bold tracking-[0.02em]" :class="['pending', 'approved'].includes(r.status) ? 'text-[var(--color-glass)]' : 'text-[var(--color-ink-2)]'">
              <Siren class="size-4.5" /> BREAK GLASS REQUEST
            </p>
            <span class="rounded-full px-2.5 py-0.5 text-[0.8rem] font-bold uppercase tracking-[0.04em]" :class="STATUS_TONE[r.status]" data-testid="bg-status">{{ r.status }}</span>
          </div>
          <dl class="mt-4 grid grid-cols-[7.5rem_1fr] gap-x-3 gap-y-2 text-[0.88rem]">
            <dt class="meta">Requested by</dt><dd class="font-semibold">{{ r.requested_by }}<span v-if="mine(r)" class="meta font-normal"> (you)</span></dd>
            <dt class="meta">Reason</dt><dd>{{ r.reason }}</dd>
            <dt class="meta">Resource</dt>
            <dd><NuxtLink :to="`/documents/${r.resource_id}`" class="font-semibold hover:underline" @click="setTenant(r.tenant_slug)">{{ r.tenant_slug }} / {{ r.resource_name }}</NuxtLink></dd>
            <dt class="meta">Vault</dt>
            <dd class="mono text-[0.8rem]">control group · 1 approval from durin-security-admins · expires {{ clock(r.expires_at) }}</dd>
            <template v-if="r.approved_by"><dt class="meta">Approved by</dt><dd class="font-semibold text-[var(--color-glass)]">{{ r.approved_by }} · {{ clock(r.approved_at) }}</dd></template>
            <template v-if="r.denied_by"><dt class="meta">Denied by</dt><dd>{{ r.denied_by }}</dd></template>
            <template v-if="r.revoked_by"><dt class="meta">Revoked by</dt><dd>{{ r.revoked_by }} · {{ clock(r.revoked_at) }}</dd></template>
            <template v-if="r.used_at"><dt class="meta">Used</dt><dd>{{ clock(r.used_at) }} — normal access restored</dd></template>
            <dt class="meta">Accessor</dt><dd class="mono truncate text-[0.8rem] text-[var(--color-ink-3)]">{{ r.vault_wrapping_accessor }}</dd>
          </dl>
          <TtlBar v-if="['pending', 'approved'].includes(r.status)" class="mt-4" :expires-at="r.expires_at" :total="900" tone="glass" />

          <p v-if="r.status === 'approved'" class="mt-3 font-bold text-[var(--color-glass)]" data-testid="bg-active">
            BREAK GLASS ACTIVE — approved in Vault by {{ r.approved_by }}. {{ r.requested_by }} may redeem once, {{ formatDuration(secondsLeft(r.expires_at, now)) }} left.
          </p>

          <div v-if="['pending', 'approved'].includes(r.status)" class="mt-4 flex flex-wrap items-center gap-2">
            <template v-if="r.status === 'pending'">
              <button class="btn btn-amber" :disabled="!can('approve') || mine(r) || !!busy" :title="can('approve') ? '' : reason('approve')" data-testid="approve" @click="act(r, 'approve')">
                <Check class="size-4" /> {{ busy === `${r.id}:approve` ? 'Authorising in Vault…' : 'Approve' }}
              </button>
              <button class="btn btn-glass" :disabled="!can('approve') || !!busy" :title="can('approve') ? '' : reason('approve')" data-testid="deny" @click="act(r, 'deny')"><X class="size-4" /> Deny</button>
            </template>
            <button v-if="can('approve') || mine(r)" class="btn btn-glass" :disabled="!!busy" data-testid="revoke" @click="act(r, 'revoke')"><Ban class="size-4" /> Revoke</button>
            <NuxtLink v-if="mine(r) && r.status === 'approved'" :to="`/documents/${r.resource_id}`" class="btn btn-primary" @click="setTenant(r.tenant_slug)">Redeem on the document</NuxtLink>
            <span v-if="!can('approve') && r.status === 'pending'" class="meta">{{ reason('approve') }}</span>
          </div>

          <p v-if="flash[r.id]?.ok && r.status !== 'approved'" class="mt-3 text-[0.86rem] font-semibold" :class="r.status === 'approved' ? 'text-[var(--color-glass)]' : 'text-[var(--color-ink-2)]'">{{ flash[r.id]!.text }}</p>
          <ErrorNote v-if="flash[r.id]?.error" :error="flash[r.id]!.error" class="mt-3" />
        </div>
      </article>
    </div>
  </div>
</template>

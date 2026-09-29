<script setup lang="ts">
// Vault cluster status — GET /vault/status, polled every 5 s. Built from
// unauthenticated sys/health, sys/seal-status and sys/leader plus HAProxy
// stats: the console needs no extra Vault authority to show this.
import { Crown, Network, KeyRound, ServerCog, Lock } from 'lucide-vue-next';

const { vault, refreshVault } = useConsoleState();
const error = ref<any>(null);
const updatedAt = ref<number | null>(null);
usePoll(async () => {
  const r = await refreshVault();
  error.value = r.error;
  if (r.ok) updatedAt.value = Date.now();
}, 5000);

const cluster = computed(() => (vault.value?.nodes ?? []).filter((n: any) => n.role === 'cluster'));
const unseal = computed(() => (vault.value?.nodes ?? []).find((n: any) => n.role === 'unseal'));
const s = computed(() => vault.value?.summary);

const MODE_TONE: Record<string, string> = {
  active: 'var(--color-clear)',
  'performance-standby': 'var(--color-authority)',
  standby: 'var(--color-authority)',
  sealed: 'var(--color-glass)',
  uninitialized: 'var(--color-glass)',
  unreachable: 'var(--color-denied)',
};
const STATUS_TONE: Record<string, string> = { healthy: 'var(--color-clear)', degraded: 'var(--color-glass)', unavailable: 'var(--color-denied)' };
</script>

<template>
  <div>
    <PageHead title="Vault" lede="Three Raft nodes behind one load balancer, auto-unsealed by a separate transit Vault. Refreshes every five seconds.">
      <span class="meta tabular">{{ updatedAt ? `updated ${clock(new Date(updatedAt).toISOString())}` : 'loading…' }}</span>
    </PageHead>
    <ErrorNote v-if="error && !vault" :error="error" />
    <SkeletonRows v-else-if="!vault" :rows="4" />

    <template v-else>
      <!-- summary strip -->
      <section class="pane mb-5 flex flex-wrap items-center gap-x-8 gap-y-3 px-5 py-4" data-testid="vault-summary">
        <div class="flex items-center gap-2.5">
          <span aria-hidden="true" class="led led-live !size-2.5" :style="{ background: STATUS_TONE[s.status] }" />
          <span class="text-[1.15rem] font-bold capitalize tracking-[-0.01em]">{{ s.status }}</span>
        </div>
        <div><p class="meta">Leader</p><p class="mono font-semibold" data-testid="vault-leader">{{ s.leader ?? 'none' }}</p></div>
        <div><p class="meta">Unsealed</p><p class="tabular font-semibold">{{ s.nodesUnsealed }} / {{ s.nodesTotal }}</p></div>
        <div><p class="meta">HA quorum</p><p class="font-semibold" :style="{ color: s.haQuorum ? 'var(--color-clear)' : 'var(--color-denied)' }">{{ s.haQuorum ? 'yes' : 'lost' }}</p></div>
        <div><p class="meta">Version</p><p class="mono font-semibold">{{ s.version }}</p></div>
        <div><p class="meta">Load balancer</p><p class="font-semibold" :style="{ color: s.loadBalancerAgrees ? 'var(--color-clear)' : 'var(--color-glass)' }">{{ s.loadBalancerAgrees ? 'routes to the leader' : 'disagrees with leader' }}</p></div>
        <ErrorNote v-if="error" :error="error" class="basis-full" />
      </section>

      <!-- nodes -->
      <section class="grid gap-4 md:grid-cols-2 xl:grid-cols-4" data-testid="vault-nodes">
        <article
          v-for="n in [...cluster, unseal].filter(Boolean)" :key="n.name"
          class="pane p-4 transition-shadow duration-500"
          :class="n.isLeader && 'shadow-[0_0_0_2px_var(--color-clear),0_12px_28px_-16px_rgb(15_118_110/0.6)]'"
          :data-testid="`node-${n.name}`"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="mono text-[0.95rem] font-bold">{{ n.name }}</span>
            <Crown v-if="n.isLeader" class="size-4 text-[var(--color-clear)]" :stroke-width="2" aria-label="leader" />
            <Lock v-else-if="n.role === 'unseal'" class="size-4 text-[var(--color-ink-3)]" :stroke-width="2" />
          </div>
          <p class="mt-2 flex items-center gap-2 text-[0.88rem] font-semibold" :style="{ color: MODE_TONE[n.mode] }">
            <span aria-hidden="true" class="led" :style="{ background: MODE_TONE[n.mode] }" /> <span data-testid="node-mode">{{ n.mode }}</span>
          </p>
          <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[0.8rem]">
            <dt class="meta">role</dt><dd>{{ n.role === 'unseal' ? 'transit unseal Vault' : n.isLeader ? 'leader' : 'Raft voter' }}</dd>
            <dt class="meta">seal</dt><dd class="mono">{{ n.sealType ?? '—' }}{{ n.sealType === 'transit' ? ' (auto-unseal)' : '' }}</dd>
            <dt class="meta">storage</dt><dd class="mono">{{ n.storageType ?? '—' }}</dd>
            <dt class="meta">sealed</dt><dd class="mono">{{ n.sealed }}</dd>
            <template v-if="n.error"><dt class="meta">error</dt><dd class="mono text-[var(--color-denied)]">{{ n.error }}</dd></template>
          </dl>
        </article>
      </section>

      <div class="mt-5 grid gap-5 xl:grid-cols-2">
        <!-- load balancer -->
        <section class="pane p-5" data-testid="vault-lb">
          <h2 class="h-section flex items-center gap-2"><Network class="size-4.5 text-[var(--color-ink-2)]" :stroke-width="1.75" /> Load balancer</h2>
          <template v-if="vault.loadBalancer.reachable">
            <p class="meta mt-1">{{ vault.loadBalancer.endpoint }} · {{ vault.loadBalancer.routing }}</p>
            <p class="mt-3 text-[0.9rem]">Active node <span class="mono font-bold text-[var(--color-clear)]" data-testid="lb-active">{{ vault.loadBalancer.activeNode ?? 'none' }}</span></p>
            <ul class="mt-3 space-y-1.5">
              <li v-for="sv in vault.loadBalancer.servers" :key="sv.node" class="flex items-center gap-3 rounded-lg bg-white/55 px-3 py-2 text-[0.84rem] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.06)]">
                <span aria-hidden="true" class="led" :style="{ background: sv.state === 'UP' ? 'var(--color-clear)' : 'var(--color-mullion-dark)' }" />
                <span class="mono w-20 font-semibold">{{ sv.node }}</span>
                <span class="font-semibold" :class="sv.state === 'UP' ? 'text-[var(--color-clear)]' : 'text-[var(--color-ink-3)]'">{{ sv.state }}</span>
                <span class="mono ml-auto text-[0.8rem] text-[var(--color-ink-3)]">{{ sv.check }}</span>
              </li>
            </ul>
            <p class="meta mt-2">Standbys report DOWN by design: only the leader takes traffic.</p>
          </template>
          <ErrorNote v-else :error="{ status: 0, error: 'unreachable', message: vault.loadBalancer.error }" class="mt-3" />
        </section>

        <!-- backend + auth methods -->
        <section class="pane p-5" data-testid="vault-backend">
          <h2 class="h-section flex items-center gap-2"><ServerCog class="size-4.5 text-[var(--color-ink-2)]" :stroke-width="1.75" /> Durin backend</h2>
          <p class="mt-2 text-[0.9rem]">
            <span class="font-semibold" :class="vault.backend.status === 'connected' ? 'text-[var(--color-clear)]' : 'text-[var(--color-denied)]'">{{ vault.backend.status }}</span>
            <span class="mono ml-2 text-[0.8rem] text-[var(--color-ink-3)]">{{ vault.backend.vaultAddr }}</span>
          </p>
          <p class="mt-2 text-[0.88rem] font-semibold text-[var(--color-authority)]">backend: metadata only — authority is issued to people</p>
          <div class="mt-2 flex flex-wrap gap-1.5">
            <span v-for="p in vault.backend.policies" :key="p" class="mono rounded-md bg-white/65 px-1.5 py-0.5 text-[0.8rem] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]">{{ p }}</span>
          </div>
          <p class="meta mt-2">{{ vault.backend.note }}</p>
          <h3 class="mt-5 text-[0.8rem] font-semibold text-[var(--color-ink-2)]">Auth methods</h3>
          <ul class="mt-2 space-y-1.5 text-[0.84rem]">
            <li v-for="a in vault.authMethods" :key="a.path"><span class="mono font-semibold">{{ a.path }}</span> <span class="text-[var(--color-ink-2)]">— {{ a.purpose }}</span></li>
          </ul>
        </section>
      </div>

      <!-- transit keys -->
      <section class="pane mt-5 p-5" data-testid="vault-keys">
        <h2 class="h-section flex items-center gap-2"><KeyRound class="size-4.5 text-[var(--color-ink-2)]" :stroke-width="1.75" /> Transit keys</h2>
        <p class="meta mt-1">Current version and decryption floor. Versions below the floor are retired for everyone.</p>
        <div class="mt-4 grid gap-5 lg:grid-cols-3">
          <div v-for="(ks, slug) in vault.transitKeys" :key="slug" :data-testid="`keys-${slug}`">
            <TenantPill :slug="String(slug)" />
            <ul class="mt-2 space-y-2.5">
              <li v-for="k in ks" :key="k.name">
                <p class="mono text-[0.8rem] font-medium">{{ k.name }}</p>
                <div v-if="!k.error" class="mt-1 flex items-center gap-2">
                  <KeyChip :current="k.currentVersion" :floor="k.minDecryptionVersion" />
                  <span class="meta shrink-0">floor v{{ k.minDecryptionVersion }}</span>
                </div>
                <p v-else class="mono text-[0.8rem] text-[var(--color-denied)]">{{ k.error }}</p>
              </li>
            </ul>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>

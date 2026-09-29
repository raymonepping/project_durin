<script setup lang="ts">
import { ShieldCheck, RefreshCw, Layers, ArrowDownToLine, KeyRound, CircleCheck, CircleX } from 'lucide-vue-next';

const { call, tenant } = useApi();
const { can, reason } = useIdentity();
const { refreshScenario } = useConsoleState();

const busy = ref(false);
const result = ref<any>(null);
const error = ref<any>(null);
const shown = ref(0);
watch(tenant, () => { result.value = null; error.value = null; shown.value = 0; });

const STEP_META: Record<string, { title: string; icon: any; why: string }> = {
  rotate: { title: 'Rotate', icon: RefreshCw, why: 'Every tenant key gets a new version; new writes use it.' },
  rewrap: { title: 'Rewrap', icon: Layers, why: 'Vault re-encrypts stored ciphertext to the new version internally — plaintext never leaves Vault.' },
  min_decryption_version: { title: 'Raise the floor', icon: ArrowDownToLine, why: 'Older versions are retired for decryption — by anyone, including this application.' },
  reissue_authority: { title: 'Re-issue authority', icon: KeyRound, why: 'Outstanding Vault tokens for this tenant are revoked; the next operation logs the person in again.' },
};

async function fortify() {
  busy.value = true; error.value = null; result.value = null; shown.value = 0;
  const r = await call('/scenarios/fortify', { method: 'POST', body: {} });
  busy.value = false;
  if (!r.ok) { error.value = r.error; return; }
  result.value = r.data;
  // Reveal the Vault steps in order (150 ms each), then the verification.
  const total = (r.data.steps?.length ?? 0) + 1;
  for (let i = 1; i <= total; i++) setTimeout(() => { shown.value = i; }, i * 170);
  refreshScenario();
}

const keyNames = computed(() => Object.keys(result.value?.after ?? {}));
const checks = computed(() => {
  const v = result.value?.verification ?? {};
  return [
    { key: 'legitimateRecovery', label: 'Legitimate recovery (current ciphertext)', ...v.legitimateRecovery },
    { key: 'preShieldCiphertext', label: v.preShieldCiphertext?.origin === 'snapshot' ? 'Stolen copy (pre-Shield ciphertext)' : 'Pre-Shield ciphertext', ...v.preShieldCiphertext },
    { key: 'crossTenant', label: `Cross-tenant key (${tenantName(v.crossTenant?.target)})`, ...v.crossTenant },
  ].filter(c => c.result);
});
</script>

<template>
  <div>
    <PageHead :title="`Shield ${tenantName(tenant)}`" lede="Respond to the compromise with real Vault controls — then prove, live against Vault, that what was possible before is denied now.">
      <button class="btn btn-primary" :disabled="busy || !can('scenario')" data-testid="fortify" @click="fortify">
        <ShieldCheck class="size-4" /> {{ busy ? 'Fortifying…' : `Fortify ${tenantName(tenant)}` }}
      </button>
    </PageHead>
    <p v-if="!can('scenario')" class="meta -mt-3 mb-5">{{ reason('scenario') }}</p>
    <ErrorNote v-if="error" :error="error" class="mb-5" />

    <div v-if="!result" class="pane grid min-h-[16rem] place-items-center p-8 text-center">
      <div class="max-w-lg">
        <p class="h-section">Initial state → Fortify → Hardened state</p>
        <p class="meta mt-2">Rotate every key, rewrap every stored value inside Vault, retire the old versions, re-issue authority — then verify each claim against Vault.</p>
      </div>
    </div>

    <div v-else class="grid gap-5 xl:grid-cols-[1fr_24rem]">
      <section class="pane p-6">
        <ol class="relative space-y-5" data-testid="fortify-steps">
          <span class="absolute bottom-3 left-[1.05rem] top-3 w-px bg-[var(--color-mullion)]" aria-hidden="true" />
          <li
            v-for="(s, i) in result.steps"
            :key="s.control"
            class="relative flex gap-4 transition-all duration-300"
            :class="shown > Number(i) ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-1'"
          >
            <span class="z-[1] grid size-[2.15rem] shrink-0 place-items-center rounded-full bg-[var(--color-clear)] text-white shadow-[0_0_0_4px_rgb(255_255_255/0.85)]">
              <component :is="STEP_META[s.control]?.icon" class="size-4" :stroke-width="2" />
            </span>
            <div class="min-w-0 pt-1">
              <p class="font-semibold">{{ STEP_META[s.control]?.title ?? s.control }} <span class="meta font-normal">· enforced by {{ s.enforcedBy }}</span></p>
              <p class="mt-0.5 text-[0.88rem] text-[var(--color-ink-2)]">{{ STEP_META[s.control]?.why }}</p>
              <ul class="mono mt-1.5 space-y-0.5 text-[0.8rem] text-[var(--color-ink-3)]">
                <li v-for="d in s.detail" :key="d">{{ d }}</li>
              </ul>
            </div>
          </li>
        </ol>

        <div class="mt-7 transition-opacity duration-300" :class="shown > result.steps.length ? 'opacity-100' : 'opacity-0'">
          <h2 class="h-section">Verification — asked of Vault just now</h2>
          <ul class="mt-3 space-y-2.5" data-testid="fortify-verification">
            <li v-for="c in checks" :key="c.key" class="flex items-center gap-3 rounded-lg bg-white/60 px-3.5 py-2.5 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.06)]">
              <component :is="c.result === c.expected ? CircleCheck : CircleX" class="size-4.5 shrink-0" :class="c.result === c.expected ? 'text-[var(--color-clear)]' : 'text-[var(--color-denied)]'" />
              <span class="flex-1 text-[0.9rem]">{{ c.label }}</span>
              <span class="mono text-[0.8rem] text-[var(--color-ink-3)]">expected {{ c.expected }}</span>
              <span class="font-bold" :class="c.result === 'ALLOWED' ? 'text-[var(--color-clear)]' : 'text-[var(--color-denied)]'">{{ c.result }}</span>
              <span v-if="c.reason" class="mono hidden text-[0.8rem] text-[var(--color-ink-3)] md:inline">{{ c.reason }}</span>
            </li>
          </ul>
          <div
            class="mt-5 flex items-center gap-3 rounded-xl px-4 py-3 font-bold tracking-[-0.01em]"
            :class="result.verification.passed ? 'bg-[var(--color-clear)] text-white' : 'bg-[var(--color-denied)] text-white'"
            data-testid="hardened"
          >
            <ShieldCheck class="size-5" /> {{ result.verification.passed ? 'HARDENED — every claim verified by Vault' : 'Verification failed — see the rows above' }}
          </div>
          <NuxtLink to="/compromise" class="btn btn-glass mt-4">Replay the stolen copy again</NuxtLink>
        </div>
      </section>

      <section class="pane h-fit p-5">
        <h2 class="h-section">Keys, before → after</h2>
        <ul class="mt-4 space-y-4">
          <li v-for="k in keyNames" :key="k">
            <p class="mono text-[0.8rem] font-medium">{{ k }}</p>
            <div class="mt-1.5 grid grid-cols-[4.5rem_1fr] items-center gap-y-1.5 text-[0.8rem]">
              <span class="meta">before</span>
              <KeyChip :current="result.before[k]?.currentVersion" :floor="result.before[k]?.minDecryptionVersion" :versions="[result.before[k]?.currentVersion]" />
              <span class="meta">after</span>
              <span class="flex items-center gap-2">
                <KeyChip :current="result.after[k]?.currentVersion" :floor="result.after[k]?.minDecryptionVersion" :versions="[result.after[k]?.currentVersion - 1, result.after[k]?.currentVersion].filter(Boolean)" />
                <span class="meta">floor v{{ result.after[k]?.minDecryptionVersion }}</span>
              </span>
            </div>
          </li>
        </ul>
        <p class="meta mt-5">{{ result.rewrapped }} values rewrapped · audit <span class="mono">{{ result.auditEventId }}</span></p>
      </section>
    </div>
  </div>
</template>

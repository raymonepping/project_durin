<script setup lang="ts">
import { ShieldAlert, Check, X, Skull, Server, RotateCcw } from 'lucide-vue-next';

const { call, tenant } = useApi();
const { can, reason } = useIdentity();
const { scenario, refreshScenario } = useConsoleState();

const exposure = ref<any>(null);
const snapshot = ref<any[]>([]);
const busy = ref<string | null>(null);
const error = ref<any>(null);
const attempts = reactive<Record<string, any>>({ attacker: null, application: null });

const active = computed(() => !!scenario.value?.compromiseMode);

async function loadSnapshot() {
  const r = await call<any[]>('/scenarios/compromise/snapshot');
  snapshot.value = r.data ?? [];
}
onMounted(loadSnapshot);
watch(tenant, () => { attempts.attacker = attempts.application = null; loadSnapshot(); });

async function simulate() {
  busy.value = 'simulate'; error.value = null;
  const r = await call('/scenarios/compromise', { method: 'POST', body: {} });
  busy.value = null;
  if (!r.ok) { error.value = r.error; return; }
  exposure.value = r.data;
  attempts.attacker = attempts.application = null;
  await Promise.all([refreshScenario(), loadSnapshot()]);
}
async function restore() {
  busy.value = 'restore';
  await call('/scenarios/compromise', { method: 'DELETE' });
  busy.value = null;
  exposure.value = null;
  await refreshScenario();
}
async function replay(actor: 'attacker' | 'application') {
  busy.value = actor;
  const r = await call('/scenarios/compromise/decrypt-attempt', { method: 'POST', body: { actor } });
  busy.value = null;
  attempts[actor] = r.ok ? r.data : { result: 'DENIED', reason: r.error?.error, explanation: ERROR_SENTENCE[r.error?.error ?? ''] ?? r.error?.message };
}

const has = computed(() => exposure.value?.attackerHas ?? (active.value ? {
  postgresqlAccess: true, ciphertexts: scenario.value?.compromiseSnapshot?.records,
} : null));
</script>

<template>
  <div>
    <PageHead title="Compromise" lede="Simulate a stolen database. The attacker gets every row — metadata and ciphertext — and then asks Vault to decrypt. Deterministic and reversible; nothing outside Durin is touched.">
      <button v-if="!active" class="btn btn-danger" :disabled="!!busy || !can('scenario')" data-testid="simulate-compromise" @click="simulate">
        <ShieldAlert class="size-4" /> {{ busy === 'simulate' ? 'Stealing…' : 'Simulate database compromise' }}
      </button>
      <button v-else class="btn btn-glass" :disabled="!!busy || !can('scenario')" data-testid="restore-compromise" @click="restore">
        <RotateCcw class="size-4" /> Restore database
      </button>
    </PageHead>
    <p v-if="!can('scenario')" class="meta -mt-3 mb-5">{{ reason('scenario') }}</p>
    <ErrorNote v-if="error" :error="error" class="mb-5" />

    <div class="grid gap-5 lg:grid-cols-2">
      <section class="pane p-5" :class="active && 'outline-[var(--color-denied)]/40'">
        <h2 class="h-section flex items-center gap-2"><Skull class="size-4.5 text-[var(--color-denied)]" :stroke-width="1.75" /> Attacker has</h2>
        <ul class="mt-3 space-y-2 text-[0.92rem]">
          <li class="flex items-center gap-2.5"><Check class="size-4 text-[var(--color-denied)]" />PostgreSQL access</li>
          <li class="flex items-center gap-2.5"><Check class="size-4 text-[var(--color-denied)]" />Customer records <span v-if="exposure" class="tabular meta">({{ exposure.attackerHas.customerRecords }})</span></li>
          <li class="flex items-center gap-2.5"><Check class="size-4 text-[var(--color-denied)]" />Document metadata <span v-if="exposure" class="tabular meta">({{ exposure.attackerHas.documentMetadata }})</span></li>
          <li class="flex items-center gap-2.5"><Check class="size-4 text-[var(--color-denied)]" />Ciphertext <span v-if="has?.ciphertexts" class="tabular meta">({{ has.ciphertexts }} values)</span></li>
          <li v-if="exposure" class="flex items-center gap-2.5"><Check class="size-4 text-[var(--color-denied)]" />Plaintext sensitive values: <strong class="tabular">{{ exposure.attackerHas.plaintextSensitiveValues }}</strong></li>
        </ul>
      </section>
      <section class="pane p-5">
        <h2 class="h-section flex items-center gap-2"><Server class="size-4.5 text-[var(--color-clear)]" :stroke-width="1.75" /> Attacker does not have</h2>
        <ul class="mt-3 space-y-2 text-[0.92rem]">
          <li class="flex items-start gap-2.5"><X class="mt-0.5 size-4 shrink-0 text-[var(--color-clear)]" /><span>Transit encryption keys <span class="meta block">never stored in PostgreSQL; exportable=false in Vault</span></span></li>
          <li class="flex items-start gap-2.5"><X class="mt-0.5 size-4 shrink-0 text-[var(--color-clear)]" /><span>Vault authorisation <span class="meta block">the database holds no Vault token</span></span></li>
          <li class="flex items-start gap-2.5"><X class="mt-0.5 size-4 shrink-0 text-[var(--color-clear)]" /><span>Decryption authority <span class="meta block">only a verified person's 5-minute token can decrypt</span></span></li>
        </ul>
      </section>
    </div>

    <!-- Two replays -->
    <section class="mt-5 grid gap-5 lg:grid-cols-2">
      <div class="pane p-5">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 class="h-section">Replay as the attacker</h2>
            <p class="meta mt-1">Vault is asked to decrypt the stolen ciphertext with no token.</p>
          </div>
          <button class="btn btn-glass" :disabled="!!busy || !can('scenario')" data-testid="replay-attacker" @click="replay('attacker')">Replay</button>
        </div>
        <VaultVerdict v-if="attempts.attacker" class="mt-4" :result="attempts.attacker.result" :explanation="attempts.attacker.explanation" :reason="attempts.attacker.reason" :vault="attempts.attacker.vault" data-testid="verdict-attacker" />
      </div>
      <div class="pane p-5">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 class="h-section">Replay as the compromised application</h2>
            <p class="meta mt-1">The app's own tenant authority tries the stolen copy. Before Shield it still works — watch what Shield does.</p>
          </div>
          <button class="btn btn-glass" :disabled="!!busy || !can('scenario')" data-testid="replay-application" @click="replay('application')">Replay</button>
        </div>
        <VaultVerdict v-if="attempts.application" class="mt-4" :result="attempts.application.result" :explanation="attempts.application.explanation" :reason="attempts.application.reason" :vault="attempts.application.vault" data-testid="verdict-application" />
        <NuxtLink v-if="attempts.application?.result === 'ALLOWED'" to="/shield" class="btn btn-primary mt-4">Next: Shield {{ tenantName(tenant) }}</NuxtLink>
      </div>
    </section>

    <!-- The stolen data -->
    <section class="pane mt-5 overflow-hidden">
      <div class="flex items-center justify-between px-5 py-4">
        <h2 class="h-section">Stolen copy — {{ tenantName(tenant) }}</h2>
        <span class="meta">{{ snapshot.length }} rows · raw, as a database dump holds them</span>
      </div>
      <div v-if="!snapshot.length" class="px-5 pb-5 meta">No snapshot yet. Simulate the compromise to capture one.</div>
      <div v-else class="max-h-[26rem] overflow-auto" tabindex="0" role="region" aria-label="Stolen copy rows">
        <table class="w-full text-left text-[0.84rem]" data-testid="snapshot-table">
          <thead class="sticky top-0 bg-white/85 backdrop-blur text-[0.8rem] text-[var(--color-ink-3)]">
            <tr><th class="px-5 py-2 font-semibold">Resource</th><th class="px-3 py-2 font-semibold">Field</th><th class="px-3 py-2 font-semibold">Ciphertext</th><th class="px-5 py-2 font-semibold">Key</th></tr>
          </thead>
          <tbody>
            <tr v-for="s in snapshot" :key="s.id" class="border-t border-[rgb(15_26_42/0.05)]">
              <td class="px-5 py-2 font-medium">{{ s.customer_name ?? s.document_name }}<span v-if="s.classification" class="meta"> · {{ s.classification }}</span></td>
              <td class="px-3 py-2 text-[var(--color-ink-2)]">{{ FIELD_LABEL[s.field_name] ?? s.field_name }}</td>
              <td class="px-3 py-2"><span class="cipher">{{ shortCipher(s.ciphertext, 18, 6) }}</span></td>
              <td class="mono px-5 py-2 text-[0.8rem] text-[var(--color-ink-3)]">{{ s.key_name.replace(/^durin-[a-z]+-/, '') }} v{{ s.key_version }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>

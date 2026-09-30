<script setup lang="ts">
// The signature interaction — "The Clearing".
// A protected value is switchable privacy glass. Behind the pane sits the
// ciphertext PostgreSQL holds. Only when Vault authorised the signed-in person
// (state "clear") does the frost wipe away top-to-bottom and reveal plaintext.
// "denied": the pane stays frosted, its frame LED turns red and Vault's
// verdict is etched on the glass. Nothing here decides — it only shows.
import { Lock, LockOpen, ShieldX } from 'lucide-vue-next';

const props = withDefaults(defineProps<{
  label?: string;
  ciphertext?: string | null;
  plaintext?: string | null;
  state?: 'frosted' | 'clear' | 'denied';
  reason?: string | null;
  keyName?: string | null;
  keyVersion?: number | null;
  retired?: boolean;
  compact?: boolean;
}>(), { state: 'frosted' });

const led = computed(() => ({ clear: 'var(--color-clear)', denied: 'var(--color-denied)', frosted: 'var(--color-mullion-dark)' }[props.state]));
const caption = computed(() => {
  if (props.state === 'clear') return 'Cleared by Vault';
  if (props.state === 'denied') return props.reason ? ERROR_SENTENCE[props.reason] ?? props.reason : 'Vault refused';
  return 'Frosted — ciphertext only';
});
</script>

<template>
  <div class="group">
    <div v-if="label" class="mb-1.5 flex items-center justify-between gap-3">
      <span class="text-[0.8rem] font-semibold text-[var(--color-ink-2)]">{{ label }}</span>
      <span v-if="keyVersion" class="mono text-[0.8rem] text-[var(--color-ink-3)]" :class="retired && 'line-through text-[var(--color-denied)]'">
        {{ keyName ? keyName.replace(/^durin-[a-z]+-/, '') : 'key' }} · v{{ keyVersion }}
      </span>
    </div>
    <div
      class="frost-wrap bg-white/55"
      :data-state="state"
      :style="{ boxShadow: `inset 0 0 0 1px rgb(15 26 42 / 0.1), inset 0 1px 0 #fff` }"
    >
      <!-- what sits behind the glass -->
      <div class="relative z-[1] flex min-h-[2.75rem] items-center pl-3.5" :class="[compact ? 'py-2' : 'py-2.5', state === 'clear' ? 'pr-12' : 'pr-28']">
        <span
          v-if="state === 'clear' && plaintext"
          class="whitespace-pre-line break-words text-[0.98rem] font-semibold tracking-[-0.005em] text-[var(--color-ink)]"
        >{{ plaintext }}</span>
        <span v-else class="cipher">{{ ciphertext || 'vault:v?:…' }}</span>
      </div>
      <!-- the pane -->
      <div class="frost-layer" aria-hidden="true" />
      <!-- frame: LED + etched caption -->
      <div class="pointer-events-none absolute right-2.5 top-1/2 z-[3] flex -translate-y-1/2 items-center gap-2">
        <span
          v-if="state !== 'clear'"
          class="rounded-md bg-white/70 px-1.5 py-0.5 text-[0.8rem] font-semibold"
          :class="state === 'denied' ? 'text-[var(--color-denied)]' : 'text-[var(--color-ink-3)]'"
        >
          <ShieldX v-if="state === 'denied'" class="mr-0.5 inline size-3 -translate-y-px" :stroke-width="2" />
          <Lock v-else class="mr-0.5 inline size-3 -translate-y-px" :stroke-width="2" />
          {{ state === 'denied' ? 'Denied' : 'Frosted' }}
        </span>
        <LockOpen v-else class="size-3.5 text-[var(--color-clear)]" :stroke-width="2" />
        <span aria-hidden="true" class="led" :class="state === 'clear' && 'led-live'" :style="{ background: led }" />
      </div>
    </div>
    <p v-if="!compact" class="mt-1 text-[0.8rem]" :class="state === 'denied' ? 'text-[var(--color-denied)]' : 'text-[var(--color-ink-3)]'">
      {{ caption }}<template v-if="state === 'denied' && reason"> · <span class="mono">{{ reason }}</span></template>
    </p>
  </div>
</template>

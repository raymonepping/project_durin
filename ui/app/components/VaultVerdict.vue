<script setup lang="ts">
// Vault's answer, verbatim, next to the human sentence.
import { ShieldCheck, ShieldX, TriangleAlert } from 'lucide-vue-next';

const props = defineProps<{
  result: 'ALLOWED' | 'DENIED' | string;
  title?: string;
  explanation?: string | null;
  reason?: string | null;
  vault?: { status?: number; path?: string; errors?: string[]; role?: string } | null;
  expected?: string | null;
}>();
const allowed = computed(() => props.result === 'ALLOWED');
const surprising = computed(() => props.expected && props.expected !== props.result);
</script>

<template>
  <div
    class="rounded-xl p-4"
    :class="allowed ? 'bg-[var(--color-clear-soft)]/60 shadow-[inset_0_0_0_1px_rgb(15_118_110/0.25)]' : 'bg-[var(--color-denied-soft)]/60 shadow-[inset_0_0_0_1px_rgb(200_30_30/0.2)]'"
  >
    <div class="flex items-start gap-3">
      <component
        :is="surprising ? TriangleAlert : allowed ? ShieldCheck : ShieldX"
        class="mt-0.5 size-5 shrink-0"
        :class="allowed ? 'text-[var(--color-clear)]' : 'text-[var(--color-denied)]'"
        :stroke-width="2"
      />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <span class="font-bold tracking-[-0.01em]" :class="allowed ? 'text-[var(--color-clear)]' : 'text-[var(--color-denied)]'">{{ result }}</span>
          <span v-if="title" class="font-semibold text-[var(--color-ink)]">{{ title }}</span>
          <span v-if="expected" class="meta">expected {{ expected }}</span>
        </div>
        <p v-if="explanation || reason" class="mt-1 text-[0.9rem] leading-relaxed text-[var(--color-ink-2)]">
          {{ explanation ?? (reason ? ERROR_SENTENCE[reason] ?? reason : '') }}
        </p>
        <div v-if="vault?.status || reason" class="mono mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[0.8rem] text-[var(--color-ink-3)]">
          <span v-if="vault?.status">vault {{ vault.status }}</span>
          <span v-if="vault?.path">{{ vault.path }}</span>
          <span v-if="reason">{{ reason }}</span>
          <span v-if="vault?.errors?.length" class="basis-full truncate">{{ vault.errors.join(' ').replace(/\s+/g, ' ').trim() }}</span>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { CircleAlert } from 'lucide-vue-next';
import type { ApiError } from '~/composables/useApi';

defineProps<{ error: ApiError | null | undefined }>();
</script>

<template>
  <div v-if="error" role="alert" class="flex items-start gap-3 rounded-xl bg-[var(--color-denied-soft)]/55 p-3.5 shadow-[inset_0_0_0_1px_rgb(200_30_30/0.18)]">
    <CircleAlert class="mt-0.5 size-4.5 shrink-0 text-[var(--color-denied)]" :stroke-width="2" />
    <div class="min-w-0 text-[0.9rem]">
      <p class="font-semibold text-[var(--color-ink)]">{{ ERROR_SENTENCE[error.error] ?? error.message }}</p>
      <p class="mono mt-0.5 text-[0.8rem] text-[var(--color-ink-3)]">
        {{ error.status || '—' }} · {{ error.error }}<template v-if="error.vault?.status"> · vault {{ error.vault.status }}</template>
        <template v-if="ERROR_SENTENCE[error.error] && error.message"> · {{ error.message }}</template>
      </p>
    </div>
  </div>
</template>

<script setup lang="ts">
// Time drawn to scale: the bar's length is the exact fraction of seconds left.
const props = defineProps<{ expiresAt: string | number | null | undefined; total: number; tone?: 'authority' | 'glass' | 'clear' }>();
const now = useNow();
const left = computed(() => secondsLeft(props.expiresAt, now.value));
const pct = computed(() => Math.max(0, Math.min(100, (left.value / props.total) * 100)));
const color = computed(() => `var(--color-${props.tone ?? 'authority'})`);
</script>

<template>
  <div class="flex items-center gap-2" :title="`${left}s of ${total}s left`">
    <div class="relative h-1.5 w-full min-w-12 overflow-hidden rounded-full bg-[rgb(15_26_42/0.08)]">
      <div class="absolute inset-y-0 left-0 rounded-full transition-[width] duration-1000 ease-linear" :style="{ width: `${pct}%`, background: color }" />
    </div>
    <span class="tabular mono shrink-0 text-[0.8rem] text-[var(--color-ink-2)]">{{ formatDuration(left) }}</span>
  </div>
</template>

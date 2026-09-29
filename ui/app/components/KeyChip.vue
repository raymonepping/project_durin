<script setup lang="ts">
// Key versions: current bold with teal; below the decryption floor struck
// through. A long run of retired versions (after many Shields) collapses into
// one struck range chip so the row stays readable.
const props = defineProps<{ versions?: number[]; current?: number | null; floor?: number | null }>();
type Chip = { label: string; kind: 'current' | 'retired' | 'live'; title: string };
const chips = computed<Chip[]>(() => {
  const list = props.versions?.length ? props.versions : (props.current ? Array.from({ length: props.current }, (_, i) => i + 1) : []);
  const retired = list.filter(v => props.floor && v < props.floor);
  const out: Chip[] = [];
  if (retired.length > 3) {
    out.push({ label: `v${retired[0]}–v${retired.at(-1)}`, kind: 'retired', title: `${retired.length} versions retired: below min_decryption_version` });
  }
  for (const v of list) {
    if (retired.length > 3 && retired.includes(v)) continue;
    const kind = v === props.current ? 'current' : retired.includes(v) ? 'retired' : 'live';
    out.push({ label: `v${v}`, kind, title: kind === 'current' ? 'current version' : kind === 'retired' ? 'retired: below min_decryption_version' : 'still decryptable' });
  }
  return out;
});
</script>

<template>
  <div class="flex flex-wrap items-center gap-1">
    <span
      v-for="c in chips"
      :key="c.label"
      class="mono rounded-md px-1.5 py-0.5 text-[0.8rem]"
      :class="c.kind === 'current'
        ? 'bg-[var(--color-clear)] font-semibold text-white'
        : c.kind === 'retired'
          ? 'text-[var(--color-denied)] line-through decoration-[1.5px] bg-[var(--color-denied-soft)]/60'
          : 'text-[var(--color-ink-2)] bg-white/60 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]'"
      :title="c.title"
    >{{ c.label }}</span>
  </div>
</template>

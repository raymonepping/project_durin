<script setup lang="ts">
defineProps<{ slug?: string | null }>();
</script>

<template>
  <span class="inline-flex items-center gap-1.5 text-[0.82rem] font-semibold" :style="{ color: tenantVar(slug) }">
    <span class="size-2 rounded-[3px]" :style="{ background: tenantVar(slug) }" />{{ tenantName(slug) }}
  </span>
</template>

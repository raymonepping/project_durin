<script setup lang="ts">
defineProps<{ rows?: number }>();
</script>

<template>
  <div class="space-y-2.5" aria-busy="true" aria-label="Loading">
    <div v-for="i in rows ?? 4" :key="i" class="h-10 animate-pulse rounded-lg bg-white/50" :style="{ opacity: 1 - i * 0.12 }" />
  </div>
</template>

<script setup lang="ts">
defineProps<{ title: string; lede?: string }>();
</script>

<template>
  <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
    <div class="min-w-0">
      <h1 class="h-page">{{ title }}</h1>
      <p v-if="lede" class="lede mt-2">{{ lede }}</p>
    </div>
    <div v-if="$slots.default" class="flex w-full flex-wrap items-center gap-2 sm:w-auto"><slot /></div>
  </header>
</template>

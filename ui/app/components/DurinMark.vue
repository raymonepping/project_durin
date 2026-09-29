<script setup lang="ts">
// Two glass panes in one aluminium frame: the left frosted (ciphertext),
// the right cleared (authorised). The product in one glyph.
defineProps<{ size?: number }>();
</script>

<template>
  <svg :width="size ?? 28" :height="size ?? 28" viewBox="0 0 32 32" fill="none" aria-hidden="true">
    <rect x="1.5" y="1.5" width="29" height="29" rx="7" fill="#0f1a2a" />
    <rect x="6" y="6" width="9.5" height="20" rx="2" fill="#dfe6ee" opacity="0.55" />
    <path d="M6 10.5h9.5M6 14h9.5M6 17.5h9.5M6 21h9.5" stroke="#0f1a2a" stroke-opacity="0.18" stroke-width="1" />
    <rect x="16.5" y="6" width="9.5" height="20" rx="2" fill="#0d9488" fill-opacity="0.18" stroke="#5eead4" stroke-opacity="0.9" stroke-width="1" />
    <circle cx="21.25" cy="23" r="1.3" fill="#5eead4" />
  </svg>
</template>

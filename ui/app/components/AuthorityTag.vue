<script setup lang="ts">
// "Vault authorised raymon · tenant-acme · auth/jwt" — who Vault issued
// authority to. The point of the demo, so it is never hidden in a tooltip.
import { KeyRound } from 'lucide-vue-next';

const props = defineProps<{
  authority?: { role?: string; user?: string; accessor?: string; source?: string } | null;
  expiresAt?: string | null;
  total?: number;
  /** "Token issued to …" — for screens where the token is then refused (Isolation). */
  issued?: boolean;
}>();
const tenant = computed(() => props.authority?.role?.match(/^tenant-(.+)$/)?.[1] ?? null);
</script>

<template>
  <div v-if="authority" class="inline-flex max-w-full flex-wrap items-center gap-x-2 gap-y-1 rounded-lg bg-[var(--color-authority-soft)]/70 px-2.5 py-1.5 text-[0.8rem] text-[var(--color-authority)] shadow-[inset_0_0_0_1px_rgb(3_105_161/0.18)]">
    <KeyRound class="size-3.5" :stroke-width="2" />
    <span v-if="issued">Token issued to <strong class="font-semibold">{{ authority.user ?? 'the backend' }}</strong></span>
    <span v-else>Vault authorised <strong class="font-semibold">{{ authority.user ?? 'the backend' }}</strong></span>
    <span v-if="tenant" class="text-[var(--color-ink-2)]">for <strong class="font-semibold" :style="{ color: tenantVar(tenant) }">{{ tenantName(tenant) }}</strong></span>
    <span class="mono text-[0.8rem] text-[var(--color-ink-3)]">{{ authority.source ?? 'auth/jwt' }} · {{ authority.role }}</span>
    <TtlBar v-if="expiresAt" class="w-24" :expires-at="expiresAt" :total="total ?? 300" />
  </div>
</template>

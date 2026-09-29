<script setup lang="ts">
import { ArrowRight, KeyRound, ShieldCheck } from 'lucide-vue-next';

definePageMeta({ layout: 'bare' });
const route = useRoute();
const returnTo = computed(() => (typeof route.query.returnTo === 'string' ? route.query.returnTo : '/'));
const error = computed(() => (typeof route.query.error === 'string' ? route.query.error : null));
const href = computed(() => `/api/v1/auth/login?returnTo=${encodeURIComponent(returnTo.value)}&prompt=login`);
</script>

<template>
  <div class="grid min-h-screen place-items-center px-4 py-10">
    <div class="w-full max-w-[27rem]">
      <div class="pane pane-strong !bg-white/88 p-8">
        <div class="flex items-center gap-3">
          <DurinMark :size="40" />
          <div>
            <h1 class="text-[1.6rem] font-extrabold leading-none tracking-[-0.03em]">Durin</h1>
            <p class="mt-1.5 text-[0.85rem] text-[var(--color-ink-3)]">Vault Enterprise data protection</p>
          </div>
        </div>

        <p class="mt-7 text-[1.02rem] leading-relaxed text-[var(--color-ink-2)]">
          Keycloak verifies who you are. Vault then decides, separately, what you may decrypt.
        </p>

        <div v-if="error" role="alert" class="mt-5 rounded-lg bg-[var(--color-denied-soft)]/70 px-3.5 py-2.5 text-[0.88rem] text-[var(--color-denied)]">
          Sign-in did not complete. <span class="mono text-[0.8rem]">{{ error }}</span>
        </div>

        <a :href="href" class="btn btn-primary mt-7 !h-11 w-full justify-center text-[0.98rem]" data-testid="sign-in">
          Sign in with Durin identity <ArrowRight class="size-4" />
        </a>

        <ul class="mt-7 space-y-2.5 border-t border-[rgb(15_26_42/0.08)] pt-5 text-[0.83rem] text-[var(--color-ink-2)]">
          <li class="flex gap-2.5"><KeyRound class="mt-0.5 size-4 shrink-0 text-[var(--color-authority)]" :stroke-width="1.75" />Your access token never reaches this browser; the console's server keeps it.</li>
          <li class="flex gap-2.5"><ShieldCheck class="mt-0.5 size-4 shrink-0 text-[var(--color-clear)]" :stroke-width="1.75" />Every decrypt runs on a five-minute Vault token issued to you, for one tenant.</li>
        </ul>
      </div>
      <p class="mt-4 text-center text-[0.8rem] text-[var(--color-ink-3)]">Lab passwords: <span class="mono">./scripts/identity-secrets.sh --show-user &lt;uid&gt;</span></p>
    </div>
  </div>
</template>

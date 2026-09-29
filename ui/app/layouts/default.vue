<script setup lang="ts">
import { ShieldAlert, X } from 'lucide-vue-next';

const open = ref(false);
const route = useRoute();
const { scenario, refreshScenario } = useConsoleState();
watch(() => route.fullPath, () => { open.value = false; refreshScenario(); });
onMounted(refreshScenario);
</script>

<template>
  <div class="min-h-screen lg:grid lg:grid-cols-[17rem_1fr]">
    <!-- rail: fixed frosted wall on desktop, sheet on small screens -->
    <aside
      class="pane pane-strong fixed inset-y-0 left-0 z-40 w-[17rem] !rounded-none transition-transform duration-300 ease-[cubic-bezier(0.16,1,0.3,1)] lg:sticky lg:top-0 lg:h-screen lg:translate-x-0"
      :class="open ? 'translate-x-0' : '-translate-x-full'"
    >
      <button class="absolute right-3 top-4 rounded-md p-1.5 hover:bg-white/60 lg:hidden" aria-label="Close navigation" @click="open = false">
        <X class="size-4.5" />
      </button>
      <AppRail @navigate="open = false" />
    </aside>
    <div v-if="open" class="fixed inset-0 z-30 bg-[rgb(15_26_42/0.2)] backdrop-blur-[2px] lg:hidden" @click="open = false" />

    <div class="flex min-h-screen min-w-0 flex-col">
      <header class="pane sticky top-0 z-20 !rounded-none">
        <AppFrameBar @menu="open = true" />
      </header>

      <div
        v-if="scenario?.compromiseMode"
        class="flex items-center gap-3 bg-[var(--color-denied)] px-6 py-2.5 text-[0.88rem] font-semibold text-white"
        role="status"
        data-testid="compromise-banner"
      >
        <ShieldAlert class="size-4.5" :stroke-width="2" />
        DATABASE COMPROMISED — simulated. An attacker holds {{ scenario.compromiseSnapshot?.records ?? 'the' }} ciphertexts and no Vault authority.
        <NuxtLink to="/compromise" class="ml-auto underline underline-offset-4">Go to Compromise</NuxtLink>
      </div>

      <main class="mx-auto w-full max-w-[84rem] flex-1 px-4 pb-16 pt-7 lg:px-8">
        <slot />
      </main>

      <DurinFooter />
    </div>
  </div>
</template>

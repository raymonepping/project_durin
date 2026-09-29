<script setup lang="ts">
// The aluminium-framed side rail. The six story steps sit on one line with a
// light that slides to "now" — the presenter always knows where the story is.
import {
  LayoutGrid, Lock, LockOpen, ShieldAlert, ShieldCheck, Split, Siren,
  Users, FileText, Building2, Database, Server, ScrollText,
} from 'lucide-vue-next';

const emit = defineEmits<{ navigate: [] }>();
const route = useRoute();

const story = [
  { to: '/protect', label: 'Protect', icon: Lock, hint: 'plaintext → ciphertext' },
  { to: '/recover', label: 'Recover', icon: LockOpen, hint: 'a person, authorised' },
  { to: '/compromise', label: 'Compromise', icon: ShieldAlert, hint: 'the database is stolen' },
  { to: '/shield', label: 'Shield', icon: ShieldCheck, hint: 'rotate, rewrap, retire' },
  { to: '/isolation', label: 'Isolation', icon: Split, hint: 'tenant A ≠ tenant B' },
  { to: '/break-glass', label: 'Break Glass', icon: Siren, hint: 'approved in Vault, once' },
];
const groups = [
  { title: 'Data', items: [
    { to: '/customers', label: 'Customers', icon: Users },
    { to: '/documents', label: 'Documents', icon: FileText },
    { to: '/tenants', label: 'Tenants', icon: Building2 },
  ] },
  { title: 'Inspection', items: [
    { to: '/inspector', label: 'Database Inspector', icon: Database },
    { to: '/vault', label: 'Vault', icon: Server },
  ] },
  { title: 'Evidence', items: [
    { to: '/audit', label: 'Audit', icon: ScrollText },
  ] },
];

const nowIndex = computed(() => story.findIndex(s => route.path.startsWith(s.to)));
const active = (to: string) => (to === '/' ? route.path === '/' : route.path.startsWith(to));
</script>

<template>
  <nav aria-label="Primary" class="flex h-full flex-col gap-6 overflow-y-auto px-4 py-5">
    <NuxtLink to="/" class="flex items-center gap-2.5 rounded-lg px-1.5 py-1" @click="emit('navigate')">
      <DurinMark :size="30" />
      <span class="flex flex-col leading-none">
        <span class="text-[1.12rem] font-extrabold tracking-[-0.03em]">Durin</span>
        <span class="mt-1 text-[0.8rem] font-medium text-[var(--color-ink-3)]">Vault data protection</span>
      </span>
    </NuxtLink>

    <NuxtLink
      to="/"
      class="flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-[0.92rem] font-semibold transition-colors"
      :class="active('/') ? 'bg-white/80 text-[var(--color-ink)] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]' : 'text-[var(--color-ink-2)] hover:bg-white/50'"
      @click="emit('navigate')"
    >
      <LayoutGrid class="size-4" :stroke-width="1.75" /> Overview
    </NuxtLink>

    <!-- The story rail -->
    <div>
      <p class="mb-2 px-2.5 text-[0.8rem] font-semibold text-[var(--color-ink-3)]">The story</p>
      <ol class="relative">
        <span class="absolute left-[1.21rem] top-3 bottom-3 w-px bg-[var(--color-mullion)]" aria-hidden="true" />
        <span
          v-if="nowIndex >= 0"
          class="absolute left-[0.93rem] size-[0.62rem] rounded-full bg-[var(--color-clear)] shadow-[0_0_0_3px_rgb(255_255_255/0.9),0_0_12px_2px_rgb(15_118_110/0.45)] transition-transform duration-500 ease-[cubic-bezier(0.16,1,0.3,1)]"
          :style="{ transform: `translateY(calc(${nowIndex} * 3.05rem + 0.95rem))` }"
          aria-hidden="true"
        />
        <li v-for="(s, i) in story" :key="s.to" class="h-[3.05rem]">
          <NuxtLink
            :to="s.to"
            class="group relative flex h-full items-center gap-3 rounded-lg pl-9 pr-2 transition-colors"
            :class="active(s.to) ? 'bg-white/80 shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]' : 'hover:bg-white/45'"
            :aria-current="active(s.to) ? 'step' : undefined"
            @click="emit('navigate')"
          >
            <span
              class="absolute left-[0.99rem] size-[0.5rem] rounded-full transition-colors"
              :class="i < nowIndex ? 'bg-[var(--color-clear)]' : 'bg-white shadow-[inset_0_0_0_1.5px_var(--color-mullion-dark)]'"
            />
            <component :is="s.icon" class="size-4 shrink-0 text-[var(--color-ink-2)]" :stroke-width="1.75" />
            <span class="flex min-w-0 flex-col">
              <span class="text-[0.92rem] font-semibold leading-tight" :class="active(s.to) ? 'text-[var(--color-ink)]' : 'text-[var(--color-ink-2)]'">{{ s.label }}</span>
              <span class="truncate text-[0.8rem] leading-tight text-[var(--color-ink-3)]">{{ s.hint }}</span>
            </span>
          </NuxtLink>
        </li>
      </ol>
    </div>

    <div v-for="g in groups" :key="g.title">
      <p class="mb-1.5 px-2.5 text-[0.8rem] font-semibold text-[var(--color-ink-3)]">{{ g.title }}</p>
      <NuxtLink
        v-for="it in g.items"
        :key="it.to"
        :to="it.to"
        class="flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-[0.9rem] font-medium transition-colors"
        :class="active(it.to) ? 'bg-white/80 font-semibold text-[var(--color-ink)] shadow-[inset_0_0_0_1px_rgb(15_26_42/0.08)]' : 'text-[var(--color-ink-2)] hover:bg-white/50'"
        @click="emit('navigate')"
      >
        <component :is="it.icon" class="size-4" :stroke-width="1.75" /> {{ it.label }}
      </NuxtLink>
    </div>
  </nav>
</template>

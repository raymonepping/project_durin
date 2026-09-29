<script setup lang="ts">
// The console footer — pattern from Editors Factory (FactoryFooter.vue):
// in-flow, once per page via the default layout, never fixed (a fixed footer
// eats screen height and breaks full-page screenshots). The glass key names
// every state colour once, so no state depends on colour alone.
const year = new Date().getFullYear();

const keyOpen = ref(false);
onMounted(() => {
  try { keyOpen.value = localStorage.getItem('durin-footer:key') === '1'; } catch { /* stays folded */ }
});
function toggleKey() {
  keyOpen.value = !keyOpen.value;
  try { localStorage.setItem('durin-footer:key', keyOpen.value ? '1' : '0'); } catch { /* ignore */ }
}

const glassKey = [
  { swatch: 'var(--color-mullion-dark)', label: 'Frosted: ciphertext only' },
  { swatch: 'var(--color-clear)', label: 'Cleared by Vault' },
  { swatch: 'var(--color-cipher)', label: 'vault:vN: ciphertext' },
  { swatch: 'var(--color-authority)', label: 'Who Vault authorised' },
  { swatch: 'var(--color-glass)', label: 'Break glass' },
  { swatch: 'var(--color-denied)', label: 'Refused / retired' },
] as const;

const words = ['Protect', 'Authorise', 'Shield', 'Prove'] as const;

const links = [
  {
    label: 'GitHub',
    href: 'https://github.com/raymonepping',
    path: 'M12 2C6.477 2 2 6.477 2 12c0 4.418 2.865 8.166 6.839 9.489.5.092.682-.217.682-.482 0-.237-.009-.868-.013-1.703-2.782.605-3.369-1.34-3.369-1.34-.454-1.154-1.11-1.462-1.11-1.462-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0 1 12 6.836c.85.004 1.705.115 2.504.337 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.202 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.163 22 16.418 22 12c0-5.523-4.477-10-10-10z',
  },
  {
    label: 'X',
    href: 'https://x.com/doctor_nosql',
    path: 'M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-4.714-6.231-5.401 6.231H2.746l7.73-8.835L2.25 2.25h6.988l4.26 5.637zm-1.161 17.52h1.833L7.084 4.126H5.117z',
  },
  {
    label: 'LinkedIn',
    href: 'https://www.linkedin.com/in/raymonepping/',
    path: 'M20.447 20.452h-3.554v-5.569c0-1.328-.027-3.037-1.852-3.037-1.853 0-2.136 1.445-2.136 2.939v5.667H9.351V9h3.414v1.561h.046c.477-.9 1.637-1.85 3.37-1.85 3.601 0 4.267 2.37 4.267 5.455v6.286zM5.337 7.433a2.062 2.062 0 0 1-2.063-2.065 2.064 2.064 0 1 1 2.063 2.065zm1.782 13.019H3.555V9h3.564v11.452zM22.225 0H1.771C.792 0 0 .774 0 1.729v20.542C0 23.227.792 24 1.771 24h20.451C23.2 24 24 23.227 24 22.271V1.729C24 .774 23.2 0 22.222 0h.003z',
  },
  {
    label: 'Medium',
    href: 'https://medium.com/@raymonepping',
    path: 'M13.54 12a6.8 6.8 0 0 1-6.77 6.82A6.8 6.8 0 0 1 0 12a6.8 6.8 0 0 1 6.77-6.82A6.8 6.8 0 0 1 13.54 12zm7.42 0c0 3.54-1.51 6.42-3.38 6.42-1.87 0-3.39-2.88-3.39-6.42s1.52-6.42 3.39-6.42 3.38 2.88 3.38 6.42M24 12c0 3.17-.53 5.75-1.19 5.75-.66 0-1.19-2.58-1.19-5.75s.53-5.75 1.19-5.75C23.47 6.25 24 8.83 24 12z',
  },
] as const;
</script>

<template>
  <footer class="pane pane-strong mt-auto !rounded-none" data-testid="durin-footer">
    <!-- the aluminium frame rule, with a teal "cleared" glint at its centre -->
    <div class="footer-rail" aria-hidden="true" />

    <div class="mx-auto max-w-[84rem] border-b border-[rgb(15_26_42/0.06)] px-4 lg:px-8">
      <button
        type="button"
        class="flex w-full items-center gap-1.5 py-2.5 text-left text-[0.8rem] font-semibold text-[var(--color-ink-2)] transition-colors hover:text-[var(--color-ink)]"
        :aria-expanded="keyOpen"
        aria-controls="footer-glass-key"
        @click="toggleKey"
      >
        <svg viewBox="0 0 12 12" class="size-2.5 shrink-0 transition-transform duration-150" :class="keyOpen && 'rotate-90'" aria-hidden="true">
          <path d="M4.5 3 8 6l-3.5 3" stroke="currentColor" stroke-width="1.4" fill="none" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        Glass key
      </button>
      <div v-show="keyOpen" id="footer-glass-key" class="flex flex-wrap items-center gap-x-5 gap-y-2 pb-3.5 text-[0.8rem] text-[var(--color-ink-2)]">
        <span v-for="k in glassKey" :key="k.label" class="inline-flex items-center gap-1.5">
          <span class="size-2.5 shrink-0 rounded-[3px]" :style="{ background: k.swatch }" aria-hidden="true" />
          {{ k.label }}
        </span>
      </div>
    </div>

    <div class="mx-auto flex max-w-[84rem] flex-col gap-3.5 px-4 pb-6 pt-5 lg:px-8">
      <p class="text-center text-[0.9rem] italic text-[var(--color-ink-2)]">
        The database holds the data. Vault holds the key. Authority belongs to people.
      </p>

      <div class="flex flex-col items-center gap-3 sm:flex-row sm:justify-between">
        <p class="flex flex-wrap items-center justify-center text-[0.8rem] text-[var(--color-ink-3)]">
          <span>© {{ year }} <span class="sig-name" data-name="Raymon Epping" tabindex="0">Raymon Epping</span></span>
          <span v-for="w in words" :key="w" class="footer-word">
            <i aria-hidden="true">·</i>{{ w }}
          </span>
        </p>

        <nav class="flex items-center gap-3.5" aria-label="Raymon Epping on social media">
          <a
            v-for="l in links"
            :key="l.label"
            :href="l.href"
            target="_blank"
            rel="noopener noreferrer"
            :aria-label="l.label"
            class="grid size-8 place-items-center rounded-lg text-[var(--color-ink-3)] transition-colors hover:bg-white/70 hover:text-[var(--color-authority)]"
          >
            <svg viewBox="0 0 24 24" class="size-3.5" fill="currentColor" aria-hidden="true"><path :d="l.path" /></svg>
          </a>
        </nav>
      </div>
    </div>
  </footer>
</template>

<style scoped>
.footer-rail {
  height: 2px;
  background: linear-gradient(90deg, transparent, var(--color-mullion) 18%, var(--color-clear) 50%, var(--color-mullion) 82%, transparent);
  opacity: 0.7;
}

/* The signature clears like a pane: a light sweep on hover/focus. */
.sig-name {
  position: relative;
  display: inline-block;
  border-radius: 3px;
  cursor: default;
  transition: color 180ms var(--ease-out);
}
.sig-name:hover,
.sig-name:focus-visible { outline: none; color: var(--color-clear); }
.sig-name::after {
  content: attr(data-name);
  position: absolute;
  inset: 0;
  color: transparent;
  background: linear-gradient(100deg, transparent 42%, rgb(255 255 255 / 0.95) 50%, transparent 58%);
  background-size: 260% 100%;
  background-position: 130% 0;
  -webkit-background-clip: text;
  background-clip: text;
  opacity: 0;
  pointer-events: none;
}
.sig-name:hover::after,
.sig-name:focus-visible::after { animation: sig-clear 0.9s var(--ease-out); }
@keyframes sig-clear {
  0% { background-position: 130% 0; opacity: 0; }
  12%, 88% { opacity: 1; }
  100% { background-position: -30% 0; opacity: 0; }
}

.footer-word {
  display: inline-flex;
  align-items: center;
  cursor: default;
  transition: color 180ms, transform 180ms var(--ease-out);
}
.footer-word:hover { color: var(--color-ink); transform: translateY(-1px); }
.footer-word i { margin: 0 6px; font-style: normal; color: var(--color-mullion-dark); }

@media (prefers-reduced-motion: reduce) {
  .sig-name::after { display: none; }
}
</style>

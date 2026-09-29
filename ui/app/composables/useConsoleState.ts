// Shared, lightly polled state for the chrome: scenario state (compromise
// banner, fortified tenants) and Vault cluster health (the LED pill).
export function useConsoleState() {
  const scenario = useState<any>('scenario-state', () => null);
  const vault = useState<any>('vault-status', () => null);
  const { call } = useApi();

  async function refreshScenario() {
    const r = await call('/scenarios/state', { tenant: null });
    if (r.ok) scenario.value = r.data;
    return r;
  }
  async function refreshVault() {
    const r = await call('/vault/status', { tenant: null });
    if (r.ok) vault.value = r.data;
    return r;
  }
  return { scenario, vault, refreshScenario, refreshVault };
}

/** Poll a function while the component is mounted. */
export function usePoll(fn: () => unknown, ms: number) {
  let t: ReturnType<typeof setInterval> | null = null;
  onMounted(() => { fn(); t = setInterval(fn, ms); });
  onBeforeUnmount(() => { if (t) clearInterval(t); });
}

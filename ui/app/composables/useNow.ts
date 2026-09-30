// A shared 1-second clock for countdowns and TTL bars drawn to scale.
// Expiry times come from the server (Vault, PostgreSQL), so the clock runs on
// server time: useApi records the offset from each response's meta.timestamp.
// A laptop whose container VM clock drifted (sleep) then still shows true TTLs.
export const useClockOffset = () => useState<number>('clock-offset', () => 0);

export function useNow() {
  const offset = useClockOffset();
  const now = useState<number>('now', () => Date.now() + offset.value);
  if (import.meta.client) {
    const started = useState<boolean>('now-started', () => false);
    if (!started.value) {
      started.value = true;
      setInterval(() => { now.value = Date.now() + offset.value; }, 1000);
    }
  }
  return now;
}

export function secondsLeft(expiresAt: string | number | null | undefined, now: number) {
  if (!expiresAt) return 0;
  const t = typeof expiresAt === 'number' ? expiresAt : new Date(expiresAt).getTime();
  return Math.max(0, Math.round((t - now) / 1000));
}

export function formatDuration(s: number) {
  if (s <= 0) return 'expired';
  const m = Math.floor(s / 60);
  const sec = s % 60;
  return m ? `${m}:${String(sec).padStart(2, '0')}` : `${sec}s`;
}

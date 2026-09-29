// A shared 1-second clock for countdowns and TTL bars drawn to scale.
export function useNow() {
  const now = useState<number>('now', () => Date.now());
  if (import.meta.client) {
    const started = useState<boolean>('now-started', () => false);
    if (!started.value) {
      started.value = true;
      setInterval(() => { now.value = Date.now(); }, 1000);
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

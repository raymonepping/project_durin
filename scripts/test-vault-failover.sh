#!/usr/bin/env bash
# scripts/test-vault-failover.sh — kill the Vault leader under load.
#
# Proves that the HA cluster + vault-lb (prompts/infra/30_01) give Durin
# availability: stop the ACTIVE node while the backend is recovering data
# through the Data Trust Gateway, measure the interruption, confirm a new
# leader took over, confirm no request ever produced plaintext without Vault,
# then restart the node and confirm it rejoins as a standby.
#
# Disruptive but self-restoring (the stopped node is started again and
# auto-unseals via vault-s). Requires podman, curl, jq.
#
# Usage: ./scripts/test-vault-failover.sh [duration_seconds=45]
set -uo pipefail

# Real OIDC tokens when the backend enforces auth; pass-through in demo mode.
# shellcheck source=scripts/lib/durin-auth.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib/durin-auth.sh"

DURATION="${1:-45}"
B="${DURIN_BACKEND_URL:-http://localhost:3001}/api/v1"
MAX_OUTAGE="${MAX_OUTAGE_SECONDS:-15}"
LOG=$(mktemp -t durin-failover.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s  (%s)\n' "$1" "$2"; }

node_mode() { # active | standby | down
  podman exec "durin-vault_$1" sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status -format=json' 2>/dev/null \
    | jq -r 'if .sealed then "sealed" elif .is_self == true then "active" else "standby" end' 2>/dev/null || echo down
}
leader() { for n in 1 2 3; do [ "$(node_mode $n)" = active ] && { echo $n; return; }; done; echo none; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

printf '\n\033[1m── Vault leader failover under load\033[0m\n'
curl -s "$B/health" | jq -e '.vault.status == "connected"' >/dev/null || { echo "backend not healthy — aborting" >&2; exit 2; }
before=$(leader)
[ "$before" = none ] && { echo "no active Vault node — aborting" >&2; exit 2; }
echo "  leader before: vault-$before"

# Load: recover a stored IBAN every 250 ms through the full stack.
(
  end=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$end" ]; do
    t=$(now_ms)
    body=$(curl -s -m 30 -w '\n%{http_code}' -X POST "$B/scenarios/recover" \
      -H 'content-type: application/json' -H 'x-tenant: acme' -d '{"field":"iban"}')
    code=$(tail -n1 <<<"$body")
    has_plain=$(sed '$d' <<<"$body" | jq -r 'if (.data.plaintext // null) != null then 1 else 0 end' 2>/dev/null || echo 0)
    echo "$t $code $has_plain $(( $(now_ms) - t ))" >> "$LOG"
    sleep 0.25
  done
) &
LOAD=$!

sleep 5
echo "  stopping vault-$before …"
podman stop -t 5 "durin-vault_$before" >/dev/null
wait "$LOAD"

after=$(leader)
echo "  leader after:  vault-$after"
[ "$after" != none ] && [ "$after" != "$before" ] \
  && pass "a different node became leader (vault-$before → vault-$after)" \
  || fail "a different node became leader" "after=$after"

total=$(wc -l < "$LOG" | tr -d ' ')
ok=$(awk '$2==200' "$LOG" | wc -l | tr -d ' ')
bad=$(awk '$2!=200' "$LOG" | wc -l | tr -d ' ')
unsafe=$(awk '$2!=200 && $3==1' "$LOG" | wc -l | tr -d ' ')
codes=$(awk '$2!=200{print $2}' "$LOG" | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')
# Longest interruption: from the last success before a failure run to the first success after it.
outage_ms=$(awk 'BEGIN{last_ok=0; in_bad=0; max=0}
  { if ($2==200) { if (in_bad && last_ok>0) { d=$1-last_ok; if (d>max) max=d } ; last_ok=$1; in_bad=0 } else { in_bad=1 } }
  END{ if (in_bad) max=-1; print max }' "$LOG")

slowest=$(awk 'BEGIN{m=0}{if($4>m)m=$4}END{printf "%.1f", m/1000}' "$LOG")
echo "  requests: $total   ok: $ok   failed: $bad ${codes:+($codes)}   slowest request: ${slowest}s"
if [ "$outage_ms" = "-1" ]; then
  fail "service recovered after failover" "requests were still failing when the load window ended"
else
  secs=$(awk -v m="$outage_ms" 'BEGIN{printf "%.1f", m/1000}')
  echo "  longest interruption: ${secs}s"
  awk -v m="$outage_ms" -v max="$MAX_OUTAGE" 'BEGIN{exit !(m <= max*1000)}' \
    && pass "longest interruption ${secs}s ≤ ${MAX_OUTAGE}s" \
    || fail "longest interruption ≤ ${MAX_OUTAGE}s" "${secs}s"
fi
[ "$unsafe" = 0 ] && pass "no failed request carried plaintext (fail closed)" || fail "fail closed" "$unsafe unsafe responses"
awk '$2!=200 && $2!=503' "$LOG" | grep -q . \
  && fail "failures are clean 503s" "unexpected codes: $codes" \
  || pass "every failed request was a clean 503 (or none failed)"

echo "  restarting vault-$before …"
podman start "durin-vault_$before" >/dev/null
for _ in $(seq 1 40); do
  m=$(node_mode "$before"); [ "$m" = standby ] && break; sleep 3
done
[ "$m" = standby ] && pass "vault-$before rejoined as standby" || fail "vault-$before rejoined as standby" "mode=$m"
curl -s "$B/health" | jq -e '.vault.status == "connected"' >/dev/null \
  && pass "backend healthy through vault-lb" || fail "backend healthy through vault-lb" "health not connected"

printf '\n\033[1mFailover: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

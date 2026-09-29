#!/usr/bin/env bash
# scripts/reset.sh — wipe demo data and re-seed to baseline
#
# Usage:
#   ./scripts/reset.sh           — wipe + re-seed, keep key versions
#   ./scripts/reset.sh --rotate  — wipe + rotate all Transit keys + re-seed
#
# The --rotate flag advances every tenant Transit key to a new version.
# Old ciphertext from a previous run remains in Vault but the new baseline
# ciphertext is always produced under the latest key version.
set -euo pipefail

# Real OIDC tokens when the backend enforces auth; pass-through in demo mode.
# shellcheck source=scripts/lib/durin-auth.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib/durin-auth.sh"

BACKEND_URL="${DURIN_BACKEND_URL:-http://localhost:3001}"
ROTATE=false

for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=true ;;
    *) echo "[reset] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

RESET_URL="${BACKEND_URL}/api/v1/scenarios/reset"
if [ "${ROTATE}" = "true" ]; then
  RESET_URL="${RESET_URL}?rotate=true"
  echo "[reset] Resetting with key rotation..."
else
  echo "[reset] Resetting (no key rotation)..."
fi

reset_response=$(curl -sf -X DELETE "${RESET_URL}" \
  -H "Content-Type: application/json" \
  --max-time 60)

echo "[reset] Reset response:"
echo "${reset_response}" | python3 -m json.tool 2>/dev/null || echo "${reset_response}"

echo "[reset] Re-seeding..."
seed_response=$(curl -sf -X POST "${BACKEND_URL}/api/v1/scenarios/seed" \
  -H "Content-Type: application/json" \
  --max-time 60)

echo "[reset] Seed response:"
echo "${seed_response}" | python3 -m json.tool 2>/dev/null || echo "${seed_response}"

# Print summary
customers=$(echo "${seed_response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('customers','?'))" 2>/dev/null || echo "?")
documents=$(echo "${seed_response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('documents','?'))" 2>/dev/null || echo "?")
protected=$(echo "${seed_response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('protectedValues','?'))" 2>/dev/null || echo "?")
echo ""
echo "[reset] Done: ${customers} customers, ${documents} documents, ${protected} protected values"

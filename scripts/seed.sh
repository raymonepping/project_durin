#!/usr/bin/env bash
# scripts/seed.sh — seed demo data via the Durin backend API
# Calls POST /api/v1/scenarios/seed. Idempotent — skips if already seeded.
set -euo pipefail

# Real OIDC tokens when the backend enforces auth; pass-through in demo mode.
# shellcheck source=scripts/lib/durin-auth.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib/durin-auth.sh"

BACKEND_URL="${DURIN_BACKEND_URL:-http://localhost:3001}"

echo "[seed] Seeding demo data via ${BACKEND_URL}..."

response=$(curl -sf -X POST "${BACKEND_URL}/api/v1/scenarios/seed" \
  -H "Content-Type: application/json" \
  --max-time 60)

echo "[seed] Response:"
echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"

# Surface the message so CI logs are unambiguous
message=$(echo "${response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['message'])" 2>/dev/null || true)
echo "[seed] ${message:-done}"

#!/usr/bin/env bash
# Resolves the SoftHSM2 slot ID from the running softhsm-server container
# and writes it to .secrets/hsm/slot-id so vault-hsm-server.sh can use it.
#
# Called by: make hsm-bootstrap
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SLOT_FILE="$ROOT/.secrets/hsm/slot-id"

echo "[HSM] Resolving SoftHSM2 slot ID from arcanium-softhsm_server..."

# Run pkcs11-tool inside the softhsm-server container (Debian, has all deps).
# Extract the hex slot ID (e.g. 0x699a5fbf) and convert to decimal for Vault.
# Extract hex ID from the first initialized Slot line, e.g. "Slot 0 (0x699a5fbf):"
SLOT_HEX=$(podman exec arcanium-softhsm_server \
  sh -c "SOFTHSM2_CONF=/etc/softhsm2.conf \
    pkcs11-tool --module /usr/local/lib/softhsm/libsofthsm2.so \
    --list-slots 2>/dev/null" 2>/dev/null |
  grep -m1 "^Slot" | awk '{print $3}' | tr -d '()' ||
  true)

SLOT_ID=""
if [ -n "$SLOT_HEX" ]; then
  # Convert hex to decimal
  SLOT_ID=$(printf '%d' "$SLOT_HEX" 2>/dev/null || true)
fi

if [ -z "$SLOT_ID" ]; then
  echo "[HSM] ERROR: Could not resolve slot ID." >&2
  echo "[HSM] Is arcanium-softhsm_server running and healthy?" >&2
  exit 1
fi

mkdir -p "$ROOT/.secrets/hsm"
echo "$SLOT_ID" >"$SLOT_FILE"
chmod 600 "$SLOT_FILE"

echo "[HSM] Slot ID: $SLOT_ID → written to .secrets/hsm/slot-id"

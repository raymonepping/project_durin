#!/bin/sh
set -eu
# Vault HSM entrypoint: reads the resolved SoftHSM2 slot ID from the
# .secrets/hsm/slot-id file (written by scripts/hsm-resolve-slot.sh),
# renders the Vault config with the real slot number, then starts vault server.

CONFIG_TEMPLATE=/vault/config/config.hcl
CONFIG_RESOLVED=/tmp/vault-config-resolved.hcl
SLOT_ID_FILE=/run/secrets/slot-id

if [ -f "$SLOT_ID_FILE" ]; then
  SOFTHSM_SLOT_ID=$(cat "$SLOT_ID_FILE" | tr -d '[:space:]')
  echo "[HSM] Using slot ID: $SOFTHSM_SLOT_ID"
  sed "s/\${SOFTHSM_SLOT_ID}/${SOFTHSM_SLOT_ID}/g;
       s/\${SOFTHSM_TOKEN_LABEL}/${SOFTHSM_TOKEN_LABEL:-arcanium-hsm}/g;
       s/\${SOFTHSM_USER_PIN}/${SOFTHSM_USER_PIN}/g" \
    "$CONFIG_TEMPLATE" >"$CONFIG_RESOLVED"
  CONFIG_TO_USE="$CONFIG_RESOLVED"
else
  echo "[HSM] WARNING: slot-id file not found at $SLOT_ID_FILE" >&2
  echo "[HSM] Run: make hsm-bootstrap to resolve slot ID first." >&2
  exit 1
fi

mkdir -p /vault/file /vault/audit
exec vault server -config="$CONFIG_TO_USE"

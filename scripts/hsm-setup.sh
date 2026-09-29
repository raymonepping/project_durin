#!/bin/sh
# Initialises a SoftHSM2 PKCS#11 token for Vault HSM auto-unseal.
# Idempotent — safe to run multiple times.
# Adapted from vault_reference/softhsm/setup_softhsm.sh
#
# Runs inside the softhsm-init container (Alpine + softhsm + opensc).
# Volumes:
#   softhsm-tokens → /var/lib/softhsm/tokens  (persistent token store)
#   softhsm-lib    → /softhsm/lib              (shared PKCS#11 library)
set -eu

TOKEN_LABEL="${TOKEN_LABEL:-arcanium-hsm}"
TOKEN_PIN="${TOKEN_PIN:-1234}"
SO_PIN="${SO_PIN:-5678}"
# On RHEL/UBI the library is in /usr/lib64/softhsm/; on Alpine it's /usr/lib/softhsm/
LIB=$(find /usr/lib64/softhsm /usr/lib/softhsm -name libsofthsm2.so 2>/dev/null | head -1)
LIB="${LIB:-/usr/lib64/softhsm/libsofthsm2.so}"

log() { printf '\n[HSM] %s\n' "$*"; }
ok() { printf '      ✓ %s\n' "$*"; }
skip() { printf '      – %s (already done)\n' "$*"; }

# Write config pointing at the persistent token volume
# Use /tmp to avoid read-only filesystem issues
printf '[tokens]\ndirectories.tokendir = /var/lib/softhsm/tokens/\nobjectstore.backend = file\nlog.level = ERROR\n' \
  >/tmp/softhsm2.conf
export SOFTHSM2_CONF=/tmp/softhsm2.conf

# ── Initialise token ──────────────────────────────────────────────────────────
log "Checking token '${TOKEN_LABEL}'"
if softhsm2-util --show-slots 2>/dev/null | grep -q "${TOKEN_LABEL}"; then
  skip "Token '${TOKEN_LABEL}' already exists"
else
  softhsm2-util --init-token --free \
    --label "${TOKEN_LABEL}" \
    --pin "${TOKEN_PIN}" \
    --so-pin "${SO_PIN}"
  ok "Token '${TOKEN_LABEL}' initialised"
fi

# ── Generate RSA-2048 signing key ────────────────────────────────────────────
log "Checking RSA-2048 demo signing key"
if pkcs11-tool --module "${LIB}" --login --pin "${TOKEN_PIN}" \
  --list-objects --token-label "${TOKEN_LABEL}" 2>/dev/null |
  grep -q "arcanium-rsa-key"; then
  skip "RSA key 'arcanium-rsa-key' already exists"
else
  pkcs11-tool --module "${LIB}" \
    --token-label "${TOKEN_LABEL}" \
    --login --pin "${TOKEN_PIN}" \
    --keypairgen --key-type rsa:2048 \
    --label arcanium-rsa-key --id 01 \
    --usage-sign --usage-decrypt
  ok "RSA-2048 key pair 'arcanium-rsa-key' generated (id=01)"
fi

# ── Export library to shared volume ──────────────────────────────────────────
log "Exporting PKCS#11 library to shared volume"
mkdir -p /softhsm/lib
cp "${LIB}" /softhsm/lib/libsofthsm2.so
ok "Library → /softhsm/lib/libsofthsm2.so"

# ── Summary ───────────────────────────────────────────────────────────────────
log "Token contents:"
pkcs11-tool --module "${LIB}" \
  --token-label "${TOKEN_LABEL}" \
  --login --pin "${TOKEN_PIN}" \
  --list-objects 2>/dev/null || true

printf '\n'
printf '────────────────────────────────────────────────────\n'
printf ' Token label : %s\n' "${TOKEN_LABEL}"
printf ' User PIN    : %s\n' "${TOKEN_PIN}"
printf ' SO PIN      : %s\n' "${SO_PIN}"
printf ' Library     : %s\n' "${LIB}"
printf ' Token store : softhsm-tokens volume\n'
printf ' Vault seal  : pkcs11 (generate_key=true — wrap keys auto-created)\n'
printf '────────────────────────────────────────────────────\n'

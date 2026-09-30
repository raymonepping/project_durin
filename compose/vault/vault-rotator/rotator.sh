#!/bin/sh
# compose/vault/vault-rotator/rotator.sh — durin-backend AppRole secret-id rotator
#
# Dedicated watchdog sidecar for AppRole secret-id lifecycle management.
# Periodically inspects durin-backend's secret-id in the shared /run/approle
# volume and replaces it before it expires, atomically, so vault-agent can
# re-authenticate with a valid one at any time.
#
# Decides on VAULT'S OWN answer, not on a local schedule (2026-09-30): it
# looks the current secret-id up and rotates when Vault says it is invalid or
# has less than ROTATE_BELOW_FRACTION of its life left. The first version
# rotated at a fixed 60 days of a declared 90 — but the approle mount then
# inherited the server-wide 168h max_lease_ttl, every secret-id silently died
# after 7 days, and a 60-day schedule can never catch that (Durin's live
# secret-id was due to expire on 2026-10-06 while the rotator reported "58
# days" to go; the same bug broke Editors Factory the same day). Reading the real
# expiry makes any such cap self-correcting, and WARN_IF_SHORTER_THAN makes it
# loud.
#
# One rotation issues exactly ONE secret-id (the first version called the
# secret-id endpoint twice — once for the value, once for an accessor — which
# left a second, valid, unused secret-id behind on every rotation) and then
# destroys the one it replaced.
set -eu

: "${VAULT_ADDR:=https://vault-lb:8200}"
: "${VAULT_CACERT:=/vault/tls/ca-chain.pem}"
: "${ROTATOR_ROLE_ID:?ROTATOR_ROLE_ID is required}"
: "${ROTATOR_SECRET_ID:?ROTATOR_SECRET_ID is required}"
: "${TARGET_ROLE_ID:?TARGET_ROLE_ID is required}"
: "${TARGET_ROLE_NAME:=durin-backend}"
: "${CHECK_INTERVAL_SECONDS:=43200}"   # 12 hours
: "${ROTATE_BELOW_FRACTION:=3}"        # rotate when less than 1/3 of the lifetime is left
: "${WARN_IF_SHORTER_THAN:=7776000}"   # the 90 days every role declares (secret_id_ttl)

export VAULT_ADDR VAULT_CACERT
# Root namespace by default; set VAULT_NAMESPACE only if the AppRole mount moves.
[ -n "${VAULT_NAMESPACE:-}" ] && export VAULT_NAMESPACE

ROLE_ID_FILE="/run/approle/role-id"
SECRET_ID_FILE="/run/approle/secret-id"
METADATA_FILE="/run/approle/metadata.json"

log() {
  echo "[vault-rotator] $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"
}

# Vault timestamps ("2026-12-29T16:54:15.123Z") -> epoch seconds (busybox date).
to_epoch() {
  date -u -d "$(printf '%s' "$1" | cut -c1-19 | tr 'T' ' ')" +%s 2>/dev/null || echo 0
}

# Ensure directory exists and has restricted permissions
mkdir -p /run/approle
chmod 700 /run/approle
umask 077

# Ensure TARGET_ROLE_ID is written
printf '%s' "$TARGET_ROLE_ID" >"$ROLE_ID_FILE.tmp"
mv "$ROLE_ID_FILE.tmp" "$ROLE_ID_FILE"
chmod 600 "$ROLE_ID_FILE"

get_rotator_token() {
  vault write -field=token auth/approle/login \
    role_id="$ROTATOR_ROLE_ID" secret_id="$ROTATOR_SECRET_ID"
}

lookup_field() { # $1 token, $2 secret-id, $3 field
  VAULT_TOKEN="$1" vault write -field="$3" \
    "auth/approle/role/$TARGET_ROLE_NAME/secret-id/lookup" secret_id="$2" 2>/dev/null
}

rotate_secret_id() {
  TOKEN=$(get_rotator_token)
  OLD_SECRET_ID=""
  [ -s "$SECRET_ID_FILE" ] && OLD_SECRET_ID=$(cat "$SECRET_ID_FILE")
  OLD_ACCESSOR=""
  [ -n "$OLD_SECRET_ID" ] && OLD_ACCESSOR=$(lookup_field "$TOKEN" "$OLD_SECRET_ID" secret_id_accessor || true)

  log "Generating fresh secret-id for role '$TARGET_ROLE_NAME'..."
  SECRET_ID=$(VAULT_TOKEN="$TOKEN" vault write -field=secret_id -f "auth/approle/role/$TARGET_ROLE_NAME/secret-id")
  if [ -z "$SECRET_ID" ] || [ "$SECRET_ID" = "null" ]; then
    log "ERROR: Failed to retrieve secret_id from Vault!"
    VAULT_TOKEN="$TOKEN" vault token revoke -self >/dev/null 2>&1 || true
    return 1
  fi
  ACCESSOR=$(lookup_field "$TOKEN" "$SECRET_ID" secret_id_accessor || echo "unknown")
  EXPIRES=$(lookup_field "$TOKEN" "$SECRET_ID" expiration_time || echo "")

  # Atomic file replacement — vault-agent reads this on its next login.
  printf '%s' "$SECRET_ID" >"$SECRET_ID_FILE.tmp"
  mv "$SECRET_ID_FILE.tmp" "$SECRET_ID_FILE"
  chmod 600 "$SECRET_ID_FILE"

  NOW_TS=$(date +%s)
  cat <<JSON >"$METADATA_FILE.tmp"
{
  "secret_id_accessor": "$ACCESSOR",
  "created_at_epoch": $NOW_TS,
  "expiration_time": "$EXPIRES",
  "role_name": "$TARGET_ROLE_NAME",
  "last_rotation_utc": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON
  mv "$METADATA_FILE.tmp" "$METADATA_FILE"
  chmod 600 "$METADATA_FILE"

  # The replaced secret-id can no longer be used to log in. Tokens already
  # issued from it are unaffected (vault-agent keeps working until its next
  # login, which then uses the new file).
  if [ -n "$OLD_ACCESSOR" ] && [ "$OLD_ACCESSOR" != "$ACCESSOR" ]; then
    if VAULT_TOKEN="$TOKEN" vault write "auth/approle/role/$TARGET_ROLE_NAME/secret-id-accessor/destroy" \
        secret_id_accessor="$OLD_ACCESSOR" >/dev/null 2>&1; then
      log "Destroyed the replaced secret-id (accessor ${OLD_ACCESSOR%%-*}…)."
    else
      log "WARNING: could not destroy the replaced secret-id (accessor ${OLD_ACCESSOR%%-*}…); it will expire on its own."
    fi
  fi

  LIFETIME=$(( $(to_epoch "$EXPIRES") - NOW_TS ))
  if [ "$LIFETIME" -gt 0 ] && [ "$LIFETIME" -lt $((WARN_IF_SHORTER_THAN - 3600)) ]; then
    log "WARNING: Vault issued a secret-id that lives $((LIFETIME / 86400)) days, not the $((WARN_IF_SHORTER_THAN / 86400)) the role declares — something above the role caps it (check 'vault read sys/mounts/auth/approle/tune')."
  fi

  VAULT_TOKEN="$TOKEN" vault token revoke -self >/dev/null 2>&1 || true
  log "Rotated secret-id for $TARGET_ROLE_NAME (expires $EXPIRES). Atomic swap complete."
}

# Ask Vault about the secret-id currently on disk.
is_rotation_needed() {
  if [ ! -s "$SECRET_ID_FILE" ]; then
    log "No secret-id in $SECRET_ID_FILE. Initial issuance required."
    return 0
  fi
  if [ ! -s "$METADATA_FILE" ]; then
    log "Metadata file missing. Re-issuing secret-id to establish rotation tracking."
    return 0
  fi

  TOKEN=$(get_rotator_token)
  CURRENT=$(cat "$SECRET_ID_FILE")
  EXPIRES=$(lookup_field "$TOKEN" "$CURRENT" expiration_time || echo "")
  CREATED=$(lookup_field "$TOKEN" "$CURRENT" creation_time || echo "")
  VAULT_TOKEN="$TOKEN" vault token revoke -self >/dev/null 2>&1 || true

  if [ -z "$EXPIRES" ]; then
    log "Vault does not recognise the current secret-id (expired or destroyed). Rotating now."
    return 0
  fi
  if [ "$EXPIRES" = "0001-01-01T00:00:00Z" ]; then
    log "Current secret-id never expires; nothing to do."
    return 1
  fi

  NOW_TS=$(date +%s)
  EXP_TS=$(to_epoch "$EXPIRES")
  CRE_TS=$(to_epoch "$CREATED")
  LEFT=$((EXP_TS - NOW_TS))
  LIFE=$((EXP_TS - CRE_TS))
  [ "$LIFE" -gt 0 ] || LIFE=$WARN_IF_SHORTER_THAN

  if [ "$LEFT" -lt $((LIFE / ROTATE_BELOW_FRACTION)) ]; then
    log "Current secret-id expires $EXPIRES: $((LEFT / 3600)) h left of a $((LIFE / 86400))-day life (below 1/$ROTATE_BELOW_FRACTION). Rotating now."
    return 0
  fi
  log "Current secret-id is healthy: expires $EXPIRES ($((LEFT / 86400)) days left of $((LIFE / 86400)))."
  return 1
}

# Main loop
log "Vault Secret-ID Rotator sidecar starting..."

# Wait for Vault to become reachable
until vault status >/dev/null 2>&1; do
  log "Waiting for Vault at $VAULT_ADDR to become unsealed..."
  sleep 3
done

while true; do
  if is_rotation_needed; then
    if rotate_secret_id; then
      log "Rotation check completed successfully."
    else
      log "WARNING: Rotation failed, will retry in 30 seconds."
      sleep 30
      continue
    fi
  fi
  sleep "$CHECK_INTERVAL_SECONDS"
done

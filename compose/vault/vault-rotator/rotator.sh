#!/bin/sh
# compose/vault/vault-rotator/rotator.sh
#
# Dedicated watchdog sidecar for AppRole secret-id lifecycle management.
# Periodically inspects durin-backend's secret-id in the shared /run/approle volume.
# If missing, stale, or older than 60 days (66% of the 90-day secret_id_ttl),
# it authenticates via approle-rotator and generates a fresh secret-id for
# durin-backend, atomically replacing the file so vault-agent can seamlessly
# re-authenticate.
set -eu

: "${VAULT_ADDR:=https://vault-lb:8200}"
: "${VAULT_CACERT:=/vault/tls/ca-chain.pem}"
: "${ROTATOR_ROLE_ID:?ROTATOR_ROLE_ID is required}"
: "${ROTATOR_SECRET_ID:?ROTATOR_SECRET_ID is required}"
: "${TARGET_ROLE_ID:?TARGET_ROLE_ID is required}"
: "${TARGET_ROLE_NAME:=durin-backend}"
: "${CHECK_INTERVAL_SECONDS:=43200}"       # 12 hours
: "${ROTATION_THRESHOLD_SECONDS:=5184000}" # 60 days (in seconds)

export VAULT_ADDR VAULT_CACERT

ROLE_ID_FILE="/run/approle/role-id"
SECRET_ID_FILE="/run/approle/secret-id"
METADATA_FILE="/run/approle/metadata.json"

log() {
  echo "[vault-rotator] $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"
}

# Ensure directory exists and has restricted permissions
mkdir -p /run/approle
chmod 700 /run/approle
umask 077

# Ensure TARGET_ROLE_ID is written so vault-agent can read it immediately
printf '%s' "$TARGET_ROLE_ID" >"$ROLE_ID_FILE.tmp"
mv "$ROLE_ID_FILE.tmp" "$ROLE_ID_FILE"
chmod 600 "$ROLE_ID_FILE"

get_rotator_token() {
  vault write -field=token auth/approle/login \
    role_id="$ROTATOR_ROLE_ID" secret_id="$ROTATOR_SECRET_ID"
}

rotate_secret_id() {
  log "Authenticating with Vault as approle-rotator..."
  TOKEN=$(get_rotator_token)

  log "Generating fresh secret-id for role '$TARGET_ROLE_NAME'..."
  SECRET_ID=$(VAULT_TOKEN="$TOKEN" vault write -field=secret_id -f "auth/approle/role/$TARGET_ROLE_NAME/secret-id")
  ACCESSOR=$(VAULT_TOKEN="$TOKEN" vault write -field=secret_id_accessor -f "auth/approle/role/$TARGET_ROLE_NAME/secret-id" 2>/dev/null || echo "unknown")

  if [ -z "$SECRET_ID" ] || [ "$SECRET_ID" = "null" ]; then
    log "ERROR: Failed to retrieve secret_id from Vault!"
    return 1
  fi

  # Atomic file replacement — vault-agent reads these files; a partial write
  # would cause a transient login failure, so always write to .tmp then mv.
  printf '%s' "$SECRET_ID" >"$SECRET_ID_FILE.tmp"
  mv "$SECRET_ID_FILE.tmp" "$SECRET_ID_FILE"
  chmod 600 "$SECRET_ID_FILE"

  NOW_TS=$(date +%s)
  cat <<JSON >"$METADATA_FILE.tmp"
{
  "secret_id_accessor": "$ACCESSOR",
  "created_at_epoch": $NOW_TS,
  "role_name": "$TARGET_ROLE_NAME",
  "last_rotation_utc": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON
  mv "$METADATA_FILE.tmp" "$METADATA_FILE"
  chmod 600 "$METADATA_FILE"

  # Revoke the rotator's short-lived session token — principle of least privilege
  VAULT_TOKEN="$TOKEN" vault token revoke -self >/dev/null 2>&1 || true

  log "Successfully rotated secret-id for $TARGET_ROLE_NAME. Atomic swap complete."
}

is_rotation_needed() {
  if [ ! -s "$SECRET_ID_FILE" ]; then
    log "No active secret-id found in $SECRET_ID_FILE. Initial issuance required."
    return 0
  fi

  if [ ! -s "$METADATA_FILE" ]; then
    log "Metadata file missing. Re-issuing secret-id to establish rotation tracking."
    return 0
  fi

  # Extract created_at_epoch using sed (no jq dependency in the base image)
  CREATED_AT=$(grep '"created_at_epoch"' "$METADATA_FILE" | sed 's/[^0-9]*//g' || echo 0)
  [ -n "$CREATED_AT" ] || CREATED_AT=0
  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - CREATED_AT))

  if [ "$AGE" -ge "$ROTATION_THRESHOLD_SECONDS" ]; then
    log "Current secret-id age ($AGE s) exceeds rotation threshold ($ROTATION_THRESHOLD_SECONDS s / 60 days). Rotating now."
    return 0
  fi

  REMAINING=$((ROTATION_THRESHOLD_SECONDS - AGE))
  log "Current secret-id is healthy (age: $((AGE / 86400)) days, next rotation in $((REMAINING / 86400)) days)."
  return 1
}

# Main loop
log "Vault Secret-ID Rotator sidecar starting..."

# Wait for Vault to become reachable before first rotation attempt
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

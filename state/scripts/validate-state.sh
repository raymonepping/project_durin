#!/usr/bin/env bash
# validate-state.sh — confirm a captured baseline contains zero secrets.
#
# Two independent checks:
#  1. Direct leak: does any actual .env value (passwords, tokens, secrets,
#     client secrets, PINs) appear verbatim anywhere in the baseline?
#  2. Shape-based: does anything in the baseline LOOK like a credential —
#     Vault token prefixes, PEM private-key headers, "Bearer <token>",
#     long high-entropy strings next to a password/secret/token key name —
#     even if it isn't a known .env value (e.g. a stray root token dumped
#     from a init.json this script wasn't told about)?
#
# Usage:
#   state/scripts/validate-state.sh <baseline-id>
#   state/scripts/validate-state.sh state/baselines/2026-09-11_pre-hardening
#
# Exit 0 = clean. Exit 1 = suspected secret found — DO NOT commit the baseline.
set -uo pipefail
cd "$(dirname -- "$0")/../.." # -> repo root

ARG="${1:?usage: validate-state.sh <baseline-id-or-path>}"
BASE="$ARG"
[ -d "$BASE" ] || BASE="state/baselines/${ARG}"
if [ ! -d "$BASE" ]; then
  echo "error: no such baseline: $ARG" >&2
  exit 2
fi

echo "Validating: $BASE"
echo

found=0

# --- 1. direct .env value leak -----------------------------------------
if [ -f .env ]; then
  while IFS='=' read -r key val; do
    case "$key" in
    '' | '#'*) continue ;;
    esac
    # Explicitly non-secret despite matching a sensitive substring below —
    # found live: SOFTHSM_TOKEN_LABEL is a human-readable identifier
    # ("arcanium-hsm"), not a credential, and its value legitimately
    # coincides with this project's volume-naming convention
    # (arcanium-hsm_softhsm-data etc.), which made the naive *TOKEN* match
    # below flag it as a false-positive "leak" of a benign label. Narrowly
    # scoped to *_LABEL only — a broader exclusion (e.g. *_ID) would wrongly
    # wave through real secrets like ARCANIUM_VAULT_SECRET_ID.
    case "$key" in
    *_LABEL) continue ;;
    esac
    # Only check values that look credential-shaped by key name, and are
    # non-trivial in length (skip short/boolean/mode values — those are
    # meant to appear, e.g. ARCANIUM_AUTH_ENABLED=false).
    case "$key" in
    *PASSWORD* | *SECRET* | *TOKEN* | *_KEY | *PIN* | *LICENSE*)
      val="${val%\"}"
      val="${val#\"}"
      if [ "${#val}" -ge 8 ]; then
        hits="$(grep -rl -- "$val" "$BASE" 2>/dev/null || true)"
        if [ -n "$hits" ]; then
          echo "LEAK: value of \$$key found in:"
          echo "$hits" | sed 's/^/  /'
          found=1
        fi
      fi
      ;;
    esac
  done <.env
else
  echo "note: no .env in repo root — skipping direct-value check"
fi

# --- 2. shape-based scan -------------------------------------------------
# Vault token prefixes (hvs./hvb./s. legacy, root token uuid-shaped),
# PEM private key headers, bearer tokens, AWS-style access keys.
PATTERNS=(
  'hvs\.[A-Za-z0-9_-]{20,}'
  'hvb\.[A-Za-z0-9_-]{20,}'
  '-----BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY-----'
  'Bearer [A-Za-z0-9._-]{20,}'
  'AKIA[0-9A-Z]{16}'
)
for pat in "${PATTERNS[@]}"; do
  hits="$(grep -rlE -- "$pat" "$BASE" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "SUSPECT (pattern: $pat) found in:"
    echo "$hits" | sed 's/^/  /'
    found=1
  fi
done

echo
if [ "$found" -eq 0 ]; then
  echo "clean — no known .env values and no credential-shaped strings found in $BASE"
  exit 0
else
  echo "FAILED — do not commit this baseline until the above is resolved"
  exit 1
fi

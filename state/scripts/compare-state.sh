#!/usr/bin/env bash
# compare-state.sh — Prompt 00. Diff two baselines' manifest.yaml, component
# statuses, and verification results.
#
# Usage:
#   state/scripts/compare-state.sh <baseline-a> <baseline-b>
#   state/scripts/compare-state.sh <baseline-b>   # resolves A from metadata
#
# With one argument, baseline A is resolved from B's own recorded metadata —
# manifest.yaml's `previous_baseline` field if present (the authoritative,
# recorded predecessor — unaffected by directory renames or filesystem
# timestamps), otherwise by sorting every baseline's `captured_at` and
# taking the one immediately before B. Directory mtime is never used; it
# does not survive a checkout, a copy, or a restore.
set -uo pipefail
cd "$(dirname -- "$0")/../.." # -> repo root

resolve_dir() {
  local a="$1"
  [ -d "$a" ] && {
    echo "$a"
    return
  }
  [ -d "state/baselines/$a" ] && {
    echo "state/baselines/$a"
    return
  }
  echo "error: no such baseline: $a" >&2
  exit 2
}

manifest_field() {
  # $1 = manifest.yaml path, $2 = top-level.field (two-space-indented child)
  grep -m1 "^  ${2}:" "$1" 2>/dev/null | sed -E "s/^  ${2}: *//" | tr -d '"'
}

resolve_previous() {
  local b_dir="$1" b_manifest="$1/manifest.yaml" prev
  if [ ! -f "$b_manifest" ]; then
    echo "error: $b_manifest missing — cannot resolve a previous baseline without it" >&2
    exit 2
  fi
  prev="$(manifest_field "$b_manifest" previous_baseline)"
  if [ -n "$prev" ] && [ -d "state/baselines/$prev" ]; then
    echo "state/baselines/$prev"
    return
  fi
  # Fall back to captured_at ordering across all baselines' manifests —
  # still metadata-driven, never directory mtime.
  local b_id b_ts
  b_id="$(manifest_field "$b_manifest" id)"
  b_ts="$(manifest_field "$b_manifest" captured_at)"
  local best_id="" best_ts=""
  for m in state/baselines/*/manifest.yaml; do
    [ -f "$m" ] || continue
    local id ts
    id="$(manifest_field "$m" id)"
    ts="$(manifest_field "$m" captured_at)"
    [ "$id" = "$b_id" ] && continue
    [ -z "$ts" ] && continue
    # Keep the latest ts that is still earlier than b's ts.
    if [[ "$ts" < "$b_ts" ]] && [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
      best_ts="$ts"
      best_id="$id"
    fi
  done
  if [ -z "$best_id" ]; then
    echo "error: no earlier baseline found via previous_baseline or captured_at metadata" >&2
    exit 2
  fi
  echo "state/baselines/$best_id"
}

if [ $# -eq 2 ]; then
  A="$(resolve_dir "$1")"
  B="$(resolve_dir "$2")"
elif [ $# -eq 1 ]; then
  B="$(resolve_dir "$1")"
  A="$(resolve_previous "$B")"
else
  echo "usage: compare-state.sh <baseline-a> [<baseline-b>]" >&2
  exit 2
fi

echo "Comparing:"
echo "  A: $A"
echo "  B: $B"
echo

echo "## manifest.yaml diff"
diff -u "$A/manifest.yaml" "$B/manifest.yaml" || true
echo

echo "## verification diff"
diff -u "$A/verification/results.json" "$B/verification/results.json" 2>/dev/null ||
  echo "(one or both baselines predate the verification/ layout — see scenarios/results.json)"
echo

echo "## arcanium mode-flags diff"
diff -u "$A/components/arcanium/mode-flags.json" "$B/components/arcanium/mode-flags.json" 2>/dev/null ||
  echo "(one or both baselines predate the components/ layout — see arcanium/capabilities.json)"

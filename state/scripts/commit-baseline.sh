#!/usr/bin/env bash
# commit-baseline.sh — Prompt 00. Tag + commit + push one captured baseline.
#
# commit_gh is the ONLY commit mechanism here — there is no plain-git
# fallback. Downgrading controls silently when a prerequisite is missing is
# not acceptable; this script fails clearly and names what's missing instead.
#
# Required flow (Prompt 00 Part 8):
#   1. commit_gh must be on PATH — fail immediately if not.
#   2. commit_gh --doctor
#   3. validate-state.sh as a hard gate
#   4. commit_gh --scan
#   5. refuse if anything outside state/ is dirty (commit_gh stages the
#      whole working tree, not just state/)
#   6. read the baseline's recorded SOURCE commit from manifest.yaml
#   7. if a tag is requested, tag THAT source SHA — not whatever the
#      baseline-artifact commit ends up being
#   8. commit_gh --message "..." --tree false
#   9. if the pre-commit hook reformats staged files and blocks the commit,
#      detect that, re-run validate-state.sh + commit_gh --scan, retry once
#  10. fail clearly if the second attempt still doesn't commit
#  11. push the tag only after the baseline commit actually succeeded
#  12. report baseline id, source SHA, artifact commit SHA, tag + target
#
# Usage:
#   state/scripts/commit-baseline.sh <baseline-id> [tag-name] [commit-message]
set -uo pipefail
cd "$(dirname -- "$0")/../.." # -> repo root

BASELINE_ID="${1:?usage: commit-baseline.sh <baseline-id> [tag-name] [commit-message]}"
BASE="state/baselines/${BASELINE_ID}"
TAG="${2:-arcanium-${BASELINE_ID//_/-}}"
MESSAGE="${3:-Arcanium baseline: ${BASELINE_ID}}"

if [ ! -d "$BASE" ]; then
  echo "error: no such baseline: $BASE" >&2
  exit 2
fi

echo "== commit-baseline =="
echo "  baseline: $BASE"
echo "  tag:      $TAG"
echo "  message:  $MESSAGE"
echo

# --- 1. commit_gh is mandatory, no fallback -------------------------------
if ! command -v commit_gh >/dev/null 2>&1; then
  echo "ABORT: commit_gh not found on PATH." >&2
  echo "commit_gh is the mandatory commit/security mechanism for baselines" >&2
  echo "(Prompt 00) — there is no plain-git fallback. Install/configure it" >&2
  echo "and re-run." >&2
  exit 1
fi

# --- 2. developer/environment preflight -----------------------------------
echo "-> commit_gh --doctor"
if ! commit_gh --doctor; then
  echo "ABORT: commit_gh --doctor reported a problem — fix it before committing a baseline." >&2
  exit 1
fi
echo

# --- 3. secret validation (hard gate) -------------------------------------
echo "-> validating baseline for secrets"
if ! state/scripts/validate-state.sh "$BASELINE_ID"; then
  echo "ABORT: validate-state.sh found something secret-shaped in $BASE." >&2
  echo "Fix it before committing — do not override this check." >&2
  exit 1
fi
echo

# --- 4. repository-wide secret scan ---------------------------------------
echo "-> commit_gh --scan"
if ! commit_gh --scan; then
  echo "ABORT: commit_gh --scan found something — resolve before committing." >&2
  exit 1
fi
echo

# --- 5. refuse to bundle unrelated changes --------------------------------
echo "-> checking nothing outside state/ is dirty (commit_gh stages the whole tree)"
OUTSIDE="$(git status --porcelain | awk '{print $2}' | grep -v '^state/' || true)"
if [ -n "$OUTSIDE" ]; then
  echo "ABORT: changes exist outside state/ — commit or stash them separately first:" >&2
  echo "$OUTSIDE" | sed 's/^/  /' >&2
  exit 1
fi
echo "  clean — only state/ is pending"
echo

# --- 6. read the recorded source commit from the baseline's own manifest --
SOURCE_SHA="$(grep -m1 '^    commit:' "$BASE/manifest.yaml" 2>/dev/null | sed -E 's/^    commit: *//' | tr -d '"')"
if [ -z "$SOURCE_SHA" ] || [ "$SOURCE_SHA" = "unknown" ]; then
  echo "ABORT: could not read baseline.git.commit from $BASE/manifest.yaml." >&2
  exit 1
fi
echo "-> baseline's recorded source commit: $SOURCE_SHA"
if ! git cat-file -e "${SOURCE_SHA}^{commit}" 2>/dev/null; then
  echo "ABORT: $SOURCE_SHA is not a commit reachable in this repository." >&2
  exit 1
fi
echo

# --- 7. tag the SOURCE commit, not the artifact commit --------------------
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "-> tag $TAG already exists (points at $(git rev-parse --short "$TAG")) — not recreating"
else
  echo "-> creating annotated tag $TAG on source commit $(git rev-parse --short "$SOURCE_SHA")"
  git tag -a "$TAG" "$SOURCE_SHA" -m "$MESSAGE" || {
    echo "ABORT: git tag failed" >&2
    exit 1
  }
fi
echo

# --- 8/9/10. commit + push via commit_gh, with one detect-and-retry -------
HEAD_BEFORE="$(git rev-parse HEAD)"

run_commit_gh() {
  echo "-> commit_gh --message \"$MESSAGE\" --tree false"
  echo "   (stages, gitleaks-scans staged files, rebases onto origin/main, commits, pushes)"
  commit_gh --message "$MESSAGE" --tree false
}

run_commit_gh
if [ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ]; then
  # The repo's pre-commit hook runs sanity_check --fix, which can reformat
  # staged files and then deliberately blocks the commit once so the
  # reformatted content gets committed rather than silently dropped.
  echo
  echo "-> commit did not land (pre-commit hook likely reformatted staged files)"
  echo "-> re-validating before the retry, per the required flow"
  state/scripts/validate-state.sh "$BASELINE_ID" || {
    echo "ABORT: baseline no longer passes secret validation after reformat — inspect before retrying." >&2
    exit 1
  }
  commit_gh --scan || {
    echo "ABORT: commit_gh --scan found something after reformat." >&2
    exit 1
  }
  echo "-> retrying commit_gh once"
  run_commit_gh
fi
echo

if [ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ]; then
  echo "ABORT: commit still did not land after one retry — check commit_gh output above." >&2
  echo "The tag (if newly created) has NOT been pushed." >&2
  exit 1
fi
ARTIFACT_SHA="$(git rev-parse HEAD)"

# --- 11. push the tag only now that the commit actually landed -----------
echo "-> pushing tag $TAG"
if git push origin "refs/tags/$TAG"; then
  echo "  tag pushed"
else
  echo "  tag push failed or was already up to date — check above output" >&2
fi

# --- 12. report -------------------------------------------------------------
echo
echo "Done."
echo "  Baseline:        $BASELINE_ID"
echo "  Source SHA:       $(git rev-parse --short "$SOURCE_SHA") ($SOURCE_SHA)"
echo "  Artifact commit:  $(git rev-parse --short "$ARTIFACT_SHA") ($ARTIFACT_SHA)"
echo "  Tag:              $TAG -> $(git rev-parse --short "$TAG")"

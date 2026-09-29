# Documentation Quality Gate

Executed per `prompts/process/00_05_docs_quality_gate.md`, against the real
corpus (`README.md` + 42 files under `docs/`), against the policy
recorded in `docs/writing/config/QUALITY.md`. Depends on
`prompts/process/00_04_docs_style_toolchain.md` having already run — it has, this same
session (`docs/writing/DOCS_TOOLCHAIN_REPORT.md`).

## Summary

```text
Overall result:
PASS
```

Every required gate passed. Two real, small defects were found and
fixed during this run (a markdown-link syntax bug this session's own new
content introduced, and a "There is" opener already noted in the
toolchain pass) — both fixed and re-verified before this report was
finalized, so no BLOCKER remains open.

## Gate results

| Gate | Result | Blocking | Evidence |
|---|---|---|---|
| Structural integrity | PASS | Yes | See below — one H1 each, no unclosed fences, no genuine table-column mismatch, in all 42 files |
| Link and reference integrity | PASS (after fix) | Yes | One real broken link found and fixed — see Finding A |
| Vale compliance | PASS | Yes | 6 errors (policy-exempted, individually reviewed), 315 warnings (passive-voice policy exemption), 0 new findings beyond `QUALITY.md`'s recorded baseline |
| AI-writing-pattern audit | PASS | No (unless P0/P1) | 0 genuine hits — see `WRITING_AUDIT.md` |
| Technical accuracy | PASS | Yes | Spot-checked 6 specific claims from this session's new content — all confirmed against real source |
| STYLE.md compliance | PASS | No | `STYLE.md` was derived from this corpus; no violation introduced |
| Terminology/formatting consistency | PASS | No | Checked during `STYLE.md` derivation; nothing found needing correction |
| Readability | PASS | No | Folded into Gate 3 per `QUALITY.md` policy |

## Finding A — a real markdown-link syntax bug in this session's own new content

- **Gate:** 2 (Link and reference integrity)
- **Severity:** BLOCKER (a broken reference, even a self-inflicted one
  from earlier in this same session, is not exempted from this gate)
- **Evidence:** `docs/external-integration.md` contained a markdown link
  whose target was a stray parenthetical aside — the rendered link text
  read "the existing `rotation_period` requirement" but its target was
  the sentence fragment "reconciliation semantics predate this prompt"
  instead of a real path, because that aside had been written directly
  inside the link-target syntax rather than as plain prose.
- **Root cause:** authoring error, caught by a mechanical
  link-resolution check (every markdown link in the corpus resolved
  against the filesystem) run as part of this gate, not by proofreading.
- **Fix applied:** rewritten as plain prose with a real link to
  `api.md` where the actual cross-reference belongs.
- **Regression risk:** none — prose-only, no technical claim changed.
- **Retest:** re-ran the full link-resolution check; only the one
  expected forward-reference remains
  (`docs/index.md` → `writing/DOCS_QUALITY_GATE.md`, this very file,
  which now exists).

## Structural integrity detail

A naive per-line scan initially reported 6 files with "multiple H1s" and
1 file with a "table column mismatch." Both were false positives from
the check itself, not the corpus, confirmed by re-running fence-aware:

- The 6 files' extra "H1-looking" lines were shell comments (`# ...`)
  *inside* fenced code blocks (`docs/managed-keys.md` alone had 7 such
  lines) — every one of the 6 files genuinely has exactly one real H1
  once code-fence context is respected.
- `docs/orchestration.md`'s "4-column" row was a 3-column row containing
  a standard, correctly-escaped literal pipe (`` \| ``) inside one cell
  (`` `/api/v1/keys/:name/rotate` \| `/rewrap` ``) — valid Markdown, not
  a real defect; the naive column-counter didn't account for escaping.

No genuinely unclosed code fence exists anywhere in the corpus (checked
with a proper open/close toggle, not a raw fence-marker count).

## Vale compliance detail

```text
Content corpus (the 42 files WRITING_AUDIT.md/BASELINE.md scored):
  6 errors, 315 warnings — matches docs/writing/config/QUALITY.md's
  recorded baseline exactly, no new error introduced.

Full scan including this pass's own audit-trail reports
(docs/writing/*.md, 7 more files):
  30 errors, 364 warnings, 49 files total.
```

The extra 24 errors are entirely self-reference noise, not new content
defects: `WRITING_AUDIT.md`, `DOCS_TOOLCHAIN_REPORT.md`, and this file
itself *quote* the exact "There is"/"simply" example phrases they are
reporting on, as illustrative evidence — Vale cannot distinguish a
phrase being cited as an example from the same phrase freshly written as
live prose. Checked directly: every one of the 24 extra hits is inside a
finding's own quoted evidence, not a new writing defect in the report's
own prose. This is the same category of report-self-reference the
frontend-toolchain pass's own `docs/frontend/UI_AUDIT.md` (which quotes
Impeccable/Taste finding text) would show if scanned the same way — an
expected, bounded, one-directional artifact of writing a report *about*
a linter's findings, not a corpus-quality regression.

## AI-writing-pattern audit detail

Re-ran the same checks as `WRITING_AUDIT.md`: zero hits for banned
vocabulary, binary contrasts, throat-clearing openers, summary-recap
endings, or genuine (paragraph-level, non-table) em-dash clustering.
Unchanged from the toolchain pass — expected, since only two small
prose edits happened between the two passes.

## Technical accuracy spot-check detail

Verified directly against source, not assumed:

| Claim | File | Verification | Result |
|---|---|---|---|
| Bearer token checked before cookie in `requireSession` | `docs/api.md`, `docs/external-integration.md` | Read `arcanium/api/src/auth/index.js:309-338` | CONFIRMED |
| Service-account token is 256-bit (`randomBytes(32)`) | `docs/external-integration.md` | Read `arcanium/api/src/routes/service-accounts.js:215` | CONFIRMED |
| `KML-DESTR-01`/`KML-OFFBOARD-01` exact requirement text, mandatory flag, dimension | `docs/maturity-model.md` | Read `arcanium/api/src/migrations/022_lifecycle_completion_controls.sql` | CONFIRMED |
| `make scenario-scope-isolation`, `scenario-terraform-provider`, `scenario-fitness` targets exist | `docs/multitenancy.md`, `docs/external-integration.md`, `docs/scenarios.md` | `grep` against `Makefile` | CONFIRMED |
| 15 real file-path shorthand mentions (`auth/authorize.js`, migration files, etc.) resolve at their implied full path | Multiple | Resolved each against the real repository tree | CONFIRMED, all 15 |
| Every internal markdown link resolves | All 42 files | Full corpus link-resolution scan | CONFIRMED after Finding A's fix |

## Required evidence (index)

- Files inventoried: 42.
- Vale findings: this file, "Vale compliance detail," and
  `WRITING_AUDIT.md`.
- no-ai-slop findings: `WRITING_AUDIT.md`.
- Broken-link/reference list: Finding A (fixed).
- Technical-accuracy spot-check: table above.
- STYLE.md/terminology findings: none — see `STYLE.md` itself for what
  was checked during its own derivation.

## Release decision

```text
RELEASE
```

All required gates pass; the one BLOCKER found during this run (Finding
A) was fixed and re-verified before this report was finalized.

---

## Final output

```text
DOCUMENTATION QUALITY GATE
==========================

Structural integrity:  PASS
Link integrity:         PASS (one real bug found and fixed — Finding A)
Vale compliance:        PASS
AI-writing patterns:    PASS
Technical accuracy:     PASS
STYLE.md compliance:    PASS
Consistency:            PASS
Readability:            PASS

Overall:
PASS

Blocking findings:
0 (Finding A was blocking; fixed and re-verified before this report was finalized)

Non-blocking findings:
0 new (6 pre-existing, policy-exempted Vale errors and 307 policy-exempted
passive-voice warnings remain, per docs/writing/config/QUALITY.md)

Release recommendation:
RELEASE
```

Report: `docs/writing/DOCS_QUALITY_GATE.md` (this file).
Policy: `docs/writing/config/QUALITY.md`.

# QUALITY.md — Arcanium documentation quality-gate policy

Durable, cross-run policy for `prompts/process/00_05_docs_quality_gate.md`. Read this file
before Section 3 of every future run; update it only when the corpus's
actual requirements change, never to make a failing run pass. Written
against `docs/writing/config/STYLE.md` as captured on 2026-09-13, same
pass that created this file.

## Required gates

```text
GATE 1  Structural integrity              — required
GATE 2  Link and reference integrity      — required
GATE 3  Vale compliance                   — required (errors block; the
                                             307 write-good.Passive
                                             warnings are a recorded
                                             exception, see below)
GATE 4  AI-writing-pattern audit          — required, low-blocking (only
                                             a genuine hit in user-facing
                                             prose blocks; see STYLE.md)
GATE 5  Technical accuracy spot-check     — required
GATE 6  STYLE.md compliance               — required
GATE 7  Terminology/formatting consistency — required
GATE 8  Readability                       — not separately gated; folded
                                             into Gate 3 (Vale's own
                                             TooWordy/readability checks)
```

## Optional gates

```text
GATE 9   Freshness           — not adopted; this corpus is small enough
                                (42 files) that a full re-scan on every
                                run is cheap, so a staleness heuristic
                                adds complexity without real benefit yet
GATE 10  Cross-reference completeness — not adopted; docs/index.md is
                                the single source of truth for "does
                                every major feature have a doc," checked
                                manually against prompts/'s own numbered
                                history each pass, not automated
```

## Vale policy

- Config: `.vale.ini` (repo root). Styles: `Vale` (bundled),
  `write-good`, `alex`, plus the project vocabulary
  (`docs/writing/config/styles/config/vocabularies/Arcanium/accept.txt`).
- `write-good.E-Prime`, `alex.ProfanityUnlikely`, `alex.Ablist` are
  disabled — confirmed false-positive-prone for this corpus's register,
  reasons recorded inline in `.vale.ini`. Do not re-enable without
  re-checking against real corpus text first.
- **Recorded exception:** `write-good.Passive` findings do not block
  Gate 3. Passive voice is frequently the correct, precise construction
  for this corpus's security/systems register — see
  `docs/writing/WRITING_AUDIT.md` Finding 6. A future run finding NEW
  passive-voice instances should not treat the raw count as a
  regression; only a genuinely unclear or newly-introduced passive
  sentence is a real finding.
- Baseline as of this pass: 6 errors (all `alex.Condescending`,
  individually reviewed and kept — see `WRITING_AUDIT.md` Finding 4),
  315 warnings, 42 files. A run that introduces a **new** error beyond
  this baseline blocks Gate 3; the 6 known ones do not re-block a future
  run unless their surrounding text actually changes.
- **Scope note:** this 42-file baseline is the content corpus
  (`README.md` + `docs/`, excluding `docs/writing/` itself). Reports
  under `docs/writing/` (this file's own siblings) routinely *quote*
  the exact phrases they report on as evidence, which re-trips the same
  Vale rules being discussed — a self-reference artifact, not a content
  defect. Don't compare `docs/writing/*.md`'s own Vale count against
  this baseline; see `DOCS_QUALITY_GATE.md`'s "Vale compliance detail"
  for how the first run handled this.

## AI-writing-pattern policy (Gate 4)

Use `no-ai-slop`'s own named patterns (banned vocabulary, binary
contrasts, colon reveals, throat-clearing openers, summary-recap
endings, em-dash clustering — checked at the **paragraph** level in
actual prose, not a raw corpus-wide count, since table cells
legitimately use the same `label — explanation` shape). Only a genuine
hit in user-facing prose blocks; a quoted phrase from another document
(e.g. a prompt file's own wording) is never itself a finding.

## Technical-accuracy policy (Gate 5)

Prioritize: `README.md`, `docs/api.md`, `docs/setup.md`,
`docs/configuration.md`, and any file changed since the last run (check
`git diff` against the previous quality-gate commit). Verify referenced
Make targets, migration files, and route handlers actually exist at the
named path — do not trust a path because another doc already cites it.

## Terminology (Gate 7)

See `STYLE.md`'s own Terminology section — `observation_status` vs.
`disposition`, "reconcile" vs. "reconciliation sweep", "desired state"
vs. `desired_state`. Add to this list only when a real drift is found,
not preemptively.

## Revision history

- 2026-09-13 — created (first run), alongside
  `docs/writing/config/STYLE.md` and the initial Vale configuration.

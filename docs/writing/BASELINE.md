# Writing Baseline — Arcanium documentation

Captured before any tool-guided content edit, per
`prompts/process/00_04_docs_style_toolchain.md`.

## Inventory

- `README.md` (root)
- 41 files under `docs/` at the time of this pass, including two new
  topic files this same pass added content freshness for
  (`docs/multitenancy.md`, `docs/external-integration.md`) and the
  frontend-toolchain outputs from the prior prompt pair
  (`docs/frontend/`). `prompts/` and `input/` explicitly excluded
  (gitignored, not shipped documentation).
- Existing style tooling: none. No `.vale.ini`, no markdown-linter
  config, no spell-check config existed before this pass.

## Existing voice, observed before judging it

Dense, technical, evidence-first. The corpus's own dominant habit —
present in files from every era of this project, not just recent
ones — is narrating **how** a claim was verified, not just stating the
conclusion: "verified by inspecting actual network responses during
testing, not assumed from code review alone" (`security.md`), "confirmed
live during evaluation, not assumed" (this same pass's own `.vale.ini`
comments, matching the established habit), "Traced to its actual root
cause rather than papered over" (`persistence.md`). Full detail captured
into `docs/writing/config/STYLE.md`.

## Tool-free first read

```text
BASELINE (writing)
------------------
Files inventoried:        42 (README.md + 41 under docs/)
Existing style tooling:   NOT PRESENT
Existing voice:           Dense, technical, evidence-narrating; a real,
                          consistent house style already present before
                          any tooling — not a patchwork.
```

## Tool-measured baseline (after Vale/no-ai-slop installed and configured)

See `docs/writing/WRITING_AUDIT.md` for the full investigation, including
several real Vale-configuration false positives found and fixed before
this number became meaningful:

```text
Vale:       6 errors, 315 warnings, 42 files (final, real baseline)
no-ai-slop: 0 instances of banned vocabulary or named structural
            anti-patterns found across the full corpus
```

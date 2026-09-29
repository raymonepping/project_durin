# Writing Improvement Plan — Arcanium documentation

Derived from `WRITING_AUDIT.md`. The audit found this corpus already had
a coherent, deliberate, evidence-first house voice before any tooling
existed — the actual work in this pass was mostly configuring Vale
correctly (several real false positives found and fixed) rather than
rewriting prose. Waves below reflect that honestly.

## Wave 1 — Clear, user-facing patterns (this pass)

| Item | File | Problem | Change | Regression risk | Validation |
|---|---|---|---|---|---|
| "There is no" opener | `docs/api.md` | Weak subject | "No `POST /api/v1/auth/login` route exists ..." | None — identical fact stated | Vale re-run, `write-good.ThereIs` no longer fires there |
| "There is no" opener | `docs/scale.md` | Weak subject | Folded into the preceding clause with an em dash | None — identical fact stated | Vale re-run |

## Wave 2 — Terminology and formatting consistency

None found needing a fix. `STYLE.md`'s terminology section documents
what was checked (`observation_status`/`disposition`, "reconcile" vs.
"reconciliation sweep", "desired state" vs. `desired_state`) and
confirmed already consistent, not something this pass had to correct.

## Wave 3 — Everything else Vale/no-ai-slop flagged as real but lower
priority

- The 6 `alex.Condescending` ("simply") instances — reviewed
  individually in `WRITING_AUDIT.md` Finding 4, none changed; a real,
  documented decision, not deferred work.
- The 307 `write-good.Passive` warnings — reviewed as a class
  (`WRITING_AUDIT.md` Finding 6), deliberately not blanket-fixed; the
  policy (don't force active voice where passive is more precise) is
  recorded in `docs/writing/config/QUALITY.md` so it isn't re-litigated
  file-by-file on a future pass.

## Wave 4 — Optional refinement

None identified. The corpus's existing voice (dense, evidence-first,
willing to be exact rather than snappy) was found coherent and worth
keeping exactly as-is; no refinement was judged to have a benefit
proportionate to touching working prose.

## Tooling work this pass actually consisted of (not prose editing)

- Installed Vale (Homebrew) and the `no-ai-slop` skill, real and
  verified before use (see `DOCS_TOOLCHAIN_REPORT.md`).
- Built a project vocabulary
  (`docs/writing/config/styles/config/vocabularies/Arcanium/accept.txt`)
  from scratch — ~90 real project-specific terms, found and fixed three
  genuine bugs in the vocabulary file itself along the way (a regex
  typo hiding `AppRole`, a misspelled `scopable` entry, two dropped
  words) before trusting any Vale output.
- Disabled three Vale checks with recorded, evidence-based reasons
  (`write-good.E-Prime`, `alex.ProfanityUnlikely`, `alex.Ablist`) —
  each confirmed false-positive-prone for this corpus's register by
  actually reading every instance, not assumed.
- Found and reverted a real regression from a `TokenIgnores` config
  attempt that broke Vale's own code-span exemption (9 → 46 errors) —
  caught by re-running after the change, replaced with narrower,
  specific vocabulary entries instead.

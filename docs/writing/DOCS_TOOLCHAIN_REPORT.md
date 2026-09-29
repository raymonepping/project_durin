# Documentation Toolchain Report — Arcanium

Executed per `prompts/process/00_04_docs_style_toolchain.md`, against the real,
existing documentation corpus (`README.md` + everything under `docs/`).

## Tooling installed

| Tool | Version | Install method | Config location |
|---|---|---|---|
| Vale | 3.21.0 | Homebrew (`brew install vale`) | `.vale.ini` (repo root) |
| Styles: `Vale` (bundled), `write-good`, `alex` | synced via `vale sync` | `docs/writing/config/styles/` |
| Project vocabulary | n/a, hand-authored | `docs/writing/config/styles/config/vocabularies/Arcanium/accept.txt` |
| `no-ai-slop` skill | `petergyang/no-ai-slop@no-ai-slop` | `npx skills add` | `.agents/skills/no-ai-slop/` (symlinked for Claude Code) |

**Styles chosen and why** (Vale's Style Hub, https://vale.sh/hub, was
reviewed for reference — not installed wholesale, per the prompt's own
instruction): `write-good` and `alex` were chosen over Google's or
Microsoft's full corporate style guides because this corpus's own
register (dense, technical, security/infrastructure-focused) doesn't
match either — a minimal, project-derived `STYLE.md` plus two small,
generic prose-quality packages was judged the better fit than importing
someone else's house style wholesale.

**Rules disabled, with reasons** (all in `.vale.ini`, not hidden):
`write-good.E-Prime`, `alex.ProfanityUnlikely`, `alex.Ablist` — each
confirmed false-positive-prone for this corpus by reading every instance
before disabling, not assumed. See `docs/writing/WRITING_AUDIT.md`
Finding 1 for the full evidence.

**Hooks:** neither Vale nor `no-ai-slop` registered an Edit/Write hook —
no trust-sensitive hook to review this pass, unlike the frontend
toolchain pass's Impeccable install.

## Agent support

| Agent | Vale | `no-ai-slop` |
|---|---|---|
| **Claude** | CLI only — Vale has no agent-skill packaging of its own; invoked directly as a shell command, which Claude does natively | Native — symlinked project skill at `.agents/skills/no-ai-slop/`, readable directly |
| **Codex** | CLI only — same reasoning, a shell command any agent can run | Partial — reads the same `.agents/skills/no-ai-slop/` directory directly per the `skills` installer's own "universal" claim; not live-verified in this session (no Codex session available) |
| **IBM Bob** | CLI only | Partial, with real evidence — the `skills` installer's own target list explicitly names "IBM Bob" and reported `skipped: IBM Bob, Continue (project directory not found)`, the identical finding the frontend-toolchain pass made for `design-taste-frontend`: Bob has a real, tool-recognized skill-directory convention, but this repository has no project-scoped Bob directory yet for it to attach to |

No claim above is asserted without the evidence next to it.

## Existing corpus discovered

42 files, no prior style tooling, a coherent evidence-first house voice
already present across every era of the project — not a patchwork. Full
detail in `BASELINE.md`.

## Baseline

```text
BASELINE (writing)
------------------
Existing style tooling:   NOT PRESENT
Vale (after real config): 6 errors, 315 warnings, 42 files
no-ai-slop:                0 banned-vocabulary/structural-pattern hits
```

## Style contract

`docs/writing/config/STYLE.md` — derived from the corpus's own real
habits (evidence-narrating claims, precise-over-polished, earned
caveats never removed), not invented or imported from a generic guide.

## Findings

Six findings, full detail in `WRITING_AUDIT.md`: a set of real Vale
configuration false positives (fixed), a checked-and-cleared em-dash
density concern, two safe sentence-opener fixes, six reviewed-but-
unchanged "simply" instances, a confirmed-clean scan for classic
AI-writing vocabulary/structural patterns, and a deliberate non-fix of
307 passive-voice warnings as a class.

## Changes applied

- `docs/api.md`, `docs/scale.md` — two "There is (no)" sentence openers
  rewritten to lead with the subject; zero technical-content change.
- `.vale.ini`, the project vocabulary file, and `docs/writing/config/STYLE.md`
  itself — tooling and durable configuration, not corpus prose.

## Changes deliberately rejected

- Every `write-good.Passive` finding (307) — passive voice is frequently
  the precise, correct construction here; see `WRITING_AUDIT.md` Finding
  6 for the reasoning and the durable policy recorded for future runs.
- All six `alex.Condescending` ("simply") findings — reviewed
  individually, none read as condescending or as filler once actually
  read in context; see `WRITING_AUDIT.md` Finding 4.
- Em-dash "overuse" — real raw count (286), but not real clustering once
  actually checked at the paragraph level; see `WRITING_AUDIT.md`
  Finding 2. An earlier draft of `STYLE.md` almost asserted this as a
  problem before the closer check was run — corrected before being
  published, not after.

## Validation

```text
BEFORE (raw, unconfigured Vale run)   AFTER (real, configured baseline)
-------------------------------------------------------------------
96 errors, 44 files (incl. Vale's       6 errors, 315 warnings, 42 files
own vendored style packages,            (vendored packages excluded from
scanned by mistake on the first run)    the scan; a real, deliberate fix)
```

Every technical fact, path, command, and warning in the corpus was left
untouched — the two content edits made were sentence-structure only,
confirmed by diff, not by assertion.

## Outstanding work

**Required:** none — the two safe edits are complete, and every
remaining Vale/no-ai-slop finding was reviewed and deliberately left
alone with a recorded reason, not silently skipped.

**Recommended:** none beyond what `prompts/process/00_05_docs_quality_gate.md` (the
companion prompt) will independently re-verify.

**Optional:** a future pass could selectively rewrite the highest-value
passive-voice sentences (e.g. in `docs/security.md`'s own trust-model
prose) to active voice where an actor genuinely exists and naming it adds
clarity — not required, and `WRITING_AUDIT.md` explicitly recommends
against doing this as a blanket pass.

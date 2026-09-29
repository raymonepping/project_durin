# STYLE.md — Arcanium documentation

The project's written-voice contract, derived from the existing corpus
(`README.md` + 40+ files under `docs/`) — not invented. Where this
document prescribes something, it is already the corpus's own dominant
practice unless marked otherwise.

## Voice

Dense, technical, and unafraid of a long sentence when the alternative
is losing precision. This documentation talks like an engineer
explaining a system to another engineer who will actually operate it —
not like marketing copy, and not like a tutorial written for someone who
has never touched the stack. At its best (`docs/api.md`,
`docs/security.md`, `docs/maturity-model.md`), it:

- states the real behavior first, then the caveat that behavior implies
- narrates **how** something was found, not just what the fix was — "A
  real design bug found and fixed" or "confirmed live during evaluation,
  not assumed" appear throughout this corpus because the whole project
  operates on proof, not assertion
- quotes real code, real config, real error messages verbatim rather
  than paraphrasing them
- names the exact file, function, or migration a claim traces back to

## Audience

Platform/security engineers operating this stack, and evaluators
reviewing it as a reference implementation. Not a general audience, not
a sales audience. See `docs/frontend/config/PRODUCT.md` for the fuller
product/audience framing this documentation set assumes.

## Principles

- **Precision over polish.** A correct, slightly awkward sentence beats a
  smooth, imprecise one. Never soften a real constraint into a vaguer
  one for rhythm.
- **An earned caveat is not hedging.** Phrases like "not assumed from
  code review alone," "verified by inspecting actual network responses,"
  or "confirmed live, not assumed" are load-bearing — they mark a claim
  this project actually tested, as distinct from a claim it merely
  believes. Do not remove them as if they were filler.
- **Show the evidence, not just the conclusion.** Where the corpus
  already links to a script, a log, or a source file for proof, keep
  that link; do not summarize away the pointer to the real evidence.
- **Technical accuracy is never traded for a smoother sentence.** If a
  style suggestion would require softening or removing a fact, path, or
  command, the suggestion loses.

## Terminology

Kept consistent across the corpus (found already correct; preserve):

- **"Arcanium"** (capitalized) for the product/prose noun;
  lowercase-hyphenated forms (`arcanium-api`, `vault-hsm`,
  `terraform-provider-arcanium`) are literal resource/container/policy
  names, not a casing lapse — see `docs/writing/config/styles/config/
  vocabularies/Arcanium/accept.txt` for the full list Vale was taught.
- **`observation_status`** vs. **`disposition`** — always described as
  two independent fields, never merged into one combined value
  (`docs/api.md`, `docs/maturity-model.md`).
- **"Reconcile"** (the governed correction action) vs. **"reconciliation
  sweep"** (the periodic observe pass) — kept distinct, not
  interchangeable.
- **"desired state"** (two words, the concept) vs. **`desired_state`**
  (the table/column, code-formatted) — the prose phrase and the
  identifier are different registers, both correct in their own context.

## Formatting conventions

- One H1 per file, the file's own title.
- Prose sections use `##`/`###`; a reference table almost always follows
  its introducing paragraph rather than standing alone.
- Code, file paths, environment variable names, route paths, and literal
  identifiers are always backtick-formatted inline — a bare, unformatted
  mention of a real identifier is treated as a defect (see Gate 6 in
  `prompts/process/00_05_docs_quality_gate.md`).
- A prompt/phase is referenced by name where it explains **why**
  something exists — `(Prompt 27)`, `(Phase 20)` — not decoratively on
  every heading.
- Mermaid diagrams for system/data-flow views (`docs/architecture.md`);
  plain tables for route/config/control references.
- A short parenthetical dated note for a moved/renamed file
  (`docs/repository-layout.md`'s own "moved into `docs/` on
  2026-09-10") — kept as real provenance, not clutter.

## Anti-patterns (banned)

From `no-ai-slop`'s own ruleset, cross-referenced against what this
corpus's real writing habits already avoid or must keep avoiding:

- Banned vocabulary: *leverage, delve, foster, utilize, facilitate,
  streamline, robust, cutting-edge, paradigm shift, game changer,
  tapestry, realm, meticulous, transformative, elevate, supercharge,
  harness* — a live scan of this corpus found **zero** instances before
  this pass; keep it that way.
- Binary-contrast filler ("It's not X, it's Y") and colon-reveal
  constructions ("The detail that makes it work:") — state the point
  directly instead, matching this corpus's existing habit.
- Throat-clearing openers ("Here's the thing," "Let me be clear") and
  summary-recap endings ("In conclusion," "Overall,") — not present in
  this corpus; do not introduce them.
- **Em dash overuse** — checked directly, not assumed. A raw scan found
  286 em dashes across the existing corpus; a closer, paragraph-level
  check (not just a raw count) found no genuine clustering in actual
  prose — the highest-density spots are table cells (`label —
  explanation` per row), a legitimate, consistent, and long-standing
  convention already present in files that predate this pass, not an
  AI-writing tell. Not banned. A real cluster of more than two or three
  em dashes in one **prose paragraph** (not a table) would still be a
  genuine finding if one ever appears — see
  `docs/writing/WRITING_AUDIT.md` for the actual check performed.
- Fabricated superlatives, marketing tone, or unearned confidence about
  something not actually tested.

## What this documentation is NOT

- Not a tutorial for a general audience — it assumes the reader can read
  code and run a shell command.
- Not marketing material — no hype, no "game-changing," no invented
  customer outcomes.
- Not exhaustive API prose duplicating `openapi/arcanium.yaml` — `
  docs/api.md` is explicit that the OpenAPI file is the authoritative
  contract and this page is narrative alongside it, correcting itself
  toward the spec on any disagreement.

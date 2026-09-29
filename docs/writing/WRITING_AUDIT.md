# Writing Audit — Arcanium documentation

Three perspectives on the existing corpus (`README.md` + everything
under `docs/`, 42 files): **Vale** (configured styles, see
`docs/writing/config/STYLE.md` and `.vale.ini`), **no-ai-slop** (its
named patterns applied mechanically via grep plus manual review — it has
no executable, it is agent guidance), and a **manual read** for whether
any tool suggestion would remove an earned caveat.

Severity: `P0` would-remove-a-technical-fact, `P1` genuine AI-writing
tell in user-facing prose, `P2` inconsistency, `P3` optional refinement,
`P4` subjective preference.

---

## Finding 1 — Vale configuration false positives (tooling, not content)

- **Source:** Vale, first full-corpus run.
- **Severity:** N/A (setup defect, fixed before any content judgment).
- **Evidence:** 96 errors on the first run; nearly all were the linter's
  own setup gaps, not real findings:
  - Every project-specific proper noun/compound identifier (`Arcanium`,
    `Nuxt`, `Vue`, `Keycloak`, `Podman`, `Makefile`, `namespaces`,
    `desired_state`, ~80 more) flagged as an unknown spelling — no
    project vocabulary existed yet.
  - `write-good.E-Prime` (bans every form of "to be") fired on nearly
    every sentence — a whole linguistic discipline, not a signal, and
    off-register for precise technical writing.
  - `alex.ProfanityUnlikely` flagged ordinary words ("remains") as
    "profane in some cases" — 100% false positive across every instance
    checked.
  - `alex.Ablist` flagged "disabled"/"special" as person-directed
    language 9/9 times when every instance actually described a
    feature/config toggle (`ARCANIUM_AUTH_ENABLED`, a disabled auth
    path) — never a person.
  - A real bug in my own first vocabulary draft: `[Aa]pproles?` (missing
    the internal capital R) caused Vale to suggest replacing the real
    identifier `AppRole` with a pattern that couldn't match it; a typo
    (`[Ss]capable`) left `scopable` unrecognized; `Makefile` and
    `auditability` were in the original word list but dropped from the
    file during editing.
  - A `TokenIgnores` regex, added to stop compound-identifier false
    positives (`vault-hsm`, `arcanium-admin`), instead **broke Vale's
    own code-span exemption** and made the false-positive count worse
    (9 → 46) — caught by re-running after the change, not assumed safe,
    and reverted in favor of specific literal vocabulary entries.
- **Decision:** Fixed. `E-Prime` and `alex.ProfanityUnlikely`/
  `alex.Ablist` disabled deliberately, with reasons recorded inline in
  `.vale.ini` — not silently suppressed. `alex.Condescending` (a
  genuinely relevant check — see Finding 4) stays on. Final, real
  baseline: **6 errors, 315 warnings** across 42 files.

## Finding 2 — Em-dash density: real count, no real clustering

- **Source:** a live scan, checked at two levels of precision.
- **Severity:** N/A (checked and found not to be a genuine issue —
  recorded because an earlier draft of `STYLE.md` almost asserted this
  as a problem before the closer check was actually run).
- **Evidence:** a raw corpus-wide count found 286 em dashes. A
  paragraph-level check (splitting each file on blank lines, counting
  per paragraph) found the highest-density "paragraphs" were markdown
  **tables** — each row's own `label — explanation` cell, a legitimate,
  readable convention — not clustered prose. Spot-checked the two
  highest counts (`docs/frontend/UI_TOOLCHAIN_REPORT.md` para with 10,
  `docs/local-dependency-audit.md` para with 9) directly: both were
  tables. Density-per-line was also checked across old and new files
  alike (`docs/api.md`, `docs/security.md` — both predate this pass —
  vs. `docs/frontend/UI_TOOLCHAIN_REPORT.md`, written during it): all
  three land in the same 1.2–1.9-per-10-lines range, confirming this is
  a long-standing, consistent trait, not something newly introduced.
- **Decision:** No change. `STYLE.md` records the real, checked
  conclusion rather than the plausible-sounding but unverified one.

## Finding 3 — "There is"/"There is no" sentence openers

- **Source:** `write-good.ThereIs` (Vale), 2 instances.
- **Severity:** P3.
- **Evidence:** `docs/api.md` ("There is no `POST /api/v1/auth/login`")
  and `docs/scale.md` ("There is no replication, no standby...").
- **Decision:** Fixed — both rewritten to lead with the subject
  (`No ... route exists`; folded into the preceding clause with an em
  dash in the second case). Zero technical-content change; both still
  state the exact same negative fact.

## Finding 4 — "simply" (alex.Condescending), 6 instances

- **Source:** `alex.Condescending`.
- **Severity:** P4 in every instance found — reviewed individually per
  no-ai-slop's own guidance ("cut when it adds nothing, keep when it
  carries emphasis, uncertainty, contrast, or the writer's natural
  rhythm"), not blanket-applied.
- **Evidence and decision, each instance:**
  1. `docs/frontend/UI_AUDIT.md:151` — inside a **direct quotation** of
     `prompts/process/00_02_frontend_design_toolchain.md`'s own text ("simply because
     another one is preferred"). Editing it would misquote the source.
     **No change.**
  2. `docs/identity-configuration.md:41` — "Group names simply flow
     through as literal `cn` values" — emphasizes the absence of
     transformation (a real, meaningful contrast: no mapping/rewriting
     happens). **No change.**
  3. `docs/maturity-model.md:68` — "Nothing is inferred from a database
     row simply existing" — the adverb carries the actual point (row
     existing *alone*, with nothing more, isn't evidence). **No
     change.**
  4. `docs/operations.md:22` — "must not be described as failed simply
     because they return HTTP 429" — genuine logical emphasis (this one
     signal alone is insufficient). **No change.**
  5. `docs/persistence.md:50` — "starts with the variable simply unset"
     — the closest to genuinely cuttable filler of the six, but still
     inside a paragraph whose whole point is the precise mechanics of
     *why* the variable ends up unset; judged not worth the edit for the
     marginal gain. **No change, documented as the closest call.**
  6. `docs/security.md:154` — "any modification simply fails the
     `sessions` lookup" — emphasizes directness (no special handling,
     no partial success). **No change.**
- **Decision, in aggregate:** `alex.Condescending`'s own label doesn't
  match any of these six — none reads as condescending to the reader.
  Left as a documented, reviewed non-finding rather than either
  silently dismissed or mechanically "fixed" against no-ai-slop's own
  stated exception for genuine emphasis.

## Finding 5 — Classic AI-writing vocabulary and structural patterns

- **Source:** no-ai-slop's own named patterns, applied via targeted
  search across the full corpus.
- **Severity:** N/A (checked, none found).
- **Evidence:** zero hits for the banned-vocabulary list (*leverage,
  delve, foster, utilize, facilitate, streamline, robust, cutting-edge,
  paradigm shift, game changer, tapestry, realm, meticulous,
  transformative, elevate, supercharge, harness*); zero hits for binary
  contrasts ("It's not X, it's Y"), throat-clearing openers ("Here's the
  thing," "Let me be clear"), summary-recap endings ("In conclusion,"
  "Overall,"), or colon-reveal constructions (checked with a
  deliberately broad pattern that would also catch legitimate
  label-colon-explanation prose — every match reviewed was a normal,
  correct use, not a dramatic reveal).
- **Decision:** No change needed. Recorded in `STYLE.md`'s anti-patterns
  section as a baseline to preserve, not because anything needed fixing.

## Finding 6 — `write-good.Passive` (307 instances) and remaining
`write-good.TooWordy` — reviewed as a class, not fixed

- **Source:** Vale, the bulk of the 315 remaining warnings.
- **Severity:** P4.
- **Decision:** No blanket change. Passive voice is frequently the
  correct, precise construction in security/systems writing — "is
  authorized," "is protected," "was corrected" describe what happens
  *to* a resource or session, which is usually the actual point of the
  sentence (see `STYLE.md`'s own "precision over polish" principle).
  Rewriting these to active voice wholesale would, in several cases,
  require inventing an actor the sentence doesn't actually have in mind
  or didn't intend to emphasize. Left as reviewable warnings for a
  future pass to apply selectively, not a required fix in this one —
  `docs/writing/config/QUALITY.md` records this as the durable policy
  so a future quality-gate run doesn't re-litigate it from scratch.

---

## Summary table

| # | Finding | Severity | Decision |
|---|---|---|---|
| 1 | Vale configuration false positives | tooling | Fixed (vocab, disabled 3 rules with reasons, reverted a broken TokenIgnores) |
| 2 | Em-dash density | N/A — checked, not real | No change; STYLE.md corrected to the checked conclusion |
| 3 | "There is"/"There is no" openers | P3 | Fixed, 2 instances |
| 4 | "simply" (alex.Condescending) | P4 ×6 | Reviewed individually; no change |
| 5 | Classic AI-vocabulary/structural patterns | N/A — checked, none found | No change |
| 6 | Passive voice / wordiness (bulk of warnings) | P4 | No blanket change; policy recorded in QUALITY.md |

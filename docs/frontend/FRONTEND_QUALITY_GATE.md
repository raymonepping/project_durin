# Frontend Quality Gate

Executed per `prompts/process/00_03_frontend_quality_gate.md`, against the real,
running `arcanium-ui` container, per the policy recorded in
`docs/frontend/config/QUALITY.md`. Depends on
`prompts/process/00_02_frontend_design_toolchain.md` having already run (it has — see
`docs/frontend/UI_TOOLCHAIN_REPORT.md`).

## Summary

```text
Overall result:
PASS WITH WARNINGS
```

One real, blocking (P0) functional defect was found during this run
(Gate 4 — logout), root-caused, fixed, and re-verified live before this
report was finalized. A second real, systemic finding (Gate 7 —
app-wide `--arc-text-dim` misuse, Finding B below) was also found during
this run; it is pre-existing (not a regression from any change in this
pass) and is reported honestly rather than fixed here, given its true
scope (28 rules across 20+ files) — that is dedicated-pass work, not a
"smallest justified fix." The one pre-existing, out-of-scope typecheck
gap (11 errors) is likewise kept as a documented, non-blocking warning
per `QUALITY.md`'s own policy. **Correction:** an earlier draft of this
report claimed Gate 7's contrast audit found "no remaining small-body-
text misuse beyond the login page" — that claim was not actually
verified before being written, and was wrong. It has been corrected
below, per Finding B, rather than left standing.

## Gate results

| Gate | Result | Blocking | Evidence |
|---|---|---|---|
| Engineering integrity | PASS* | No | 11 pre-existing typecheck errors, identical set before/after — see `BASELINE.md`; `QUALITY.md` policy: only a *new* error blocks |
| Production build | PASS | Yes | `npm run build` — 2.72 MB / 691 kB gzip, unchanged from baseline |
| Browser runtime | PASS | Yes | All 15 routes (14 primary + `/login`) load, real shell + live data, no fatal runtime failure |
| Functional workflows | PASS (after fix) | Yes | Login, navigation, command palette, filter, **logout** — see Finding A below |
| Responsive behaviour | PASS | Yes | Desktop/Laptop/Mobile re-verified across all routes; the two mobile defects from the design-toolchain pass remain fixed |
| DESIGN.md compliance | PASS WITH WARNINGS | No | See "DESIGN.md compliance audit" below — Finding B (pre-existing, not a new regression) |
| Accessibility | PASS WITH WARNINGS | No | Contrast fix from the toolchain pass confirmed still in place; focus-visible/skip-link/reduced-motion confirmed present. Finding B (below) is a real, pre-existing, systemic gap — HIGH severity, not BLOCKER (see reasoning in Finding B), so it does not block this release but must not be reported as absent |
| Visual regression | PASS | Yes | See "Visual regression" below |
| Console health | PASS | Yes | 0 errors/warnings across 42 authenticated route×viewport combinations; the 2 known, documented conditions (login 401, first-unauth-load hydration mismatch) are unchanged from baseline |
| Dependency sanity | PASS | Yes | See "Dependency sanity" below |

\* Reported as the gate's actual state under this project's own recorded
policy (`QUALITY.md`): a pre-existing, unrelated, out-of-scope gap is not
a release blocker, but it is not silently hidden either — it remains
visible in every report this pass produces.

## Finding A — Logout was completely broken (found during this run)

- **Gate:** 4 (Functional workflows)
- **Severity:** BLOCKER (before fix) — a core, always-visible workflow
  (every authenticated session's own "Sign out" action) failed 100% of
  the time.
- **Evidence:** A real, live Playwright click through the actual persona
  menu → "Sign out" → Keycloak's `openid-connect/logout` endpoint
  returned `HTTP 400 Bad Request`, landing back on Keycloak's own login
  page instead of completing logout.
- **Root cause:** `compose/identity/keycloak/setup_keycloak.sh`'s
  `ensure_client()` never registered a `post.logout.redirect.uris` client
  attribute. RP-initiated logout (`arcanium/api/src/auth/oidc.js`'s
  `buildLogoutUrl()`) sends `post_logout_redirect_uri=$ARCANIUM_BASE_URL`
  to Keycloak's end-session endpoint; without that attribute, Keycloak
  has no way to know that redirect target is allowed for this client and
  rejects the request outright.
- **Fix applied:** Added the `post.logout.redirect.uris` attribute (set
  to the exact same `ARCANIUM_BASE_URL` value `buildLogoutUrl()` already
  sends) to the client provisioning script, applied on every run (both
  fresh-create and idempotent re-run against an already-existing client,
  so this already-provisioned realm picked up the fix immediately without
  a full realm rebuild).
- **Regression risk:** Low — an additive attribute on one existing OIDC
  client, no application code touched, no other client/realm/route
  affected.
- **Retest:** Re-ran the exact failing sequence live — login as
  `demo-operator`, open the persona menu, click "Sign out" — the request
  now returns Keycloak's real "Logging out" page and correctly lands back
  on `http://localhost:3000` with the session actually destroyed
  (subsequent navigation to `/` correctly redirects to `/login`, proving
  the session was really cleared, not just visually). Also re-ran
  `scenarios/11_security_foundation/test_negative_auth.sh` (29/29 passed)
  since this touches identity-provider configuration, to confirm no
  unrelated auth regression.

## Functional workflows exercised (Gate 4, full detail)

| Workflow | Route | Actions | Expected | Actual | Result |
|---|---|---|---|---|---|
| Login | `/login` → `/` | Click "Sign in" → Keycloak form → submit `demo-operator`/real password | Redirected to dashboard, session established | Matched | PASS |
| Primary navigation | all | Click each sidebar link | Route changes, correct page title, no console error | Matched | PASS |
| Command palette | any | Click "Search… ⌘K" | Modal opens listing pages/entities, `Esc` closes it | Matched | PASS |
| Filter | `/keys` | Type "webhook" in the filter box | List narrows from 8 to the 1 matching key, live | Matched | PASS |
| Logout | any → `/login` | Open persona menu → "Sign out" | Real RP-initiated logout at Keycloak, session destroyed, lands back on the app | **Failed, then fixed** — see Finding A | PASS (after fix) |

## DESIGN.md compliance audit

- **Typography:** heading hierarchy, font usage, and monospace usage
  match `DESIGN.md` on every route inspected.
- **Color:** semantic tokens used consistently; no new hex literal
  introduced outside the existing token set. **See Finding B below** —
  `--arc-text-dim` is used well beyond the one login-page instance fixed
  in the toolchain pass.
- **Spacing:** consistent with the documented 4px-multiple rhythm on
  every route reviewed.
- **Components:** button/input/card/nav/dialog patterns consistent with
  `DESIGN.md`'s inventory; no new one-off component variant introduced.
- **Motion:** no new animation/transition introduced beyond the CSS-only
  breakpoint work from the toolchain pass (which added no new motion).
  `prefers-reduced-motion` handling unchanged and confirmed present.
- **Anti-patterns:** none of `DESIGN.md`'s prohibited patterns were
  introduced by this pass's changes.

No `DESIGN.md` violation was introduced by any change made in this pass;
Finding B is a real, pre-existing violation of `DESIGN.md`'s own contrast
rule, not something this pass caused.

## Finding B — `--arc-text-dim` used on small body text app-wide (pre-existing)

- **Gate:** 6 (DESIGN.md compliance) / 7 (Accessibility)
- **Severity:** HIGH (not BLOCKER) — real, systemic, and a documented
  violation of the project's own rule, but the actual contrast gap is
  narrow (~4.3:1 measured vs. 4.5:1 AA, not a "1:1, invisible" situation
  like Finding 3 in `UI_AUDIT.md`), and every affected instance found is
  secondary/auxiliary text (footnotes, breadcrumb separators, timestamps,
  request IDs, hints), never primary content.
- **How this was found (a correction, not a fresh discovery hidden until
  now):** An earlier draft of this report asserted, without actually
  running the check, that no `--arc-text-dim`-on-small-text instances
  remained beyond the login page fixed in the toolchain pass. Running
  the actual check immediately after writing that sentence proved it
  wrong. This report is being corrected here rather than left with the
  unverified claim standing — the whole engagement's standard is "prove
  it, don't assert it," including about our own work.
- **Actual scope (verified):**
  ```bash
  grep -rnE "font-size:\s*(9|10|11|12|13)(\.[0-9]+)?px;.*color:\s*var\(--arc-text-dim\)|color:\s*var\(--arc-text-dim\);.*font-size:\s*(9|10|11|12|13)(\.[0-9]+)?px" \
    arcanium/ui/app arcanium/ui/app/assets/css/main.css
  ```
  **28 distinct CSS rules**, across **20+ files** (`main.css`,
  `layouts/default.vue`, and pages including `index.vue`,
  `reconciliation/[id].vue`, `keys/index.vue`, `keys/[id].vue`,
  `applications/[id]/intent.vue`, `onboard.vue`, `jobs.vue`,
  `evidence.vue`, `observability.vue`, `maturity.vue`, `teams.vue`,
  `integrations.vue`, `suppliers/[id].vue`, `applications/[id]/index.vue`,
  `components/AppFooter.vue`, `components/ClusterTopology.vue`), at sizes
  from 9.5px to 13px.
- **Decision:** Reported honestly, **not fixed in this pass.** Fixing 28
  rules across 20+ files is a mechanical but wide-blast-radius change —
  it deserves its own dedicated pass with its own full visual-regression
  sweep (every affected page re-screenshotted before/after), not a rushed
  blanket find-replace bundled into this report's closing minutes. Added
  to `UI_IMPROVEMENT_PLAN.md` as Required follow-up.
- **Why this doesn't block RELEASE for this pass specifically:** it is
  not a regression introduced by any change in this pass (verified: it
  predates every edit made in either the design-toolchain or quality-gate
  passes), the contrast gap is narrow, and the affected text is uniformly
  secondary/auxiliary. It is, however, real, and is why this report's
  overall verdict is **PASS WITH WARNINGS**, not an unqualified PASS.

## Visual regression

Compared `.artifacts/ui-baseline/` against `.artifacts/ui-after/`
(42 route×viewport screenshots each, plus `/login` at 3 viewports):

| Viewport | Classification |
|---|---|
| Desktop (1440×900), all routes | NEUTRAL — pixel-identical; the fix's breakpoints sit below this width |
| Laptop (1280×800), all routes | NEUTRAL — pixel-identical, same reason |
| Mobile (390×844), all routes | IMPROVEMENT — topbar no longer overlaps/clips; lifecycle-coverage grid now stacks instead of overflowing off-screen |
| `/login`, all viewports | IMPROVEMENT — note text now legible at accessible size/contrast |

No SUSPICIOUS or REGRESSION classification on any route×viewport pair.

## Finding C — fitness-test flakiness, found while re-running regression after Finding A's fix

Because Finding A's fix touched identity-provider configuration, the full
regression suite (fitness, negative-auth, scope-isolation, smoke) was
re-run for confidence — standard practice, not part of the required Gate
model, but caught a real, pre-existing bug in its own right:
`scenarios/13_fitness/test_architecture_invariants.sh`'s own webhook-
delivery check (added in Prompt 28) intermittently failed. Root-caused to
two real test-authoring gaps, not application bugs: (1) it picked a
`desired_state` row with no `ORDER BY` and assumed a single value toggle
would always produce a status *transition*, but `rotation_period`'s
comparator is a deep-equal against the key's live Vault-configured
`auto_rotate_period` (not an age/threshold check) — a key already
mismatched at every plausible toggle value never transitions, so no event
correctly fires; and (2) a hardcoded service-account name
(`fitness-test-sa`) collided with a leftover row from an earlier run.
Both fixed in the test script itself (read the real observed value first,
match it to force a known COMPLIANT baseline, then diverge from it to
force a genuine transition; timestamp-suffixed service-account name).
Verified stable across 5 consecutive full runs after the fix. A byproduct
of this debugging also required manually restoring `payments-api-key`'s
`rotation_period` desired-state row, which had been left at an
experimental value by ad-hoc debugging commands run before the test fix
was found — restored to match its real Vault-configured value (30 days,
now genuinely COMPLIANT).

## Dependency sanity

- `@playwright/cli` correctly landed in `devDependencies`, not
  `dependencies` — confirmed via `npm ls --depth=0` and `package.json`
  inspection.
- No duplicate icon/component/animation libraries introduced.
- No new runtime (`dependencies`) package added by this pass at all —
  Impeccable and Taste were installed as agent skills
  (`.claude/`/`.agents/`/`.github/`/`.codex/`), never as npm dependencies.
- Lockfile (`package-lock.json`) updated consistently for the one added
  devDependency; no lockfile drift.

## Accessibility

```text
Accessibility: PASS WITH WARNINGS
```

The one real accessibility defect found this pass (login-note
contrast/size, `UI_AUDIT.md` Finding 3) is fixed and confirmed still in
place. No new accessibility defect was introduced by any change in this
pass (topbar/grid changes are layout-only, both breakpoints tested with
the same keyboard/focus/skip-link behavior as before — unaffected, since
none of that logic was touched). **Finding B** (above) is a real,
pre-existing, systemic HIGH-severity gap that is not a regression from
this pass but must be visible in this result rather than reported as a
clean PASS.

## Required evidence (index)

- Routes tested: 14 primary + `/login` (see `BASELINE.md`).
- Viewports tested: 1440×900 / 1280×800 / 390×844 (`QUALITY.md`).
- Workflows tested: login, navigation, command palette, filter, logout
  (table above).
- Screenshots: `.artifacts/ui-baseline/`, `.artifacts/ui-after/`
  (gitignored, regenerable).
- Console findings: `BASELINE.md` "Existing browser errors" section;
  zero new findings this pass.
- Impeccable / Taste findings: `UI_AUDIT.md`.
- DESIGN.md violations: Finding B (pre-existing, see above) — none
  introduced by this pass.
- Engineering check results: this file, "Gate results" table.
- Build result: PASS (unchanged from baseline).
- Dependency observations: this file, "Dependency sanity" section.

## Release decision

```text
RELEASE WITH WARNINGS
```

All required gates pass or pass-with-warnings; no BLOCKER remains open
— the one BLOCKER found during this run (Finding A, logout) was fixed
and re-verified before this report was finalized. Two non-blocking,
pre-existing conditions remain visible rather than hidden: the
out-of-scope typecheck gap (11 errors, `QUALITY.md` policy) and Finding
B (`--arc-text-dim` app-wide, HIGH severity, narrow contrast gap,
secondary text only). Both are tracked as Required follow-up in
`UI_IMPROVEMENT_PLAN.md`, not silently dropped.

---

## Final output

```text
FRONTEND QUALITY GATE
=====================

Engineering:       PASS WITH WARNINGS (11 pre-existing typecheck errors, unrelated)
Build:              PASS
Browser:            PASS
Workflows:          PASS (one BLOCKER found and fixed — Finding A, logout)
Responsive:         PASS
Design:             PASS WITH WARNINGS (Finding B, pre-existing, app-wide)
Accessibility:      PASS WITH WARNINGS (Finding B)
Visual regression:  PASS
Console:            PASS
Dependencies:       PASS

Overall:
PASS WITH WARNINGS

Blocking findings:
0 (Finding A was blocking; fixed and re-verified before this report was finalized)

Non-blocking findings:
2 (pre-existing typecheck gap; Finding B — app-wide --arc-text-dim on small text)

Release recommendation:
RELEASE WITH WARNINGS
```

Report: `docs/frontend/FRONTEND_QUALITY_GATE.md` (this file).
Policy: `docs/frontend/config/QUALITY.md`.

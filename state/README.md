# Project state baselines

Reproducible, evidence-based records of what source formed a point in time,
what was actually running, and what was actually verified to work —
**not a backup**. See "State vs backup" below.

This convention (Prompt 00) is deliberately project-neutral in design, even
though the adapters underneath it are specific to this project's actual
components (Arcanium, Vault, HSM, identity, infra, KMS, observability,
workloads). If this repository's stack changes, the adapters change; the
three-tier model, status semantics, and tooling contract below do not.

## Why baselines exist

Before substantial feature work, hardening, refactoring, or migration
begins, a baseline answers three questions with evidence, not memory:

1. **Source state** — exactly which code/configuration formed this baseline?
2. **Deployment state** — what was actually running or deployed?
3. **Observed functional state** — what was actually verified to work, by a
   real (usually non-mutating) check — not inferred from "the container is
   up"?

The result is a diffable engineering record. Six phases from now,
`compare-state.sh` shows what actually changed against a real prior state,
not a reconstruction from git log and memory.

## Mandatory tooling

Two local tools are load-bearing here and are never reimplemented:

- **`commit_gh`** — the only commit/repository-security mechanism. Baseline
  commits, `--doctor` preflight, and `--scan` secret scanning all go through
  it. There is no plain-`git commit` fallback in `commit-baseline.sh` — if
  `commit_gh` is missing, the script fails clearly rather than silently
  downgrading the guarantee.
- **`folder_tree --output git .`** — the only project-structure discovery
  tool used here. Every baseline's `source/project-tree.md` comes from it,
  never from `find`/`tree`/`ls -R` or hand-rolled formatting.

## Status semantics

Every capture and every check reports one of four states:

| Status | Meaning |
|---|---|
| `CAPTURED` | the intended observation completed and produced trustworthy data |
| `PARTIAL` | some useful state was captured, but part of the intended observation could not complete |
| `UNKNOWN` | the state could not be determined — a valid, first-class result, not a gap to paper over |
| `FAILED` | the check ran and **positively observed** a failure |

Never collapsed: `unreachable → empty`, `unknown → healthy`,
`not run → pass`, `no results → no problems`.

Overall baseline status:

```text
FAILED    if any mandatory verification positively FAILED
PARTIAL   if nothing failed, but any required capture is PARTIAL or UNKNOWN
CAPTURED  if every required capture completed
```

A `PARTIAL` or even `FAILED` baseline is still retained — the status itself
is part of the evidence, never a reason to discard the capture.

## The three-tier model, and where each lands in a baseline

1. **Source state** — `source/`: git commit/branch/tag/dirty state, the
   actual uncommitted diff if any, tool versions, whitelisted config file
   hashes, and the git-tracked project structure from `folder_tree`.
2. **Deployment state** — `components/<name>/`: per first-class project
   component, whitelisted fields only — image/digest, container state,
   health, ports, network membership, non-secret **mode flags** (never
   values that could be credentials).
3. **Observed functional state** — `verification/`: not "the container is
   up" but "the thing it's for actually works" — a live, normally
   non-mutating check. Mutating checks (that create/rotate/delete/provision
   real resources) are opt-in only via `--with-scenarios`; without it they
   report `UNKNOWN` with an explicit reason, never a fabricated pass.

## Secret safety

**Whitelist, don't redact.** The capture script never runs
`podman inspect`, `podman compose config`, or dumps a full process
environment — all of those can casually put credentials into a baseline.
It only ever captures explicitly whitelisted fields, plus a `.env`
mode-flag allowlist (booleans/enums only, never anything named
`*PASSWORD*`/`*SECRET*`/`*TOKEN*`/`*_KEY*`/`*PIN*`/`*LICENSE*`/`*CREDENTIAL*`).

`validate-state.sh` is not advisory — `capture-state.sh` calls it itself,
**before** the atomic rename that makes a capture into a real baseline (see
below). It independently checks for direct `.env` value leaks and
credential-shaped patterns (Vault token prefixes, PEM private-key headers,
bearer tokens, cloud access-key patterns). Exit codes: `0` clean, `1`
suspected secret (must not be committed), `2` validation could not run.
There is no `--force` bypass. A value that's flagged but is genuinely not a
secret gets a narrowly-scoped, documented allowlist rule — not a disabled
check (see `.env`-key exclusions inside the script for a worked example).

`commit-baseline.sh` additionally runs `commit_gh --scan` across the whole
working tree before ever staging anything.

## Atomic capture — never a half-finished baseline

`capture-state.sh` builds every artifact inside `state/.capture-<id>.tmp/`,
never directly under `state/baselines/`. Only after all of the following are
true does it atomically rename the temp directory into place:

1. every component adapter has run;
2. `manifest.yaml` and `summary.md` exist;
3. `validate-state.sh` passes against the temp directory.

If any step fails, the `.tmp` directory is left in place for inspection and
`state/baselines/<id>/` is never created — the existence of a baseline
directory is itself proof it completed and validated. `state/CURRENT` is
only updated after the rename succeeds. (`state/.capture-*.tmp/` is
gitignored — it must never be swept into a commit by accident.)

## Baselines are immutable

One directory per capture, never overwritten: `state/baselines/<id>/`.
`capture-state.sh` refuses to run if the target already exists. History is
the point — `git log` on this directory shows the platform's own state
evolving across phases.

## State vs backup — do not conflate these

```text
state/
= evidence of source/configuration, observed deployment condition, and
  functional verification
= safe-to-commit metadata only
= NOT sufficient to restore the system

backup/  (wherever this project keeps real backups — not this directory)
= actual recovery material: Vault Raft snapshots, pg_dump output, HSM
  backup material, etc.
= sensitive, NOT casually committed to Git
```

A baseline can *record that a backup exists* without holding the backup
itself:

```yaml
backup:
  vault_snapshot:
    available: true
    sha256: <hash>
    location_class: external-secure-storage
```

## Layout

```text
state/
├── README.md
├── CURRENT                        — path of the most recently completed baseline
├── scripts/
│   ├── capture-state.sh
│   ├── validate-state.sh
│   ├── compare-state.sh
│   └── commit-baseline.sh
└── baselines/
    └── <baseline-id>/
        ├── manifest.yaml           — machine-readable centerpiece
        ├── summary.md              — generic section (from manifest) + project narrative
        ├── source/
        │   ├── git.txt  git-status.txt  diff.patch
        │   ├── versions.json  hashes.sha256
        │   └── project-tree.md      — from folder_tree, mandatory
        ├── runtime/
        │   ├── containers.json  images.json  networks.json  volumes.txt
        ├── components/
        │   ├── arcanium/  vault/  hsm/  identity/  infra/  kms/
        │   └── observability/  workloads/
        └── verification/
            ├── results.json
            └── summary.md
```

Components today: **arcanium, vault, hsm, identity, infra, kms,
observability, workloads** — identity (OpenLDAP + Keycloak, Prompt 18) was
missing from earlier captures until this rewrite; check `manifest.yaml`'s
`components:` block for what a given baseline actually covers rather than
assuming this list is exhaustive going forward.

## Usage

```bash
# capture a new baseline (non-mutating verification only, the default)
state/scripts/capture-state.sh 2026-09-11_initial "baseline before Prompt 18"

# include the opt-in mutating scenario suite too (touches the running demo estate)
state/scripts/capture-state.sh 2026-09-20_post-phase "after Phase N" --with-scenarios

# validate any baseline (or an in-progress .tmp capture) for secrets
state/scripts/validate-state.sh 2026-09-11_initial

# compare two baselines, or a baseline against its recorded predecessor
state/scripts/compare-state.sh 2026-09-11_initial 2026-09-20_post-phase
state/scripts/compare-state.sh 2026-09-20_post-phase

# tag + commit + push a baseline — requires commit_gh, no fallback
state/scripts/commit-baseline.sh 2026-09-11_initial
state/scripts/commit-baseline.sh 2026-09-11_initial arcanium-initial \
  "Arcanium baseline before Prompt 18 Security Foundation"
```

## Baseline naming

`YYYY-MM-DD_<label>`, e.g. `2026-09-11_initial`,
`2026-09-11_pre-auth-hardening`, `2026-09-12_post-auth-hardening`,
`2026-09-20_pre-migration`. The post-state of one phase is normally
sufficient as the pre-state of the next — don't create redundant duplicate
baselines without a reason.

## Commit and tag semantics

`commit-baseline.sh` tags the baseline's **recorded source commit**
(`manifest.yaml`'s `baseline.git.commit`), not whatever commit the state
artifacts themselves end up on — those are two different things, and only
the source commit is what the tag is meant to mark. It reports both SHAs
(source and artifact) on completion. Nothing outside `state/` may be dirty
when committing a baseline (`commit_gh` stages the whole working tree) —
commit or stash unrelated changes first.

## Comparison semantics

`compare-state.sh` resolves a baseline's predecessor from
`manifest.yaml`'s `previous_baseline` field (recorded at capture time — the
authoritative predecessor, unaffected by renames or checkouts), falling
back to sorting every baseline's `captured_at` timestamp if that field is
absent. **Never** directory modification time — it doesn't survive a
checkout, a copy, or a restore. The diff distinguishes `ABSENT` /
`UNKNOWN` / `FAILED` / `CAPTURED_EMPTY` / `CAPTURED_VALUE` — a value that
went from `UNKNOWN` to actually captured is reported as "previously
unobserved; now captured", never manufactured into a false "changed" story.

## Recommended cadence

```text
initial / pre-change
post-change
post-next-major-phase
...
```

Not for six piles of screenshots — for a real before/after engineering
record of the platform evolving.

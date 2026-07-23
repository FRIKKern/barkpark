# CLI-Reliability (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Studio Space-Priority Desk** — is preserved in full
> (D1–D34 verbatim, plus later waves) at `.claude/workflows/bp-studio-space-priority-charter.md`;
> do NOT read this file for SPD history. This slot is now the memory of the
> **CLI-Reliability** throughput epic.
>
> Epic anchor: bp task **`task-09f4775e7ccc2cca`** (scoreboard-parent research epic).
> Wave paper: **`cli-reliability-wave-2026-07-23`** (style=article).
> Decided 2026-07-23.

## Vision

The CLI dev-loop's health instruments must be UNABLE to lie. Two freshly-verified
non-Elixir false-green classes get fixed as permanent instruments, not patches:
(1) `make doctor` / scripts/doctor.sh false-greens a stale installed `bp` binary
because it diffs the binary's build commit against LOCAL HEAD instead of
origin/main — a binary built in a diverged worktree that misses merged CLI
changes (#5786-class) reports healthy. (2) The served scaffy catalog can drift
from main silently because nothing in CI ever runs `go run ./scaffy/seed --check`
(it WAS red for days until a manual re-seed on 2026-07-23 13:56Z). Both fixes are
mutation-proven (a behind binary MUST red; corpus drift MUST red) and land with
permanent regression harnesses, merging on the Go/CI lane parallel to the Elixir
queue. Improvement-only; honest 2-slice wave.

## Decisions

- **D1 — merge-base semantics, not a bare origin/main swap.** Stale iff
  `git diff --name-only $(git merge-base $BP_COMMIT origin/main) origin/main -- '*.go' go.mod go.sum internal cmd deploy.sh`
  is non-empty. Why: proven on real fixture repos across the full verdict matrix —
  a binary AHEAD with unpushed local Go commits has merge-base==tip and stays
  green; a bare swap would false-red it (vm-doctor-matrix, 8/8 cells).
- **D2 — guard order is load-bearing: cat-file → rev-parse → merge-base → diff.**
  `git cat-file -e "$BP_COMMIT^{commit}"` (unknown commit → loud skip) FIRST,
  then `git rev-parse --verify --quiet origin/main` (offline/no-ref → loud skip),
  then non-empty merge-base, then the diff. Why: the bare one-liner FALSE-GREENS
  offline — `$base` goes empty, the git error is swallowed, and an empty diff
  reads ok (proof line: "BARE verdict: GREEN <-- FALSE-GREEN"). All new branches
  route through bad()/skip()/ok() (SessionStart hook silence contract) and the
  unconditional `exit 0   # advisory` tail stays (upgrade_test + hook contract).
- **D3 — pathspec gains `deploy.sh`.** Why: root deploy.sh is a real binary input
  (`make cli-assets-sync` vendors it into the embed); its root↔vendored identity
  is enforced only by vendored-assets.yml — one word removes the dependency on
  that external invariant (historic drift #757/#499).
- **D4 — permanent harness `scripts/doctor.test.sh` (install-cli.test.sh
  convention) wired via a NEW `.github/workflows/shell-harnesses.yml`.** Why:
  doctor.sh false-greened twice in one week by two different routes (#5935 regex,
  compare-target today) — patch-without-harness is how this file fails; and NO
  existing CI lane runs any scripts/*.test.sh (zero `run:` hits repo-wide), so
  "ride an existing job" was refuted — a lane must be authored. Rejected rival:
  a `--selftest` flag inside doctor.sh (the checkout must audit the binary; keep
  the advisory script lean).
- **D5 — the harness's fake-git MUST stub `merge-base` (returning a plausible
  SHA) and MUST place a fake `bp` on PATH.** Why: upgrade_test's fixture has
  neither, so its PASS never exercises section 2 — copying it verbatim
  reproduces the same blind spot one level down (vm-upgrade-test-interplay).
- **D6 — autoseed tripwire = dedicated advisory workflow
  `.github/workflows/scaffy-catalog-drift.yml` + `make seed-check`.** TOKENLESS
  (seed --check reads the published perspective from guerrilla.barkpark.cloud by
  design; NO guerrilla creds in CI) and ADVISORY (job-level
  `continue-on-error: true`; remediation is a human re-seed, never a CI
  mutation). Triggers: push-to-main with paths scaffy/commands/**,
  scaffy/seed/**, internal/scaffy/**, its own yml; daily cron `17 6 * * *`;
  workflow_dispatch. `concurrency.cancel-in-progress: false` — a literal `true`
  reds never-cancel-main-check via doc-gates' `.github/workflows/**` glob
  (mutation-proven both directions in preflight). The job summary distinguishes
  UNREACHABLE (fetch failure — no table is even printed) from DRIFT (table rows)
  from in-sync, so advisory reds aren't ambiguous noise. Why dedicated: bolting
  an advisory network check onto a required gate's workflow muddies the gate
  story.
- **D7 — in-workflow self-test step.** Before the real check, mutate one .scaffy
  in the RUNNER's ephemeral checkout, assert exit 1 + a DRIFT row naming that
  command, restore via `git checkout --`. Why: the tripwire must re-prove it can
  fail on every run, not once at merge time (astro-finder-drift precedent;
  make-the-check-able-to-fail doctrine).
- **D8 — claim the existing anchor tasks; file nothing new for the slices.**
  Slice 1 = `scaffy-backlog-doctor-bp-freshness`, slice 2 =
  `scaffy-backlog-seedcheck-ci-advisory`, both re-parented under
  `task-09f4775e7ccc2cca`. Why: the wish's cited pdf-bl-doctor-bp-staleness-regex
  is closed and covered a different bug (regex false-skip, #5935); these two open
  tasks are the exact live ledger anchors — filing duplicates forks the ledger.
  Slice 1 must diff against CURRENT doctor.sh (post-#5726): the no-stamp loud red
  and `make cli-install` hint already exist and must be preserved.
- **D9 — builders: Opus, both slices; slice 1 carries HIGH-FLIP-RISK.** The
  flip-prone judgment is the doctor verdict matrix — legit up-to-date and
  ahead-with-local-Go binaries MUST stay green. Reviewer re-derives that matrix
  independently on fixtures (E2), and a genuinely independent second reviewer is
  warranted before merge.
- **D10 — post-merge obligations (lead):** one green `workflow_dispatch` run of
  scaffy-catalog-drift.yml on main proving Actions-runner egress to
  guerrilla.barkpark.cloud (unprovable pre-merge), and one live `make doctor` on
  a deliberately-behind worktree confirming the RED fires in situ.
- **D11 — premise corrections recorded honestly.** seed --check is GREEN today
  (re-seeded 13:56Z by scaffy-dr-catalog-reseed) — slice 2 delivers the
  tripwire, not a re-seed. The wish's task citation was stale. "Parallel to the
  Elixir queue" is correctness-parallel only — elixir.yml runs on every PR
  (~13-16 min wall) and main has ZERO branch protection; all gates are
  discipline. No freshness path may ever consume `go version -m` vcs stamps
  (unsound in nested worktrees — walk-up binds to the ancestor repo's HEAD;
  the ldflags `commit` field is the only trustworthy signal).

## Roadmap

1. **Slice 1 (medium, round 1, Opus)** — doctor.sh merge-base staleness fix +
   scripts/doctor.test.sh verdict-matrix harness + shell-harnesses.yml wiring.
   Task `scaffy-backlog-doctor-bp-freshness`. Files: scripts/doctor.sh,
   scripts/doctor.test.sh, .github/workflows/shell-harnesses.yml.
2. **Slice 2 (small, round 1, Opus)** — scaffy-catalog-drift.yml advisory
   tokenless tripwire + `make seed-check`. Task
   `scaffy-backlog-seedcheck-ci-advisory`. Files:
   .github/workflows/scaffy-catalog-drift.yml, Makefile.
3. **Backlog (filed as published children, future waves):**
   `clirel-bl-local-update-early-exit` — local-update.sh OLD==NEW early-exit
   skips the bp rebuild (fixer-side residual; low severity since doctor's hint
   is `make cli-install`, which rebuilds unconditionally);
   `clirel-bl-go-tests-scaffy-paths` — go-tests.yml path filter misses
   scaffy/commands/** so the corpus census test can go stale again (historic
   7→12 incident, task-94df363c6ad6de68);
   `clirel-bl-wire-orphan-shell-tests` — wire the four orphaned
   scripts/*.test.sh into shell-harnesses.yml once slice 1 lands.

## Wave log

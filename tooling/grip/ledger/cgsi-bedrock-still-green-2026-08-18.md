# Re-derivation recipe — bedrock-still-green (CI gate-script integrity wave)

Question: does `scripts/required-checks.test.sh --hermetic` actually PASS on origin/main today,
given it runs only in a non-required lane (`required-checks-drift.yml`)?

Verdict on origin/main 541195b5d1: **YES — 177 passed, 0 failed.** Premise refuted.

## 0. The briefed recipe CANNOT produce the proof (fail-closed refusal, rc=3)

    cd $(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x \
      && bash scripts/required-checks.test.sh --hermetic; echo rc=$?

    # rc=3, one line: "no git object database at <dir> (a `git archive` extract or a copied
    # tree?); sections 13 and 18 read the tracked corpus with `git ls-files`/`git grep`, and
    # without it section 13 prints ok over ZERO files"

A `git archive` extract has no `.git`, so the harness REFUSES rather than printing a vacuous
green over zero files. Use a real worktree instead.

## 1. Run it for real (~3m47s)

    WT=<scratchpad>/wt-bedrock-still-green
    git -C /Volumes/SATECHI/github/barkpark worktree add --detach "$WT" origin/main
    cd "$WT" && bash scripts/required-checks.test.sh --hermetic | tail -3
    # required-checks: 177 passed, 0 failed (hermetic — the API stage was skipped)

    bash scripts/required-checks-verify.sh --selftest | tail -1
    # SELFTEST OK — every clause can both pass and fail          (18/18, rc=0)

    bash scripts/required-checks-verify.sh | tail -1
    # OK: live protection, the committed spec and the rendered check names all agree.  (rc=0)

## 2. Can-fail proof (Axis C) — plant a disarm in the worktree copy only

    perl -0pi -e 's/^advisory_prose_check\(\) \{/advisory_prose_check() {\n  return 0\n/m' \
      scripts/required-checks-verify.sh
    bash scripts/required-checks-verify.sh --selftest; # rc=1, "SELFTEST FAILED"
    bash scripts/required-checks.test.sh --hermetic;   # rc=1, "176 passed, 1 failed"
                                                      # → "FAIL verify --selftest is red"
    git checkout -- scripts/required-checks-verify.sh   # restore INSIDE the worktree

Note the coupling: the 3,437-line harness caught the disarm through exactly ONE clause — it
delegates to `verify --selftest`. It does not independently re-plant the advisory-prose
violation. That is a coverage observation, not a defect.

## 3. CI history (job level, because a run-level green hides a continue-on-error red)

    gh run list --workflow=required-checks-drift.yml --branch main --limit 60 \
      --json conclusion -q '.[].conclusion' | sort | uniq -c      # 51 success, 9 cancelled, 0 failure
    for id in $(gh run list --workflow=required-checks-drift.yml --branch main --limit 25 \
      --json databaseId,conclusion -q '.[]|select(.conclusion=="success")|.databaseId' | head -12); do
      gh run view $id --json jobs -q '[.jobs[]|"\(.name)=\(.conclusion)"]|join(" | ")'; done
    # 12/12: "Required-check spec gate=success | Required-check spec drift (advisory)=success"

## 4. The S7 "permanent by accident" claim is stale

    git show origin/main:.github/required-checks.json | grep -n "8222"

The `Required-check spec gate` S7 row was HAND-CORRECTED 2026-08-06 (wave 36). It already
records that #8222 is CLOSED with mergedAt null and that the old trigger "can NEVER FIRE"; it
replaced it with a live, re-measurable trigger (spec gate green on main HEAD + a clean
`scripts/registration-deadlock-sweep.sh`) tracked as
`cch-w36-bl-register-spec-gate-after-census-green`. The hold is deliberate, not accidental.

## Cleanup / safety

    git -C /Volumes/SATECHI/github/barkpark worktree remove --force "$WT"
    git -C /Volumes/SATECHI/github/barkpark status --porcelain -- scripts/ .github/ | wc -l   # 0

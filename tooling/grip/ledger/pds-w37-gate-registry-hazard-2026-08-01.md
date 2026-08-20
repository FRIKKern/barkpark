# pds-w37 — gate-registry hazard: re-derivation recipes

Measured 2026-08-01 against `origin/main` = `501fb9670971998e5e5af05126cabfed3ea425bc`.
Everything below runs from a CLEAN tree cut from origin/main (the primary checkout at
the time of measurement was 100+ commits behind on `scripts/required-checks*.sh`, so a
run from it measures a different toolchain).

## 0. build a clean measurement tree (never measure from the primary checkout)

    git worktree add --detach /tmp/mainwt origin/main
    # or, for a mutable sandbox that is NOT a worktree of this repo:
    rm -rf /tmp/sandbox && mkdir -p /tmp/sandbox \
      && git archive origin/main | tar -x -C /tmp/sandbox \
      && cd /tmp/sandbox && git init -q . && git add -A \
      && git -c user.email=a@b -c user.name=a commit -qm base

## 1. the blocking gate's ACTUAL command (Required-check spec gate)

`.github/workflows/required-checks-drift.yml` job `spec-gate` runs exactly one thing:

    cd /tmp/mainwt && bash scripts/required-checks.test.sh --hermetic; echo TEST_RC=$?
    # 111 passed, 0 failed  /  TEST_RC=0     (~2-4 min)

## 2. the advisory half (Required-check spec drift) — ALREADY RED ON MAIN

    cd /tmp/mainwt && bash scripts/required-checks-verify.sh --ci; echo VERIFY_RC=$?
    # VERIFY_RC=1 — spec requires 4 contexts, live protection carries 2
    # MISSING from live: Cloud gate (app_id 15368) / Console gate (app_id 15368)

## 3. does a NEW elixir.yml job red either half? (mutation)

In /tmp/sandbox insert an always-run job before `  format:` in
`.github/workflows/elixir.yml`, then re-run §1.

    # observed: 111 passed, 0 failed — RC 0, byte-identical to baseline.
    # Same result when the job is ALSO added to elixir-gate's `needs:`.

## 4. does the next regeneration PROMOTE it? (the real hazard)

Fixture = every context in the committed spec + the new job name, all `success`:

    jq -r '[(.protection.required_status_checks.checks[].context),
            (.exclusions[].context), "Receipt census integrity"]
           | map({name:., conclusion:"success", started_at:"2026-01-01T00:00:00Z",
                  app:{id:15368}}) | {check_runs:.}' \
      .github/required-checks.json > /tmp/fix/checkruns-shaX.json
    cp /tmp/fix/checkruns-shaX.json /tmp/fix/checkruns-shaY.json
    cp /tmp/fix/checkruns-shaX.json /tmp/fix/checkruns-shaM.json
    echo shaM > /tmp/fix/main-shas.txt
    echo '{"statuses":[]}' | tee /tmp/fix/status-shaX.json > /tmp/fix/status-shaY.json

    bash scripts/required-checks-generate.sh --fixture-dir /tmp/fix \
      --sha shaX --sha shaY --out /tmp/gen.json
    jq -r '.protection.required_status_checks.checks[].context' /tmp/gen.json

    # standalone job in the tree  -> 5 contexts, "Receipt census integrity" PROMOTED
    # pristine origin/main tree   -> 4 contexts (same fixture; the name has no job)
    # job inside elixir-gate.needs-> 4 contexts + exclusion row "S3 SUBSUMED"

## 5. R2 SAMPLE (does an always-run shape survive?)

    jq '(.check_runs[]|select(.name=="Receipt census integrity")|.conclusion)="skipped"' \
      /tmp/fix2/checkruns-shaY.json > t && mv t /tmp/fix2/checkruns-shaY.json
    # regenerate -> 4 contexts. A job that EVER concludes skipped is dropped.
    # Therefore always-run == promotable. The `needs:` membership is the ONLY brake.

## 6. aggregator half-landing blast radius (executable)

Extract the decide script straight out of the workflow and drive it:

    git show origin/main:.github/workflows/elixir.yml | sed -n '659,725p' \
      | sed 's/^          //' > /tmp/base.sh

    # A+B (needs: + env:) without C (decide arm), census FAILED:
    R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success \
    R_ESCAPE=success O_COMPILE=true O_TEST=true R_CENSUS=failure bash /tmp/base.sh
    # -> "Elixir gate: every upstream job either succeeded..."  RC 0  == SILENT LAUNDER

    # C (decide arm) without A (needs:) -> empty result -> the '' arm:
    #    "FAIL receipt-census: EMPTY result ..."  RC 1  == permanent red, loud
    # C without B (env: missing) -> "R_CENSUS: unbound variable"  RC 1  == loud

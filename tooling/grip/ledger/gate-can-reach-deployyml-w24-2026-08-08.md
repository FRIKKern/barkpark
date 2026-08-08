# Can any required gate red on a deploy.yml-only PR? — re-derivation recipe (wave 24, 2026-08-08)

Verdict: NO. All three suite gates publish green with every substantive job skipped; the
fourth required context ("PR references an active task") measures the task ref, not the code.

## 0. Work from origin/main, not this checkout

The primary checkout was 678 commits behind origin/main when this was derived, and
`scripts/{cloud,console}-path-escape-check.sh` did not exist in it at all.

    S=$(mktemp -d); git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C "$S"

## 1. The three dispatchers all say false for `.github/workflows/deploy.yml`

    printf '.github/workflows/deploy.yml\n' | bash "$S/scripts/cloud-path-escape-check.sh"   --match cloud     # false
    printf '.github/workflows/deploy.yml\n' | bash "$S/scripts/console-path-escape-check.sh" --match console   # false
    printf '.github/workflows/deploy.yml\n' | bash "$S/scripts/elixir-path-escape-check.sh"  --match compile   # false
    printf '.github/workflows/deploy.yml\n' | bash "$S/scripts/elixir-path-escape-check.sh"  --match test      # false

## 2. LIVE proof on a real head — PR #10606, whose whole diff is deploy.yml + one script

    gh pr view 10606 --json files -q '.files[].path'
    gh api "repos/FRIKKern/barkpark/commits/2b45e9de3188e886cff2a9cd8c2667a2ab73661c/check-runs?per_page=100" \
      -q '.check_runs[]|"\(.name) | \(.conclusion)"' | sort
    # then, per gate:
    id=$(gh api ".../check-runs?per_page=100" -q '.check_runs[]|select(.name=="Cloud gate")|.id')
    gh api "repos/FRIKKern/barkpark/check-runs/$id/annotations" -q '.[]|"\(.title) | \(.message)"'

Three notices, verbatim titles: `Cloud gate: green — nothing ran`,
`Console gate: green — nothing ran`, `Elixir gate: green — nothing ran`.

## 3. D414's laundered green is REFUTED on origin/main — mutation, both directions

    cp -a "$S" "$S2"
    # (a) add an un-decided leaf to console-gate's needs:
    #     needs: [changes, …, path-escape, laundry-leaf]
    bash "$S2/scripts/console-path-escape-check.sh" --selftest   # 200 passed, 5 failed; exit 1
    #     -> FAIL — needs_without_decide = 'laundry-leaf', wanted ''
    # (b) add a blocking job to cloud.yml that is NOT in cloud-gate's needs at all:
    bash "$S3/scripts/cloud-path-escape-check.sh" --selftest     # 149 passed, 10 failed
    #     -> FAIL — blocking_not_in_needs = 'deliveries-recorder-guard', wanted ''

Unmutated baselines: cloud 159 passed / 0 failed, console 205 passed / 0 failed.

## 4. Widening CLOUD_PATHS with deploy.yml is legal but SELF-REFERENTIALLY GREEN

    # insert '.github/workflows/deploy.yml' into CLOUD_PATHS in cloud-path-escape-check.sh
    bash "$S4/scripts/cloud-path-escape-check.sh" --check      # OK: every repo-root read … is dispatched on
    printf '.github/workflows/deploy.yml\n' | bash "$S4/scripts/cloud-path-escape-check.sh" --match cloud  # true
    bash "$S4/scripts/cloud-path-escape-check.sh" --selftest   # 160 passed, 0 failed
    diff <(bash "$S/scripts/…" --selftest) <(bash "$S4/scripts/…" --selftest)
    #   > ok — cloud: '.github/workflows/deploy.yml' -> true

The one new assertion is GENERATED FROM the set it asserts. Delete the line and the
assertion deletes itself: nothing reds. Contrast a path with a real read —

    # delete 'deploy/site-deploy.sh' from CLOUD_PATHS
    bash "$S5/scripts/cloud-path-escape-check.sh" --check      # FAILS, names the fix
    bash "$S5/scripts/cloud-path-escape-check.sh" --selftest   # 156 passed, 2 failed

## 5. Cost measurements

    git log --oneline --since=14.days origin/main -- .github/workflows/ | wc -l              # 73
    git log --oneline --since=14.days origin/main -- .github/workflows/deploy.yml | wc -l    # 4
    gh run view 31251578730 --json jobs -q '.jobs[]|"\(.name) | \(.startedAt) -> \(.completedAt)"'
    # Cloud test ≈ 97s, Cloud compile ≈ 32s, ratchet ≈ 16s

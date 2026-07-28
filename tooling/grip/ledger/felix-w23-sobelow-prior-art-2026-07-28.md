# Re-derivation recipes — felix wave 23 Sobelow prior-art collision (2026-07-28)

Every fact in the wave-23 verify report re-derives from one of these.

## Prior-art rows (bp reachable — all seven resolved, exit 0)

    for t in task-004737a5e2e88db2 hg-bl-sobelow-fingerprint-to-inline-migration \
             hgw2-s2-sobelow-honest-baseline hg-bl-sobelow-inline-annotation-reversion \
             hg-bl-sobelow-red-under-green task-felix-sobelow-gate-blocking-eval \
             task-felix-w13-sobelow-stay-advisory-verdict; do
      bp task get $t -o json; echo EXIT=$?; done

Two ids named in the wave brief DO NOT EXIST; the real ids carry suffixes:

    bp task get task-felix-w21-bl-boundedcmd-extraction      # not_found
    bp task get task-felix-w21-bl-releasecapture-bound       # not_found
    bp task get task-felix-w21-bl-boundedcmd-extraction-eval # exists
    bp task get task-felix-w21-bl-releasecapture-bound-tests # exists

## hgw2-s2 landed on main (the ground moved under wave 23)

    git show origin/main:api/scripts/sobelow-baseline-reconcile.sh | grep -n 'mix sobelow\|sequence='
    git log --oneline -3 origin/main -- api/scripts/sobelow-baseline-reconcile.sh   # c69cc0b1e (#6412)
    git show origin/main:api/.sobelow-skips | grep -c '^[A-Za-z]'                   # 108
    git show origin/main:.github/workflows/security.yml | grep -n 'continue-on-error\|--exit\|--selftest'

## Sobelow JOB conclusion (never read the run-level rollup)

    for r in 30342320311 30341004813 30340995486 30328109322 30317787518 30312040357; do
      gh run view $r --json headSha,jobs -q '.headSha[0:9] as $s | .jobs[] | "\($s) \(.name) => \(.conclusion)"' | grep -i sobelow; done

## Live finding set (51) from the failing step of the newest main run

    JOB=$(gh run view 30342320311 --json jobs -q '.jobs[]|select(.name|startswith("Sobelow static"))|.databaseId')
    gh run view --job "$JOB" --log > /tmp/job.log
    awk -F'\t' '$2 ~ /^Sobelow \(--skip/ {print $3}' /tmp/job.log | sed -E 's/^[^ ]*Z //' \
      | sed -E 's/\x1b\[[0-9;]*m//g' > /tmp/sobc.txt
    grep -cE '^[A-Za-z]+\.[A-Za-z]+: ' /tmp/sobc.txt        # 51
    grep -oE '^[A-Za-z]+\.[A-Za-z]+:' /tmp/sobc.txt | sort | uniq -c | sort -rn
    awk '/^File: /{print $2}' /tmp/sobc.txt | sort | uniq -c | sort -rn

## Phantom-entry count, from CI's own same-toolchain rescan

    gh run download 30342320311 -D /tmp/art          # run from inside the repo
    cat /tmp/art/*/metadata.txt                      # baseline_lines=106
    f=/tmp/art/*/sobelow-skips.diff
    grep -c '^-[^-]' $f    # 52 phantom committed entries
    grep -c '^+[^+]' $f    # 50 unbaselined findings

## Stale doc

    git show origin/main:docs/ops/merge-gates.md | grep -n -i -A6 'stay advisory'   # still says 137

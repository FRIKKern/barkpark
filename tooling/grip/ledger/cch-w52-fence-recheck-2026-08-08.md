# cch wave-52 fence re-check — re-derivation recipes (2026-08-08)

Baseline: `origin/main` = `572d51e13`. Local `main` in this checkout is 652 behind /
49 ahead of `origin/main` and MUST NOT be quoted; every recipe below reads `origin/main`
or a `git archive origin/main` extract, never the worktree.

    git fetch origin main -q && git log --oneline -1 origin/main
    git rev-list --count HEAD..origin/main; git rev-list --count origin/main..HEAD

## R1 — report.go is NOT in CONSOLE_PATHS on origin/main

    git show origin/main:scripts/console-path-escape-check.sh | sed -n '142,157p'
    git show origin/main:scripts/console-path-escape-check.sh | grep -c 'internal/agent\|report\.go'   # 0

## R2 — the escape ratchet passes today, from a pristine origin/main tree

    D=$(mktemp -d); git archive origin/main | tar -x -C "$D"
    bash "$D/scripts/console-path-escape-check.sh"; echo "ESCAPE-RC=$?"
    # 16 distinct repo-root read(s) resolved from cloud/priv/static ; OK ; RC=0

## R3 — MUTATION: an undeclared read of report.go reds the ratchet

    printf '\nconst _p = readFileSync(path.join(REPO_ROOT, "internal/agent/report.go"), "utf8");\n' \
      >> "$D/cloud/priv/static/__app.test.mjs"
    bash "$D/scripts/console-path-escape-check.sh"; echo "RC=$?"   # RC=1, ::error:: UNCOVERED
    # restore the file, re-run -> RC=0

## R4 — s2 flips report.go into the Console gate's dispatch set

    printf 'internal/agent/report.go\n' | bash "$D/scripts/console-path-escape-check.sh" --match console
    # -> false   (origin/main today)
    # insert `internal/agent/report.go` as the 2nd line of CONSOLE_PATHS, re-run
    # -> true    (after cch-w51-s2 merges)

## R5 — wave-52 Paper is still body-empty; no cch-w52-* slices exist

    bp paper view cloud-console-hardening-wave-52-2026-08-08     # 422 semantic_empty
    bp search query "cch-w52" -o json                            # count 1, and it is the DR wave-21 paper
    bp search query "cloud-console-hardening-wave-52" --all -o json   # the paper doc id EXISTS

## R6 — cch-w51-s2 state, and it has no unpushed work

    bp task get cch-w51-s2-backup-sentinel-cross-fence-pin -o json
    # lifecycle_status open, claim null, assignee null, round 2, priority 1,
    # after=[cch-w51-s1-...], files=[cloud/priv/static/__app.test.mjs,
    #                                scripts/console-path-escape-check.sh]
    git branch -r --sort=-committerdate | grep -v HEAD | while read b; do
      n=$(git diff --name-only origin/main...$b 2>/dev/null \
            | grep -c 'console-path-escape-check\|internal/agent/report.go')
      [ "$n" -gt 0 ] && echo "HIT $b ($n)"
    done
    # 14 hits across 2490 remote branches, ALL committed before s2 was created
    # (2026-08-08T00:42:51Z); no branch name matches backup-sentinel/cross-fence/w51-s2.

## R7 — s2's dependency has ALREADY merged (so s2 is ready to fly)

    git show origin/main:cloud/priv/static/app.js       | grep -c 'no backup probe wired'  # 1
    git show origin/main:cloud/priv/static/__app.test.mjs | grep -c 'no backup probe wired' # 2

## R8 — the two properties wave 21's report.go leg must preserve

    git show origin/main:internal/agent/report.go | sed -n '595,597p'
    #   } else {
    #       r.BackupDetail = "no backup probe wired"
    #   }
    git grep -nE 'BackupProbe[[:space:]]*[:=][[:space:]]*\S' origin/main -- internal cmd
    # ZERO hits  (arm C holds today)

## Caveat on R2/R3/R4

Run from a `git archive` EXTRACT, not a clone. `cch-w51-s2` acceptance criterion 7
explicitly forbids stamping the slice's own proof this way ("never a git archive
extract") because the ratchet enumerates the WORKING TREE with `find`, so untracked
files present in a real clone are invisible to an extract. The mutation result
(RC 0 -> 1 -> 0 on one planted line) is unaffected by that difference; a false-GREEN
from a missing untracked file could only make R2 optimistic, never R3/R4 wrong.

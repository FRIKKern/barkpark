# w25 verify — s3/s1 collision, guard anchors, harness path (2026-08-02)

Re-derivation recipes only. Every number below is reproducible by the command beside it.
All reads are from `origin/main` (`git rev-parse origin/main` = `5444aa5e1ea8bc643ba8c7a100f9173413c688a4`
at time of writing). The PRIMARY CHECKOUT WAS 356 COMMITS BEHIND AND DIRTY — do not read
these files from the working tree.

## R1 — the checkout is not main

    git rev-parse HEAD; git rev-parse origin/main; git rev-list --count HEAD..origin/main

Non-zero count ⇒ every premise read from the worktree is a stale-tree read (the same trap
that produced wave 25's "D276-D293 do not exist" false negative at strategize).

## R2 — hydrate an origin/main-true static tree in scratch

    S=$(mktemp -d); git archive origin/main cloud/priv/static | tar -x -C $S
    git archive origin/main internal/taskboard/testdata | tar -x -C $S
    git archive origin/main internal/pdrender/testdata  | tar -x -C $S
    cd $S && node cloud/priv/static/__app.test.mjs | tail -7

`__app.test.mjs` READS OUTSIDE `cloud/priv/static` — `internal/taskboard/testdata/styleguide_lifecycle.txt`
and `internal/pdrender/testdata/styleguide_tokens.txt`. Omit either and it reds 2 / 1 with ENOENT,
which is indistinguishable from a real regression. Expected on origin/main: `# pass 776 / # fail 0`.

## R3 — the harness path (a fence written with the wrong prefix fences nothing)

    git ls-tree -r --name-only origin/main | grep -E '__app\.test\.mjs|overflow-guard|cssom-heads'

Exactly one console harness: `cloud/priv/static/__app.test.mjs`. **NOT** under `__preview__/`.
`__preview__/` holds `overflow-guard.mjs` and `cssom-heads.baseline`.

## R4 — s1 and s5 are ancestors; s3 and s7 are unbuilt

    for s in 775c0bd8d 3d8093f71; do git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done
    bp task get cch-w24-s3-launch-catalog-stops-lying-after-a-connect -o json | python3 -c \
      "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['claim'])"
    git branch -r --list 'origin/*w24-s3*' 'origin/*w24-s7*'   # empty ⇒ nothing built yet

## R5 — the s1/s3 collision, proved by synthetic two-hunk 3-way merge

    W=$(mktemp -d)
    git show 775c0bd8d^:cloud/priv/static/app.js > $W/base.js     # pre-s1 main
    git show 775c0bd8d:cloud/priv/static/app.js  > $W/ours_s1.js  # s1 applied
    # theirs = base + ONE line inserted after `loadProviders();` inside the 201 branch
    python3 - <<'PY'
    import os; W=os.environ['W']
    s=open(f"{W}/base.js").read()
    old="        loadProviders();\n        return;\n      }"
    assert s.count(old)==1
    open(f"{W}/theirs_s3.js","w").write(s.replace(old, old.replace("loadProviders();",
      "loadProviders();\n        remountLaunchCatalogAfterConnect(kind);")))
    PY
    cp $W/ours_s1.js $W/merged.js
    git merge-file -L s1 -L base -L s3 $W/merged.js $W/base.js $W/theirs_s3.js; echo rc=$?
    grep -c '<<<<<<<\|>>>>>>>' $W/merged.js

Expected `rc=0`, `0` markers. Root cause of the triviality — s1 never touched the branch s3 edits:

    for f in 775c0bd8d^ 775c0bd8d; do git show $f:cloud/priv/static/app.js \
      | awk '/^  function submitProviderCred/,/^  }$/' | sed -n '/r.status === 201/,/^      }$/p'; done \
      | sort | uniq -c   # every line count is even ⇒ byte-identical across s1

s1's footprint inside `submitProviderCred` is the READ lines only —
`credQ("#cred-label")`, `credRemediationBox()`, `credQ("#cred-submit")` plus two `if (btn)` null-guards.

## R6 — the guard's registry shape and the ONE hot anchor

    grep -n 'const DEFECTS' -A 20 cloud/priv/static/__preview__/overflow-guard.mjs
    grep -n 'requested.includes' cloud/priv/static/__preview__/overflow-guard.mjs

There is **no `LEGS` array** — `grep -rn LEGS cloud/priv/static/__preview__/` returns only two
prose comments. The structure is `const DEFECTS = [...17 ids...]` plus 17 `if (requested.includes(<id>))`
blocks in the SAME ORDER. The tail (after `W24-theater-failed-hostname-whole`) is the anchor D236
proved conflicts; it is RESERVED, not first-come.

## R7 — s7's blast radius reaches a harness its gate does not run

    grep -n 'scenarios.mjs' cloud/priv/static/__app.test.mjs | head -3

`__app.test.mjs` imports `./__preview__/scenarios.mjs`. `cch-w24-s7`'s filed gate
(`smoke.mjs && breakpoint-sweep`) omits `__app.test.mjs` while editing `scenarios.mjs` —
wave 24's defect shape, one file over.

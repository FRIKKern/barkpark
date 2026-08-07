# dr-w7 — fence and merge order, re-derived at builder-launch time (2026-08-07)

Tip at derivation: `origin/main = ef77af2748ceda54fdd6e078f71a6e6044b55439` (re-checked unchanged after every run below).

## THE TRAP THAT MUST BE RE-RUN FIRST — the checkout is SHALLOW

`/Volumes/SATECHI/github/barkpark` was a shallow clone (`.git/shallow`, 2 entries). On a shallow
checkout `git merge-tree --write-tree` exits **128** with `fatal: refusing to merge unrelated
histories` for any PR head whose merge base is below the graft line — and a naive
`&& echo CLEAN || echo CONFLICT` reports that as **CONFLICT**. #9920 reported a false CONFLICT
this way while GitHub itself said MERGEABLE.

    git rev-parse --is-shallow-repository        # must print false BEFORE trusting any merge-tree
    git fetch --unshallow -q origin              # ~minutes; one time

## RE-DERIVE (zsh-safe; the `set -- $pair` idiom in the original brief does NOT word-split in zsh)

    cd /Volumes/SATECHI/github/barkpark
    git fetch -q origin main
    PRS="9857 9876 9887 9888 9889 9890 9905 9917 9918 9919 9920 9921 9922 9929 9930"
    for n in $(echo $PRS); do
      git fetch -q origin pull/$n/head:refs/tmp/pr$n --force
      printf '#%s vs main: ' $n
      git merge-tree --write-tree origin/main refs/tmp/pr$n >/dev/null 2>&1 && echo CLEAN || echo CONFLICT
    done
    # full 105-pair matrix
    for a in $(echo $PRS); do for b in $(echo $PRS); do
      [ "$a" -lt "$b" ] || continue
      git merge-tree --write-tree refs/tmp/pr$a refs/tmp/pr$b >/dev/null 2>&1 || echo "#$a x #$b: CONFLICT"
    done; done
    # cumulative sequential stack, both directions (order-independence proof)
    CUR=$(git rev-parse origin/main)
    for n in 9876 9905 9890 9888 9889 9887 9929 9930 9857 9917 9918 9919 9920 9921 9922; do
      T=$(git merge-tree --write-tree $CUR refs/tmp/pr$n | head -1) || { echo "STOP $n"; break; }
      CUR=$(git commit-tree $T -p $CUR -p refs/tmp/pr$n -m sim); echo "merged #$n -> $CUR"
    done

## MAKE THE CHECK ABLE TO FAIL (mutation proof — never quote a green without this)

    git fetch -q origin pull/6086/head:refs/tmp/pr6086 --force
    git merge-tree --write-tree origin/main refs/tmp/pr6086 2>&1 | grep CONFLICT
    # => CONFLICT (content): Merge conflict in .claude/workflows/bp-epic-cycle.workflow.js

## HUNK-BAND MAP (the fence question merge-tree cannot answer)

    for n in 9888 9889 9918; do printf '#%s ' $n
      git diff origin/main...refs/tmp/pr$n -- cloud/lib/barkpark_cloud/web/router.ex \
      | grep '^@@' | sed -E 's/^@@ -([0-9]+),([0-9]+).*/\1 \2/' \
      | awk '{printf "%d-%d ", $1, $1+$2-1}'; echo; done

Result (old-file coords): #9888 `478-483 8759-8764`; #9889 `55-60 1315-1320 7735-7741`;
#9918 `268-274 2056-2062 2220-2226 4299-4306 4335-4340 4357-4364 4660-4665 4871-4881 4907-4913
5052-5059 8287-8294`. Nearest separation between any two PRs = **203 lines** (#9918 274 → #9888 478),
not D94's 423: D94's stated band `2059–8291` misses #9918's alias hunk at 268 entirely.

## THE SLICE-LEVEL FENCE (what actually binds wave 7's builders)

    D=/tmp/f; mkdir -p $D
    for n in $(echo $PRS); do git diff --name-only origin/main...refs/tmp/pr$n > $D/$n.txt; done
    grep -l 'internal/cli/cloud_status_cmd.go' $D/*.txt   # => 9887 ONLY
    grep -l 'internal/agent/report.go'         $D/*.txt   # => 9888 ONLY
    git diff origin/main...refs/tmp/pr9887 -- internal/cli/cloud_status_cmd.go | grep '^@@'
    # 17-22 24-52 60-67 73-93 99-107 109-116 118-135 460-471  (file is 489 lines on main)

`attentionDetail` is at `internal/cli/cloud_status_cmd.go:123` on main — **inside** #9887's
`118-135` hunk, which rewrites the function and adds `unmeteredMarker`. S3's `degraded` arm and
S2's release-pin render both land there. #9888's report.go bands stop at 550; the space probe
(`gatherSpace` 765, `parseDuTree` 969, `parseHumanBytes` 1023) lives at 762-1051 — region-disjoint.

## SPACE HAS NO READ SURFACE, EVEN WITH #9889

    git grep -n 'normalize_space' refs/tmp/pr9889 -- cloud/lib
    # => only cloud/lib/barkpark_cloud/telemetry.ex (definition) and one router COMMENT.
    # Zero production call sites; #9889 wires POST /v1/agent/space (write) and no GET.

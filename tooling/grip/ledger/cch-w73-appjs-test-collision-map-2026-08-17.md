<!-- doc-tier: cold | canonical-for: cch-w73-appjs-test-collision-map re-derivation | budget: 400tok -->

# cch-w73 __app.test.mjs foreign-PR collision map — re-derivation

VERDICT: the two open touchers of cloud/priv/static/__app.test.mjs (#10006, #6028)
both land NEAR THE TOP of the file, not at the tail. Wave-72 tests appended at the
tail (lines 21687-21741, file ends 21741). Wave-73 tail-append convention => NO
textual collision with either foreign PR. app.js hunks of both stay clear of the
ERRORS map, friendly(), the github card, deployRefusalCopy, and createAndDeploy/
runDeploy handler regions.

## Re-derive the test-file landing points

    gh pr diff 10006 | grep -E '^@@|^diff'   # __app.test.mjs hunk: @@ -1561,7 +1561,136 @@
    gh pr diff 6028  | grep -E '^@@|^diff'    # __app.test.mjs hunk: @@ -3574,6 +3574,37 @@
    git show origin/main:cloud/priv/static/__app.test.mjs | wc -l            # 21741
    git show origin/main:cloud/priv/static/__app.test.mjs | grep -nE '^test\(' | tail -1
        # 21734 test("cch-w72-s2: ...") — w72 tests appended at tail

## Re-derive app.js region boundaries (origin/main)

    git show origin/main:cloud/priv/static/app.js | grep -nE \
      'var ERRORS|function friendly|githubCardHtml|deployRefusalCopy|createAndDeploy|runDeploy'
        # ERRORS 179 | friendly 366 | githubCard 3271-3390 | deployRefusalCopy 13008
        # createAndDeploy 14397 | runDeploy 14561
    # 10006 app.js hunks: 921-1436, 20778  -> all outside every region above
    # 6028  app.js hunks: 4557,5436-5672,12089,18312 -> all outside every region above

## #6028 aliveness

    gh pr view 6028 --json state,isDraft,mergeable,updatedAt,commits \
      --jq '{state,mergeable,updatedAt,last:.commits[-1].committedDate}'
        # OPEN, not draft, mergeable=CONFLICTING, last commit 2026-07-31T04:24:40Z
        # updatedAt 2026-08-11 (metadata, not a commit). 17 days stale, conflicts main.
        # Does not bind wave-73: needs a rebase to merge; surfaces never overlap error-copy.

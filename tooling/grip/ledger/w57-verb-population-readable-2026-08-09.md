# W57 V1/V2 — which terminal-verb population a dump script can ACTUALLY read

Re-derivation recipes. Everything below was run against `origin/main` @ `0239dd4ee`.

## 0. The working tree's app.js is NOT origin/main — read from git, always

    git diff --stat origin/main -- cloud/priv/static/app.js
    #  cloud/priv/static/app.js | 5296 ++++--------  590 insertions(+), 4706 deletions(-)

A probe run against the checked-out file reports `d428_reachable` all-`undefined`
and `decommission:live` in 360/360 combos (the authority argument appears
ignored). Both are artifacts of the stale worktree copy, not facts about the
console. Extract first:

    git show origin/main:cloud/priv/static/app.js > /tmp/w57_app.js

## 1. The probe

`/tmp/w57_verb_dump.mjs` (this wave's copy; model =
`cloud/priv/static/__preview__/__lifecycle_state_dump.mjs`). Loads the shipped
app.js verbatim in a `node:vm` sandbox with `document.readyState="loading"`, so
`init()` stays merely registered and no boot path runs. It prints
`__bpTestHook.lifecycleVerbs`, drives `lifecycleActionsModel/4` over
8 payloads x 5 box states x 3 authorities x 3 authority-states = 360 combos, and
reports `typeof hooks[n]` for each of D428's seven identifiers.

    node /tmp/w57_verb_dump.mjs /tmp/w57_app.js

## 2. Results (origin/main)

    lifecycleVerbs        : archive resurrect adopt audit pause decommission   (6)
    paintedVerbs          : identical set; paintedEqualsDeclared = true
    distinctVerbSequences : 2 — the full six, or "decommission" alone (degrade)
    paintedPairs          : decommission:live 120 / decommission:disabled 240
                            each other verb: cli 45 / disabled 90
    d428_reachable        : runDecommission=function, attachDomain=function,
                            retryInstance/removeInstance/updateInstance/
                            rollbackInstance/patchAutoupdate = undefined  (2 of 7)

## 3. Mutation proof — the population read can LOSE

    sed 's/{ verb: "audit", label: "Audit" },/&\n    { verb: "incinerate", label: "Incinerate" },/' \
      /tmp/w57_app.js > /tmp/w57_app_mut.js
    node /tmp/w57_verb_dump.mjs /tmp/w57_app_mut.js | grep -c incinerate   # 6

A verb added to `LIFECYCLE_VERBS` shows up in `lifecycleVerbs`, `paintedVerbs`,
`paintedModes`, `paintedPairs` and `distinctVerbSequences` with no probe edit.
That is the ADD direction, driven.

## 4. The server-side population is SCAN-readable, not run-readable

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n delete_barkpark
    # 2242 2465 6368 6394 9155
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'post "/v1/billing/cancel"'
    # 5728

`BarkparkCloud.Web.Router` keeps no runtime route table. The in-tree precedent
for a source-derived population is
`cloud/test/barkpark_cloud/web/router_ability_matrix_test.exs:40` (`@router_source`
= `Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)`) scanning at
`:187-188`. Note the path: `barkpark_cloud/web/router.ex`. The charter's cited
`cloud/lib/barkpark_cloud_web/router.ex` does not exist:

    git show origin/main:cloud/lib/barkpark_cloud_web/router.ex
    # fatal: path ... does not exist in 'origin/main'

## 5. The six CLI chips are honest

    git show origin/main:internal/cli/cloud_instance_cmd.go | sed -n '62,84p'

Dispatches `archive resurrect decommission adopt audit` (via `cloud.Verb*`) and
`pause|resume`. Every command the rail prints as a chip exists.

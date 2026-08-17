# w48 — refusal-copy doctrine ruling: re-derivation recipes

Baseline `origin/main` = `fc27f0d7499046c2a5d511f2334f3fe1bc5878f7`.
All recipes run inside a full-tree archive, never the primary checkout:

    D=$(mktemp -d); git archive origin/main | tar -x -C $D
    cp -R /Volumes/SATECHI/github/barkpark/cloud/deps  $D/cloud/deps
    cp -R /Volumes/SATECHI/github/barkpark/cloud/_build $D/cloud/_build

## R1 — the two clauses of the launch remedy, proved end to end (Elixir)

Probe file (written into the archive only, never committed):
`$D/cloud/test/barkpark_cloud/web/w48_remedy_reachability_probe_test.exs`

    cd $D/cloud && CC=clang MIX_ENV=test mix test \
      test/barkpark_cloud/web/w48_remedy_reachability_probe_test.exs

Asserts, over the real router: a PLAIN MEMBER `GET /v1/teams/:id/members` → 200 with
all three roles + emails; a PLAIN ADMIN `PATCH /v1/teams/:id/members/:uid {role:"admin"}`
→ 200; and `Authz.authorize(m, team, :launch)` flips `{:error,:forbidden}` → `:ok`
after that grant (the remedy TERMINATES).

## R2 — the two payload shapes POST /v1/launch actually emits

`$D/cloud/test/barkpark_cloud/web/w48_launch_required_scope_probe_test.exs`

    cd $D/cloud && CC=clang MIX_ENV=test mix test \
      test/barkpark_cloud/web/w48_launch_required_scope_probe_test.exs

    session member -> {"error":"forbidden","scope":"team","required":"admin"}
    PAT w/o deploy -> {"error":"forbidden","scope":"token","required":"deploy"}

## R3 — what the console renders for each shape (node, no test framework)

`$D/cloud/priv/static/w48probe.mjs` — a 12-line copy of `__app.test.mjs`'s vm
sandbox that grabs `hooks.newLaunchRefusalToast` and `hooks.friendly`, then prints
the rendered sentence for each shape above plus the bare 403.

    cd $D/cloud/priv/static && node w48probe.mjs

## R4 — the remedy's addressee may not exist on the roster

`$D/cloud/test/barkpark_cloud/web/w48_remedy_addressee_probe_test.exs`

    cd $D/cloud && CC=clang MIX_ENV=test mix test \
      test/barkpark_cloud/web/w48_remedy_addressee_probe_test.exs

Owner+member team → roster roles `["member","owner"]`, rows labelled `admin` = 0.
Last-owner demote/remove → `409 {"error":"last_owner"}` (an authority-holder always
exists; only its LABEL may be absent).

## R5 — the fabricated default is load-bearing for the PRE-HOC caller (mutation)

    cd $D/cloud/priv/static && cp app.js /tmp/app.js.bak
    perl -0pi -e 's/\|\| "admin"/|| ""/' app.js   # narrow to the :17344 occurrence
    node __app.test.mjs 2>&1 | grep -E '^# (tests|pass|fail)|not ok'
    cp /tmp/app.js.bak app.js

Neutralising `|| "admin"` reds 5 of 988 — `cch-w36-s1` (the post-hoc toast) and FOUR
`cch-w47-s1` tests (the pre-hoc runway refusal). One function, two evidence regimes.

## R6 — read-only pins (no run needed)

    git show origin/main:cloud/priv/static/app.js       | sed -n '218p;223p;264p;17343,17350p'
    git show origin/main:cloud/priv/static/app.js       | sed -n '11605,11607p;11629p'
    git show origin/main:cloud/priv/static/app.js       | sed -n '2048,2052p'   # archives OMIT
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4138,4140p;6342,6343p;7086,7088p;8312,8321p'
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex   | sed -n '259,270p'

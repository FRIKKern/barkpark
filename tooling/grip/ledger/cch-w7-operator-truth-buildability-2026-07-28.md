# cch-w7 — operator-truth buildability + PR #6028 collision (re-derivation recipes)

Tree: `origin/main` @ `69a9d591d` (fetched 2026-07-28; the strategize brief quoted
`f38c01920` — origin has moved 1+ commits since). Host: local dev laptop, quiet
(no wave builders running). Node local = v22.22.0; CI `console-unit` pins node 20.

Every command below is literal and re-derives one row of the verifier's report.

## R1 — mock.js is stateless: the browser preview reports a revoke over an unchanged list

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'export function route'
    #  2999:export function route(name, method, path, state) {
    grep -n 'mod.route(' cloud/priv/static/__preview__/mock.js
    #  114:        var res = mod.route(scen, method, path);      <- 3 args, no state bag

Behavioural proof, no vm, no flag, node-20-shaped (this is also the GATE shape):

    node -e '
    import("./cloud/priv/static/__preview__/scenarios.mjs").then(({route})=>{
      const S="account-modal-revoke", st={};
      const g=route(S,"GET","/v1/account/sessions",st);
      const v=g.body.sessions.find(s=>!s.current).id;
      const n1=g.body.sessions.length;
      const d=route(S,"DELETE","/v1/account/sessions/"+v,st);
      const n2=route(S,"GET","/v1/account/sessions",st).body.sessions.length;
      const a1=route(S,"GET","/v1/account/sessions").body.sessions.length;
      route(S,"DELETE","/v1/account/sessions/"+v);
      const a2=route(S,"GET","/v1/account/sessions").body.sessions.length;
      console.log(JSON.stringify({stateful:[n1,d.status,n2],stateless:[a1,a2]}));
    })'
    # {"stateful":[4,200,3],"stateless":[4,4]}

Source assertion that FAILS on main today and passes after the one-arg fix:

    node -e 'console.log(/mod\.route\(\s*scen,\s*method,\s*path\s*,/.test(
      require("fs").readFileSync("cloud/priv/static/__preview__/mock.js","utf8")))'
    # false

The lie is visible because app.js REFETCHES after a successful DELETE:

    git show origin/main:cloud/priv/static/app.js | sed -n '1135,1139p'
    #  1138:              loadSessions(); // repaints the whole list

## R2 — the destroy family is 8 DELETE handlers wide; only 2 are state-aware

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'method === "DELETE"'
    # 3134 3149 3196 3242 3393 3468 3480 3498
    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'if (state)'
    # 3138 3152     <- only the two session handlers mutate

Token revoke measured (broken in BOTH harnesses, state bag or not):

    node -e 'import("./cloud/priv/static/__preview__/scenarios.mjs").then(({route})=>{
      const st={}; const b=route("tokens-populated","GET","/v1/tokens",st).body.tokens.length;
      const d=route("tokens-populated","DELETE","/v1/tokens/tok_ci",st);
      const a=route("tokens-populated","GET","/v1/tokens",st).body.tokens.length;
      console.log(JSON.stringify({before:b,status:d.status,after:a}));})'
    # {"before":4,"status":200,"after":4}

## R3 — no workflow runs mock.js / smoke.mjs / serve.mjs / seal-predicate*

    grep -rn "mock.js\|smoke.mjs\|serve.mjs\|seal-predicate\|__app.test.mjs\|__css_check\|cssom-parity" .github/workflows/
    # console-harness.yml only: node --check app.js | node --test __app.test.mjs
    #                            | __css_check.mjs | __preview__/cssom-parity.mjs

Header staleness (claims 415, suite is 714 on origin/main):

    sed -n '7p' .github/workflows/console-harness.yml
    node --test cloud/priv/static/__app.test.mjs 2>&1 | grep '^# tests'
    # (on a worktree at origin/main) # tests 714

## R4 — the theme "server echo" EXISTS (the direction's doubt is refuted)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5907,5916p'   # site: site_json(updated, bp)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '9715p'        # theme: s.theme

…but the reset path is CORRECT server-side, so the reconcile is low-value:

    cd cloud && mix run --no-start -e '
      alias BarkparkCloud.Registry.Site
      for a <- [%{"theme"=>""},%{"theme"=>"fjord"},%{"theme"=>"vaporwave"},%{"doc_type"=>""}] do
        cs = Site.settings_changeset(%Site{theme: "ember", doc_type: "post"}, a)
        IO.puts(inspect(a)<>" valid="<>inspect(cs.valid?)<>" changes="<>inspect(cs.changes))
      end'
    # %{"theme" => ""}       valid=true  changes=%{theme: nil}     <- clear WORKS
    # %{"doc_type" => ""}    valid=true  changes=%{}               <- silent no-op 200

Client/server theme enums agree today (4 each), asserted by nothing:

    git show origin/main:cloud/priv/static/app.js | grep -n 'var SITE_THEMES'          # 9412 evergreen ember fjord charple
    git show origin/main:cloud/lib/barkpark_cloud/registry/site.ex | grep -n known_site_themes  # 294 charple ember evergreen fjord

## R5 — keyset tiebreak anchors reproduce verbatim

    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex      | sed -n '439p;445,446p'
    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '545p;555,556p'
    git show origin/main:cloud/priv/static/app.js | sed -n '2787,2793p;12349,12355p'

## R6 — PR #6028 collision surface

    gh pr diff 6028 --name-only
    gh pr view 6028 --json mergeable,mergeStateStatus,updatedAt
    # MERGEABLE / UNSTABLE / 2026-07-23T18:04:20Z
    gh pr diff 6028 | grep -n '^@@'      # app.js hunks @4450 5323 5357 5469 11457 17034
    for p in $(gh pr list --state open --limit 100 --json number -q '.[].number'); do
      gh pr diff $p --name-only | grep -q '^cloud/' && echo $p; done
    # 6028 only

Touches NEITHER mock.js, scenarios.mjs, serve.mjs, accounts.ex nor notifications.ex.

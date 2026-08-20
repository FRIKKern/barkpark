# cch-w69 — the fixture-shape pin's real reader paths, and the full count-pin census

Verifier lane `smoke-pins-and-emit`, 2026-08-17. Every command below is run from the
repo root unless a `$D` prefix appears; `$D` is a read-only extraction of
`origin/main` (`27e40616`) made because the primary checkout was BEHIND main at
dispatch (`a6535504`, six commits behind, `cloud/priv/static/app.js` differing by
209 lines). Re-make it with:

    D=/tmp/om && mkdir -p $D && git archive origin/main cloud/priv/static design | tar -x -C $D

## 1 — the #site-github authority path is the envelope's TOP-LEVEL `role`

    git show origin/main:cloud/priv/static/app.js | sed -n '16338,16341p'
    # function instanceAdminAuthority() {
    #   if (meState() !== "loaded") return "unknown";
    #   return (meCache.role === "owner" || meCache.role === "admin") ? "grant" : "refuse";
    # }

`meCache` is assigned in exactly one place — `absorbMe()`, `meCache = r.data`
(`app.js:16109` on the stale tree / same function on main) — so `meCache.role` IS
`/v1/me`'s top-level `role`, NOT `team_authority.role`.

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'team_authority:' -A6
    # both keys are minted from ONE `team_role` binding in one map literal

Two DIFFERENT readers exist and must not be conflated:

| reader | path it reads | gates |
|---|---|---|
| `instanceAdminAuthority()` / `launchAuthority()` | `meCache.role` (top level) | `#site-github`, instance band, launch |
| `teamAuthorityState()` | `meCache.team_authority.admin` | members band (`app.js:16159`, `:20617`) |

The sweep's own selector agrees: `member-authority-sweep.mjs` `meRole()` reads
`r.body.role`.

## 2 — green baselines on origin/main (exit codes, not printed lines)

    cd $D
    node cloud/priv/static/__preview__/smoke.mjs               # exit 0 · "all 111 scenarios rendered"
    node design/emit-fence.test.mjs                            # exit 0 · # tests 9 / # pass 9 / # fail 0
    node cloud/priv/static/__preview__/member-authority-sweep.mjs
    # exit 0 · 10 member actor(s) · 67 control(s) · 24 hook row(s) · 0 finding(s) · 0 guard failure(s)
    node cloud/priv/static/__me_envelope_census.mjs             # exit 0 · 29 key paths, no MISSING, no INVENTED

## 3 — count/shape pin census: what a 112th scenario trips

    git grep -n 'PIN_[A-Z_]* = \|const FLOOR_[A-Z_]* = ' origin/main -- cloud design scripts .github

Only three equality/floor constants exist in the console harness, all in one file:

    cloud/priv/static/__preview__/member-authority-sweep.mjs:339  const PIN_MEMBER_SCENARIOS = 10;
    cloud/priv/static/__preview__/member-authority-sweep.mjs:340  const PIN_TOTAL_SCENARIOS  = 111;
    cloud/priv/static/__preview__/member-authority-sweep.mjs:343  const FLOOR_CONTROLS = 60;   # floor, cannot trip on growth
    cloud/priv/static/__preview__/member-authority-sweep.mjs:344  const FLOOR_MOUNTS   = 20;   # floor, cannot trip on growth

But `PIN_TOTAL_SCENARIOS` is NOT the only corpus-size guard. Mutation (append to
`scenarios.mjs` just above `export const SCENARIO_NAMES`):

    SCENARIOS["zz-mutation-probe"] = JSON.parse(JSON.stringify(SCENARIOS["site-member"]));

| guard | exit | how it names the growth |
|---|---|---|
| `member-authority-sweep.mjs` | 1 | `FAIL corpus-size — 112 scenario(s) committed (pinned 111) — the corpus grew by 1` |
| `breakpoint-sweep.mjs` (`SCENARIO_RESIDUE`, name-keyed, 85 entries) | 2 | `UNLISTED scenario "zz-mutation-probe" (family hash:#site) — no cell renders it and SCENARIO_RESIDUE does not carry it.` |
| `breakpoint-sweep.test.mjs` | 1 | 4 of 54 fail: #17 coverageReport, #21 import proof, #44 "the census reconciles: 112 scenarios…", #50 "A 101st SCENARIO IS REFUSED BY NAME" |
| `smoke.mjs` (`EXPECTATIONS` both-ways census) | 1 | `census guard failed — every scenario needs an expectation, both ways` |
| `__me_envelope_census.mjs` | **0** | key-shape only; blind to corpus size |

So a new scenario costs FIVE edits, not one: the `EXPECTATIONS` row, the
`SCENARIO_RESIDUE` entry + its `// <family> — N` header, `PIN_TOTAL_SCENARIOS`,
and `PIN_MEMBER_SCENARIOS` only if the new actor answers `role:"member"`.

## 4 — the fixture-shape mutations, one at a time

`SCENARIOS["rollback"]` measured shape (probe over `route()` + `data`):

    rollback /v1/me role (top-level): "owner"
    rollback /v1/me team_authority: {"role":"owner","admin":true,"owner":true}
    acme-web current_deployment_id="…d1" deployCount=3 -> canSiteRollback=true
    acme-blog current_deployment_id=null deployCount=0 -> canSiteRollback=false

`#site-rollback`'s real gate (`app.js:12471`) is **not** a "rollbackable" flag:

    var canSiteRollback = !!site.current_deployment_id && (deployments && deployments.length >= 2);

| mutation appended to `scenarios.mjs` | smoke.mjs | member-authority-sweep |
|---|---|---|
| `SCENARIOS["rollback"].data.me.role = "member"` | **exit 0, silent** | exit 1 — `FAIL #site-github … privileged rollback → 0` + `FAIL actor-set — 11 … (pinned 10/111)` |
| `…data.deployments = …slice(0,1)` | exit 1 — `FAIL rollback — #site-body missing ">Roll back to this<"` (blames the per-ROW link, names no fixture) | **exit 0, blind** |
| `team_authority.admin = false` while top-level `role` stays `"owner"` | **exit 0, 111 rendered** | **exit 0** (and the me-envelope census also 0) |

Reading: the actor-demotion half of `cch-w68-bl-smoke-rollback-fixture-shape-pin`
is ALREADY pinned — by the sweep, by name, with the correct diagnosis. The
unpinned halves are (i) `canSiteRollback`'s two-term condition, which reds under a
borrowed name, and (ii) the top-level-`role` ↔ `team_authority` agreement, which
nothing in the harness can lose — the live instance of charter **D285**'s ruling
that `SCENARIO_RESIDUE` is name-keyed and content edits move no name.

## 5 — `#site-load-retry` has no driven attach

    git grep -n 'site-load-retry' origin/main -- cloud/priv/static
    # app.js:531        the button is minted in siteLoadFailureHtml
    # app.js:12199      var slr = $("#site-load-retry");   <- the attach, undriven
    # smoke.mjs:1012    assert.equal(reg.get("site-load-retry"), undefined)   <- NEGATIVE control only
    # __app.test.mjs:20484  assert.match(html, /id="site-load-retry"/)        <- string shape only

No gate boots the degrade branch and asserts a handler. Criterion 2's premise
holds as written.

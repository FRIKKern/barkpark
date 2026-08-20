# w45 counter-truth — baselines re-derived, and what the binding census actually verifies (2026-08-07)

Tree: `origin/main = b00d793c0e2065e98a03fed6c4356245d897ee3a`, extracted clean, host load ~2.25.

## Re-derivation recipes

FULL-TREE extraction (a `cloud`-only extract manufactures 4 ENOENT failures — 946/4):

    S=/tmp/w45full; rm -rf $S; mkdir -p $S; git archive origin/main | tar -x -C $S

Baselines (run from `$S/cloud/priv/static`):

    node --test __app.test.mjs                    # 950/950 pass, 0 fail
    node --test __preview__/breakpoint-sweep.test.mjs   # 51/51 pass
    node __preview__/breakpoint-sweep.mjs         # rc 0 — 106 · 25 distinct/26 cells · 81 residue · 13 families
    node __preview__/smoke.mjs                    # rc 0 — "all 106 scenarios rendered"
    node __binding_census.mjs                     # rc 0 — 79 · 40 elevated · 22 predicated · 18 unpredicated
    node __me_envelope_census.mjs                 # rc 0 — 29 key paths, 94/106 scenarios answer /v1/me 200
    node __reason_arm_census.mjs                  # rc 0
    node __unknown_census.mjs                     # rc 0 — 5-site pin
    node __css_check.mjs                          # rc 0 — 877 classes, 96 tokens, 576 contrast pairs

Derive scenarioReport directly (proves 81 is COMPUTED, not only typed):

    node -e 'import("./__preview__/breakpoint-sweep.mjs").then(m=>{console.log(Object.keys(m.SCENARIO_RESIDUE).length, JSON.stringify(m.scenarioReport({})))})'

## Census mutation recipes (all with `md5 -q app.js` unchanged before/after)

Restore with `git show origin/main:cloud/priv/static/__binding_census.mjs`.

- M4 — predicate names a function absent from app.js → **rc 0**:
  `sed -i '' 's/predicate: "launchCheckoutAuthority"/predicate: "launchCheckoutAuthorityZZZ_absent"/g' __binding_census.mjs`
- M6 — flip one `predicate: null` → a made-up name AND EXPECT 22/18 → 23/17 → **rc 0**, headline prints "THE 17 UNPREDICATED".
- M7 — flip `elevated: true` → `false` on `updateInstance` (router: `require_primary_team_admin`) + EXPECT 40/18 → 39/17 → **rc 0**.
- M8 — change `updateInstance`'s `auth_fn: A_PTADMIN` → `A_USER` → **rc 0**, and the census PRINTS `Auth.require_user` for a primary-team-admin route.
- M9 (control, the one that loses) — change its `route` to a bogus path → **rc 1**, `pinned (79) · live (79)` set diff refuses.

Conclusion: the census verifies (a) the call-site SET against app.js (arm 1, keyed `fn|VERB route`) and (b) `context_fn` targets exist in source (check 2e). It does NOT verify `predicate`, `elevated`, or `auth_fn` — those three are typed prose the headline is computed from.

## Sweep mutation (it can lose)

    perl -0pi -e 's/\n  "panel-overview-member": "hash:#instance",//' __preview__/breakpoint-sweep.mjs
    node __preview__/breakpoint-sweep.mjs   # rc 2 — UNLISTED scenario "panel-overview-member"

## Structural floor on "unpredicated → 0"

`__binding_census.mjs` check (2d), lines 625-644, hard-requires `submitProviderCred`'s
`predicate` to stay `null` (`bp.predicate !== null` → die2). The unpredicated column has a
FLOOR OF 1 while 2d stands. 18 → 11 (the D428 seven) is the reachable number, and it is
exactly the EXPECT `{total:79, elevated:40, predicated:29, unpredicated:11}` already written
into the open row `cch-w38-bl-three-elevated-verbs-still-unpredicated`.

## Gate reach

    grep -rn "binding_census\|breakpoint-sweep\|me_envelope\|reason_arm\|unknown_census" .github scripts Makefile .githooks

Zero hits. Of the console instruments only `__app.test.mjs`, `smoke.mjs`,
`seal-predicate.test.mjs` and `__css_check.mjs` are wired in `console-harness.yml`.

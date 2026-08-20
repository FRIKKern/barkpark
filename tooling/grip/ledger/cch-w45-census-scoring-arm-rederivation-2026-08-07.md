# cch-w45 — the census scoring arm: re-derivation recipes (2026-08-07)

Verifier lane `census-scoring-arm`, wave 45 of the Cloud Console Hardening epic.
Everything below was run against `origin/main = b00d793c0e2065e98a03fed6c4356245d897ee3a`
in a clean `git archive` extraction, never the primary checkout.

## 0 — the extraction every recipe below assumes

```sh
S=/tmp/w45v1; rm -rf $S; mkdir -p $S
git archive origin/main cloud | tar -x -C $S
cd $S/cloud/priv/static && node __binding_census.mjs; echo BASE_RC=$?
# BASE_RC=0 · "79 call sites · 40 ELEVATED · 22 PREDICATED · 18 UNPREDICATED"
```

## 1 — M4: a `predicate` that names nothing exits 0

```sh
cd $S/cloud/priv/static && cp __binding_census.mjs bc_m4.mjs
# in bc_m4.mjs replace the submitInlineProviderCred row's
#   predicate: "providerCanWrite"  ->  predicate: "zzzNotARealPredicate"
node bc_m4.mjs; echo M4_RC=$?      # M4_RC=0, and the table prints the fake name
grep -c zzzNotARealPredicate app.js # 0 — the name exists nowhere in the console
```

## 2 — M6: PIN + EXPECT moved to 17 with app.js BYTE-UNCHANGED exits 0

```sh
cd $S/cloud/priv/static && cp __binding_census.mjs bc_m6.mjs
# runDecommission row: predicate: null -> predicate: "instanceAdminAuthority"
# EXPECT: { total: 79, elevated: 40, predicated: 23, unpredicated: 17 }
md5 app.js; node bc_m6.mjs; echo M6_RC=$?; md5 app.js
# M6_RC=0 · md5 identical before/after · "THE 17 UNPREDICATED ELEVATED WRITES"
```

## 3 — M6b: the SAME move on `submitProviderCred` exits 2

```sh
cd $S/cloud/priv/static && cp __binding_census.mjs bc_m6b.mjs
# submitProviderCred row: predicate: null -> "providerCanWrite"; EXPECT 23/17
node bc_m6b.mjs; echo M6B_RC=$?    # M6B_RC=2
# "FAIL(2): the POST /v1/providers discrimination control is broken."
```

Check (2d) is a live self-veto for exactly one fix. PR #10085 retires the two
directional sub-clauses and is CONFLICTING with main.

## 4 — the NAIVE arm reds 19 of 22 true rows

Probe: for each predicated ELEVATED PIN row, require the predicate identifier to
(a) be declared in app.js AND (b) appear textually inside the span of the
function that issues the `api()` call.

```sh
# /tmp/w45v1/naive.mjs re-implements the census's own indexFunctions()/innermost()
node /tmp/w45v1/naive.mjs $S/cloud/priv/static/app.js /tmp/w45v1/rows.json
# 18 RED of 21 tested rows (onNotifCellToggle carries TWO pin rows on one
# fn|verb, so the true count is 19 RED of 22). Clause (a) alone: 22/22 pass.
```

The three survivors are the only rows where the predicate is evaluated in the
same function as the write: renderLaunchPlan, renderNewPricing, openRoleModal.

## 5 — the RENDER-PATH-WALK variant has NO separating threshold

Probe: min hop distance over a textual call graph (edge F→G iff F's span names
identifier G) from any function mentioning the predicate to the call-site
function.

```sh
node /tmp/w45v1/walk.mjs $S/cloud/priv/static/app.js /tmp/w45v1/rows.json
#   TRUE rows: hops 0,0,0,1,1,1,1,2,2,2,2,2,3,3,3,6,6 + 1 UNREACHABLE at MAX=8
node /tmp/w45v1/walk.mjs $S/cloud/priv/static/app.js /tmp/w45v1/cross.json
#   98 deliberately-WRONG (fn × unrelated real predicate) pairings:
#   1 at hops=2, 5 at hops=4, 28 at 5, 21 at 6, 20 at 7, 18 at 8, 5 UNREACH
```

Overlap at every threshold ≥2. Threshold 4 admits `disconnectGithub` predicated
by `operatorRouteAllowed` and `submitLaunchFlow` by `launchCheckoutAuthority`.

WHY it cannot work, structurally: the true fence for `sendTestNotification` is
`testBtn.hidden = !canManage` (app.js:3697-3698, inside `renderNotifications`) —
a DOM VISIBILITY relation, not a call relation. No call-graph walk of any depth
can see it. That row is UNREACHABLE at MAX=8 while nonsense pairings reach in 5.

## 6 — ARM(A), the cheapest arm that reds M4 at zero false-red cost

Insert immediately above `const EXPECT`: every non-null `PIN[].predicate` must
match `function <n>(` or `(const|let|var) <n> =` in app.js, else `process.exit(2)`.

```sh
node $S/cloud/priv/static/bc_arm.mjs;   echo ARM_CLEAN_RC=$?  # 0, "all 23 pinned predicates are declared"
node $S/cloud/priv/static/bc_m4arm.mjs; echo ARM_M4_RC=$?     # 2, names the row
node $S/cloud/priv/static/bc_m6arm.mjs; echo ARM_M6_RC=$?     # 0 — ARM(A) does NOT defend M6
```

ARM(A) catches PIN DECAY (a renamed/deleted predicate) and typos. It does not
prove the predicate fences the call site, and it does not defend the EXPECT move.

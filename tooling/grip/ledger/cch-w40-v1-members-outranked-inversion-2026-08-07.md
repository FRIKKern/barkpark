# cch-w40 v1 — re-derivation recipe: `outranked` reachability + the cost of inverting `ERRORS.forbidden`

Subject: wave 40 S1 (invert `ERRORS.forbidden`) vs. `task-ed706f4e1c616f89`
(two unwritten `FORBIDDEN_REASON_COPY` arms). Everything below re-derives from
`origin/main` only — the primary checkout is 133 `cloud/` files behind and its
`router.ex` predates cch-w37-s2 entirely, so a local grep answers FALSE-NEGATIVE.

## 0 — the checkout is not main (run first, or every later fact is a level-skip)

    git rev-parse HEAD origin/main
    grep -c cannot_grant_higher_role cloud/lib/barkpark_cloud/web/router.ex          # → 0 (STALE)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c cannot_grant_higher_role   # → 1

## 1 — materialize a runnable main tree in a scratchpad (no repo write, no branch move)

    D=<scratchpad>
    rm -rf $D/mainrepo && mkdir -p $D/mainrepo
    git archive origin/main cloud internal/taskboard/testdata internal/pdrender/testdata deploy | tar -x -C $D/mainrepo
    cd $D/mainrepo/cloud/priv/static && node --test-reporter=tap __app.test.mjs   # 919/919, rc=0
    cd $D/mainrepo/cloud/priv/static/__preview__ && node smoke.mjs                # 104/104, rc=0

(Without the three non-`cloud` paths the suite reds 4 tests on ENOENT — those
censuses read `internal/**` and `deploy/**`. That is a harness fact, not a defect.)

## 2 — the emitters, verbatim

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4950,5005p'
    #  PATCH /v1/teams/:id/members/:user_id → Auth.forbidden(conn, reason: "outranked" | "cannot_grant_higher_role")
    #  DELETE /v1/teams/:id/members/:user_id → Auth.forbidden(conn, reason: "outranked")
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '528,530p'
    #  def forbidden(conn, evidence), do: json_halt(conn, 403, Enum.into(evidence, %{error: "forbidden"}))

## 3 — drive `friendly()` with those exact bodies

Slice the copy band out of main's `app.js` and export it; do NOT hand-transcribe.

    git show origin/main:cloud/priv/static/app.js > $D/main_app.js
    { sed -n '179,324p' $D/main_app.js; echo 'export { friendly, ERRORS, forbiddenEvidenceCopy, FORBIDDEN_REASON_COPY, FORBIDDEN_ROLE_COPY };'; } > $D/h.mjs
    node -e 'import("'$D'/h.mjs").then(m=>console.log(m.friendly({error:"forbidden",reason:"outranked"})))'
    # → "Only the team owner can manage billing."

(179..324 is the exact brace-balanced span: 178 or 323 leaves the slice inside a
block and node reports `Unexpected token 'export'` — a boundary error, not a syntax bug.)

## 4 — the three variants, run as full-suite mutations against §1's green baseline

Apply to `$D/mainrepo/cloud/priv/static/app.js`, rerun both suites, restore.

| variant | edit | `__app.test.mjs` | `smoke.mjs` |
|---|---|---|---|
| B invert | `forbidden:` → `"You don't have permission to do that.",` | **7 red** | 104/104 |
| C delete | remove the `forbidden:` key | (regression probe) | — |
| ARMS only | add `outranked` + `cannot_grant_higher_role` to `FORBIDDEN_REASON_COPY` | **919/919 green** | 104/104 |
| D = B+ARMS | both | **same 7 red** | 104/104 |

The red list is identical for B and D, so the arms are pin-free: the whole test
cost belongs to the inversion.

    grep "^not ok" <tap output>
    # 95  cch-w36-s4 …billing sentence over a 403      ← operator: 'match', /team owner/
    # 908 cch-w37-s1 THE FENCE CAN LOSE …
    # 910 cch-w35-s4 POSITIVE CONTROL (RED under M1) …
    # 911 cch-w35-s4 THE OWNER GATE, MEASURED NOT ASSUMED …
    # 914 cch-w35-s4 an unwritten `required` …
    # 915 cch-w35-s4 THE FENCE IS INERT …
    # 916 cch-w35-s4 FOUR LANES FROM ONE EDIT …

A literal grep finds only **4** lines carrying the sentence in `__app.test.mjs`;
test 95 pins it as a REGEX (`/team owner/`, `:2518`). Never predict this list — run it.

## 5 — the charter conflict (read before writing any S1 D-row)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/cch.md
    grep -n "re-word\|byte-identical which D395\|D414\|D444" /tmp/cch.md

D414 forbids **deleting or re-wording** `ERRORS.forbidden` (GR46 closed
`gr-backlog-portal-retry-sentence` on the string existing). D395(b) proved
*deletion* regresses billing; §4 variant B shows *re-wording* is a different
mutation D395(b) never ran. D444's tripwire (`smoke.mjs:1957`) is fed by the
independent literal at `app.js:13531`, not by `:207` — proven green in §4.

## 6 — why the billing screens cannot be degraded by the inversion

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n require_primary_team_owner
    # 5202 / 5243 / 5278 — checkout, portal, cancel: first statement of each route
    # auth.ex:459 sends required: "owner" ⇒ forbiddenEvidenceCopy wins ⇒ :207 unreachable from billing.

## 7 — band arbitration

    for p in 10005 10006 9955 6028; do gh pr diff $p | awk '/^diff --git a\/cloud\/priv\/static\/app.js/{on=1;next}/^diff --git /{on=0} on&&/^@@/{print}'; done

Earliest open-PR hunk in `app.js` is `@@ -921` (#10006). The copy band
(179-330) is **uncontended**. In `__app.test.mjs` only #10005 appends at EOF
(`@@ -15612,3 +15632,171`), so new tests appended at the tail rebase after it.

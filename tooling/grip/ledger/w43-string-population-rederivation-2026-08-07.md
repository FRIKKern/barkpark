# W43 verifier — the three disputed populations, and the exact command that re-derives each

Tree: `git archive origin/main cloud | tar -x -C $S` at `origin/main = dad66869ef651e2ec9b79704faf434b05c542b85`.
All commands run from `$S/cloud/priv/static/__preview__`.

Every number below differs from a circulating rival ONLY by its counting rule. No rival was wrong
about the bytes; each quoted a different scope without stating it. State the rule or the number is noise.

---

## 1. The me() role-argument census

    node census.js scenarios.mjs          # balanced-paren scan, comment-aware

    raw `me(` matches ............ 100   (this is the "100 call sites" in circulation)
      - in COMMENT lines .........   9   lines 797,1021,2032,2357,2381,2495,2554,2555,3470
      - the definition (:959) ....   1
      - REAL call sites .......... .90

    third argument, over the 90 real call sites:
      "member" ..... 7   lines 2388,2439,2558,2918,3479,3612,3652
      "owner" ...... 4   lines 985 (inside operatorMe), 2371, 2406, 2423
      "admin" ...... 0
      omitted ...... 79   -> falls through `role || "owner"` at :971

RIVAL RECONCILIATION
  8 member / 5 owner  = `grep -cE 'me\(.*"member"' scenarios.mjs` — a LINE grep; counts comment
                        lines 2381 and 2555 which merely mention `me() role "member"` / `"owner"`.
  7 member / 4 owner  = explicit third arg, ALL call sites (includes :985 inside the operatorMe helper).
  7 member / 3 owner  = explicit third arg, SCENARIO call sites only (excludes :985). This is the
                        form already written into task cch-no-admin-fixture-in-the-preview-corpus.

RUNTIME AUTHORITY (beats every source scan — a scenario may reuse one fixture):

    node -e 'import("./scenarios.mjs").then(s=>{...histogram over (S[k].data||{}).me.role...})'
    ROLE HISTOGRAM: {"(no me)":10,"owner":81,"member":7,"owner+operator":6}
    scenarios with role==admin: 0
    me.teams present: 0 | me.team_authority present: 0 | user.platform_operator: 6

---

## 2. The admin-worded string population

    node adminpop.mjs     # 3 surfaces x owning scenario x that scenario's fixture role

    TOTAL admin-worded strings on the three named surfaces .......... 15
      smoke.mjs `what:` .......... 4   (962, 2175, 2372, 2463)
      smoke.mjs assert messages .. 7   (1993, 2179, 2192, 2378, 2383, 2478, 2482)
      scenarios.mjs `label:` ..... 4   (2367, 2402, 2550, 3648)

    over MEMBER fixtures .. 5  (962, 2175, 2179, 2550, 3648) — all TRUE, "non-admin"/"no admin sections"
    over OWNER  fixtures .. 10
      - HOMONYM ........... 1  smoke:2383 "the 3 real role chips render" — Admin is RENDERED DATA
                               (usr_lin's roster chip), never a claim about the actor
      - GATE-DESCRIBING ... 4  smoke:2192 "the admin page", :2378 "the admin-only invitations card",
                               :2478 "admin rows carry Delete", :2482 "every admin row" — these name
                               the TIER a view requires; an owner exceeds >=admin, so they are TRUE
      - FALSE ............. 5  names the ACTOR's role over a fixture that is role:"owner":
                               smoke.mjs:2372 what:  "Members (admin) — ..."
                               smoke.mjs:2463 what:  "Environment variables (admin) — ..."
                               smoke.mjs:1993 assert "an admin roster carries the typed-confirm Disconnect"
                               scenarios.mjs:2367 label: "Members (admin) — ..."
                               scenarios.mjs:2402 label: "Environment variables (admin) — ..."

RIVAL RECONCILIATION
  2 = `grep -cE '^\s*what:.*\(admin\)' smoke.mjs`               — smoke `what:` only
  6 = mandated grep MINUS comment lines                          — a raw source-line count. This is the
      number in cch-no-admin-fixture's description, where it is called "Six smoke assertions" — but
      2 of the 6 live in scenarios.mjs and 4 of the 6 are not assertions at all.
  9 = admin-worded strings over OWNER fixtures, minus the homonym — the form already written into
      cch-w42-s3's criterion ("5 assertion messages + 2 what: + 2 scenarios.mjs label:"). CORRECT.
      Note it is 9 to CORRECT but only 5 that are FALSE; the other 4 are gate-describing and true.
  (`grep -cE '\(admin\)|admin (rows?|roster)'` also totals 9 — a coincidence of cardinality, a
   different set. Do not use it as the derivation.)

THE PROOF THAT `(admin)` NAMES THE ACTOR, not the tier — the corpus's own convention, 100% clean:
    members-populated  role=owner   Members (admin) — ...
    members-member     role=member  Members (member) — ...
    env-populated      role=owner   Environment variables (admin) — ...
    env-member         role=member  Environment variables (member) — ...
And the contradiction sits inside ONE nine-line block: smoke.mjs:2372 says "(admin)" while
smoke.mjs:2380 asserts "the acting owner is self-tagged and gets no self-remove".

---

## 3. The scenario total

    node -e 'import("./scenarios.mjs").then(s=>console.log(Object.keys(s.SCENARIOS).length))'
    -> 104
    node smoke.mjs | tail -1
    -> all 104 scenarios rendered

  Corroborated by three independent committed literals:
    breakpoint-sweep.mjs:28   "SCENARIO  104 scenarios, 25 rendered, 79 in a COMMITTED residue literal."
    breakpoint-sweep.mjs:396  "104 scenarios · 26 cells over 25 DISTINCT"
    breakpoint-sweep.test.mjs:555 "the census reconciles: 104 scenarios, ..."

  WHERE '42' CAME FROM: nowhere in the tree. `grep -rn '\b42\b' --include='*.mjs' .` returns only
  pixel widths and an IP octet; no instrument emits 42. "All 42 rendered scenarios" is the WAVE
  NUMBER (wave 42) bleeding into a sentence that wanted a scenario count. Read it as 104.

  Stale historical totals live in smoke.mjs comments and each is labelled as measured at its time:
  :83 "all 98 scenarios", :105/:111 "all 99 scenarios", :2952 "all 101 scenarios". Not rivals.

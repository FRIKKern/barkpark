# w45 verifier — console-unit step order and what a census red suppresses

Subject: `.github/workflows/console-harness.yml` on `origin/main` = `b00d793c0e2065e98a03fed6c4356245d897ee3a`.
All rows below are re-derivable by the single command in the row. No repo state was mutated;
mutations were performed only inside `/tmp/w45full`, a `git archive origin/main` extraction.

## 1. The file, read directly (never quoted from a task body)

    git show origin/main:.github/workflows/console-harness.yml | grep -nE '^  [a-z-]+:$'

Jobs: `changes:74` `path-escape:192` `console-unit:208` `cssom-parity:526`
`tier-floor-render:660` `overflow-guard:741` `console-gate:795`.

    git show origin/main:.github/workflows/console-harness.yml | awk 'NR>=209 && NR<=522' | grep -nE '^      - name:' | cat -n

console-unit's NAMED steps, in order (offsets are +208 from file start):

     1 Setup Node
     2 Syntax-check the shipped console client
     3 Run console harness                       (__app.test.mjs)
     4 Run preview smoke harness
     5 Seal predicate tests
     6 Responsive sweep — breakpoint/screen coverage refusal
     7 Responsive sweep unit tests
     8 Bring-up retry unit tests
     9 CSS/token drift gate
    10 Elevated-write binding census (ADD + REMOVE)      file line 415/416
    11 Refusal reason-arm census                          file line 453/454
    12 /v1/me envelope census                             file line 502/503

The job's first step is an UNNAMED `- uses: actions/checkout@v4` (file line 214), so the
raw step index is 11/12/13 while the named index is 10/11/12. The claim "binding census
step 10 of 12" is TRUE under named-step counting and off-by-one under raw counting.

## 2. No step-level `if:`, no `continue-on-error` anywhere

    git show origin/main:.github/workflows/console-harness.yml | grep -nE '^\s+if:'
    # 211, 529, 663, 744, 825 — all JOB-level. Zero step-level `if:`.

    git show origin/main:.github/workflows/console-harness.yml | grep -nE 'continue-on-error'
    # 547, 576, 649, 722, 815 — every hit is inside a `#` comment BANNING it (D19).

Consequence: every step after the binding census runs under GitHub's default
`success()` condition.

## 3. What a census red actually suppresses — measured, not reasoned

Extraction (FULL tree; `cloud`-only under-extracts and produces a false red baseline):

    S=/tmp/w45full; rm -rf $S; mkdir -p $S; git archive origin/main | tar -x -C $S

Clean baseline, all ten runnable console-unit instruments in workflow order: rc=0 each,
`__app.test.mjs` 950/950.

Mutation (adds ONE unpinned elevated write to app.js, the honest shape of a census red):

    # insert before `function decommissionAction(bp, authority) {` in cloud/priv/static/app.js:
    #   function __mutantWrite() { api("POST", "/v1/account/two-factor/enroll", {}, { noBounce: true }); }
    node cloud/priv/static/__binding_census.mjs   # rc=1, "ADDED cloud/priv/static/app.js:1692", pinned (79) · live (80)

Replaying the ordered sequence under GitHub step semantics (a step runs only if all
prior steps succeeded):

     8 RAN rc=1 :: node cloud/priv/static/__binding_census.mjs
     9 SKIPPED :: node cloud/priv/static/__reason_arm_census.mjs
    10 SKIPPED :: node cloud/priv/static/__me_envelope_census.mjs

Run in ISOLATION on the same mutated tree, both suppressed censuses are rc=0. Their
verdicts are therefore unobservable in a run where the binding census reds — the job is
correctly RED (no false green reaches the merge button), but two instruments publish
NOTHING and their state that run is "I could not look", not "clean".

## 4. The suppressed instruments are exactly the ones this wave moves

`__reason_arm_census.mjs` reads BOTH `router.ex` (argv[2]) and `app.js` (argv[3])
— `:88-89`. `__me_envelope_census.mjs` imports `__preview__/scenarios.mjs` (`:119`) and
reads `router.ex` (`:122`). Movement one edits `app.js`; the admin fixture edits
`scenarios.mjs`. Both suppressed censuses are live over this wave's own diff.

Proof that the LAST step can lose (so its suppression costs real coverage) — add one key
to the corpus `me()` producer in `scenarios.mjs` and run it:

    # after `role: actorRole,` insert `invented_key: true,`
    node cloud/priv/static/__me_envelope_census.mjs
    # rc=1 — "INVENTED — the corpus serves these and /v1/me does not state them (1): invented_key"

## 5. The ordering rule this licenses

A slice that can red the binding census must not land in the same CI run as a slice whose
only proof is the reason-arm or the me-envelope census: the first swallows the second's
verdict. Either (a) order them across merges, or (b) hoist the two derived censuses ABOVE
the pinned binding census in the step list, or (c) give each census its own job so the
three verdicts are independent check-run facts.

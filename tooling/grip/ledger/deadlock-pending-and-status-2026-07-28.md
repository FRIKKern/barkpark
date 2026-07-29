# Re-derivation: the deadlock detector's PENDING blind spot, and whether a status context can ever be required

Honest Gates wave 5, verifier lane `deadlock-pending-and-status`. Every row below was run
against origin/main @ ab396959c on 2026-07-28. Nothing here is inherited.

## 1. PENDING returns exit 0, shape-identical to green

```sh
cd /Volumes/SATECHI/github/barkpark
printf '%s' '{"check_runs":[{"name":"Elixir gate","status":"in_progress","conclusion":null},{"name":"PR references an active task","status":"completed","conclusion":"success"}]}' > /tmp/pending.json
bash scripts/required-checks-verify.sh --spec .github/required-checks.json --runs /tmp/pending.json --sha FAKE --deadlock; echo PENDING_EXIT=$?
# ->   ok     every required context appears in the 2 name(s) rendered on FAKE
# ->   PENDING_EXIT=0
```

Same for a `queued` run with no `conclusion` key at all (`/tmp/p4.json`). Cause:
`scripts/required-checks-verify.sh:222` maps a null conclusion to the literal string
`null`, and the state `case` at :290 lists only `cancelled|timed_out|stale|action_required`.

## 2. PENDING is additive-safe — it never masks state 3 or state 4

```sh
printf '%s' '{"check_runs":[{"name":"Elixir gate","status":"in_progress","conclusion":null}]}' > /tmp/p2.json
bash scripts/required-checks-verify.sh --spec .github/required-checks.json --runs /tmp/p2.json --sha FAKE --deadlock; echo EXIT=$?   # -> 3, missing: PR references an active task
printf '%s' '{"check_runs":[{"name":"Elixir gate","conclusion":null},{"name":"PR references an active task","conclusion":"cancelled"}]}' > /tmp/p3.json
bash scripts/required-checks-verify.sh --spec .github/required-checks.json --runs /tmp/p3.json --sha FAKE --deadlock; echo EXIT=$?   # -> 4, re-run
```

## 3. The live control: a real head that genuinely deadlocks

```sh
bash scripts/required-checks-verify.sh --deadlock --sha 7f8ced21cc00f25072bef63d20e6d5f97be5ad3d; echo LIVE_EXIT=$?
# -> DEADLOCK ... missing: Elixir gate ... LIVE_EXIT=3
```

## 4. The generator can NEVER emit a status-based context (double-guarded)

```sh
D=/tmp/hgfx; rm -rf $D; mkdir -p $D; echo AAA > $D/main-shas.txt
printf '%s' '{"statuses":[{"context":"Elixir gate","state":"success"},{"context":"Vercel – barkpark","state":"failure"}]}' > $D/status-AAA.json
printf '%s' '{"check_runs":[{"name":"Elixir gate","conclusion":"success","started_at":"2026-01-01T00:00:00Z","app":{"id":15368}}]}' > $D/checkruns-AAA.json
bash scripts/required-checks-generate.sh --fixture-dir $D --sha AAA --allow-single-sha --status-source --explain --out /tmp/g1.json
# -> AAA  R0  Elixir gate          (R0 rejects source != check_runs)
# -> FAIL: selection produced ZERO contexts — refusing to emit a spec that protects nothing
RC_DISABLE_RULES=R0 bash scripts/required-checks-generate.sh --fixture-dir $D --sha AAA --allow-single-sha --status-source --explain --out /tmp/g2.json
# -> AAA  R4  Elixir gate          (status rows carry app_id "0"; R4 is the backstop)
# -> AAA  R3  Vercel – barkpark    [legacy namespace; normalization moved: U+2013 EN DASH]
```

Also: R2 rejects `conclusion` `null`, so a merely-PENDING check-run can never be promoted
into the spec either.

## 5. Where the pending signal is actually consumed

`scripts/required-checks-apply.sh` runs NO deadlock pre-flight before the PUT (grep for
`--deadlock` in it returns nothing); it only verifies the read-back afterwards.
`scripts/bp-merge.sh:173` runs the detector ONCE, then polls. Pending must return 0 there
or the merge verb would refuse every freshly pushed PR.

```sh
grep -n 'deadlock' scripts/required-checks-apply.sh   # -> no matches
BP_MERGE_LIB=1 bash -c 'source scripts/bp-merge.sh; classify_refusal "2 of 2 required status checks have not succeeded: 1 expected and 1 successful."'  # -> PLURAL
BP_MERGE_LIB=1 bash -c 'source scripts/bp-merge.sh; classify_refusal "1 of 1 required status check is expected."'                                       # -> DEADLOCK
```

The second row is the cardinality coupling: the singular `is expected.` arm refuses
immediately as a permanent deadlock. It is unreachable at N=2 (every message is plural) and
becomes reachable the moment the spec falls to one context.

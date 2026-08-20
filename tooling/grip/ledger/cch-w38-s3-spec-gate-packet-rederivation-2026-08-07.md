# cch-w38 S3 — spec-gate packet + roster disposition: re-derivation recipes (2026-08-07)

Slice `cch-w38-s3-spec-gate-packet-and-roster-disposition`. Every integer below was
re-derived at `origin/main ef77af274` inside worktree `wf_9e9e2b3b-0f0-34`, which is
branched from it. Nothing here was taken from an inherited brief without a command
behind it, and where a number CHANGED from the brief's, the new number and its
command are what stand.

**No repo behaviour changed in this slice, and no PR was opened.** This file is the
only committed artifact; every other write landed on the Barkpark ledger and was read
back from the *published* perspective before the next one was issued — a printed `rev`
is not persistence.

**Run every command below from a worktree cut at `origin/main`, never the primary
checkout.** The primary checkout is ~504 commits behind and answers
`54 passed, 1 failed` off a 2.2x smaller suite: a FALSE RED that has already cost this
epic a wave.

---

## 0. The gate this slice had to pass

```sh
bash scripts/required-checks.test.sh --hermetic   # rc captured WITHOUT a pipe
# required-checks: 119 passed, 0 failed (hermetic — the API stage was skipped)
# RC=0

bash scripts/required-checks.test.sh              # LIVE half, needs a token with admin
# required-checks: 123 passed, 0 failed
# LIVE_RC=0
```

`rc` is captured by redirecting to a file and reading `$?` on its own line. Reading it
through `| tail` reports the rc of `tail`, which is 0 for a FAILING script — the
rotating-charter trap, recurred twice in this repo.

## 1. The packet's state numbers

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection \
  --jq '{contexts:.required_status_checks.contexts, enforce_admins:.enforce_admins.enabled}'
# {"contexts":["Elixir gate","PR references an active task","Cloud gate","Console gate"],
#  "enforce_admins":true}
#   -> EXACTLY FOUR contexts. The candidate would be the FIFTH.
#   -> the same command proves the EXISTING gh token reaches the admin-only endpoint.
#      NO new PAT is needed. This is NOT hg-breakglass-token-fine-grained.

gh api repos/FRIKKern/barkpark/commits/ef77af274/check-runs \
  --jq '.check_runs[] | select(.name|test("spec gate")) | "\(.name) \(.conclusion) \(.head_sha[0:9])"'
# Required-check spec gate success ef77af274

gh pr view 8222 --json state,mergedAt,closedAt,mergeStateStatus
# {"closedAt":"2026-07-31T02:45:36Z","mergeStateStatus":"DIRTY","mergedAt":null,"state":"CLOSED"}
#   -> the exclusion's documented re-evaluation trigger can NEVER FIRE.

gh pr view 9921 --json state,mergedAt,mergeStateStatus,title
# {"mergeStateStatus":"CLEAN","mergedAt":null,"number":9921,"state":"OPEN",
#  "title":"fix(gates): the registration sweep stops passing on what it did not see"}
#   -> THE PACKET'S REFUSAL CONDITION. It waits on this merging.
```

## 2. THE DENOMINATOR — why the sweep's rc 0 is not authorization

The sweep prints a verdict and hides the denominator. Re-derive the split with the
sweep's OWN side-(A) predicate (`registration-deadlock-sweep.sh:204-211`) instead of
trusting `swept N; casualties: 0`:

```sh
gh pr list --repo FRIKKern/barkpark --state open --limit 100 \
   --json number,mergeable,mergeStateStatus,isDraft > /tmp/prs.json
jq 'length' /tmp/prs.json                                                  # 23
jq '[.[] | select(.mergeable=="MERGEABLE" and .isDraft==false
      and ([.mergeStateStatus] | inside(["CLEAN","UNSTABLE","BEHIND","HAS_HOOKS"])))]
    | {evaluated: length, prs: [.[].number]}' /tmp/prs.json
# { "evaluated": 4, "prs": [9921, 9905, 9890, 9876] }        -> 19 SKIPPED
jq -r 'group_by(.mergeStateStatus)[] | "\(.[0].mergeStateStatus)\t\(length)"' /tmp/prs.json
# BLOCKED 14 · CLEAN 4 · DIRTY 4 · UNSTABLE 1
```

**NOTE THE `inside` FORM.** The obvious `["CLEAN",…] | index(.mergeStateStatus)` is
WRONG: inside the pipe `.` is the array, so `.mergeStateStatus` indexes an array with a
string and jq errors — and an error here is easy to misread as "no matches". Written
the wrong way, this recipe would have produced `evaluated: 0`.

Wave 38's survey measured **2 evaluated of 22**; today it is **4 of 23**. The integer
moves because the fleet is live. The FINDING does not: nineteen open PRs say nothing
either way, and that is a measurement of a GitHub Actions outage, not of this repo.

Main's script cannot report this at all:

```sh
grep -n 'swept\|casualties\|skipped\|PARTIAL COVERAGE' scripts/registration-deadlock-sweep.sh
# :197  swept=$((swept + 1))        <- incremented BEFORE the side-(A) `continue` at :217,
#                                      so skips are counted as swept
# :242  echo "swept $swept open PR(s); casualties: $casualties"   <- the ONLY summary line
# (no `skipped` counter, no PARTIAL COVERAGE line, no zero-evaluated exit anywhere)
```

Therefore `cch-w37-bl-register-spec-gate-human-gate`'s criterion 1 — "a zero-evaluated
green is REFUSED as authorization" — is UNSATISFIABLE with the script on main. It is
not satisfiable by trying harder. #9921 is the fix.

**ORDERING TRAP.** Run the sweep BEFORE the spec PR merges. After the merge the
candidate proposes no context `origin/main` does not already require, so the run
short-circuits to that sentence and returns a green indistinguishable from a real
authorization.

## 3. The regeneration clobber (`required-checks-generate.sh:146`)

```sh
grep -c 'CORRECTED AGAIN' scripts/required-checks-generate.sh   # 0   <- the generator
grep -c 'CORRECTED AGAIN' .github/required-checks.json          # 1   <- the artifact (:76)
sed -n '141,147p' scripts/required-checks-generate.sh
#   EXCLUDED_BY_DECISION_NAMES=( "Required-check spec gate" "Security gate" )
#   EXCLUDED_BY_DECISION_REASONS=( "… Re-evaluate once #8222 lands or is rebased." … )
sed -n '710,718p' scripts/required-checks-generate.sh
#   the two arrays zipped BY INDEX
```

Wave 36 corrected the reason in the artifact by hand; the generator still carries the
pre-wave-36 text, so the next regeneration silently reverts it. Because NAMES and
REASONS are index-parallel, deleting the name at index 0 without deleting REASONS[0]
would shift `Security gate` onto the spec-gate reason — **registering the context
structurally forces the stale line's deletion.** The cure is free if the flip proceeds,
and owed by hand if it does not.

## 4. The four false-open receipts

Each row was closed on its receipt, and each close states which criteria closed
RE-DERIVED, which MERGE-GATED, and which were left unmet. **None was blanket-stamped.**

```sh
# 1. cch-w23-bl-pat-deploy-grant-survives-demotion  -> done 3/6
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex \
  | grep -n 'demoted? =\|revoke_team_pats_exceeding_role\|pat_abilities_allowed'
#  873/875/878  the MINT FENCE          989  def revoke_team_pats_exceeding_role
# 1844  demoted? = rank(new) < rank(current)   1863  the call, INSIDE Repo.transaction
git show origin/main:cloud/test/barkpark_cloud/web/router_pat_test.exs | sed -n '365,403p'
#   "DEMOTION kills the elevated PAT but KEEPS the read PAT a member may still hold"
#   asserts register_support(deploy_token).status == 401  AND  read_token GET == 200
git log origin/main --oneline -S'revoke_team_pats_exceeding_role' \
  -- cloud/lib/barkpark_cloud/accounts.ex | tail -1     # 541d5d1c1 (#9522)
git merge-base --is-ancestor 541d5d1c1 origin/main && echo ancestor
#   LEFT UNMET: [0] fail-first repro (UNRECOVERABLE after the fix),
#               [1] the M8 mutation (not re-run), [4] mix test (zero CI this slice)

# 2. cch-cloud-app-has-no-plug-errorhandler  -> done 3/3
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \
  | grep -n 'use Plug.ErrorHandler\|def handle_errors'
#   242  use Plug.ErrorHandler        7931  def handle_errors(conn, %{kind:, reason:})
#   THE PATH IS cloud/lib/barkpark_cloud/web/router.ex — NOT barkpark_cloud_web/,
#   which does not exist on origin/main and silently 'fatal: path … does not exist'.
git show --stat 467f7e283      # #9521; crash_envelope_census_test.exs +349, __app.test.mjs +98
#   [1] is L1 (file read here). [0] and [2] are L2 — the curl reproductions and the
#   4-failure :no_response mutation are QUOTED from that commit, not re-run.

# 3. cch-w11-s1-flip-behind-a-generator-that-cannot-lose  -> done 11/13
git merge-base --is-ancestor dcd8c9ce origin/main && echo ancestor    # #8394
sed -n '602p' scripts/required-checks-generate.sh    # S1-LOSS refusal, before stage 2
sed -n '752,778p' scripts/required-checks-generate.sh # leaf demotion, keyed by file+job id
#   [9] closed on the LIVE protection read in §1 (the PUT happened: four contexts).
#   [10] is UNRECOVERABLE, not merely unrun: its experiment was to read #8222's
#        mergeStateStatus immediately after the PUT; #8222 is now CLOSED/DIRTY with
#        mergedAt null, which reports a merge conflict, not a protection verdict.
#   [11] the two-sided merge-gate mutation was not re-run (zero CI).

# 4. cch-w28-s1-empty-roster-control-asserts-clause-a  -> done 7/7
gh pr view 9356 --json mergedAt,mergeCommit,state
# {"mergeCommit":{"oid":"0a1b4d2e…"},"mergedAt":"2026-08-03T14:53:51Z","state":"MERGED"}
git merge-base --is-ancestor 0a1b4d2e origin/main && echo ancestor
#   6/7 already stamped; the ONLY outstanding criterion was merge-gated and the merge
#   landed four days ago. The cleanest shape of the disease: a shipped P0 reported unpaid.
```

`cch-w32-bl-roster-false-open-sweep` — the sweep that ALREADY named the ErrorHandler
row as fully paid — is itself still open at 0/5 because its own closes never landed.
It carries a `--miss` note recording that, and was left OPEN with its claim released.

## 5. `cch-w36-bl-unpredicated-write-affordances-fix` — CORRECTED, not retired

```sh
git show origin/main:cloud/priv/static/app.js | grep -ic 'pin release'    # 0
#   -> the row named an affordance THAT DOES NOT EXIST.

gh pr diff 9920 | grep -E '^\+' | grep 'elevated: true' | grep 'predicate: null' | wc -l
#   18   call sites
#   15   distinct `route:` values among them (two route pairs are double-called:
#        /v1/barkparks/:* at 6750+6794, /v1/barkparks/:*/retry at 6776+17284,
#        /v1/launch at 13129+16345)
git show origin/main:cloud/priv/static/app.js \
  | grep -n 'submitProviderCred\|submitLaunchFlow\|newLaunch\b\|newRenderFailed'
#   the four members the row OMITTED, all real
```

Title moved from "Nineteen … ten of them on one screen" to "Eighteen … over fifteen
distinct routes"; the instance-detail cluster is resized from ten to EIGHT. The row
stays OPEN — the fix work is genuinely unpaid, so retiring it would lose it — and its
ordering dependency is re-pointed from the cancelled `cch-w36-s5` to
`cch-w37-s4-binding-census-add-and-remove` / PR **#9920, which is OPEN with mergedAt
null**. The description therefore quotes an unmerged PR, which is why that row's
criterion [0] (re-derive at claim time, do not quote the description) is load-bearing.

## 6. The roster denominator, before and after

```sh
bp task get cloud-console-hardening-epic -o json | python3 -c \
 "import json,sys;from collections import Counter;\
  ch=json.load(sys.stdin).get('children') or [];\
  op=[x for x in ch if x['lifecycle_status']=='open'];\
  dr=[x for x in op if x['doc_id'].startswith('drafts.')];\
  print('children',len(ch),dict(Counter(x['lifecycle_status'] for x in ch)));\
  print('open',len(op),'open drafts',len(dr),'non-draft open',len(op)-len(dr))"
```

| | children | done | open | open drafts | cancelled | in_progress | considering |
|---|---|---|---|---|---|---|---|
| BEFORE | 463 | 249 | 174 | 13 | 36 | 3 | 1 |
| AFTER  | 464 | 253 | 161 | 7  | 46 | 3 | 1 |

Open fell by 13: **−6** duplicate `drafts.` phantoms, **−2** superseded registration
duplicates, **−4** false-open rows closed on receipts, **−2** superseded wave-36 rows,
**+1** newly filed. Cancelled rose by exactly 10; done by exactly 4.

Exact-title duplicate pairs where BOTH rows are open: **6 → 0.**

```sh
# the duplicate scan, over the same children payload
#   group by title; report groups where every member is lifecycle open
```

**HONEST RESIDUE, filed rather than swept.** Seven `drafts.` rows remain open. Five are
phantoms of already-DONE published rows and are safe to cancel; the other two —
`drafts.cch-w37-s1-invalid-precedence-details-win` (9/10 met, **no published twin at
all**) and `drafts.cch-w37-bl-roster-collapse-three-paid-rows` — must be read before
they are touched. Filed as `cch-w38-bl-w37-s1-successor-is-an-unpublished-draft` (P1).

That first one matters more than its size: disposing `cch-w36-s6-invalid-precedence-details-win`
as superseded would have made a nine-criteria-stamped obligation invisible to every
board, because boards read the published ledger only and its successor was never
published. The brief for this slice said those stamps sat on a `drafts.cch-w36-s6`
twin; **there is no such row** — they are on `drafts.cch-w37-s1`. Recorded here rather
than quietly corrected.

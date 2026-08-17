# cch wave 45 — Law 0 ledger repayment: re-derivation recipes

Verifier phase, 2026-08-07. origin/main = `b00d793c0e2065e98a03fed6c4356245d897ee3a`.
Every row below was derived by running the command shown. No bp mutations were issued.

## 0. Live-row count (the prescribed command is BROKEN)

The assignment's MUST-RUN one-liner does `d=d.get('doc',d)`, which swaps the
envelope for the inner doc — and the inner doc has neither `child_count` nor
`children`. It prints `None Counter()`. Corrected recipe:

    bp task get cloud-console-hardening-epic -o json \
      | python3 -c "import json,sys;from collections import Counter;d=json.load(sys.stdin);print(d['child_count'],Counter(c['lifecycle_status'] for c in d['children']))"

Result: `563 Counter({'done': 257, 'open': 249, 'cancelled': 53, 'in_progress': 3, 'considering': 1})`
Live = 249 + 3 + 1 = **253**. Matches the strategic direction exactly.

## 1. The four required contexts (pin, do not quote from memory)

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{strict:.required_status_checks.strict, contexts:.required_status_checks.contexts, enforce_admins:.enforce_admins.enabled}'

=> `strict:false, enforce_admins:true, contexts:["Elixir gate","PR references an active task","Cloud gate","Console gate"]`

## 2. Per-row: unmet criteria + claim worker/epoch

    for t in <slug>; do bp task get $t -o json | python3 -c "
    import json,sys; d=json.load(sys.stdin); doc=d.get('doc',d); cl=doc.get('claim') or {}
    print(doc['lifecycle_status'], cl.get('worker'), cl.get('previous_worker'), cl.get('epoch'), cl.get('expired_at'))
    for i,x in enumerate(doc['content'].get('acceptance_criteria') or [],1):
        if not x.get('met'): print('UNMET',i,x.get('criterion'))"; done

All nine rows: exactly ONE unmet criterion, and it is the merge gate. Confirmed.

## 3. Row -> PR mapping (three rows carry NO PR in their now-line)

w41-s1/s2/s3 now-lines name a branch + commit, never a PR. They were squash-merged,
so `git merge-base --is-ancestor <commit> origin/main` says NO. Prove landing by
CONTENT IDENTITY instead, then name the PR from the file's history:

    git diff --stat origin/main <commit> -- $(git show --name-only --format="" <commit>)   # empty => landed
    git log origin/main --oneline -3 -- <path>                                             # names the PR

| row | commit | PR | four contexts |
|---|---|---|---|
| w41-s1 | fa38c2465 | #10124 | all SUCCESS |
| w41-s2 | d6c0b3eb8 | #10125 | all SUCCESS |
| w41-s3 | df51d2058 | #10126 | all SUCCESS |
| w42-s3 | — | #10250 | all SUCCESS |
| w42-s5 | — | #10156 | all SUCCESS |
| w43-s1 | — | **#10199** (NOT #10085) | all SUCCESS |
| w43-s3 | — | #10201 | all SUCCESS |
| w43-bl-me-census-onboarding-subtree | — | #10251 | all SUCCESS |
| w44-s5 | — | #10252 | all SUCCESS |

Verify any of them:

    gh pr view <n> --json mergedAt,statusCheckRollup | python3 -c "
    import json,sys; d=json.load(sys.stdin); req={'Elixir gate','PR references an active task','Cloud gate','Console gate'}
    seen={c['name']:c.get('conclusion') for c in d['statusCheckRollup']}
    print(d['mergedAt']); [print(r, seen.get(r,'MISSING')) for r in sorted(req)]"

## 4. THE CLOSE BLOCKER — six of nine have NO current claim

`bp task close` is specified "Close a **claimed** task by id" and requires
`worker_id` + `observed_epoch`. Six rows are `open` with a LAPSED lease:
`claim.worker` is **null**, `expired_at` is in the past, and the name survives
only in `claim.previous_worker`. Closing those with previous_worker+epoch is a
close against a claim that does not exist. They must be RE-CLAIMED first
(`bp task claim`, which bumps the epoch), then closed on the NEW epoch.

Only three rows (the `in_progress` ones) carry a live claim closable as-is:

| row | claim.worker | epoch | closable now? |
|---|---|---|---|
| cch-w42-s3-members-row-reads-the-targets-rank | epic-builder-the-members-row-reads-the-target-s-rank- | 5 | YES |
| cch-w43-bl-me-census-onboarding-subtree | epic-builder-the-v1-me-envelope-census-stops-comparin | 6 | YES |
| cch-w44-s5-server-crux-disagreement-gets-an-elixir-pin | epic-builder-the-owner-on-peer-owner-disagreement-bet | 5 | YES |

Lapsed (re-claim, then close on the new epoch):

| row | previous_worker | stale epoch | expired_at |
|---|---|---|---|
| cch-w41-s1-… | epic-builder-the-two-server-authority-predicates-are- | 6 | 05:58:00Z |
| cch-w41-s2-… | epic-builder-v1-me-states-the-team-authority-the-gate | 6 | 05:56:00Z |
| cch-w41-s3-… | epic-builder-the-four-owner-admin-console-predicates- | 7 | 05:56:00Z |
| cch-w42-s5-… | epic-builder-the-notification-event-vocabulary-gets-a | 6 | 07:34:00Z |
| cch-w43-s1-… | epic-builder-the-preview-corpus-mints-the-account-the | 7 | 09:05:00Z |
| cch-w43-s3-… | epic-builder-the-binding-census-stops-asserting-a-fal | 6 | 09:06:00Z |

Also expect a `doc_changed_since_claim` 409 on any row whose brief was edited
under the lapsed claim; recover with `--set observed_rev=<current_rev>`.

## 5. Tenth candidate is NOT merge-gated — it is SUPERSEDED

`cch-w40-bl-two-owner-only-billing-remedies-are-mailed-to-every-team-member`:
`open`, no claim, no assignee, and **zero acceptance_criteria** (so it can never
be closed on criteria). Its premise was PAID by `cch-w42-s6`:

    git show origin/main:cloud/lib/barkpark_cloud/notifications/event_email.ex | sed -n '130,160p'

Both named bodies now render two arms on an `owner?/1` predicate that
fails closed on a nil/unknown role; the non-owner arm leads with the consequence
and says "Only the team owner can manage billing." The fan-out is still
every-member — deliberately, per the in-file note (the teardown warning's reach
must be maximal). Row should be CANCELLED with that note, not built.

## 6. Stranded PRs — one is a RE-RUN, one is a real RED

    gh pr view 10154 --json mergeable,mergeStateStatus,statusCheckRollup
    gh api repos/FRIKKern/barkpark/commits/$(gh pr view 10154 --json headRefOid --jq .headRefOid)/check-runs?per_page=100 \
      --jq '.check_runs[]|select(.conclusion=="failure")|.name'

**#10154** (`loop-epic/the-role-ladder-census-derives-its-own-d-1`, head
`ba208c5ec`) — MERGEABLE, BLOCKED. Cloud gate SUCCESS, Elixir SUCCESS, task gate
SUCCESS; **Console gate FAILURE for an ENVIRONMENT REFUSAL only**. The gate's own
words: "verdict=REFUSED — this instrument REFUSED TO MEASURE (exit 2). The browser
never came up … Measured defects (exit 1) in this run: none … re-running is the
only thing that can turn it green." Zero measured defects. This is the epic's own
can-lose doctrine working correctly. One re-run from mergeable.

**#10155** (`loop-epic/main-push-gate-failures-find-a-human-ins-2-r`, head
`904eca506`) — MERGEABLE, BLOCKED, genuinely RED. Path-escape ratchet: `121
passed, 1 failed`, the one being
`FAIL — blocking_not_in_needs = 'report-main-failure', wanted ''`.
Self-inflicted and in-class: the PR adds a `report-main-failure` job treated as
blocking but absent from the gate's `needs`, i.e. a gate telling a merge something
it cannot support. Needs a code fix, not a re-run.

## 7. THREE draft docs are inflating the epic's live count

    bp task get cloud-console-hardening-epic -o json | python3 -c "
    import json,sys; d=json.load(sys.stdin)
    print([(x['doc_id'],x['lifecycle_status']) for x in d['children'] if x['doc_id'].startswith('drafts.')])"

13 `drafts.` children exist; 10 are already `cancelled` (the established
disposition), but THREE are `open` and therefore counted among the 253 live rows:

- `drafts.cch-w40-bl-probe-packet-audit-x1`
- `drafts.cch-w40-s5-followup-reason-only-refusals-invisible-to-refusal-lens`
- `drafts.cch-w41-s3-the-admin-limb-gets-a-guard-that-can-lose` (4/10, a shadow of
  the real `cch-w41-s3-…` at 9/10, whose work merged as #10126)

Cancelling these three is free Law-0 repayment and matches how the other ten
drafts were dispositioned.

## 8. REFUTED: closing cch-w42-s3 does NOT unblock the round-2 rows

The assignment states "closing cch-w42-s3 is what unblocks BOTH already-filed
round-2 rows on the ledger." There is no such edge. Re-derive:

    for t in cch-w43-bl-binding-census-arity-arm cch-no-admin-fixture-in-the-preview-corpus; do
      bp task get $t -o json | python3 -c "
      import json,sys; d=json.load(sys.stdin); doc=d.get('doc',d)
      print(doc['doc_id'], doc['lifecycle_status'], doc.get('dependency_count'), doc.get('dependent_count'), doc.get('queue_gate'))"; done

Both: `open`, `dependency_count=0`, `dependent_count=0`, `queue_gate=None`. They
are already claimable RIGHT NOW; nothing gates them. Closing w42-s3 is still
correct Law-0 hygiene, but it is not a precondition for round 2 and must not be
sequenced as one.

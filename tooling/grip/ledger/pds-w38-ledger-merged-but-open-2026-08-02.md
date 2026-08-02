# PDS wave 38 — the merged-but-open set, derived LEDGER-SIDE

Derived 2026-08-02 against origin/main `db7ea8858`. Nothing here is transcribed;
every number below has a rerun command.

## 0. Population (two lenses disagree — print BOTH, never pick)

    bp task get task-2ac1f95237c4a8e5 -o json | \
      python3 -c "import json,sys;from collections import Counter;print(Counter(c['lifecycle_status'] for c in json.load(sys.stdin)['children']))"
    # => Counter({'open': 248, 'done': 141, 'cancelled': 15, 'considering': 9})   (413 children)

    bp doc query task --filter 'content.parent_id == "task-2ac1f95237c4a8e5"' --limit 500 -o json
    # => count 409, open 244  (PUBLISHED perspective)

The 4-row difference is four DRAFT-ONLY open rows invisible to the published lens:
`drafts.pds-bl-tagregistry-guard-no-rung`, `drafts.pds-bl-wrongpath-arm-blind-to-wrong-id`,
`drafts.pds-w27-census-self-honesty`, `drafts.pds-w29-s3-fake-fails-closed`.
None of the four matches the merge-gated shape, so the close list is unaffected — but
"245 open" in the brief is a THIRD number and matches neither lens.

## 1. The sound predicate (criteria-side, not commit-message-side)

Over every open/in_progress child: `unmet = [c for c in acceptance_criteria if not c.met]`,
qualify when `unmet` is non-empty and EVERY unmet criterion text matches
`/MERGE-GATED|LEAD CLOSES/i`; qualify separately when `unmet` is EMPTY (stale-open).
`pds-w29-pay-lb` is excluded BY THE PREDICATE, not by hand: 12/14, and its second
unmet criterion is real unshipped work.

    # rerun: see analysis snippet in the wave-38 verifier report; population file
    bp doc query task --filter 'content.parent_id == "task-2ac1f95237c4a8e5"' --limit 500 -o json > kids.json

11 rows qualify. 9 are genuinely merged-but-open. 2 (`pds-w25-round-parked`,
`pds-w25-round-open`) are NOT merge-gated in the PR sense — their criterion says
"this slice has no PR" and demands a LEAD RE-DERIVATION of a pinned shard. Stamping
them without re-deriving is the false-done this slice exists to kill.

## 2. THE CLOSE LIST (9 rows) — id, epoch, previous_worker, unmet index, merge

    pds-w36-help-seal-fix                      epoch 12  epic-builder-the-help-line-is-computed-from-what-the-   idx 9   #8992 4d2b02a58
    pds-w37-unread-callee-receipts             epoch 7   epic-builder-two-receipts-whose-callee-cannot-fail-th   idx 8   #8993 fbc6b80a1
    pds-w36-revoke-all-sessions-count          epoch 5   epic-builder-sign-out-everywhere-stops-being-an-unrea   idx 8   #8952 501fb9670
    pds-bl-record-update-basis-overclaims      epoch 4   epic-builder-a-shipped-receipt-lie-dns-record-update-   idx 7   #8807 0679c5dcb
    pds-w29-registry-postcondition-invariant   epoch 7   epic-builder-the-success-claim-registry-stops-accepti   idx 8   #8645 f84f4ac93
    pds-w30-live-proof-runner                  epoch 9   epic-builder-the-epic-s-first-l1-a-credential-gated-r   idx 9   #8647 1cef6eed3
    pds-w30-board-envelope-poison-parity       epoch 5   epic-builder-the-board-envelope-fence-gains-the-two-p   idx 5   #8648 8b2018bc0
    pds-w32-census-pin-simplify                epoch 6   epic-builder-keep-and-relabel-total-delete-the-two-ce   idx 10  #8808 c15e41588
    pds-bl-opaque-arm-blind-to-nonliteral-kind epoch 4   wave33-reviewer                                        NONE    #8808 c15e41588

Every listed sha is an ancestor of origin/main:

    for s in 4d2b02a58 fbc6b80a1 501fb9670 0679c5dcb f84f4ac93 1cef6eed3 8b2018bc0 c15e41588; do \
      git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done

Two of the nine carry NO Task: trailer on their merge commit (1cef6eed3, 8b2018bc0) and
NO grep-able task id — they were resolved by matching the row's stamped evidence file
paths against `git show --stat`. A commit-message-side sweep MISSES both. This is the
non-vacuity case for wave 38's RECORD-PARITY arm being ledger-side, not trailer-side.

## 3. Claim mechanics — every one of the nine has a LAPSED lease

`claim.worker` is null on all nine; `claim.previous_worker` and `claim.epoch` are as
tabled. Server rules, read at origin/main:

* `api/lib/barkpark/tasks/internal.ex:61` `close_holder/2` — three allow-arms:
  unclaimed / holder / **self_resume** (worker nil AND worker_id in
  [previous_worker, released_by]). So `bp task close <id> <previous_worker> <epoch>`
  SUCCEEDS. It also records the BUILDER as the closer of a criterion that says
  "THE LEAD CLOSES THIS" — the exact attribution lie the epic exists to kill.
* The honest form: close under the LEAD's own worker id with
  `--set holder_override="<reason>"` (`tasks_controller.ex:492`, PDS-D288); the ledger
  then records `held_by` + reason and the close is auditable.
* `bp task stamp` is NOT available on these rows: `stamp.ex:162` uses the STRICT
  `check_holder/2` (`internal.ex:27`, worker must equal `claim.worker`) and
  `stamp.ex:207` requires `in_progress`. All nine are `open` with worker null.
  Flip the criterion inside the close via `--set 'criteria:=[…]'` instead.
* `bp task stamp --merge-gated` exists (`internal/cli/tasks_stamp_cmd.go:95`) but is
  absent from the capabilities manifest (`cch-w19-bl-stamp-merge-gated-flag-undocumented`).

## 4. SECOND-ACT FLAGS — do NOT stamp these three without doing the dependent act

* `pds-w32-census-pin-simplify` idx 10 also requires `pds-bl-census-exact-pins-tax-growth`
  be "closed or updated with this verdict". That row is **open 2/13**. Real act required.
* `pds-w29-registry-postcondition-invariant` idx 8 also requires
  `pds-w27-bl-support-run-registry-rows-vacuous` (**open 0/6**) AND
  `pds-bl-hzresdone-registry-row-vacuous` (**open 0/4**) be "closed against it".
  Both carry substantial unshipped work; closing them as done would fabricate.
* `pds-w30-board-envelope-poison-parity` idx 5 names `pds-bl-board-tui-reader-honesty`
  and `pds-w29-taskboard-envelope-fence` — **BOTH ALREADY done (4/4 and 8/8)**.
  This dependency is PRE-PAID; the row closes freely. Fourth pre-paid dispatch item.
* Beyond the direction's three: `pds-w37-unread-callee-receipts` and
  `pds-w36-revoke-all-sessions-count` each ALSO require a SECOND INDEPENDENT REVIEWER
  to re-derive a HIGH-FLIP-RISK SCIM tenancy claim, and `pds-w36-help-seal-fix` /
  `pds-w37-unread-callee-receipts` require the Sobelow breakdown unchanged against
  main's 24 (3 Config.CSRF HIGH, 7 SQL.Query, 3 SQL.Stream, 9 Traversal.FileModule,
  2 CI.System). Merging is NECESSARY, not SUFFICIENT, on five of the nine.

## 5. The 14 done-with-0/N rows — NONE is a reason-less false-done

    # 14 rows: done, total>0, met==0
    # 9 carry disposition_reason; 5 carry ONLY close_reason; 14/14 carry close_reason;
    # 0 carry neither.

Reason-less-in-`disposition_reason` but fully reasoned in `close_reason`:
`pds-bl-ssr-leftovers-lever-refuted-rescope` (MOOT), `pds-bl-export-no-serialization`
(SUPERSEDED + half-premise REFUTED), `pds-backlog-streamed-bundle-channel` (SUPERSEDED),
`pds-bl-templates-deploy-noop` (ALREADY FIXED IN CODE), `pds-bl-harness-pgrep-wrong-process`
(ALREADY FIXED IN CODE). **A sweep reading only `disposition_reason` reports 5 false
false-dones; a sweep reading only `close_reason` misses nothing.** The field split IS
the defect — not the rows.

Separately, three done rows carry ZERO criteria (0/0), including
`pds-w34-census-cas-shadow`, whose `close_reason` reads "DISSOLVED BY SET — CLOSED ON
WAVE-37 DERIVED NUMBERS at origin/main 501fb9670bc (NOT on PDS-D485's or D505's claim)".
The wish's item 2 is PRE-PAID and its close explicitly refuses to inherit the charter.

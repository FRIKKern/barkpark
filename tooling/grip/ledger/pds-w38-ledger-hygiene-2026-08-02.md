# PDS wave 38 — ledger hygiene, re-derived (2026-08-02)

Task: `pds-w38-ledger-hygiene-derived` · epic `task-2ac1f95237c4a8e5` · closes recorded under `lead-merge`.

Every number below was derived in-process against the live ledger and `origin/main` at head
`f85188bdf`. Nothing here is transcribed from the wave charter, the dispatch brief, or a prior
wave's paper — that inheritance is the disease this row exists to treat.

## The predicate

```
population := every child of task-2ac1f95237c4a8e5
              bp doc query task --filter parent_id=task-2ac1f95237c4a8e5 \
                --fields acceptance_criteria,lifecycle_status,title,close_reason,disposition_reason \
                --perspective raw --all -o json          # 422 rows
qualify(row) := row.lifecycle_status in (open, in_progress)
                AND row.acceptance_criteria is non-empty
                AND ( unmet(row) == []                              # nothing outstanding but the close
                      OR every u in unmet(row) matches /MERGE-GATED|LEAD CLOSES/i )
```

The raw lens returns the same 422 rows `bp task get` returns as `children`, so the lens gap this
wave is chasing elsewhere does not move this number.

**Eleven rows qualify. Nine are closed.**

| row | met/total | unmet | disposition |
|---|---|---|---|
| pds-bl-opaque-arm-blind-to-nonliteral-kind | 2/2 | 0 | CLOSED — the purest instance: nothing outstanding but the close |
| pds-bl-record-update-basis-overclaims | 7/8 | 1 | CLOSED — bare merge gate |
| pds-w30-live-proof-runner | 9/10 | 1 | CLOSED — bare merge gate |
| pds-w30-board-envelope-poison-parity | 5/6 | 1 | CLOSED — merge + two dependents already done (pre-paid) |
| pds-w32-census-pin-simplify | 10/11 | 1 | CLOSED — merge + dependent row UPDATED with the verdict |
| pds-w36-help-seal-fix | 9/10 | 1 | CLOSED — merge + Sobelow breakdown unchanged |
| pds-w36-revoke-all-sessions-count | 8/9 | 1 | CLOSED — merge + SCIM tenancy re-derived |
| pds-w37-unread-callee-receipts | 8/9 | 1 | CLOSED — merge + Sobelow + cross-org reachability re-derived |
| pds-w29-registry-postcondition-invariant | 9/10 | 1 | CLOSED at 9/10 — criterion 8 left `met=false` on purpose |
| pds-w25-round-parked | 7/8 | 1 | **NOT closed** |
| pds-w25-round-open | 7/8 | 1 | **NOT closed** |

The naive `total - met <= 1` heuristic returns twelve and wrongly admits
`pds-bl-charter-says-opaque-callers` (0/1, whose single unmet criterion is real work). The text
predicate is what excludes it. `pds-w29-pay-lb` (12/14) never enters the pool: its unmet set is
`{9: MERGE-GATED, 12: "pay-lb CREATES internal/cli/hetzner_lb_cmd_test.go …"}` and index 12 matches
neither pattern.

## Merges, proven rather than believed

Every discharging merge commit was checked with `git merge-base --is-ancestor <sha> origin/main`
(exit 0 for all eight) — the PR's `MERGED` state was never taken on its own.

| row | PR | merge commit |
|---|---|---|
| pds-bl-opaque-arm-blind-to-nonliteral-kind | #8808 | `c15e41588` |
| pds-bl-record-update-basis-overclaims | #8807 | `0679c5dcb` |
| pds-w29-registry-postcondition-invariant | #8645 | `f84f4ac93` |
| pds-w30-board-envelope-poison-parity | #8648 | `8b2018bc0` |
| pds-w30-live-proof-runner | #8647 | `1cef6eed3` |
| pds-w32-census-pin-simplify | #8808 | `c15e41588` |
| pds-w36-help-seal-fix | #8992 | `4d2b02a58` |
| pds-w36-revoke-all-sessions-count | #8952 | `501fb9670` |
| pds-w37-unread-callee-receipts | #8993 | `fbc6b80a1` |

## Merging is necessary, not sufficient

**Sobelow (pds-w36-help-seal-fix, pds-w37-unread-callee-receipts) — SATISFIED.** Counted from the
deciding step only — `Sobelow (--skip reads api/.sobelow-skips baseline; --exit Low reds on any NEW
finding)` — never the job rollup and never the mutation-probe step that follows it in the same job.
Three runs: main's own post-merge run at `f85188bdf` (job `91432865984`), PR #8992 (job
`91426910188`), PR #8993 (job `91427119596`). All three identical:

```
3 Config.CSRF   7 SQL.Query   3 SQL.Stream   9 Traversal.FileModule   2 CI.System   = 24
```

The job is red on all three, including on main itself — that is the known stale-baseline red. The
criterion names the **breakdown**, and the breakdown is unchanged.

**SCIM tenancy (pds-w36-revoke-all-sessions-count, pds-w37-unread-callee-receipts) — RE-DERIVED,
with its limit named.** Read from `api/lib` at `f85188bdf` without reading the builder's prose
first. `:scim_org` is assigned only by `RequireScimToken` from the bearer; no `/scim/v2` route takes
a client-supplied org selector. `Scim.get_org_group/2` (`scim.ex:376`) filters `organization_id`;
`get_org_user/2` (`:217`) gates on `member_of_org?/2` (`:314`); `delete_group/2` (`:476`) repeats the
predicate inside its own `delete_all` and returns `{:error, :not_found}` at `n == 0`, which the
controller answers as a 404 whose body is identical to an unknown id — so there is no
exists-elsewhere oracle either. `Scim.org_user_active?/2` (`:175`) is `exists AND member_of_org?`,
so the PATCH receipt's `active` is org-relative truth read back from storage. **The claims hold.**

*Unsatisfied and named:* the re-deriver is a different agent in the same wave, not an out-of-band
reviewer. Both closes say so in their `close_reason` and in their `criteria_override` reason.

*Residue found and filed rather than swallowed:* reachability is org-scoped, the deprovision
**effect** is not. `Accounts.revoke_all_user_sessions/1` (`accounts.ex:358`) filters on `user_id`
alone and `revoke_owner_tokens/1` (`scim.ex:189`) on `owner_user_id` alone, while the membership
drop is correctly scoped to `workspace_ids(org)`. A user in orgs A and B, deprovisioned by A, loses
B's sessions and every owner-bound PAT. Filed as `pds-bl-deprovision-blast-radius-crosses-orgs`
(published, open, 0/4).

**Dependents.** `pds-w30-board-envelope-poison-parity` was PRE-PAID: `pds-bl-board-tui-reader-honesty`
is done 4/4 and `pds-w29-taskboard-envelope-fence` done 8/8, re-read from the ledger.
`pds-w32-census-pin-simplify`'s criterion allows *closed **or updated*** — the UPDATE arm was taken.

## Rows deliberately NOT closed

| row | met/total | why |
|---|---|---|
| pds-w25-round-parked | 7/8 | Its `[MERGE-GATED]` marker is a lie about itself. The criterion is a LEAD RE-DERIVATION of a pinned shard — "confirms the 27 rows and the 8 unchanged hashes … **this slice has no PR**". There is no merge to discharge it and the re-derivation was not performed. |
| pds-w25-round-open | 7/8 | Identical shape: "confirms the 103 rows plus every free close by content … **this slice has no PR**". |
| pds-w29-pay-lb | 12/14 | Criterion 13 requires `internal/cli/hetzner_lb_cmd_test.go`, which does not exist. Real unshipped work; the predicate excludes the row without a judgment call. |
| pds-bl-census-exact-pins-tax-growth | 2/13 | UPDATED with the wave-32 verdict, left open. Criteria 3–4's pin/floor premise is superseded (those pins no longer exist on main); criteria 5–8 (ARM B) are unbuilt. |
| pds-w27-bl-support-run-registry-rows-vacuous | 0/6 | Every criterion is real unshipped work (reproduce the M1b lie, red on that mutation, narrow the grandfather clause). |
| pds-bl-hzresdone-registry-row-vacuous | 0/4 | Every criterion is real unshipped work (a production `hzResDone` caller performing a post-action re-read; a derived population check). |

Because the last two stay open, `pds-w29-registry-postcondition-invariant` is closed at **9/10** with
criterion 8 `met=false` and the residue named in its `close_reason` — the `cch-bl-get-census-rederive`
precedent: close the row, leave the criteria honest, record what was not flipped.

## The done-side mirror inverts the premise

Same 422-row query, `lifecycle_status == done` and no criterion met:

```
done rows                        141
done at 0/N (N > 0)               14
  close_reason non-blank          14
  disposition_reason non-blank     9
  BOTH non-blank                   9
  NEITHER                          0
  close_reason ∪ disposition_reason 14
```

All fourteen carry a substantive reason — `REFUTED` / `SUPERSEDED` / `MOOT` / `ABSORBED` /
`ALREADY FIXED` / `CLOSED by <sha> (#PR)`. **The defect is the field split, not the rows.** A sweep
reading only `disposition_reason` reports five phantom false-dones —
`pds-bl-ssr-leftovers-lever-refuted-rescope`, `pds-bl-export-no-serialization`,
`pds-backlog-streamed-bundle-channel`, `pds-bl-templates-deploy-noop`,
`pds-bl-harness-pgrep-wrong-process` — every one of which has a real `close_reason`.

**Any future arm sweeping done-at-0/N must read `close_reason` UNION `disposition_reason`, or it
manufactures its own lie.** `NEITHER = 0` proves the union is total; `BOTH = 9` proves the two fields
are not redundant copies of each other.

## Claim mechanics used

All nine had a TTL-reaped lease (`claim.worker` null, `claim.previous_worker` naming the original
builder). Closing as `previous_worker` would have succeeded through `close_holder/2`'s `:self_resume`
arm and recorded a **builder** as the closer of a criterion whose own text says the lead closes it —
an attribution lie in the same family as this epic's target. Every close therefore ran as
`lead-merge` with `--set holder_override="…"`, and every row reads back
`claim.closed_by = lead-merge` with `content.close_override.holder.held_by` naming the builder.

`bp task stamp` is unavailable on these rows (holder-only **and** `in_progress`-only, and all nine
were `open`), so criteria were flipped inside the close via `--set 'criteria:=[…]'`. Because D289's
criteria gate measures the doc **as read**, a merge-gated flip riding the same close can never
satisfy the gate it is measured against — so eight of the nine also carry
`--set criteria_override="…"`, each stating which arm it covers.

Epochs read immediately before each close: `pds-bl-opaque-arm-blind-to-nonliteral-kind` 4 ·
`pds-bl-record-update-basis-overclaims` 4 · `pds-w29-registry-postcondition-invariant` 7 ·
`pds-w30-board-envelope-poison-parity` 5 · `pds-w30-live-proof-runner` 9 ·
`pds-w32-census-pin-simplify` 6 · `pds-w36-help-seal-fix` 12 ·
`pds-w36-revoke-all-sessions-count` 5 · `pds-w37-unread-callee-receipts` 7.

One trap worth writing down: the claim lease is at `doc.claim` in the `bp task get` envelope, **not**
at `doc.content.claim`. Reading the wrong one reports "no lease" for every row and the first close
answers `fenced_off`.

## Already done — checked before spending the slice

The wave's direction says `pds-w34-census-cas-shadow` is `open` on the ledger while PDS-D485 calls it
closed. **It is already `done`**: closed by worker `ledger-hygiene-w37` with the reason "DISSOLVED BY
SET — CLOSED ON WAVE-37 DERIVED NUMBERS at origin/main 501fb9670bc (NOT on PDS-D485's or D505's
claim)". Wave 37's own ledger-hygiene slice paid it. The charter-vs-ledger divergence that direction
names had already been closed by the time this wave dispatched.

<!-- doc-tier: agent | canonical-for: task-claim-lifecycle | budget: 1500tok -->

# The task claim lifecycle — the fenced contract

Split out of [TASK-SYSTEM.md](../setup/TASK-SYSTEM.md), which remains the human
guide (setup, Studio, organising work). **This file owns the machine-facing half:
what each verb does, what it fences on, and every refusal it can emit.**

Lifecycle: `open · in_progress · blocked · done · cancelled`.

## The verbs

The contract, precisely:

- **Claim** flips to `in_progress`, stamps `{worker, ts_iso, epoch}`, and bumps the epoch.
- **Release** — `POST /v1/tasks/:id/release`, holder `worker_id` + `observed_epoch`: `in_progress`→`open`, clears `claim.worker`+`assignee`, bumps the epoch, stamps `released_by`/`released_at`, emits `task.released`.
- **Stamp** — holder + epoch fenced. `--met` needs evidence **and** `--criterion-text` (exact row wording; index-only met-flip → 409 `criterion_text_required`). `--miss` needs neither — records one of the last 5 attempts, no `met` flip. Emits `task.criterion`; never trips the work-digest fence. **Real only once the PUBLISHED row holds it:** refusals are loud (exit 6 + remedy), but a draft-only row's stamp lands where no board reads it, and a `bp` predating #13410 prints a green for it. `make cli-build`; trust the read-back, not the exit code. **`in_progress` only** — a closed row refuses `not_in_progress:done`; no per-criterion evidence after close.
- **Withdraw** — `--withdraw --note "<why>"` (with `--criterion-text`) is the only verb that LOWERS a met flag: review refutes a proof *after* the close. Sets `met: false` so `criteria_progress` drops, **leaves the original evidence exactly where it was** (append-only is kept by adding, never by clearing), and appends a signed `{note, ts, worker, superseded_evidence}` record to the criterion's `withdrawals` list. Refuses an already-unmet criterion (`409 criterion_not_met`); needs no `--merge-gated` on a merge gate (lowering a lock cannot fabricate a done). The ONE stamp outcome allowed on a **sealed** row: `in_progress` = holder-only + epoch-fenced like any stamp; done/cancelled/open takes `--observed-rev <the rev you read>` instead (`409 observed_rev_required`). `python3 scripts/withdrawn_but_met.py --live` finds criteria still flagged met whose evidence retracts itself in prose (the pre-verb convention).
- **Merge gates are the lead's**; PR-body proof dies at merge — close over, never flip ([ADR 0005](../decisions/0005-pr-body-criteria.md)).
- **Pulse** — holder-only `{worker_id, now, criterion?}` heartbeat: renews the lease, emits `task.pulse`. Takes no epoch arg but **bumps the epoch** (measured 1→2→3→4), so the claim's epoch is stale after your first pulse — re-read `claim.epoch` before stamping or closing. `now` caps at **500 bytes** (501 → `now must be at most 500 bytes`).
- **Close** needs holder + epoch. Status defaults `done`; reason + criterion updates (`met:true` needs its `criterion` text) commit in the same rev-CAS. Brief drift → `doc_changed_since_claim`; pass `observed_rev` for strict full-rev CAS.
- **Leases expire.** A per-minute sweeper releases claims idle past `task_lease_ttl_seconds` (default **2700**, env-tunable), emitting `task.lease_expired` (reap keeps `assignee`). Finish, pulse or re-claim.
- **Ready** = `lifecycle_status` ∈ {`open`,`blocked`} AND every `blocks` edge points at a `done` task. Closing `done` auto-flips dependents `blocked`→`open` once their whole blocker set is done.
- **Criteria progress (advisory).** Envelopes (`get`/`ls`/`ready`/`prime`/children) carry `criteria_progress: {met, total}` — only `met:true` counts, omitted when absent (never `0/0`).
- **Reader order is contractual.** Criteria first, then the purpose dossier; un-dossiered tasks show facts labelled DERIVED. `why` is causal (the problem/risk), never a title/criterion restatement.
- **Rail awareness (advisory).** Claim/queue-claim/close carry `rail_rev` (ETag of the parent rail: children + `blocks` edges); prime carries `rails: {parent_id → rail_rev}`. `notices`: `blocked_while_claimed`, and `rail_changed` when body `observed_rail_rev` ≠ current. **Allow-and-fence (L4):** a blocker edge or `move` onto an `in_progress` task bumps its epoch.
- **Move (re-parent).** `POST /v1/tasks/:id/move` `{new_parent_id}` (null = root) flips `parent_id`, emits `task.reparented` `{from, to}`, returns `rail_rev` (dest) + `from_rail_rev`. Bad parent → 409 `invalid_parent`, self/descendant → `cycle`, same-parent → no-op.

## The refusal vocabulary

Every code below is a *contract* answer, not a transport failure — the request was
understood and refused for a named reason.

| Refusal | Cause → fix |
|---|---|
| `400 worker_id is required` | Claim/release/stamp/pulse/close need `worker_id` — positional via bp, JSON body via curl. |
| `409 not_holder` / `criteria_unmet` | Holder-only; a `done` needs criteria met **as stored**. Stamp as you prove — or record why: `--set holder_override=`/`criteria_override="<why>"`. |
| `409 fenced_off` | Stale `observed_epoch` — **your own `pulse` bumped it**, the lease was swept, or a blocker/move landed on your claimed task (L4). The hint names the pulse first. Renew: `bp task claim <id> <same-worker>` (digest kept), close with the new epoch. |
| `409 stale_claim` | Lost a concurrent claim race. Call `/v1/tasks/claim` again. |
| `409 doc_changed_since_claim` | The brief was edited under your claim — re-read, then close again. |
| `409 not_ready` | Targeted claim on an `in_progress`/`done`/`cancelled` task (your OWN in_progress re-claim is a **renewal**, not an error). |
| `409 blocked_by_unsatisfied_deps` | Targeted claim while a `blocks` edge points at a non-`done` task. |

Closing honestly — where the receipt goes, and what to do with what you could not
prove — is the [close-packet convention](close-packet.md).

# cch-w65 — the task author field, and the census that disagrees with itself

**Row:** `cch-w65-bl-a-task-document-has-no-author-field`
**Worker:** api-w14 · **Date:** 2026-09-11 · **Base:** `origin/main` @ `e41af712a`
**Verdict in one line:** c0's gap is CLOSED (shipped 2026-09-11, undeclared in the schema),
c1's backfill is IMPOSSIBLE and no sidecar can rescue it, and c2 needs NO code change —
it was ruled and shipped on 2026-09-06, and the fix the row's wording invites is the one
that ruling names as destructive. One NEW live defect found in c0's own shipped code.

Every count below carries the command that produced it. The document census runs against a
single full page of the published perspective:

```
python3 -c '<paged loop>'   # GET /v1/data/query/production/task?limit=500&offset=N
                            # until hasMore=false  ->  8,674 documents, 2026-09-11T06:4xZ
```

---

## c0 — the declared field list, read off the schema

`api/lib/barkpark/tasks/schema.ex`, `task_schema/1`, `fields:` at line 188. The 30 declared
top-level fields, verbatim in declaration order:

```
title  brief  description  purpose  design  design_doc  acceptance_criteria  estimate
execution_policy  queue_gate  due_at  priority  labels  tags  parent_id
lifecycle_status  assignee  worklog  blocked_reason  attachments  sessions
outcome  close_reason  retro  kind  claim  dependencies  papers  history  history_summary
```

**No author-like field is DECLARED.** The absence is controlled, not inspected:

```
git grep -niE '"(author|created_by|filer|creator|filed_by|principal)"' \
  -- api/lib/barkpark/tasks api/lib/barkpark/tasks.ex api/lib/barkpark/plugins/tasks.ex
# -> 0 hits
git grep -c '"assignee"' -- api/lib/barkpark/tasks.ex api/lib/barkpark/tasks/schema.ex
# -> 1, 1   (CONTROL: the probe can see a field that IS there)
git grep -c "created_by" -- api/lib/barkpark/tasks/schema.ex
# -> 0       (absent from the schema specifically)
```

### …but the SERVER writes one anyway, since eight hours ago

`content.created_by` is stamped by the writer, not declared by the schema:

```
git log --oneline -1 -S stamp_task_creator -- api/lib/barkpark/content/writer.ex
# 992ea5ac5 feat(content): server-set creator attribution on a task birth (#17530)
git log -1 --format='%ci' 992ea5ac5     # 2026-09-11 00:28:20 +0200
```

`writer.ex:1555-1639` — `stamp_task_creator/4` + `resolved_created_by/2`. Server-set on every
non-`:sync` birth, from `CallerContext.actor_stamp/1`; a body-supplied `created_by` is discarded
on every write in both directions.

**It is LIVE on the ledger this row lives on:**

```
curl -s https://guerrilla.barkpark.cloud/status.json | jq -r .commit   # 0f6310c2c
git merge-base --is-ancestor 992ea5ac5 0f6310c2c && echo HAS           # HAS
```

45 of 8,674 task documents carry `content.created_by`; all 45 are
`{"kind":"api_token","id":"e5ce2b91-e38d-426e-ae68-5006dc414b97"}`.

**SO c0's ANSWER IS: the gap is real in the SCHEMA and closed in the WRITE PATH.** The one
thing still owed is the DECLARATION — `created_by` belongs in the `system` group of
`task_schema/1`, or the dossier contract goes on claiming a key set the engine does not have.
That is ~10 lines, and it is the whole remaining cost of c1.

### THE NEW DEFECT: a draft birth re-attributes a legacy row

3 of the 45 stamped rows were BORN weeks before the stamp existed and carry a creator stamped
TODAY:

| row | `_createdAt` | `created_by.at` |
|---|---|---|
| `spd-b42-georgia-default-shortfall-inflow-width` | 2026-07-20T05:57:54Z | 2026-09-11T04:48:05Z |
| `dr-w15-bl-deferral-cause-null-audit` | 2026-08-07T15:04:24Z | 2026-09-11T00:57:07Z |
| `dr-w26-followup-queued-seconds-disposition` | 2026-08-09T01:49:54Z | 2026-09-11T01:22:45Z |

All three are `_draft: false`, `_publishedId == _id`. The mechanism is the DRAFT TWIN, and the
revision trail dates it to the second:

```
curl -s -H "Authorization: Bearer $T" \
  "$B/v1/data/history/production/task/spd-b42-georgia-default-shortfall-inflow-width?limit=3"
#  action=create   status=draft      2026-09-11T04:48:05.655116Z   <-- == created_by.at
#  action=publish  status=published  2026-09-11T04:48:06.121495Z
```

`resolved_created_by(nil, opts)` fires because `prev_doc` is nil for `drafts.<id>` — a draft
twin of a legacy published row is a BIRTH. The publish 466 ms later promotes that content onto
the fifteen-week-old published row. `writer.ex:1600-1606` states the opposite invariant in
prose: *"PRE-EXISTING ROWS STAY HONESTLY UNATTRIBUTED… the update arm below is what keeps them
that way — a patch to a legacy row DROPS a body-supplied `created_by` rather than crediting
whoever touched the row next, which is the exact failure the row was filed against."* The
update arm holds; the draft-birth arm goes around it. Rate so far: **3 of 45 stamps in the
first eight hours are misattributions**, and every one of them credits an EDITOR as a FILER.

NOT FIXED HERE — a wrong repair to an attribution field is worse than a recorded one, and the
correct repair (a draft birth inherits its published twin's `created_by`, including its
absence) is a `Content.Writer` change with its own blast radius. It needs its own row.

## c1 — pricing, given the field now exists

| writer | principal at write time | stamps today |
|---|---|---|
| `POST /v1/data/mutate` (MutateController) | `conn.assigns.caller_context` from the verified bearer | YES |
| `POST /api/documents/:type` (LegacyController) | same | YES |
| `bp task create`, MCP `task_create`, fleet file-orders, epic-cycle Decide, GitHub adopt via `/v1/tasks` | clients of the two doors above (`Content.apply_mutations`) | YES, inherited — no third birth path exists |
| Studio task pane (`studio_live/shared.ex`, `source: :studio`) | user session | YES, `{"user", id}` |
| `Github.Intake` (`source: :github`) | no `:caller_context` -> nil `actor_id` | NO, honestly unstamped |
| `Sync.Applier` (`source: :sync`) | exempt first, by design | NO, preserves the upstream value |
| Oban / background workers | no `:caller_context` | NO |

**Marginal cost of "adding the author field": ZERO writers.** One seam
(`Content.Writer.stamp_task_creator/4`) already covers every birth door. The only unpaid item
is the schema declaration.

### BACKFILL FOR THE EXISTING EPIC CHILDREN: IMPOSSIBLE, NOT MERELY HARD

The row says ~855; the live count is **945** children of `cloud-console-hardening-epic`, of
which **942 have `created_by: null`**. Three sidecars were checked and none carries a filer:

| sidecar | actor column | value on task writes |
|---|---|---|
| `revisions` | `actor_user_id` (mig `20260630120000`), `actor_kind`/`actor_id`/`actor_label` (mig `20260904120000`) | **NULL on every revision checked** |
| `mutation_events` | none — only `source` (mig `20260626130000`, default `"api"`) | n/a |
| `audit_events` | fed from the same `actor_user_id` | same nil |

The reason is structural, not incidental: `Broadcast.tap_broadcast/7` calls
`save_revision(doc, type, dataset, action, actor_user_id)` at `broadcast.ex:116` — **five
args**, so the 6th `actor_stamp` parameter defaults to `%{}` and the kind/id/label triple is
never written from the generic writer at all. Only `papers/block_ops.ex` and
`papers/value_writeback.ex` pass it. And `actor_user_id` itself comes from `opts[:user_id]`,
which is nil for an api_token caller. Verified on live data — every revision of
`spd-b42-…` returns `actor_id: null, actor_kind: null, actor_label: null, actor_user_id: null`.

**Any backfill of `created_by` on those 942 rows would be fabricated. Say so plainly; do not
build one.**

## c2 — the cancel-without-a-close-rail shape

### The mechanism, in code

```
api/lib/barkpark/tasks/internal.ex:218   close_holder/2 -> claim_map(content) == nil -> {:ok, :unclaimed}
api/lib/barkpark/tasks/close.ex:1334     apply_close_update/10
                                           %{"claim" => claim} when is_map(claim) -> stamps closed_by/closed_at/closed_session
                                           _ -> Map.put(content, "lifecycle_status", new_status)   # worker_id DISCARDED
```

A close of a never-claimed row is ACCEPTED with no override and records nothing on the
document. It is **not cancel-specific** — it is every terminal transition on a claim-less row.

### The size: the row is off by 21x, and it names the smaller half

Terminal rows, whole ledger, bucketed by what the claim rail actually holds:

| lifecycle | rows | `claim.closed_by` | claim map, NO close terms | no claim map at all |
|---|---|---|---|---|
| done | 6,271 | 6,047 | **147** | 77 |
| cancelled | 875 | 832 | 0 | 43 |
| blocked | 19 | 18 | 0 | 1 |
| **total terminal** | **7,165** | **6,897** | **147** | **121** |

CONTROL (non-vacuity): 7,331 rows carry a claim map and 6,899 carry `claim.closed_by`, so the
probe can see the field and the absences are real.

`cloud-console-hardening-epic`, 945 children: done 726 (**13** with no claim map), cancelled
118 (**8** with no claim map), zero in the middle bucket. **The two derivations differ by 21 on
this epic, not by one**, and 13 of the 21 are `done` — so "a cancel can happen without a close
rail" names the minority of its own defect. Ledger-wide the gap is **268**.

### THE FIX WAS ALREADY RULED — AND IT IS NOT THE ONE THIS ROW INVITES

```
git log --oneline -1 -S pds-bl-close-audit-gaps -- api/lib/barkpark/tasks/close.ex
# 14ae4e6c5 fix(tasks): a claimless close names its closer, and a Studio close names its token (#16295)
git log -1 --format='%ci' 14ae4e6c5   # 2026-09-06 06:55:50 +0200   (ancestor of origin/main)
```

`pds-bl-close-audit-gaps` measured the same hole on 2026-09-06 (139 of 6,617 terminal rows
then; 121 now) and ruled: **record the closer on the `task.closed` mutation event, beside
`caller_token_id`, and leave the DOCUMENT saying truthfully that nobody ever held the row.**
`close.ex:604-660` carries the reasoning verbatim, including the two costs of the alternative:
synthesising a claim map erases the never-held fact container rows depend on, and it silently
converts `idempotent_replay?/3` into a success receipt for an unidentifiable second caller.

**I BUILT THE ALTERNATIVE ANYWAY AND IT PROVED THE RULING RIGHT, SO IT IS REVERTED.** Writing
`%{"closed_by", "closed_at"}` on the `_ ->` arm compiled and ran, and broke exactly the two
tests the ruling predicts:

```
MIX_TEST_PARTITION=api_w14 mix test test/barkpark/tasks/close_test.exs \
                                   test/barkpark/tasks/close_idempotent_replay_test.exs
# with the change:  84 tests, 2 failures
#   close_test.exs:315  already-terminal guard: second close by "w" returned {:ok, …} not {:error, :stale_claim}
#   close_test.exs:2147 "AND THE ROW IS STILL HONESTLY CLAIMLESS. No holder was invented."
# reverted (this branch's tree):  83 tests, 0 failures
```

It also needed a second edit to `Internal.close_holder/2` to stop a reopened row 409-ing
`not_holder` against a claim that never had a holder — a two-file behaviour change to
re-litigate a settled question. Reverted in full. **No api/ file changed on this branch.**

### THE RULING FOR LAW 0: THREE RAILS, THREE QUESTIONS

| question | rail | complete? |
|---|---|---|
| HOW MANY rows closed | `content.lifecycle_status` on the published document | YES — present on all 7,165 terminal rows |
| WHO closed a CLAIMED row | `content.claim.closed_by` | NO — misses 268 ledger-wide, 21 on this epic |
| WHO closed ANY row | `task.closed` mutation event: `closed_by` + `caller_token_id` (+ `actor.epoch` when a lease existed) | YES from 2026-09-06; silent before it |

**`lifecycle_status` is canonical for Law 0's CLOSES integer.** A claim-rail close census is
not a second honest derivation of the same quantity — it answers a different question and is
incomplete by design. The event rail answers WHO, never HOW MANY, and cannot serve a
historical census because it did not exist before 2026-09-06.

The middle bucket has its own answer: those 147 `done` rows carry a real lease (worker, epoch,
work_digest) and a `close_reason` but no close terms, i.e. they were flipped to `done` without
`Close` ever running — `"Historical completion reconciled from 7/7 met acceptance criteria"`
bulk writes and pre-stamp closes. **It is historical: newest `_updatedAt` 2026-08-21, ZERO
since 2026-09-06.** The 121-row claim-less bucket, by contrast, is live (3 rows on or after
2026-09-06) and is the ruled-legitimate shape.

### PROPOSED CHARTER SENTENCE — for the epic owner, NOT edited here

To be added to the standing Law 0 statement (near D780/D798/D800). Proposed verbatim:

> **LAW 0'S CLOSES INTEGER IS DERIVED FROM `content.lifecycle_status`, NEVER FROM THE CLAIM
> RAIL.** The two are not two honest derivations of one quantity: `claim.closed_by` is absent
> on 268 of the ledger's 7,165 terminal rows and on 21 of this epic's 945 children (13 `done`,
> 8 `cancelled`), because `Close.apply_close_update/10` deliberately does not invent a claim
> for a row nobody ever held (`pds-bl-close-audit-gaps`, #16295, 2026-09-06). A wave that wants
> to know WHO closed a row reads the `task.closed` mutation event, which carries `closed_by`
> and `caller_token_id` for claimed and claim-less closes alike from 2026-09-06 onward and is
> silent before it. D798's "`cch-w60-s6` … a claim-rail census cannot see it" is CORRECT and
> UNDERSTATED: the shape is 21 rows on this epic, not one, and it is not specific to `cancel`.

## What was NOT run

- No `MIX_ENV=prod mix compile --warnings-as-errors` — no file under `api/` is modified on this
  branch (the experiment was reverted; `git status` is clean but for the packet).
- No mutation proof of a NEW behaviour, because no new behaviour ships. The mutation evidence
  above runs the other way: the mutation is the rejected fix, and the two tests it reds are the
  ruling's own guards.
- No write to the ledger row (no claim, no stamp, no close) — `lead-api-r9` holds it.
- The 45-row `created_by` census is the PUBLISHED perspective only; draft twins were not paged.

## What the filing got wrong

1. **"there is no author, no created_by, no filer"** — true when filed on 2026-08-09, false as
   of 2026-09-11T00:28Z and live on the ledger the row is stored in. The gap that remains is
   the SCHEMA DECLARATION, which is a different and much smaller claim.
2. **"the 855 existing children"** — the live number is 945.
3. **"The two derivations disagree by one row"** — 21 on this epic, 268 ledger-wide.
4. **"a cancel can happen without a close rail"** — so can a `done`, and `done` is 13 of the
   epic's 21. Framing it as a cancel shape hides the majority case.
5. **The disposition_reason's RULING, "add the author field"** — already executed by a
   different lane. The row should be re-read against #17530 before any more is spent on it.

## Follow-ups this packet recommends filing

- **Declare `created_by` in `task_schema/1`'s `system` group** so the dossier contract stops
  under-declaring a live key. ~10 lines.
- **A draft birth must inherit its published twin's `created_by`, including its absence.**
  3 misattributions in the first 8 hours; every one credits an editor as a filer.
- **Thread the actor into `save_revision/6` from `tap_broadcast/7`** (the 6th argument is
  already there and is never passed), so version history stops being blind to who wrote it.

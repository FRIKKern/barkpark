# Deploy-reliability epic — SEAL RULING (drafted 2026-08-08, wave 22 verify phase)

Status: DRAFT RULING for the wave-22 Decide phase. No prior seal ruling exists anywhere
(`git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -nEi "seal criteri|epic seal|SEAL RULING|definition of done"` → one incidental
hit at line 2071 about a *wave's* definition of done; the PDS charter → zero hits). A 22nd wave has
been run against an epic that has never written down when it is finished.

Every criterion below is stated so it can be FAILED, with the command that decides it.

---

## RE-DERIVATION RECIPES (run these before quoting any number here)

    # census (all figures in S-0/S-4 below), against control-plane Postgres
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -q' < census.sql
    # NOTE: the container's role is barkpark_cloud / db barkpark_cloud_prod.
    # `-U postgres` FAILS ("role postgres does not exist"). `docker exec … psql -f <path>`
    # resolves the path INSIDE the container — pipe the file on stdin, as above.

    # ledger split
    bp task get task-fb4fb869490b4213 -o json   # children[] carry lifecycle_status + criteria_progress

    # null-sort mechanisms
    git show origin/main:internal/cli/cloud_usage.go      | sed -n '321,340p'
    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '246,297p'

    # the leak boundary — PATH CORRECTION, see S-3
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '11040,11052p'

---

## S-0. THE POPULATION EVERY SEAL NUMBER IS QUOTED AGAINST

Live census, `deployments` on cloud-db-1, 2026-08-08 (31,699 rows, 2026-07-14 → 2026-08-08):

| window | volume | live | failed | deferred | live/row | live/non-deferred |
|---|---|---|---|---|---|---|
| lifetime | 31,699 | 10,575 | 18,622 | 2,502 | **33.36%** | 36.22% |
| last 7d | 10,206 | 1,969 | 5,735 | 2,502 | **19.29%** | 25.56% |
| pre-door (< 2026-08-06 22:29:27) | 29,167 | 9,868 | 18,602 | 697 | **33.83%** | 34.66% |
| post-door | 2,532 | 707 | **20** | 1,805 | **27.92%** | **97.25%** |

**RULING S-0a — the 98.6% headline is restated or it is not printed.** The wave's own
`657/666 = 98.6%` and this census's `97.25%` are the same *shape* of number: a rate whose
denominator drops the deferred population. Post-door that population is 1,805 of 2,532 rows =
**71.29% discarded**. The D3-legal statement is the pair, always together:

> post-door: 707 live of 2,532 rows = **27.92% live-per-row**; of the 727 rows that reached the
> build at all, 707 live = 97.25%, with **1,805 rows (71.29%) deferred at the door and excluded**.

Printing `98.6%` or `97.25%` bare is a seal-blocking violation of the epic's own honesty law, in
the wave that sells on honesty. FAILS IF: any shipped surface renders a post-door success rate
without its deferred population in the same view.

---

## S-1. WHAT RETIRES THE NAMED HARM

The wish's harm is "Guerrilla deployments fail far too often and nothing reports it."

**RULING S-1a — the harm is retired on the FAILURE ARM and the epic must say so in its own voice.**
The failure numerator is FROZEN: last `status='failed'` row inserted **2026-08-07 10:02:55.296662**,
count **18,622**, and 2026-08-08 has **0 failed rows in 259**. Per-day live/row: 11.57% (07-30) →
27.69% (08-07) → 33.98% (08-08).

**RULING S-1b — the LIFETIME failure rate (58.75%) is RETIRED BY NAME as a seal gauge, and the
reason is not that it looks bad — it is that it CANNOT FAIL.** Its numerator has been frozen for
~22 h. A frozen numerator over a monotonically growing denominator can only fall. A gauge that is
arithmetically incapable of moving the wrong way is exactly what this epic's own tripwire law
forbids. Arithmetic (rerun: the python in this file's proofs):

    lifetime failed/row = 18,622/31,699 = 58.75%
      to reach 25%: needs 42,789 more non-failed rows = 2.3x current lifetime volume
                    = 165 days at 2026-08-08's clean-row rate (259/day)
      to reach 10%: needs 154,521 more rows = 5.9x volume

So the lifetime rate will read "failing" for months after the harm is gone, and will read "improving"
every single day regardless of what the platform does. It is a **monument, not an instrument**.
FAILS IF: the lifetime rate appears on any surface that an operator could read as current health,
without the words "cumulative since 2026-07-14; numerator frozen 2026-08-07".

**RULING S-1c — the surviving harm is the SECOND clause, "nothing reports it", and it is now the
WHOLE epic.** No seal is available on reporting-of-failures alone, because there are no failures to
report. The seal moves to memory (S-2).

---

## S-2. WHAT DURABLE MEMORY MUST ANSWER

**Verified absence:** `git grep -lni "first_seen_at\|first_served_at\|sha_first_seen" origin/main --
cloud/ api/ internal/` returns **nothing**. `git grep -n serving_since origin/main -- cloud/` outside
tests returns **only** `health.ex:25,54,60,62`. There is no durable record of which commit went live
when, anywhere in the tree.

**RULING S-2 — the epic seals only when one command answers all four, from a DURABLE store, after a
container replacement:**

1. **WHICH** commit is live on each of the two hosts that run this product.
2. **SINCE WHEN** — an absolute instant that survives `docker restart`. FAILS IF: a bare
   `docker restart` with no code change makes the answer read *newer*. (Today it does:
   `health.ex:64-75` derives `serving_since` from `:erlang.monotonic_time/0` against
   `:erlang.system_info(:start_time)` — a process point sample, as its own docstring admits.)
3. **HOW LONG IT TOOK**, split merge→run-start (GitHub's queue) from run-start→serving (ours), so
   the gauge blames the right system. FAILS IF: the split uses run-level `run_started_at` — the
   survey proved that equals `created_at` on the 20,020 s outlier while the first JOB started 5h25m
   later.
4. **IS THE MECHANISM STILL ON** — is `@build_slot_capacity` still refusing, stated as an observed
   concurrency and a refusal RATE, not as a module attribute served to nobody.

**RULING S-2b — the answer must be keyed on the SHA, not on the run.** 180 of 493 merges (36.5%)
were delivered by a *later* run and 179 runs were evicted from the `deploy-production` concurrency
group. A run-keyed memory answers the wrong question 36.5% of the time.

---

## S-3. WHAT CLOSES THE RECORDER-WITHOUT-A-READER LIST

**RULING S-3 — a slice is not done until a test asserts RENDERED BYTES from a named human caller.**
The standing list, each of which FAILS the epic today: the delivery gauge on a 403 route; the
rollout brake machine-only; `build_slots` served to nobody at
`instance_site_deploy_controller.ex:64`; `avgDurationMs` over 24,832 crystals rendered by nobody;
ROUTE emitted and discarded by a `@stage_names` guard.

**RULING S-3a — two entries come OFF the list on evidence, and one must be ADDED.**

*Off:* `deferral_cause` is now populated and distinguishable. *On, newly measured:* it is populated
on only **684 of 2,502 deferred rows (27.3%)** — 1,818 deferred rows carry `deferral_cause = NULL`,
and the only value ever written is `BOX_AT_CAPACITY_DEFERRED`, **first seen 2026-08-07 10:12:35**,
i.e. ~11.7 h AFTER the door. **`BOX_BUSY_DEFERRED` has ZERO rows in production.** The direction's
claim that leg 3's counted-door half is "DONE end to end" with two distinct causes is **REFUTED by
the data**: one cause exists, and it explains a quarter of the population. FAILS IF: any
door-refusal rate is computed over deferred rows without stating that 72.7% of them have no recorded
cause.

*Also newly measured:* `coalesced_attempts > 0` on **2 rows of 31,699**, sum 15. The digest called it
"mis-sited"; the census upgrades that to **quantified**: the column is 99.994% empty and cannot carry
any seal criterion.

**RULING S-3b — PATH CORRECTION, binding on every downstream reader.** The inherited citation
"`router.ex:11046`" resolves to **`cloud/lib/barkpark_cloud/web/router.ex`**, NOT
`api/lib/barkpark_web/router.ex` — the latter is 2,651 lines on origin/main and contains no
`strip_ansi` at all. A verifier who reads the obvious path finds nothing and would report a LIVE
defect as dead. The defect is live and confirmed today at the corrected path:

    failure_reason_raw: d.failure_reason |> FailureCopy.scrub() |> FailureCopy.strip_ansi(),

against `failure_copy.ex:181-187`'s own doctrine ("measured 2000/2000 leaked under
`scrub |> strip_ansi` and 0/2000 under `strip_ansi |> scrub`… Any path that renders a raw capture
without classifying it must be `strip_ansi() |> scrub()`"). Aggravating: the comment two lines above
the defect *asserts the wrong order as correct* ("Scrubbed, then ANSI-stripped"). A self-certifying
wrong comment is worse than no comment. FAILS IF: the epic seals with any priority-1 leak boundary
open.

---

## S-4. WHAT MAKES THE 316-OPEN LEDGER HONEST

`bp task get task-fb4fb869490b4213 -o json`, 388 children:

| lifecycle | n | criteria shape |
|---|---|---|
| open | **316** | 269 at **0/N**, 41 partial, 6 no-criteria |
| done | 66 | 65 full (met==total), **1 at 0/N** |
| cancelled | 6 | 5 at 0/N, 1 no-criteria |

Open aggregate: **327/1,391 criteria met = 23.5%**.

**RULING S-4a — the ledger is HONEST and must NOT be "cleaned".** There are **zero** open tasks with
all criteria met — no stale-open shipped work at all. Bulk-cancelling the 269 never-started rows to
make the ledger read sealed is the exact false-done this epic has already caught twice, and it is
forbidden. FAILS IF: any bulk lifecycle mutation touches more than 5 children in one act without a
per-task evidence stamp.

**RULING S-4b — the ledger is UNBOUNDED, and that, not its size, is the seal blocker.** Filed by day:
22 / 99 / 233 / 34 (08-05→08-08). Done by day: 4 / 20 / 42 / 0. The epic files ~2.7x faster than it
burns; of the 269 never-started opens, **254 (94%) were filed in the last 3 days**. Seal therefore
CANNOT be "the ledger is empty" — at this ratio it never empties. FAILS IF: a proposed seal criterion
is stated as a count of open tasks.

**RULING S-4c — seal is stated on the 41 PARTIALS, which are the real residual.** Every one is
shipped work one criterion short (12/13, 12/13, 11/12, 11/12, 10/11, 9/10 ×5, 8/9 ×4 …), and the
missing criterion is characteristically "merged" or "live proof". Seal criterion: **all 41 partials
reach met==total or are explicitly re-scoped with a written reason.** That is a bounded, falsifiable
set; the 269 zeros are backlog and are re-parented to a successor epic, not cancelled.

**RULING S-4d — one false-done to reopen, by name.** `dr-followup-start-reported-callers` ("The other
three `Deploy.start/1` call sites still fly blind") is `lifecycle_status: done` at **0/4 criteria
met**. It is the only done-at-zero row in 388. Reopen it or write down why closing it at 0/4 was
correct.

**RULING S-4e — the highest-leverage act this wave is a PUSH, not a builder, and it is STILL
unperformed.** Re-verified 2026-08-08: `git ls-remote --heads origin | grep -ci dr-w21` → **0**;
`gh pr list --search dr-w21 --state all --json number,title` → **[]**. Six wave-21 slices are built
on local `loop-epic/*` branches and exist nowhere on origin. FAILS IF: the epic seals while any
built slice is unpushed — that is the epic's own harm ("nothing reports it") reproduced in its
own process.

---

## S-5. WHICH TRIPWIRE CAN GO THE WRONG WAY AND SAY SO

**RULING S-5 — exactly one gauge is nominated as the seal tripwire, and it is a WINDOWED
live-per-row with its population, in D3's CLOCK/RATE vocabulary, refusing below its minimum sample.**
It qualifies because it can move both directions on real events:

- it FELL on real degradation: 22.90% (07-27) → **11.57% (07-30)**;
- it ROSE on the real fix: 11.57% → 25.67% (08-06) → 27.69% (08-07) → 33.98% (08-08);
- it will FALL again if the door starts refusing more than it admits — post-door deferral share is
  already 75.47% / 71.41% / 66.02% by day, so the same instrument that shows the fix also shows the
  fix's cost.

Its refusal arm is load-bearing: on 2026-08-08 the sample is 259 rows and shrinking as the fleet
quiets, so the gauge must state its n and refuse below the minimum rather than print a lucky number.
FAILS IF: the nominated tripwire has no observed instance of moving in the unfavourable direction
in its own recorded history.

---

## S-6. RULING — WHICH NULL-SORT MECHANISM IS LAW

Two shipped precedents disagree, and no gate reds on the divergence.

**Mechanism A — `internal/cli/cloud_usage.go:327-338`, `usageStateSeverity`.** Absence is first
mapped to a NAMED token (`unmetered` for never-read, `unavailable` for read-and-broke) and the token
is ranked: `over_limit 4 > near_limit 3 > unavailable 2 > unmetered 1 > live 0`. Correct on the axis
it addresses — a blind meter outranks a live one. **But its unknown-input arm is
`default: return 0` — "live", the FLOOR.** An unanticipated token rolls a fleet row up as fully
healthy. Fail-OPEN.

**Mechanism B — `internal/cli/cloud_status_cmd.go:246-297`, `attentionRank` + `attentionBucket`.**
Rank for an unknown label is `len(attentionRankOrder)+1` (sorts last, benign), but the healthy
boundary is stated separately as a **MEMBERSHIP switch** whose `default:` is `"attention"`, with the
comment: *"a new state that someone forgets to rank cannot silently land in HEALTHY — the exact
inversion this epic exists to kill."* Fail-CLOSED.

**RULING S-6 — MECHANISM B IS LAW.** Three reasons, in order of weight:

1. **Only B's unknown-input behaviour is pinned by a test that can fail.**
   `cloud_status_cmd_test.go:128` asserts `attentionBucket("some_future_rung") == "attention"`.
   `git grep -n usageStateSeverity origin/main -- internal/` shows the usage tests
   (`cloud_usage_unavailable_test.go:84-92`) assert only the four *known* orderings; **no test
   anywhere exercises A's `default` arm.** Under this epic's own law — a check that cannot fail is
   not a check — A's default is unguarded.
2. B separates SORT ORDER from the HEALTHY/NOT boundary. A conflates them, so a single integer both
   orders the table and decides whether the row is calm; there is no place to be safe in.
3. B already matches the shipped console (`app.js classifyBp`), so B is the cross-surface answer and
   A is the outlier.

**Scope of the ruling, stated honestly.** A's fail-open default is today **LATENT, not live**:
`usageStateToken` (cloud_usage.go:625-645) can only return the five tokens A cases, so `default: 0`
is currently unreachable. It becomes live the instant a sixth token is added — which is precisely
what wave 22's proposed CLOCK/RATE vocabulary would do. Fix is one line plus one test:
`default: return len-of-ladder` (unknown outranks live) and a
`usageStateSeverity("some_future_meter") > usageStateSeverity("live")` assertion mirroring
`cloud_status_cmd_test.go:128`.

**Binding form of the law, for every new surface this epic ships:** *a value that was never measured
must be a NAMED token, never a zero; the token must sort above healthy; and the healthy boundary must
be a membership test whose default is NOT healthy, pinned by a test that feeds it a token nobody has
defined.*

---

## SEAL CHECKLIST (the whole ruling, as failable rows)

| # | Criterion | Fails if |
|---|---|---|
| 1 | Lifetime failure rate retired by name as a health gauge | it appears anywhere as current health |
| 2 | Every post-door success rate carries its deferred population | a bare 97–99% ships |
| 3 | Durable `(sha, first_seen_at)` store, SHA-keyed, survives restart | `docker restart` makes the lag read newer |
| 4 | Lag split merge→run-start / run-start→serving | the split uses run-level `run_started_at` |
| 5 | Door concurrency + refusal RATE are measurements | `build_slots` is still a module attribute served to nobody |
| 6 | `deferral_cause` NULL share (72.7%) stated wherever the door is reported | a refusal rate ships without it |
| 7 | Every recorder ships its reader in the same PR, proved on rendered bytes | a slice merges with a machine-only reader |
| 8 | The priority-1 raw-capture leak closed at `cloud/.../web/router.ex:11046` | `scrub \|> strip_ansi` survives on any raw path |
| 9 | 41 partial tasks reach met==total or are re-scoped in writing | any is bulk-cancelled |
| 10 | 269 never-started tasks re-parented, NOT cancelled | >5 children bulk-mutated without per-task evidence |
| 11 | `dr-followup-start-reported-callers` reopened or justified | it stays done at 0/4 |
| 12 | Zero built-but-unpushed slices | `git ls-remote --heads origin \| grep -c dr-w2*` finds a gap |
| 13 | One nominated tripwire with a recorded unfavourable move | the tripwire has never gone the wrong way |
| 14 | Mechanism B is law; `cloud_usage.go` default inverted + tested | `usageStateSeverity`'s default still returns live |

---

## S-7. DO NOT BUILD A SEAL PREDICATE — ONE ALREADY SHIPS

`cloud/priv/static/__preview__/seal-predicate.mjs` exists on origin/main and is the
cloud-console-hardening epic's executable seal gate. Its historical fail-open hole is CLOSED:
`grep -n "EMPTY-ROSTER" ` shows the refusal at **line 1274** ("R1 applied to the population it was
written for"), alongside `EMPTY-DEFECT-REGISTER` at 1179. It already refuses a zero-cardinality
roster, which is exactly the failure mode ruling S-4a forbids.

**RULING S-7 — deploy-reliability ADOPTS this predicate (`--epic task-fb4fb869490b4213
--successor <name>`) rather than writing a second one.** Two consequences follow immediately:
its `EMPTY-ROSTER` refusal mechanically enforces S-4a (cancelling the 269 to drain the roster would
trigger a refusal, not a SEAL), and its by-name forwarding clause is the mechanism S-4c needs to
re-parent the 269 zeros without cancelling them. FAILS IF: this wave writes a bespoke seal script.

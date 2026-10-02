# dr-w22: the build-concurrency lever — experiment design + owner decision packet (2026-09-11)

Task `dr-w22-bl-build-concurrency-lever-experiment-packet`. This file is a PACKET, not a
fix: nothing under `api/lib/barkpark/sites/` is touched and `@build_slot_capacity` is not
raised (D180/D252 stand).

**Read this section before any number below.** Every figure here is either (a) re-derived
today from `origin/main` by the command printed beside it, or (b) QUOTED from a dated
charter ruling and labelled with that date. No quoted figure is presented as re-derived.
Two of the four criteria (c1, c2) need the live control-plane DB and a quiet box; they are
NOT re-derived here — §5 and §6 carry the exact procedure so an owner with a box can run
them, and the criteria are reported `--miss: prod-gated`.

## 0. What the filing said, and what `origin/main` + the charter actually say

| Filing claim | Status | Source |
|---|---|---|
| `@build_slot_capacity 1` at `deploy_runner.ex:301`, `build_slot_capacity/0` at `:682-683` | **LINE DRIFT** — the facts hold, the lines do not | now `:387` and `:879-880`; re-derive: `git grep -n build_slot_capacity origin/main -- api/lib/barkpark/sites/deploy_runner.ex` |
| The attribute has no config or env path | **TRUE, re-derived** | `@build_slot_capacity 1` is a bare module attribute; `def build_slot_capacity, do: @build_slot_capacity` (`:880`). No `Application.get_env`, no `System.get_env` reaches it. |
| Its docstring says raising it is "how a box swaps itself to death" | **TRUE, verbatim** | `:873-876`: *"Deliberately not operator-tunable from a control-plane deploy: raising it here without raising the unit's resource caps is how a box swaps itself to death."* |
| "Nothing currently caps cross-site build concurrency" | **FALSE AS WRITTEN, and this is the packet's central correction** | charter D364 (`:7078-7095`): D350's mechanism clause "conflates RUN concurrency with COMPILE concurrency, and two caps exist". `@build_slot_capacity` IS the cross-site admission door; `ef77af274` (#9827) added it and **its first refusal fired 2026-08-06T22:29:27Z**. |
| The 6.9× search-latency collateral is the live customer number | **SUPERSEDED** | D364 closes with: *"D350's 6.9× ratio must not be re-used in any form."* The ≥2-concurrent regime it measured was **closed by a shipped fix**: search p50 **8,314 ms → 781 ms** across the door (D364, 2026-08-08, quoted not re-derived). |
| "The terminal-abandonment arm is UNTESTED in production data" | **FALSE** | charter D480: the bound **has** fired — *"six times, all at exactly 12 rounds, inside ONE 2h21m window on 2026-08-07 across five sites, plus one busy-slug abandonment at 6 rounds on 08-05."* What is true is narrower: it has never fired inside the *stamped* population (`deferral_depth`'s first non-null stamp is 2026-08-07 10:12:35, ~6.5 h AFTER the last abandonment, with 1,818 deferred rows NULL). |
| "depth 9 against a bound of 12" | **TRUE AS A READING, MISLEADING AS A BOUND** | `defer/3` fires the terminal arm at `prior >= max_consecutive_deferrals(cause) - 1` (`cloud/lib/barkpark_cloud/sites/deploy.ex:1712`), so the bound-th round is written `failed`, never `deferred`. **The maximum writable DEFERRED depth is 11**, not 12 (`deploy.ex:1729-1732`, in the code's own words). D560 struck D525's depth-9-vs-12 comparison as unfalsifiable for exactly this reason. |
| "245 at depth 1, decaying to 1 each at 7/8/9" | **A SNAPSHOT OF A TIME-VARYING QUANTITY** | three different charter readings disagree because the population moves: D480 live ladder at 10:16Z = 1/461 2/357 3/253 4/142 5/50 6/12 7/2 8/1 9/1; D480 post-W20-backoff = 690 rows, **max depth 7, n=1**; D604 (since 08-10) = 141 deferred, **depths 1–5**. Never pin this distribution; re-take it (§6). |
| "4.9 builds/min against 0.95 supply, 5.3× oversubscribed" | **NO DURABLE PRODUCER** | D419: a grep over `cloud/lib` + `internal/cli` for any builds/min or supply rate returns nothing. The comparable measured figure is D180's capacity ≈**78–95 builds/hr** against **103.6 attempts/hr** (ρ 1.28 peak, 0.58 median) — quoted, 2026-08-07. |

**Consequence for the owner: the concurrency lever has ALREADY BEEN PULLED once, in the
"on" direction, and it worked.** `@build_slot_capacity 1` is not an absent cap awaiting an
experiment; it is a cap that took the ≥2-concurrent regime to 0.00% of wall time and took
the largest customer-visible harm this epic ever measured down by ~10×. The open question
is therefore not "should we add a cap" but **"is 1 the right value, and what does moving it
cost"** — and that question is fenced by D180/D252, which is why the first item in §7 is a
fence question, not a build.

## 1. The two hypotheses, stated so they can lose

- **H-helps.** The cap converts *concurrent* build pressure into *serialised* build
  pressure. Publishes wait longer at the door but each build runs on an unloaded box, so
  the publish→live JOURNEY gets faster and fewer journeys die.
- **H-chain.** The cap does nothing but move the queue into the deferral ladder. Each
  refusal starts or extends a chain paced by `deferral_backoff_seconds/1`
  (`deploy.ex:1660-1662`, `min(base * depth, max(base, 240))`), so journeys get *longer*
  and some walk the ladder to the terminal arm and are ABANDONED — the failure mode the
  depth-derived backoff (#10611, charter D373) already fights.

The two are not opposites in deferral COUNT. **Both hypotheses predict more deferrals**
(D419), so deferral count, deferral rate, and mean chain depth decide nothing and must not
be the outcome variable. Depth is also a biased proxy for wall clock: a full capacity chain
costs `60+120+180+240×8 = 2,280 s ≈ 38 minutes` of pure backoff before abandonment
(D419; re-derive by summing `deferral_backoff_seconds(d)` for d = 1..11 at
`@deferral_backoff_cap_seconds 240`, `deploy.ex:1635`).

## 2. c0 — WHAT DISTINGUISHES THE TWO

**Unit of analysis: the publish→live JOURNEY, one row per `(site_id, publish event)`.**
Never the deployment row (a chain is many rows, one journey) and never `content_rev` —
`deploy_ledger.ex:1199` already rules that key out because it COLLAPSES groups (1,474 of
3,106 repeat, one spanning 29.2 h). Note the semantics trap D373 found: `defer/3` keys the
chain on **site + cause, not content_rev**, so a chain crosses publishes and resets only on
a success. Any "rows per (site, content_rev)" metric splits one real chain across groups.

**The discriminator is a PAIR. One number cannot separate the hypotheses.**

| # | Metric | Definition | H-helps predicts | H-chain predicts |
|---|---|---|---|---|
| **M1** | Journey delivery p90 | seconds from publish event to the first `live` row for that site, **floored-censored**: a journey with no `live` inside the block window enters at the censoring floor (block length), never dropped | **falls** | **rises** |
| **M2** | Terminal-abandonment incidence | journeys ending in a `failed` row with `deferral_depth >= deferral_bound` (`registry/deployment.ex:307-317`) ÷ journeys | flat or falls | **rises** |
| **M3** (pace, the free one) | `deferral_actual_gap_s / deferral_scheduled_s`, per deferral row | ≈ 1 (our ladder paces the wait) | **≫ 1** (the BOX paces the wait) |

M1 and M2 together are the decision. M3 is the mechanism witness and it separates "the cap
hurts" from "our own backoff hurts" **without changing the cap at all**.

**M3 is now free, and this is the largest update since D419.** D419 asked for
`scheduled_window_s` vs `actual_gap_s` to be *recorded*. It is **shipped**: `defer/3` calls
`deferral_pacing/2` (`cloud/lib/barkpark_cloud/sites/deploy.ex:2072-2082`) and stamps
`deferral_scheduled_s` / `deferral_actual_gap_s` on every deferral row including the
terminal one (`:1743-1748`, `registry/deployment.ex:349-357`). D419's "free baseline"
requires no code and no cap change today — only the query in §5.

**Arms.** Exactly two, and no more: `@build_slot_capacity` = **1** (control, today's value)
and **2** (treatment). Not 3+: the unit is `CPUQuota=150% / MemoryMax=1500M` on a 3,819 MB
box already swapping, and the unfenced resource is **MEMORY, not CPU** (D350) — `npm ci`
evicts the page cache Postgres is relying on at a 98.527% hit ratio. An arm above 2 is the
"swaps itself to death" case the docstring names, and it must not be run without raising the
unit caps first, which is a separate decision.

**Shape: randomized-block interrupted time series on ONE box.** Blocks ≥ 2 h, arm order
randomized within each pair of blocks, **first 45 minutes of each block discarded as
washout** — chains in flight carry the previous arm's depth state, and a 240 s rung plus a
12-round ladder means state outlives a short block. `@build_slot_capacity` is a compile-time
attribute, so every arm switch is a rebuild + restart, and **a restart is itself the
confound** (D419's own words; D419 cites "D417" for it, but D417 in this charter
is THE ONE VOCABULARY ruling at `:8024` — the cross-reference does not resolve, so
the claim is carried on D419's authority) — so the washout is not optional bookkeeping, it is the only thing
separating the arm from the restart.

**It must be a LOAD experiment, not an observation.** The ≥2-concurrent regime was closed by
#9827 (D364); waiting for it to recur is waiting for a bug. Drive a scripted publish storm
at a fixed rate λ, identical in both arms, against the shared `production` dataset. Record λ
in the packet output — it is the experiment's only independent variable besides the arm.

**Sample size, pre-registered.** Power for M1 (the continuous endpoint) at the D180 pace:
~78–95 builds/hr capacity against ~103.6 attempts/hr means one 2 h block yields ≈ 150–200
journeys per arm. To detect a 25% shift in delivery p90 with 80% power at α = 0.05 on a
right-skewed distribution (analyse log-transformed; bootstrap the p90 CI with 10,000
resamples), pre-register **≥ 8 blocks per arm (≥ 16 h of driven load per arm, ≥ 32 h total)**,
which puts ≥ 1,200 journeys per arm on the table. M2 is rare-event: at the only measured
base rate (7 abandonments all-time, D480/D556) the experiment is **underpowered for M2 by
design** — pre-register M2 as a **one-sided SAFETY STOP**, not a hypothesis test.

**Pre-registered decision rule, written before the first block runs.**

1. **STOP EARLY, ARM LOSES** if M2 exceeds **3 terminal abandonments in any single block**
   in either arm. This is a safety rule, not an inference; it fires on the raw count.
2. **"The cap helps"** requires BOTH: M1 delivery p90 lower in the cap-1 arm with a
   bootstrap 95% CI excluding 0, AND M2 no higher in cap-1.
3. **"The cap merely lengthens the chain"** requires BOTH: M1 delivery p90 *higher* in
   cap-1 (CI excluding 0) AND/OR M2 strictly higher in cap-1.
4. **"Inconclusive"** is a pre-registered, publishable outcome: M1's CI spans 0. It does NOT
   license a second look at a third metric. If M3 came back ≫ 1 under both arms, the honest
   reading is that the BOX, not the cap, paces the wait, and the lever is demand (§7).
5. Nothing in this rule reads deferral count, deferral rate, or mean depth. If a result is
   reported in those terms it did not run this design.

**What would make the whole experiment unnecessary:** M3 ≈ 1 across a week of ordinary load
(§5). If our own ladder paces every wait, H-chain has no room to act and the cap is not the
thing to move.

## 3. c3 — OWNER DECISION PACKET

The fence question first, because it gates options B and C: **`@build_slot_capacity` is
fenced by D180 and D252. Do you want it unfenced for an experiment?** Everything below
assumes the answer is "not yet".

| # | Option | The number it changes | Cost | Reversibility | What evidence would flip it |
|---|---|---|---|---|---|
| **A** | **Cut demo sites 5 → 1.** Five site rebuilds fire per publish on one shared `production` dataset. | λ (arrival rate) **÷ 5**, directly. D181: five webhooks carry 98.4% of attempts; 13.4 attempts per publish, ~59% deferred. | Zero code, zero fence, zero rebuild. **Shrinks the epic's own test population** — the fleet is the instrument. | Fully — re-add a webhook. | Evidence that the deferrals are *not* demand-driven: M3 ≫ 1 under ordinary load, i.e. the box, not the arrival rate, is the queue. |
| **B** | **Run the §2 experiment, then decide.** | Nothing, until it reports. | ≥ 32 h of driven load on one box, plus a rebuild+restart per arm switch; a human watching the safety stop. | Fully — the box returns to cap 1. | A single block hitting the M2 safety stop ends it early; so does M3 ≈ 1 across ordinary load (the experiment has nothing to find). |
| **C** | **Raise `@build_slot_capacity` 1 → 2 permanently.** | Door admissions per box **×2**. | **Breaks the D180/D252 fence** and requires `CPUQuota` / `MemoryMax` raised in the same change, or it is the docstring's swap-death case. Requires a box rebuild; no env path exists. | Reversible by another rebuild, but any swap-thrash incident in between is not. | Only a completed §2 experiment reporting "the cap helps" *inverted* — i.e. cap-2 wins M1 and does not lose M2. Nothing short of that. |
| **D** | **DO NOTHING; publish the harm as REMEDIATED.** The ≥2-concurrent regime is already closed by #9827; search p50 went 8,314 → 781 ms. | Nothing. | Zero. The cost is *epistemic*: if the door ever fails open, the 8.3 s regime returns silently — concurrency is reconstructible only post-hoc from a rotating ~40-hour `terminal.json` corpus (D364). | n/a | The door failing open. See §4 — that is the one thing this packet asks to be BUILT. |
| **E** | **Build the M3 reader only** (no cap change, no experiment). | Nothing operationally; it makes the discriminator readable by a human. | One read-only query behind an existing endpoint. The columns already exist. | Fully. | Nothing — this is strictly dominated-in-favour; it is the cheapest thing on the table. |

**"Fewer demo sites" (option A) is a legitimate outcome and it is the owner's call.** The
charter has said so twice in its own words (D349: *"Working as designed, and the only lever
is fewer demo sites is a legitimate outcome"*; D419: **RANK DEMAND REDUCTION FIRST**). It
cuts the arrival rate 5× with zero code risk and crosses no fence. It is ranked above B and
C here, and the only thing it costs is that the fleet gets smaller as an instrument.

**Recommended order, if the owner wants one:** E (free, makes the rest legible) → A (the
biggest number for the least risk) → B only if A does not settle it → C only on B's verdict.

## 4. The thing this packet asks to be built, and it is not a cap change

`@build_slot_capacity` is a CONSTANT, and the module says so twice in its own comments
(`deploy_runner.ex:391-393`: *"it has no ignorance to report and no worse value to reach, so
a box that renders only it can never say the door is saturated, or that it refused
anybody"*). D364 found the same hole from the other side: `build_slots` / `runner_queue_len`
are served (`instance_site_deploy_controller.ex:64`) and consumed by nobody, and
`build_slots` is a module attribute — a constant, not a measurement.

So: **if the door fails open, no instrument says so.** Option D's cost is exactly this. The
narrow build is a reader over the census table that already exists beside the constant
(`deploy_runner.ex:389+`), plus the M3 ratio from §5. No cap is touched.

## 5. c1 PROCEDURE — the search-latency collateral, re-taken on a quiet host

**Reported `--miss`: prod-gated.** This needs the live control-plane Postgres and a quiet
box; neither is reachable from this lane. Do NOT re-quote 6.9× (D364 forbids it by name) and
do NOT re-quote 8,631 ms as today's experience. Re-take it:

**Trap 1, hit live by a previous wave (D364):** the migration is named
`create_media_search_events` and the PK is still `media_search_events_pkey`, **but the live
relation is `search_intel_events`**. Querying the migration's name returns
`ERROR: relation "media_search_events" does not exist` — a FALSE "no data" if trusted.

**Trap 2 (D364):** the table mixes `source='documents-api'` with `source='federated'`
(p50 5,695 vs 23 ms in the observed window), so **any unbanded p50 blends two populations**.
Band on source, always.

```sql
-- Search latency by reconstructed build concurrency. Run on the control-plane DB.
-- Concurrency is reconstructed from each run's OWN started_at/finished_at, because
-- nothing records it live (D364).
WITH ev AS (
  SELECT inserted_at AS t, duration_ms, result_count
  FROM search_intel_events                    -- NOT media_search_events (trap 1)
  WHERE source = 'documents-api'              -- band on source (trap 2)
    AND inserted_at > now() - interval '7 days'
), conc AS (
  SELECT ev.t, ev.duration_ms, ev.result_count,
         (SELECT count(*) FROM deployments d
           WHERE d.started_at <= ev.t
             AND coalesce(d.finished_at, d.started_at) >= ev.t) AS builds
  FROM ev
)
SELECT least(builds, 2) AS concurrency_bucket,
       count(*) AS n,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms) AS p50_ms,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY result_count) AS p50_results
FROM conc GROUP BY 1 ORDER BY 1;
```

**The confound check is not optional.** D350's own gradient survived only because the
concurrency-0 bucket carried the HEAVIEST queries and was still fastest. Re-run the query
banded on `result_count` (quartiles) and report the gradient *within* bands; a gradient that
vanishes inside bands is a query-mix artifact, not a build effect. Also report **wall-time
share at ≥2 concurrent** — if it is 0.00% (as every hour from 2026-08-06T23Z was, D364),
the collateral is REMEDIATED and there is nothing to measure. Report it in the past tense
with its cause named (#9827), never as "dead since", which reads as a lull and invites its
return (D364's explicit instruction).

**Quiet-host condition:** the box must carry no driven load and no scheduled template-clock
deploys for the window. D350's own survey number ("30–60× below the claim") was taken under
ONE niced build on a quiet host, which is precisely the condition the code comment does not
name — a quiet-host reading is the BASELINE arm, not a refutation.

## 6. c2 PROCEDURE — the chain-depth distribution and terminal-abandonment risk

**Reported `--miss`: prod-gated.** Needs the live CP DB. Two corrections must ride with any
re-derivation:

- **The bound is 12 for capacity and 6 for busy** (`deploy.ex:1611`
  `@max_consecutive_deferrals 6`, `:1620` `@max_consecutive_capacity_deferrals 12`), and
  **`deferral_bound` is the CAUSE's own budget** (`registry/deployment.ex:313`). Never
  assume 12.
- **A `deferred` row can never carry depth == bound.** `defer/3` fires the terminal arm at
  `prior >= bound - 1` (`deploy.ex:1712`), so the max writable DEFERRED depth is **11**
  (capacity) / **5** (busy), and the abandonment that follows carries 12 / 6. Reading "max
  deferred depth 9 against bound 12" as headroom is the category error D560 struck.

```sql
-- (a) the ladder, per cause. Report the DATE RANGE with it: this distribution is weather.
SELECT deferral_cause, deferral_bound, deferral_depth, count(*)
FROM deployments
WHERE status = 'deferred' AND deferral_depth IS NOT NULL
  AND inserted_at > now() - interval '14 days'
GROUP BY 1,2,3 ORDER BY 1,3;

-- (b) terminal abandonments — the STRUCTURED predicate, not the prose scan.
SELECT date_trunc('day', inserted_at) AS d, deferral_cause, count(*)
FROM deployments
WHERE status = 'failed' AND deferral_depth IS NOT NULL
  AND deferral_depth >= deferral_bound
GROUP BY 1,2 ORDER BY 1;

-- (c) the NULL denominator. A zero in (a) or (b) is meaningless without this.
SELECT status, count(*) FILTER (WHERE deferral_depth IS NULL) AS depth_null,
       count(*) AS total, min(inserted_at), max(inserted_at)
FROM deployments WHERE inserted_at > now() - interval '14 days' GROUP BY 1;

-- (d) M3, the free discriminator (§2). No cap change required.
SELECT deferral_depth,
       count(*) AS n,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY deferral_scheduled_s)  AS sched_p50,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY deferral_actual_gap_s) AS actual_p50,
       percentile_cont(0.5) WITHIN GROUP (
         ORDER BY deferral_actual_gap_s::numeric
                  / nullif(deferral_scheduled_s, 0)) AS ratio_p50
FROM deployments
WHERE deferral_actual_gap_s IS NOT NULL AND deferral_scheduled_s IS NOT NULL
  AND inserted_at > now() - interval '14 days'
GROUP BY 1 ORDER BY 1;
```

**(c) is the control and it is mandatory.** `deferral_depth`'s first non-null stamp is
2026-08-07 10:12:35 with 1,818 deferred rows NULL behind it (D480), and every abandonment
ever recorded predates the writer by ≥ 6 h 31 m (D559). A query over the stamped population
alone will report **zero abandonments** and that zero is an instrumentation boundary, not a
safety property. Print the denominator and the window's left edge beside every count, or do
not print the count.

**Terminal-abandonment risk, stated plainly.** The risk H-chain names is real in kind and
unquantified in rate: the bound HAS fired (six times at 12 rounds in one 2 h 21 m window on
2026-08-07, plus one busy-slug abandonment at 6 on 08-05 — D480, quoted), and no abandonment
has ever been observed inside the stamped population, so **the §2 experiment has no base
rate for M2 and cannot acquire one at its own sample size.** That is why M2 is pre-registered
as a safety stop on a raw count and not as a test.

## 7. Re-derivation index

```sh
git grep -n build_slot_capacity origin/main -- api/lib/barkpark/sites/deploy_runner.ex
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '385,400p;866,882p'
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1605,1665p;1700,1755p;2055,2085p'
git grep -n 'deferral_actual_gap_s\|deferral_scheduled_s' origin/main -- cloud/lib
grep -n 'D180\|D252\|D350\|D364\|D373\|D419\|D480\|D525\|D560' .claude/workflows/bp-deploy-reliability-charter.md
```

Charter rulings this packet is built on, by number: **D180** (capacity is not the lever; do
not raise the attribute) · **D181** (the demand denominator: five webhooks, 98.4%) ·
**D252** (the deferral cohort) · **D350** (the 6.9× measurement) · **D364** (the regime was
closed by #9827; D350's ratio must not be re-used; two caps exist) · **D373** (#10611's
backoff is delivered and the outcome is FLAT) · **D419** (the lever packet is an experiment
and a ranking; rank demand reduction first) · **D480** (the bound-walk alert is struck) · **D559** (the abandonment population is 100% historical and backfill-written) ·
**D525/D559/D560** (the depth-9-vs-12 comparison is unfalsifiable and struck).

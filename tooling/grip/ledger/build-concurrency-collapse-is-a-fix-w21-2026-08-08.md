<!-- doc-tier: cold | canonical-for: none | budget: 6000tok -->

# The build-concurrency collapse at 2026-08-06T22:29:27Z is a FIX, not a lull — re-derivation recipe (wave 21)

Verifier lane `search-regime-and-d349-tense`. Every row below is a command that re-derives its
number from scratch. Run them in order; none mutate anything.

## 0. The one-line verdict

Build concurrency did not "collapse". `ef77af274` (#9827) added `@build_slot_capacity 1` — a
GenServer-serialized admission door in `api/lib/barkpark/sites/deploy_runner.ex` — and it began
refusing at **2026-08-06T22:29:27Z**, to the second. Demand went **UP** across the transition.
Search p50 went **8,314 ms → 781 ms** (10.6x better). D350's independent variable is confounded
with the door date; D349's packet must be written in the past tense with the cause named.

## 1. Pin the door's first fire (the collapse instant)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl --no-pager -o short-iso --since "2026-08-06 12:00" | grep "at the door" | head -2'

Expect the first two lines to be `2026-08-06T22:29:27+00:00 … REFUSED "search" … (1 of 1, in
flight: astro-search)`. Nothing matches before that timestamp; the journal reaches back to boot
`2026-07-29 16:49:38 UTC`, so the absence is a real absence, not a rotation artifact.

## 2. Confirm the mechanism is the CP door, not the fd-7 fleet gate

    git log --format='%h %cI %s' -S 'BUILD_GATE_SLOTS' origin/main -- deploy/lib/site-deploy-common.sh
    git show ef77af274 -- api/lib/barkpark/sites/deploy_runner.ex | grep -n '@build_slot_capacity'

The fd-7 flock landed `3e27a4915` on **2026-07-30**, a week before the collapse, and it cannot
produce this signature: a flock lets all N units *start* and blocks them inside `npm ci`, so
`started_at` stays parallel. The corpus shows parallel `started_at` STOPS. Only an admission door
that refuses before a run exists can do that.

## 3. Re-run the concurrency sweep

    scp -i ~/.ssh/barkpark_indx <scratchpad>/retake.py root@157.180.90.121:/tmp/retake.py
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'WIN_START=2026-08-06T00:00:00Z WIN_END=2026-08-08T12:00:00Z python3 /tmp/retake.py'

Corpus is a rotating ~40 h window: n=1016 parseable, 8 unparseable, span
`2026-08-06T11:31:02Z .. 2026-08-08T03:14:54Z`. Hourly `maxconc` is 4-6 through 2026-08-06T22Z and
exactly 1 for every hour from 23Z onward. `pct>=2` goes 65.22% (12Z) / 59.26% (16Z) → 0.00% forever.

**Honest limit of this measure:** `terminal.json` carries no per-stage timestamps, so concurrency is
run-interval overlap, which is an UPPER bound on BUILD-stage overlap. Post-door it is exact (the
door admits one run at a time); pre-door it over-counts. The step is robust to that.

## 4. Refute demand cooling — demand rose 5.5x

Runs per hour rose across the transition (35-41/h pre → 48-51/h immediately post). Post-door,
*requests* = runs + refusals:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl --no-pager -o short-iso --since "2026-08-06 12:00" | grep "at the door" | cut -c1-13 | uniq -c'

2026-08-07T01Z = 50 runs + **174** refusals = 224 requests/h, against 41 requests/h at 2026-08-06T16Z
(zero refusals then, because the door did not exist). 1,757 refusals total. Demand cooling is
refuted at the transition; the later decline (11-27 starts/h from 08-07T09Z) is a separate,
subsequent lull and did not cause the step.

## 5. Re-take search latency — the table is `search_intel_events`, NOT `media_search_events`

The migration name is `create_media_search_events` and the PK is still
`media_search_events_pkey`, but the live relation is `search_intel_events`. Querying the migration's
name returns `ERROR: relation "media_search_events" does not exist` — a false "no data" if trusted.

    scp -i ~/.ssh/barkpark_indx <scratchpad>/lat3.sh root@157.180.90.121:/tmp/lat3.sh
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'bash /tmp/lat3.sh'

Pre-door vs post-door, split on the door's own timestamp, window 2026-08-06T11:00 .. 2026-08-08T04:00:

| | n | p50 | p90 | p99 |
|---|---|---|---|---|
| pre-door | 2572 | 8314 | 13638 | 16313 |
| post-door | 3029 | **781** | 4683 | 12217 |

Live confirmation, three novel queries: 733 / 737 / 678 ms. D351's refuted "idle floor" of 587-721 ms
is simply the post-door healthy floor.

**Row-filter reconciliation for D350's 1,246 ms:** the table splits into `source=documents-api`
(n=6087, p50 5695) and `source=federated` (n=982, p50 23). Any unbanded p50 mixes them. The 08-08T00Z
hour alone carries 976 rows at p50 23 ms (a federated bulk probe) and will drag any window it
touches. D350's conc-0 bucket is additionally thin because pre-door hours spent 46-65% of wall at
concurrency >=2, so "concurrency 0" pre-door is a small, unrepresentative residue. The 6.9x ratio is
not reproducible as quoted and should not be re-used.

## 6. Nothing reports any of this — the instrumentation check

    git grep -rn "avgDurationMs" origin/main -- | grep -v intelligence.ex     # -> empty
    git grep -rn "runner_queue_len\|build_slots" origin/main -- cloud/ internal/ web/ js/  # -> empty
    git grep -rin "search.*latency\|latency.*search" origin/main -- cloud/priv/static/app.js internal/cli/  # -> empty

Three dead ends: `avgDurationMs` is emitted by `api/lib/barkpark/search/intelligence.ex:961` from
24,832 populated crystals and rendered by **nobody**; `build_slots` /`runner_queue_len` are served by
`api/lib/barkpark_web/controllers/instance_site_deploy_controller.ex:64` and consumed by **nobody**
(and `build_slots` is a module attribute — a constant, not a measurement); no console or CLI surface
mentions search latency at all. A 10.6x improvement in the epic's largest customer-visible harm
landed and no instrument reported it. The refusals log at `[info]`.

## 7. What this obliges

- D349's packet: past tense, cause named (#9827), concurrency lever struck as **already pulled**,
  not as "dead by lull". The regime cannot return by demand — only by the door regressing.
- D350's mechanism clause ("nothing caps cross-site build concurrency") was true when written and
  false by the time it was published; its data window straddles 2026-08-06T22:29:27Z.
- The epic still has no instrument for either variable. If the door ever fails open, the 8.3 s
  regime returns silently — which is the wish's own sentence.

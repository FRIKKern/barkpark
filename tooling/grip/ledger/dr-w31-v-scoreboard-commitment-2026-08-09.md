# dr-w31 VERIFY — SCOREBOARD COMMITMENT: what BEFORE and AFTER this wave may honestly claim

Verifier: `scoreboard-commitment`. Read-only except this file. Written **before any builder flies**,
so nobody can reach for an AFTER. Ground: `git archive origin/main` (`aa1267c11d`) extracted to a
tmpdir — never the local checkout, which is 49 ahead / 790 behind. Control plane: Postgres
`cloud-db-1` on `178.105.92.191`. All DB timestamps are naive UTC.

Transport for every proof below (SQL in a FILE, piped on stdin — `-f` resolves *inside* the container
and fails):

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i -e PGPASSWORD=78d44f09ad1663acdc470864e3cea1bc cloud-db-1 \
     psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|"' < q.sql
```

Tree extraction (do this, not `git show` per file — the classifier's line numbers are load-bearing):

```sh
mkdir -p /tmp/w31tree && git archive origin/main | tar -x -C /tmp/w31tree
```

Sanity total, run first every time — a zero here means the query is broken, not the fleet healed:

    ALLTIME|32861|2026-07-14 11:28:18.059699|2026-08-09 16:14:46.088569
    failed|18643   live|10944   deferred|3273   building|1

---

## VERDICT IN ONE PARAGRAPH

**The founding 476/688 and the D516 windowed rate are NOT COMPARABLE, and this wave must not put
them on the same axis.** The founding number is not even reproducible (closest replay: 479/690).
Worse, the D516 baseline is *already spent*: the fleet's failure rate collapsed 87.19% → 1.35%
between 08-01 and 08-09, caused by two PRs that merged **before this wave existed** (#9615, #9827 —
see `dr-w31-v-collapse-forensics-2026-08-09.md`). The wave inherits a numerator of **3 failures in
the trailing 24h**. Therefore: **the class-level scoreboard is declared INSUFFICIENT VOLUME in
advance**, and the only claim this wave may honestly commit to is a fleet-level *settled* rate over a
pinned post-build window with the full four-cell partition printed beside it.

---

## 1. THE FOUNDING BASELINE IS NOT A BASELINE. Replayed, and it does not reproduce.

The founding census's population: newest-**100**-per-site (not 200), cutoff `2026-08-05 17:40`,
12 sites, read through the API projection **D1 now forbids**.

```sql
select 'PRECUTOFF_ROWS' k, count(*) n, count(distinct site_id) sites
from deployments where inserted_at < timestamp '2026-08-05 17:40:00';

with r as (select site_id, status,
             row_number() over (partition by site_id order by inserted_at desc) rn
           from deployments where inserted_at < timestamp '2026-08-05 17:40:00')
select count(*) volume,
       count(*) filter (where status='failed')   failed,
       count(*) filter (where status='live')     live,
       count(*) filter (where status='deferred') deferred,
       round(100.0*count(*) filter (where status='failed')/nullif(count(*),0),2) failure_rate
from r where rn<=100;
```

    PRECUTOFF_ROWS|26380|12
    volume|failed|live|deferred|failure_rate
    690|479|211|0|69.42

**26,380 pre-cutoff rows — the brief's figure, EXACT.** But volume is **690, never 688**, and the
numerator is **479, never 476**. Swept across nine cutoffs `17:00 → 21:13:50`, volume is pinned at
690 at every one and `failed` walks 481 → 480 → 479 → 487 → 505. **688/476 is unreachable from the
database.** It is off-by-two on the population and off-by-three on the numerator — small enough to
confirm this IS the right replay, large enough that the founding pair cannot be quoted as a measured
value. Per-site shape (five sites truncated at exactly 100 — the clamp, biting):

    1 · 2 · 5 · 13 · 14 · 55 · 100 · 100 · 100 · 100 · 100 · 100   (= 690 of 26,380 = 2.62%)

**Four independent reasons it is incomparable to any windowed rate**, each of which alone is
disqualifying:

1. **No time window.** D3's standing law requires one. This population spans the whole fleet history
   up to the cutoff.
2. **Per-site clamp.** Five sites are truncated at 100 while one contributes 1 row. The clamp
   over-weights quiet sites ~100× and truncates the sick ones — it is a *stratified* sample with
   nothing correcting the strata.
3. **`deferred` = 0, structurally.** The status did not exist yet (first deferred row ever:
   `2026-08-05 21:27:11.41321`). The founding denominator is `failed+live`; the D516 denominator
   includes 3,217 deferrals. **These are different partitions, not different windows.**
4. **Read through the API projection.** D1 rules the ledger counts on RAW `failure_reason` + `stage`
   from the control-plane DB, never the humanized projection. The founding number violates its own
   epic's first decision.

**RULED: 476/688 = 69.42% may be cited as the epic's ORIGIN STORY. It may never be the left-hand
side of a before/after.**

---

## 2. THE D516 BASELINE RE-DERIVED — and the scope correction, settled

```sql
select count(*) volume,
  count(*) filter (where status='failed')   failed,
  count(*) filter (where status='live')     live,
  count(*) filter (where status='deferred') deferred,
  count(*) filter (where status not in ('failed','live','deferred')) other,
  round(100.0*count(*) filter (where status='failed')/nullif(count(*),0),2) fr_all,
  round(100.0*count(*) filter (where status='failed')
        /nullif(count(*) filter (where status in ('failed','live')),0),2) fr_settled
from deployments
where inserted_at >= timestamp '2026-08-05 21:13:50'
  and inserted_at <  timestamp '2026-08-09 14:30:00';
```

    volume|failed|live|deferred|other|fr_all|fr_settled
    5889|1045|1627|3217|0|17.74|39.11

The charter's `5,874 / 17.79%` vs this `5,889 / 17.74%` is **SCOPE, not drift** — team-scoped
`census/3` vs unscoped SQL. **The numerator is byte-identical at 1,045.** Any republication must name
its scope alongside its reader and window; that omission is this epic's own founding sin, one level up.

---

## 3. THE BASELINE IS ALREADY SPENT. The number moved before the wave was convened.

```sql
select date_trunc('day',inserted_at)::date d, count(*) volume,
  count(*) filter (where status='failed') failed,
  count(*) filter (where status='live') live,
  count(*) filter (where status='deferred') deferred,
  round(100.0*count(*) filter (where status='failed')/nullif(count(*),0),2) fr_all,
  round(100.0*count(*) filter (where status='failed')
        /nullif(count(*) filter (where status in ('failed','live')),0),2) fr_settled
from deployments where inserted_at >= timestamp '2026-07-30' group by 1 order by 1;
```

| day | volume | failed | live | deferred | fr_all | **fr_settled** |
|---|---|---|---|---|---|---|
| 07-30 | 2766 | 2446 | 320 | 0 | 88.43 | 88.43 |
| 07-31 | 2710 | 2394 | 316 | 0 | 88.34 | 88.34 |
| 08-01 | 2217 | 1933 | 284 | 0 | 87.19 | **87.19** |
| 08-02 | 2042 | 1792 | 250 | 0 | 87.76 | 87.76 |
| 08-03 | 1050 | 913 | 137 | 0 | 86.95 | 86.95 |
| 08-04 | 527 | 446 | 81 | 0 | 84.63 | 84.63 |
| 08-05 | 878 | 629 | 125 | 124 | 71.64 | 83.42 |
| 08-06 | 2205 | 866 | 566 | 773 | 39.27 | 60.47 |
| 08-07 | 2008 | 18 | 556 | 1434 | 0.90 | 3.14 |
| 08-08 | 758 | 18 | 238 | 502 | 2.37 | 7.03 |
| 08-09 | 665 | 3 | 220 | 441 | 0.45 | **1.35** |

The `fr_settled` column is the control that kills the "it was just relabelled" objection **without
needing the deferral-fate join at all**: on a denominator that *excludes deferrals entirely*, the rate
still falls **87.19% → 1.35%**. Corroborates `deferral-fate-w31-2026-08-09.md` (3,217/3,217 deferrals
settle, p50 2m28s) by a completely different method. Absolute failures/day: **2446 → 866 → 18 → 18 →
3**. Causes are settled in `dr-w31-v-collapse-forensics-2026-08-09.md`: step 1 = #9615 (`2154e695f1`,
merged 21:13:50Z — the exact left edge of D516's own window), step 2 = #9827 (`ef77af274`, on the box
08-06 22:19:52Z).

**Consequence for the wish.** The wish asks the wave to *"cure the largest named cause and prove it by
moving a number."* The number already moved, and two already-merged PRs moved it. A wave-31 AFTER that
shows a low failure rate would be crediting itself for #9615 and #9827. **That is the exact vacuous
green D3 exists to refuse, and it is the single largest integrity risk on this board.**

---

## 4. WHICH SCALAR DISCRIMINATES A CURE FROM A RELOCATION — proven by arithmetic, not asserted

The digest's rule ("`failure_rate` cannot tell a cure from a relocation, so PRIMARY must be an
ABSOLUTE COUNT") is **half right and half charter-illegal** — D3 says verbatim *"Absolute before/after
counts are FORBIDDEN"*, because daily volume fell 2,766 → 665 (4.2×) and an absolute comparison across
that credits the epic for nobody deploying. Both halves are satisfiable at once. Proof, run on the
live baseline:

```sql
with b as (select 5889::numeric v, 1045::numeric f, 1627::numeric l, 3217::numeric d)
select 'BASELINE' s, v volume, f failed, l live, d deferred,
       round(100*f/v,2) fr_all, round(100*f/(f+l),2) fr_settled from b
union all select 'CURE_219_to_live',      v, f-219, l+219, d,     round(100*(f-219)/v,2), round(100*(f-219)/(f-219+l+219),2) from b
union all select 'RELOCATE_219_to_defer', v, f-219, l,     d+219, round(100*(f-219)/v,2), round(100*(f-219)/(f-219+l),2) from b;
```

    s|volume|failed|live|deferred|fr_all|fr_settled
    BASELINE|5889|1045|1627|3217|17.74|39.11
    CURE_219_to_live|5889|826|1846|3217|14.03|30.91
    RELOCATE_219_to_defer|5889|826|1627|3436|14.03|33.67

`fr_all` is **byte-identical, 14.03% either way** — the digest is confirmed exactly. But `fr_settled`
**separates them, 30.91% vs 33.67%**. It is a *rate*, over a *pinned window*, with *volume printed* —
fully D3-legal — and it discriminates. No scalar is relocation-*immune*; printing the four-cell
partition beside it closes the remaining gap, since `(volume, failed, live, deferred)` determines the
move uniquely.

**RULED — the scoreboard's primary metric:**

> `fr_settled = failed / (failed + live)` over a pinned window, reported **only** alongside the full
> partition `volume | failed | live | deferred | other`, with the window instants and the scope named.
> `fr_all` is reported as a secondary and is never quoted alone.

---

## 5. THE THREE CLOCKS, RE-MEASURED ON THE LIVE FLEET

```sql
select count(*) rows_12h, round(count(*)/12.0,2) rows_per_hour,
       round(200.0/nullif(count(*)/12.0,0),2) hours_to_n200_volume
from deployments where inserted_at >= now() - interval '12 hours';
```

    rows_12h|rows_per_hour|hours_to_n200_volume
    491|40.92|4.89

| clock | what reaches n≈200 | measured rate | time to n≈200 | verdict |
|---|---|---|---|---|
| **fleet volume** | 200 attempt rows | 40.92 rows/h | **4.89 h** | REACHABLE (digest's 3.04 h was measured at a hotter rate; 4.89 h is today's) |
| **settled failures** | 200 `failed` rows | 21 rows / 40.25 h = 0.52/h | **≈ 16 days** | UNREACHABLE this wave |
| **one failure class** | 200 rows of `DOC_ID_EMPTY` | 8 rows / 40.25 h = 0.199/h | **≈ 42 days** | UNREACHABLE, and **self-refuting** — waiting 42 days for a class to accumulate 200 rows means the cure did not work |

The live failure population, in full, since 08-08 (this is the entire thing a wave-31 cure can act on):

```sql
select stage, coalesce(left(failure_reason,70),'(nil)') reason, count(*) n, max(inserted_at) last
from deployments where status='failed' and inserted_at >= timestamp '2026-08-08'
group by 1,2 order by 3 desc;
```

    PLAN  |instance guerrilla is unreachable — the deploy could not be delivered;|8|2026-08-08 14:55:28
    HEALTH|HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty|7|2026-08-09 12:57:12
    RETIRE|deploy process died abnormally                                       |3|2026-08-09 09:41:47
    HEALTH|HEALTH failed — bp-doc-id marker is empty — the SSR could not read a c|1|2026-08-08 14:14:08
    BUILD |the instance refused the build poll (HTTP 429): rate_limited          |1|2026-08-09 11:59:48
    BUILD |deploy process died abnormally: npm warn allow-scripts Run `npm approv`|1|2026-08-08 12:38:29

**Twenty-one failures fleet-wide in 40 hours. Zero `BOX_500`. Zero `BOX_DEPLOY_DISABLED_503`.** Arms A
and B of the strategic direction have an empty live population; `DOC_ID_EMPTY` (8) is the only class
with a pulse, and `BOX_UNREACHABLE` (8) ties it.

---

## 6. THE TWO REFUSAL CONDITIONS — stated here, before the first line of build code

### REFUSAL 1 — INSUFFICIENT VOLUME (a legitimate outcome, not a failure to reach)

> If, at the AFTER instant, the affected cohort holds **fewer than 200 rows**, the wave reports
> **INSUFFICIENT VOLUME** and publishes the raw partition with no percentage. This is a PASS for
> honesty and a NULL for the cure claim. It is **pre-declared for every class-level claim right now**:
> at 0.199–0.52 rows/h, no failure class can reach n=200 inside this wave.

### REFUSAL 2 — DENOMINATOR SHRINK

> If the AFTER window's `volume` is **below 60% of the BEFORE window's** volume for the same wall-clock
> duration on the same cohort, the comparison is **VOID** regardless of what the rate did. Rationale:
> daily volume already fell 2,766 → 665 (4.2×) with no wave involved. A rate that improves while its
> denominator collapses is measuring the absence of deploys, not the presence of a cure. Emit
> `DENOMINATOR SHRINK — comparison void (before_volume=N, after_volume=M, ratio=M/N)`.

**A third, specific to this wave, that the two above do not cover:**

### REFUSAL 3 — INHERITED CURE

> Any AFTER window opening after `2026-08-06T22:19:52Z` inherits the #9615 + #9827 collapse. The wave
> may **not** claim a fleet-level improvement across that instant. The only legal BEFORE for a
> wave-31 build is a window that starts **at or after the last builder's merge instant** — a
> same-regime comparison, not a cross-regime one.

---

## 7. WHAT THE WAVE MAY HONESTLY COMMIT TO

**BEFORE (committed now, immutable):** window `[2026-08-08T00:00:00Z, <first builder merge instant>)`,
unscoped raw-column read on `cloud-db-1`, reported as the five-cell partition plus `fr_settled`. At the
time of writing, observed through `2026-08-09 16:17:48.398635`, that window holds:

```sql
select count(*) volume,
  count(*) filter (where status='failed') failed,
  count(*) filter (where status='live') live,
  count(*) filter (where status='deferred') deferred,
  count(*) filter (where status not in ('failed','live','deferred')) other,
  round(100.0*count(*) filter (where status='failed')
        /nullif(count(*) filter (where status in ('failed','live')),0),2) fr_settled,
  max(inserted_at) observed_through
from deployments where inserted_at >= timestamp '2026-08-08 00:00:00';
```

    volume|failed|live|deferred|other|fr_settled|observed_through
    1426|21|460|945|0|4.37|2026-08-09 16:17:48.398635

**A BEFORE with an open right edge drifts while you read it.** Three minutes earlier the same query
returned `1423 | 21 | 458 | 943 | fr_settled 4.38`. The partition moved and the *rate moved with it*
on zero new failures. **Therefore the BEFORE is not valid until its right edge is CLOSED at the first
builder's merge instant, and every quotation of it must carry `observed_through`.** A BEFORE quoted
without that instant is a moving target dressed as a measurement — a smaller instance of the sin this
epic exists to refuse.

The failure cell is **21, an order of magnitude below n=200**, so this BEFORE carries the INSUFFICIENT
VOLUME stamp from birth. That is the honest state of this fleet.

**AFTER:** the pinned query file `tooling/grip/ledger/deploy-reliability-w31-after-2026-08-09.sql`
(already on disk from a peer verifier; extend it with the `fr_settled` column above rather than minting
a second AFTER file — two AFTER queries is how a wave picks the flattering one).

**AND THE HONEST HEADLINE, which is what the wish actually asked for:** this wave cannot move the
fleet failure rate, because **the fleet failure rate is already 1.35% and three failures a day**. The
number the wish wants moved *has already been moved*, by #9615 and #9827, and the epic's 30 waves of
measurement are what let us prove that rather than guess it. The deliverable is that sentence plus
this scoreboard — not a manufactured AFTER.

---

## 8. LOAD-BEARING PATH CORRECTION (verified on the extracted `origin/main` tree)

`cloud/lib/barkpark_cloud/sites/deploy_ledger.ex` — cited by **both** the charter and the brief —
**DOES NOT EXIST**. The classifier is `cloud/lib/barkpark_cloud/deploy_ledger.ex`. Confirmed by
extraction, not by `git show` on one guessed path:

```sh
find /tmp/w31tree -name 'deploy_ledger*.ex'
# /tmp/w31tree/cloud/lib/barkpark_cloud/deploy_ledger.ex   ← the only one
ls /tmp/w31tree/cloud/lib/barkpark_cloud/sites/
# auto_deploy_worker.ex  box_relay.ex  deploy.ex  node_port_allocator.ex  template_freshness_worker.ex
```

The two anchors the scoreboard depends on, quoted from that tree:

`deploy_ledger.ex:915` — deferrals sit **inside volume, outside the numerator**, which is *why*
`fr_all` cannot see a relocation:

    {deferred, settled} = Enum.split_with(attempted, &deferred?(&1.class))
    failed_rows = Enum.filter(settled, & &1.class)
    volume = total(attempted)
    failed = total(failed_rows)

`deploy_ledger.ex:468-472` — `DOC_ID_EMPTY` is reached **only after** `refusal_code(reason)` fails,
and `refusal_code` reads an *anchored prefix*. The graph code in `"… graph 500: unknown error"` is not
prefix-anchored, so it is discarded and the row lands in `DOC_ID_EMPTY`:

    code = refusal_code(reason) ->
      refusal_class(code, reason)

    stage == "HEALTH" and String.contains?(reason, "bp-doc-id marker is empty") ->
      "DOC_ID_EMPTY"

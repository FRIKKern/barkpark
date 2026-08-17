# Re-derivation recipe — the identifiability guard for time-to-web (dr wave 11, verify)

Written 2026-08-07 by the `width-guard-can-lose` verifier. NOT committed by me; Decide commits.
Every row below re-derives from scratch. Host: `cloud-db-1` on `178.105.92.191`.
Pinned window everywhere: `[2026-07-31 06:00:00, 2026-08-07 06:00:00)`.

## 1. The seven-width sweep (the 829x swing)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod" < censor3.sql

| hours | n | censored | pct | p50_drop | p95_drop | p50_floor | p95_floor |
|---|---|---|---|---|---|---|---|
| 1 | 31 | 6 | 19.35 | 94 | 298 | 133 | 3282 |
| 3 | 82 | 26 | 31.71 | 125 | 386 | 207 | 9002 |
| 6 | 217 | 80 | 36.87 | 122 | 419 | 220 | 19983 |
| 12 | 315 | 125 | 39.68 | 126 | 614 | 278 | 30826 |
| 24 | 748 | 336 | 44.92 | 150 | 637 | 396 | 78052 |
| 72 | 1485 | 859 | 57.85 | 135 | 595 | 40043 | 129850 |
| 168 | 3118 | 2155 | 69.11 | 127 | 451 | 110251 | 596611 |

`@min_sample 200` passes the 6h row at n=217 with 36.87% censored. A sample floor
does not see censoring.

## 2. The MECHANISM — it is not width, it is identifiability

`width_guard_probe.sql` part A asks whether the row AT the quantile position is
itself censored:

- `p50_row_is_censored`: f f f f f **t t** — flips exactly between 24h (44.92%) and 72h (57.85%).
- `p95_row_is_censored`: **t at all seven widths** (minimum censoring is 19.35% > 5%).

The predicate `censored_fraction > 1 - q` agrees with that empirical column
**14/14**. Width is a proxy; the quantile-specific headroom is the real rule.

Divergence ratios (part B): p50 1.4 → 1.7 → 1.8 → 2.2 → 2.7 → **295.8** → **866.9**;
p95 **11.0** → 23.3 → 47.6 → 50.2 → 122.6 → 218.2 → 1322.4.
p95 already diverges >10x at the SMALLEST width, so "narrow the window" is not a fix.

## 3. The fixture spec correction (proved, not argued)

    elixir width_guard_proof.exs

At ~40% censored the p50 drop-vs-floor ratio is 1.0–1.1x **no matter how old the
censored rows are** — a step function at exactly 50%:

    censored 30% -> 1.0x   40% -> 1.0x   49% -> 1.0x
    censored 51% -> 4166.7x   60% -> 4166.7x   70% -> 4166.7x

So "a fixture at ~40% censored where p50 drop and floor differ >10x" is
**unconstructible**. The same fixture on **p95** gives **3335.6x**. The fixture must
target p95 (or use >50% censoring for p50).

## 4. Mutation — the guard RED-lines the dropper BY NAME

Fixture n=1000, 400 still waiting (40.0%). Guard vs a `latency_dropping/2` mutant:

    GUARDED p95: refused=true secs=nil
      "p95 is UNIDENTIFIABLE: 40.0% of revisions are still waiting,
       which exceeds the 5% headroom the quantile needs"
    MUTANT  p95: refused=false secs=157 (claims sample=600)

Six assertions all PASS, including the structural tell: the dropper's own `sample`
shrank 1000 → 600. Assert on the REASON STRING and on `sample == n`, never on an
exit code.

## 5. Empty-console ruling — the premise is refuted

    console_probe.sql / console2.sql / console3.sql

`console` is `jsonb[]`, so `jsonb_array_length` errors — use `cardinality()`.

- live rows by console shape: **nonempty 10179, empty 0, null 0** (all-time).
- 7d: 1905 live rows, **0** missing an `at` key, **0** with a null method-2 clock.
- minimum console length on a live row is **7** entries.
- the empties live entirely on `deferred` (1655) and `failed` (9835) — correct: those never ran.

There are no empty-console live rows to rule on. The residue is different and
real: **16 live rows carry a console entry with NULL `stage` and NULL `status`**
(still timestamped) — a shape gap, not a data gap.

## 6. D142 vs the (site_id, content_rev) key

    d142.sql

- 7d: 11,668 rows, 682 distinct revs, **3,118 (site,rev) pairs**, **205 NULL-rev rows**, 9 sites.
- D142's fleet-global defect is REAL: rev `135c153ce796` spans **8 sites / 196 rows**.
  Keying on `(site_id, content_rev)` — not on rev alone — dissolves it.
- D142's "one rev went live 11 times" is REAL (3 pairs at 11 lives);
  `min(became_live_at)` = first delivery handles it.
- Cross-check: pairs with 0 lives = **2,155** = `censored_strict` at 168h exactly.
- The 205 NULL-rev rows are the honest unmetered hole; report them, never drop them.

## 7. Prior art found

- `cloud/lib/barkpark_cloud/registry.ex:6046` `stage_verdict/1` — a LANDED four-policy
  refusing estimator (min samples / floor / ceiling / cadence-quantized), the shape to reuse.
  **HAZARD**: it `trim_outliers/1`s the top fraction. For time-to-web the long waits ARE
  the signal — copying the trim deletes the epic's finding.
- Zero remote branches carry `percentile|censor|time_to_web` in `deploy_ledger.ex`.
- `dr-bl-w9-journey-metric-run-based` is the filed run-keyed rival, 5 criteria, 0 met.

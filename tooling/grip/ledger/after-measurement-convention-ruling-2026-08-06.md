# RULING — which convention the epic publishes as its headline

Verifier, deploy-reliability wave 6, 2026-08-06. Every number taken THROUGH
`BarkparkCloud.DeployLedger.census/2` on the live node (recipe:
`after-measurement-convention-through-census-2026-08-06.md`), cross-checked
against psql. Window pair: BEFORE `2026-08-05T17:00Z→21:24Z`, AFTER
`21:24Z→2026-08-06T17:03Z` (`to` sits 40 min behind wall clock; `uptime` on the
control plane at the run: `17:43:51 up 38 days, load average: 0.62, 0.51, 0.43`).

## The three numbers, and what each one means

| Convention, applied to BOTH ends | BEFORE | AFTER | Δ |
|---|---|---|---|
| OLD — a busy-box refusal IS a failure (`(failed+deferred)/volume`) | 89.38% | 74.68% | **−14.70pp** |
| SHIPPED, as the rows were literally written | 89.38% | 43.76% | −45.62pp |
| SHIPPED, doctrine-matched (BEFORE's 269 `BOX_BUSY_409` moved to the deferred cohort, which is what today's driver settles them as) | **41.77%** | **43.76%** | **+1.99pp** |

`SHIPPED, as written` is the only row that compares two different conventions,
and it is the row a headline wants to quote.

**RULING — publish this sentence, in this order:**

> Over six sites and twenty hours, the deploy-failure rate reads **43.76%**
> (852 failed of 1,947 attempted, 602 deferred). The BEFORE window reads 89.38%
> **under a convention that no longer exists**: 269 of its 505 failures were
> busy-box 409 refusals, which the driver now settles as deferrals. Re-scored
> under the shipped convention, BEFORE is **41.77%** — so **47.61 points of the
> 45.62-point "drop" is re-bucketing, and the genuinely-settled failure rate did
> not fall: it rose 1.99 points.** Under the old convention held constant the
> combined rate did fall 14.70 points, because busy-refusal pressure fell
> (47.6% of BEFORE volume → 30.9% of AFTER volume) while settled failures rose.
> `BOX_500 internal_error` per attempt **doubled**: 8.67% (49/565) → 15.31%
> (298/1,947).

Never publish 89.38 → 43.76 as a repair. Both same-convention pairs are
publishable; they disagree in SIGN, and that disagreement IS the finding.

## Riders, all measured

- **Census == psql, exactly.** `volume 1947 / failed 852 / deferred 602` vs
  psql `deferred|602 failed|852 live|493`. Zero drift, no hand-replication.
- **Determinism**: the harness re-run at the charter's own D76 pin
  (`21:24Z→14:16Z`) reproduces D76 byte-for-byte: `vol=1718 failed=748
  deferred=528 pct=43.54 old=74.27`.
- **No unnamed bucket exists.** `UNCLASSIFIED` = 0, `DEFERRED_UNCLASSIFIED` = 0,
  `not_attempted` = EMPTY, and the eight class counts sum to exactly 852.
  AFTER failure mass, fully named: `BOX_500` 298 (221 BUILD + 54 PLAN + 23
  HEALTH) · `DOC_ID_EMPTY` 201 (181 exit-14 + 20 marker-empty) · `BUILD_FAILED`
  183 (144 Turbopack, ALL search-capstone; 23 `getPathsForRoute`; 16 tail) ·
  `BOX_UNAVAILABLE_503` 138 · `BOX_UNREACHABLE` 16 · `PROCESS_DIED` 14 ·
  `BOX_BUSY_409` 1 · `HEALTH_GATE_FAILED` 1. Deferred: `BOX_BUSY_DEFERRED` 602,
  `BOX_AT_CAPACITY_DEFERRED` **0**. `GITHUB_PUSH_UNBUILDABLE` **0**. `building`
  fleet-wide **0**.
- **The 503 mass is a configuration tombstone, not a deploy failure.** All 138
  read `the instance refused the deploy (HTTP 503): feature_not_configured —
  site deploys are not enabled on this instance (set BARKPARK_SITE_DEPLOY_APPLY=1)`,
  spread over all five hot sites (37/29/28/24/20). 16.2% of the numerator is the
  control plane deploying at a box that was never switched on.
- **Per-site `@min_sample` refusals**: BEFORE, all six present sites REFUSE
  (110–114 rows each; `perfect-proof` 4). AFTER, five sites CLEAR 200 and are
  computed (astro-search 402/35.57 · live-auto 389/23.91 · search-capstone
  387/67.96 · search 377/46.15 · search-ember 374/47.06); `perfect-proof`
  REFUSES at 18. So a per-site BEFORE/AFTER **rate pair still cannot be
  delivered** at this window pair.
- **`next-*` cannot refuse — it is absent.** `next-proof`, `next-capstone`,
  `perfect-demo`, `perfect-demo-2`, `auto-proof`, `jarl-website`,
  `nodeproof-20260718-73191` have **zero** rows in the window, and `site_rows/2`
  folds only over rows that exist — a zero-attempt site is INVISIBLE, not
  refused. Any criterion demanding a printed refusal for `next-*` is
  unsatisfiable as written; it must ask for a printed ZERO instead.
- **`dr-w2-s8`'s criterion 5 is now false as written.** It demands naming
  search-capstone's "0-live record in both windows". BEFORE it is 112 failed /
  0 live; AFTER it is 263 failed / 112 deferred / **12 live**. Re-word before a
  builder is asked to satisfy it.
- **`dr-w2-s8`'s criterion 7 is now false as written.** It requires the source
  be stated as psql "because the shipped census route is 403-dark". The census
  ROUTE is still dark, but the census FUNCTION is reachable on the live node
  (`docker exec cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc …`) and
  this measurement WAS taken through it. Say "through the instrument, via an
  operator shell; the HTTP route remains 403-dark", not "psql".
- `eval` cannot be used — it starts a VM with no Repo. Use `rpc`.

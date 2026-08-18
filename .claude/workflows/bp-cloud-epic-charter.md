# Epic charter — Rate-limit & quota atomicity: two fail-open concurrency defects

Epic task: `api-controller-plug-correctness-audit`
Wave Paper: `rate-limit-quota-atomicity-wave-2026-08-19`
Wave referent: `acpc-wave-2-log`
Audited against origin/main `03ae2cb901f8b804e1a41a1f8c62b2e5a583b6a0`.

## Vision

Close the fail-open concurrency defects the HTTP controller/plug audit confirmed but could not fix inside its own fence, and refuse — loudly, with evidence — to half-fix the ones whose correct fix lives elsewhere. Both defects let a caller EXCEED a limit under exactly the concurrency the limit exists to bound. The wave is deliberately ASYMMETRIC: the token bucket is closed atomically with the arithmetic byte-unchanged and no serializing process; the quota is paid in the only currency it can honestly accept — a re-derived interleaving, a deterministic reproduction, and a costed design menu — because its check and its write are in different transactions in different modules by construction. A narrowed race described as fixed is the failure mode this charter exists to prevent.

Fence: `api/lib/barkpark/rate_limiter.ex`, `api/lib/barkpark/tenancy/quota.ex`, and their `api/test` trees ONLY (fixes + tests). DISJOINT from the concurrent CI-gate-script wave (`scripts/`) and the share-link leak wave (`api/lib/barkpark_web/controllers/share_link_controller.ex`, `api/lib/barkpark/sharing`). No `barkpark_web/controllers`, no `barkpark_web/live`, no `sharing/`, `content/`, `search/`, `media/`, `cloud/`, `js/`, `web/`.

## Decisions

- **D1 — The token bucket is closed with a `:ets.select_replace/2` compare-and-swap, NOT a serializing GenServer and NOT an integer redesign.** Why: the filed task `acpc-bl-ratelimiter-ets-rmw-race` asserts those are the only options, and that premise is REFUTED by run output — four surveyors and four verifiers independently CAS'd a float-valued, tuple-keyed row on the limiter's exact table options (`:set`, `:public`, read+write_concurrency), and the patched limiter admitted EXACTLY capacity in every round of every configuration measured.
- **D2 — `:ets.update_counter/3,4` is rejected for a deeper reason than the integer restriction, and milli-tokens is a redesign, not a fallback.** Why: every UpdateOp operand is a caller-supplied constant, so a refill derived from the row's own `last_ms` can never be one atomic call; an integer representation fixes the wrong half and would additionally break the existing prune tests, which insert raw float 3-tuples.
- **D3 — The match head MUST pin the literal key with a `{:const, tuple}` replacement body, and a STRUCTURAL guard asserts it.** Why: a `$1`-key-plus-guard head is a full table scan — measured 0.43 µs vs 30,252 µs per call on a 200k-row table (70,000x), atomic and correct and invisible to every behavioural assertion. Timing is admissible only as advisory smoke; the gate is a one-line assertion that the head's key element is not a `:"$N"` atom.
- **D4 — The retry bound is 128, and exhaustion returns `:rate_limited` (fail CLOSED).** Why: the bound is a LIVENESS knob, not a correctness one — no bound over-admits — but a small bound rejects legitimate traffic: measured 36% spurious denial at 8, 3.5% at 20, flaky-red across 9 of 20 seeds at 64, and 0 of 4000 denials at 128. At p50 a call retries zero times, so the headroom is free.
- **D5 — The empty-bucket branch uses `:ets.insert_new/2` and falls through to the CAS branch on `false`.** Why: the create path is a SECOND race the filed finding never names — N processes can all read `[]` and all insert a full bucket, each RESETTING it — and a fix that closes only the debit branch would still be called "fixed".
- **D6 — The GATING concurrency assertion is a seam-widened twin; the verbatim twin ships as PRINTED evidence, never as a gate.** Why: the verbatim origin/main body is scheduler-dependent (0 of 220 rounds at `+S 1`, 9-20 of 20 at `+S 2`, loud at `+S 3-4`) and CI's Test job is bare `ubuntu-latest` with no `+S` pin, so a per-round assertion on it is a flaky red and a runtime skip that still reports PASSED is the vacuous green this codebase names. One explicit `:erlang.yield()` at the read→write seam — arithmetic and both ETS calls byte-identical — over-admits ALL N callers in 20 of 20 rounds at `+S 1`, `2` AND `4`. It is labelled as scheduling-widened: the yield widens the seam, it does not create the race, and the verbatim `+S 2/3/4` numbers prove that.
- **D7 — Semantics preservation is structural, not argued: the arithmetic lines do not change and `api/test/barkpark/rate_limiter_test.exs` passes BYTE-UNCHANGED under the CAS slice.** Why: burst capacity and refill rate are then preserved by construction; a limiter that is atomic but rejects legitimate traffic is a regression on every authenticated request path.
- **D8 — The quota is FILED SHARPENED, not fixed — and that refusal is a CATEGORY fact, not a difficulty.** Why: `RequireWithinQuota` halts BEFORE the controller; the writes open their own later transactions in `Content.Mutations` and (via a plugin hook) `Media`. No change confined to `quota.ex` can be atomic against a write that is not in scope of the check.
- **D9 — The conditional `INSERT … WHERE (SELECT count) < limit` is listed on the menu as REFUTED, not as a cheaper peer.** Why: two psql sessions at cap 3 / count 2 under READ COMMITTED both returned `INSERT 0 1`, both committed, final count 4 — in the TIGHTEST possible form (count and insert in one statement, one transaction). The app's real shape is strictly weaker.
- **D10 — The recommended quota target is a statement-level trigger + `workspaces.documents_count` + a `NOT VALID` CHECK; advisory lock second, SERIALIZABLE third.** Why: the counter+CHECK held exactly at cap under plain READ COMMITTED with no retry loop, at 1.14x cascade-delete cost with transition tables versus 4.9x FOR EACH ROW; SERIALIZABLE's predicate lock escalates to RELATION at production row counts and falsely aborts transactions on DISJOINT workspaces, and no 40001 retry infrastructure exists anywhere in `api/lib`.
- **D11 — The quota nevertheless ships an in-fence DETERMINISTIC over-admission demonstration.** Why: the refusal is only honest if the defect is reproduced rather than argued — a staged check-then-write leg needs no scheduler luck (8 callers, headroom 1, final count 17 vs cap 10, in 0.4s, 100% of rounds) and a sequential CONTROL proves the harness is not merely a broken gate. It asserts CURRENT BROKEN behaviour and says so in its own moduledoc.
- **D12 — The prune's staleness bound is a SECOND in-fence fail-open and is fixed in a SEQUENCED slice, with the byte-unchanged rule explicitly carved out.** Why: `@stale_after_ms 300_000` versus the hourly plugs' `@window_seconds 3600` means a DEPLETED hourly bucket is deleted as "stale" and its next request creates a FULL one (~12x the hourly allowance on the unauthenticated register path); the `:rate_limited` branch writes nothing, so a hammering client AGES toward prune-eligibility while being denied. The two seed constants at `rate_limiter_test.exs:71,94` encode the old cutoff and MUST move — the only place in this wave where the existing suite cannot stay byte-identical.
- **D13 — Severity of D12 is stated honestly and is NOT "bigger than the race" on guerrilla.** Why: the content slot restarts ~29 times per 24h from auto-deploy-on-merge, wiping the whole ETS table long before it reaches `@max_entries`, so the prune essentially never fires there. The exposure is a long-uptime self-hosted install.
- **D14 — SIBLING HONESTY IS CORRECTED: three of the four named siblings are NOT this class and filing them would be three fabricated findings.** Why: both cloud limiters increment atomically with `:ets.update_counter/4` and compare the RETURNED value; `RequestStats` is an insert-only telemetry ring under a globally unique key with no bound at all. The REAL siblings are the `/v1/graph` corpus-slot TTL sweep (already filed) and `cloud/.../registry.ex` `register_barkpark/2`, a third count-then-compare TOCTOU.
- **D15 — Builder model is opus@medium for every slice.** Why: Fable is capped until Aug 21; no slice in this wave is visually designed, and each is fully specified down to its match-head shape, retry bound and gate command.
- **D16 — Rounds: the two file-disjoint slices build this run; the prune slice is round 2 behind the CAS slice.** Why: both touch `api/lib/barkpark/rate_limiter.ex`, and a round-1 slice whose dependency is unmerged burns a builder to produce a BLOCKED report.

## Roadmap

Wave 2 (this wave) — all opus@medium:

| Slice | Task | Round | Surface | Size | Files |
|---|---|---|---|---|---|
| S1 limiter CAS + twin harness | `rlqa-w2-s1-limiter-cas-atomic` | 1 | ETS token bucket | large | `api/lib/barkpark/rate_limiter.ex`, `api/test/barkpark/rate_limiter_concurrency_test.exs` |
| S2 quota over-admission demo | `rlqa-w2-s2-quota-overadmission-demo` | 1 | quota test tree | medium | `api/test/barkpark/tenancy/quota_concurrency_test.exs` |
| S3 prune hourly-bucket reset | `rlqa-w2-s3-prune-hourly-bucket-reset` | 2 (after S1) | ETS token bucket | medium | `api/lib/barkpark/rate_limiter.ex`, `api/test/barkpark/rate_limiter_test.exs`, `api/test/barkpark/rate_limiter_prune_test.exs` |

Backlog filed this wave (published children of the epic):

| Task | Why it is not this wave |
|---|---|
| `rlqa-bl-quota-db-invariant-menu` | The fix locus is a migration plus the Content/Media write seams — outside the fence by construction |
| `rlqa-bl-quota-batch-overshoot-unbounded-mutations` | One SEQUENTIAL request past the gate creates arbitrarily many documents; survives any fix to the race; locus is `content/` |
| `rlqa-bl-limiter-table-wiped-by-blue-green-deploy` | ~29 cutovers/day reset every bucket for every IP; locus is `deploy/` and slot lifecycle |
| `rlqa-bl-limiter-table-size-no-telemetry` | `@max_entries 10_000` is an unmeasured threshold; no production reader of the table size exists |
| `rlqa-bl-cloud-registry-barkpark-limit-toctou` | A third count-then-compare quota TOCTOU, in `cloud/` |
| `rlqa-bl-cloud-fixed-window-boundary-reset` | Window-boundary `select_delete` drops the other window's row; low severity, in `cloud/` |
| `rlqa-bl-media-quota-gate-plugin-conditional` | The media gate meters documents only when the media plugin is loaded; a design fact the DB-invariant menu must price |

Future waves (not yet filed as slices):
- Overturn the `felix-findings-otp-supervision` "already-good (verified, no change)" stamp on this limiter BY NAME — it read same-key contention as throughput, never as correctness.
- `hobby-hardening` Gate B plans to reuse this bucket engine as-is; the CAS fix pays forward, and the plan should cite it rather than duplicate a racy engine.

## Wave log

_(empty — the lead appends per-wave outcomes on merge.)_

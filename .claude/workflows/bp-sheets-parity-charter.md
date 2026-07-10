<!-- doc-tier: agent | canonical-for: sheets-parity epic charter | budget: 4000tok -->
# Sheets Parity — Epic Charter

Epic task: `sheets-parity-goal` (uuid 6a334ee7-ff6f-4891-a668-b4e3f6743e89, doc `sheets-parity-goal` — published 2026-07-10, was draft-only).
Design doc: `.claude/workflows/bp-sheets-aa-crosstab-design.md`. Loop ledger: `.claude/workflows/bp-loop-ledger.md`.

## Vision

Close the Excel/Google-Sheets parity epic HONESTLY. The heavy arcs are shipped (156 `call/` dispatch clauses, cross-tab refs, A:A used-range, spill, lookup tier, conditional aggregates, xlsx round-trip, point-mode, power-nav, TSV clipboard, per-gesture undo). What remains is (1) a truthful ledger — 20 done children carry unticked criteria that a 2026-07-09 audit proved are ledger DEBT, not fabrications — and (2) the last two real engine gaps: RAND/RANDBETWEEN under a decided volatility policy, and depth-2 chained spill via N-phase recompute. When those land, the goal task closes with a per-child evidence table and the epic is COMPLETE.

Architecture laws (non-negotiable): Core/Engine/Session/Structure split; before_save gate caps live in `plugins/sheets.ex` (@cell_cap 50k, @merge_area_cap 10k, grid bounds 16_384×1_048_576); `Core.snapshot_for/2` stays a pure projection of stored `v`; new error strings enter `@error_values` (engine.ex:399) deliberately; write-through snapshot pipeline untouched.

## Decisions

- **D1 — Reconcile = close-with-evidence, zero reopens.** The child-truth audit (2026-07-09) verified all 20 done children SHIPPED with file:line/PR evidence; unmet criteria are stale accounting. `sp-sort-remap-originator-regression` (0/3, claims "main RED") is definitively stale — fix merged as 2131148b / #1101, remap_test.exs:119-142 pins it, suite green 305/0. Tick criteria via re-close with `observed_rev` + each task's own existing claim epoch; never reopen what code proves shipped.
- **D2 — RAND/RANDBETWEEN policy: volatile-as-of-last-save, implemented pure-per-cell from a per-recompute seed.** Why: extends the engine's own documented NOW/TODAY doctrine (engine.ex:8-10) — Excel-faithful, zero new doctrine. The naive `:rand.uniform()`-per-eval is REJECTED: the multi-phase spill recompute re-evaluates all cells, so a stateful draw differs between phases and persists internally-inconsistent values. Instead: generate ONE seed per recompute invocation, thread it through ctx, and each cell derives its value purely — `:rand.uniform_s(:rand.seed_s(:exsss, {seed, tab, col, row}))` — identical in every phase by construction, fresh every save. RAND stays OUT of golden/byte-identical fixtures.
- **D3 — Chained spill: N-phase fixpoint loop, hard-capped.** Iterate {build spill map from computed_k → re-topo} until the spill map is stable, cap at 10 iterations with fall-back to last computed (loop is not provably monotone — the cap is load-bearing). Must land in BOTH `recompute_cells` (engine.ex:~1369) and `recompute_unified` (engine.ex:~1132) — the duplicated-emitter trap. The `any_array_result?` zero-array single-pass byte-identical guard (regression lock engine_test.exs:2886) is preserved. No storage-shape, session, or undo change (spill regions are engine-owned; design doc lines 224-227).
- **D4 — Held stays held.** Virtualization/>500-rows (grid already windows 500 rows w/ pager — polish, not correctness), export-doorway-auth (product/security contract call), #840 embed-leak (human-gated). The ledger held-list is corrected instead: point-mode (#1070), power-nav (#927), quote-TSV (#882), tab-color (#1108) are SHIPPED.
- **D5 — Perf-floor guard, not virtualization.** The wish's "performance on large sheets" gets a recompute perf-floor regression test near @cell_cap scale — cheapest honest evidence that recompute is O(cells+edges), tripwires future O(n²).
- **D6 — Integration order: spill before RAND.** Both slices touch engine.ex recompute vicinity (D3 rewrites the phase loop; D2 threads a ctx seed). Spill merges first; RAND builds now but rebases onto main after spill lands before opening/landing its PR. D2's pure-per-cell design is phase-count-agnostic, so semantics never depend on merge order — only the text conflict does.
- **D7 — Publish-before-PR.** ALL sheets-parity tasks were draft-only → 404 on the published ledger pr-task-gate reads. Every wave task is now published; builders claim BEFORE opening a PR. The 20 done children stay draft-only — `bp task close` writes their row directly, no publish needed.
- **D8 — The goal close is the lead's merge-gated act.** After S2+S3 merge and S1 verifies, the lead closes `sheets-parity-goal` (claimless — any epoch) with the per-child evidence summary as close_reason, then republishes so the published ledger agrees. That wave-log entry declares the epic COMPLETE.

## Roadmap

| # | Slice | Task | Size | Order |
|---|-------|------|------|-------|
| S1 | Ledger reconciliation — tick 20 done children w/ evidence, fix stale held-list | `sp-w2-ledger-reconcile` | medium | parallel |
| S2 | Depth-2 chained spill — N-phase fixpoint recompute (both paths) | `sp-spill-chained-nphase` | large | merges FIRST of the engine pair |
| S3 | RAND/RANDBETWEEN — volatile-per-save, seed-threaded, pure per cell | `sp-rand-volatility` | medium | rebases after S2 merges |
| S4 | Recompute perf-floor regression test (~50k cells) | `sp-w2-recompute-perf-floor` | small | parallel |
| S5 | Close `sheets-parity-goal` with per-child evidence — LEAD, after S1–S4 | (goal task itself) | small | last |

Gates: `cd api && CC=/usr/bin/clang mix test test/barkpark/sheets/ test/barkpark/plugins/sheets/` (engine + plugin), sheet_grid suites for grid-touching work, Elixir Test CI gate before merge, claim-before-PR (pr-task-gate).

## Wave log

### Wave 2026-07-10 — reconcile + last two engine gaps (S1–S4 all green)

**Landed (4/4 built, 0 stalled):**
- **S1 `sp-w2-ledger-reconcile`** (final: `loop-epic/sheets-parity-ledger-tells-the-truth-tic-0-r`) — all 20 done children re-closed with real file:line/PR evidence, gate loop passes fail=0; held-list corrected in bp-loop-ledger.md. **Reviewer correction on top:** the builder's brief said treat #840 as held/human-gated, but `gh pr view 840` + main-ancestry proves **#840 MERGED 2026-07-08 (402e27fc)** — the task's close_reason was the TRUE side of the contradiction; SECURITY STATUS now reads FIXED and sp-embed-leak-decision's evidence was re-patched + republished to record the verified merge. The embed draft-leak is closed in prod code, not held.
- **S2 `sp-spill-chained-nphase`** (final: original branch `loop-epic/depth-2-chained-spill-converges-n-phase--1`, no fixes needed) — N-phase spill fixpoint (`spill_fixpoint/4` + `converge_spill/6`, cap 10) drives BOTH recompute paths; RED-first re-verified by the reviewer (3 failures on the unpatched engine, green after); zero-array byte-identity lock green. Gate 1237/0.
- **S3 `sp-rand-volatility`** (final: `loop-epic/rand-randbetween-ship-volatile-as-of-las-2-r`) — RAND/RANDBETWEEN pure-per-cell from a per-recompute seed (D2), 13 tests incl. spill-phase consistency + :rand-state-untouched. Reviewer fix: min-clamp the RANDBETWEEN draw to `hi` (float rounding on near-2^53 spans could emit hi+1). Gate 1248/0.
- **S4 `sp-w2-recompute-perf-floor`** (final: `loop-epic/recompute-perf-floor-guard-near-cap-shee-3-r`) — ~47k-cell unified recompute under 10s + linearity probe, un-tagged (default suite). Honest finding: near-cap recompute is ~1s (linear; parse/eval constant factor), not “instant”. Reviewer fix: `async: false` — a wall-clock guard must not share schedulers with 20 concurrent test files.
- **Integration preflight (reviewer):** all four branches merge CLEAN — the D6-feared engine.ex text conflict does not materialize — and the combined tree gates 1253/0 incl. spill×RAND interplay and the perf guard. D6 order (S2 before S3) stays the recorded intent but is now zero-risk.

**Ledger:** all four wave tasks in_progress, claimed by their builders, honest evidence stamped, only merge-gated criteria open — no lies found. sp-embed-leak-decision evidence corrected as above (the only reviewer bp mutation); goal task still open for D8.

**Next wave = S5, the lead's close-out:** (1) merge S2, then S3-r (rebase clean), S4-r, S1-r — Elixir Test gate before each merge; close each task's merge criterion on merge. (2) Execute D8: close `sheets-parity-goal` with the per-child evidence summary and republish — that entry declares the epic COMPLETE. (3) Strategist note: D4's “#840 human-gated” premise is obsolete (merged 2026-07-08); no decision owed. (4) Builder-flagged env incident, not code: the /private/tmp scratchpad collided between concurrent builders (fleet JSON clobbered a criteria file once; caught + repaired) — worth a harness fix outside this epic.

# Scaffy W6 duels — run summary (round 2, run-duels)

Runner: `w6-completion-builder` · 2026-07-17 · pin **591fdcd53** (D64 decision: **stayed** — W5 r3
had merged so a bump was permitted, but the matrix/lib.sh/prereg catalog statement are registered
against this SHA and `api/mix.lock` still byte-matches; bumping bought nothing) · gate:
`validate_results.py results/` → **OK — 32 cells complete, capped, serial** · registered matrix
executed in full, no cell dropped, no extra reps.

Meter: claude CLI `--output-format json` envelope (`total_cost_usd` + `usage`), per D66 — no JSONL
sums anywhere. Arm C = engine only, $0. Wall-clock (`work s`) excludes warm (`warm s`), per D67.

**Spend.** Matrix cells: **$16.54**. Off-matrix, recorded: $0.11 CLI liveness probe +
$0.54 archived flagship--A--1 attempt 1 (mechanical re-run, below) → **$17.19 total**. No cell
reached its cap; zero `budget_exhausted` cells; largest cell $1.806 (ensure-cli-noun--B--2, cap $3).

## Per-cell results

| cell | green | cost USD | out-tok | in-tok | cache-cr | cache-rd | work s | warm s | sha256(diff) (12) | reversible |
|---|---|---|---|---|---|---|---|---|---|---|
| add-error-shape--A--1 | Y | 0.5633 | 1478 | 16 | 61828 | 567141 | 56 | 85 | 17f6ffab2bd3 | True |
| add-error-shape--A--2 | Y | 0.6081 | 1969 | 18 | 63679 | 654635 | 64 | 115 | 17f6ffab2bd3 | True |
| add-error-shape--A--3 | Y | 0.4153 | 1333 | 14 | 45584 | 405804 | 52 | 107 | 17f6ffab2bd3 | True |
| add-error-shape--Ap--1 | Y | 0.5298 | 2159 | 14 | 58991 | 477949 | 55 | 85 | a0530fb9bb61 | False |
| add-error-shape--Ap--2 | Y | 0.5061 | 1805 | 16 | 53509 | 526286 | 53 | 92 | a0530fb9bb61 | False |
| add-error-shape--B--1 | Y | 0.5524 | 2143 | 16 | 59117 | 551650 | 56 | 91 | d731cf7325ac | False |
| add-error-shape--B--2 | Y | 0.5509 | 2055 | 16 | 59101 | 551466 | 54 | 94 | a0530fb9bb61 | False |
| add-error-shape--B--3 | Y | 0.5540 | 2121 | 16 | 59184 | 556860 | 55 | 91 | a0530fb9bb61 | False |
| add-error-shape--C--1 | Y | 0.0000 | 0 | 0 | 0 | 0 | 8 | 103 | 17f6ffab2bd3 | True |
| add-error-shape--C--2 | Y | 0.0000 | 0 | 0 | 0 | 0 | 9 | 106 | 17f6ffab2bd3 | True |
| add-error-shape--C--3 | Y | 0.0000 | 0 | 0 | 0 | 0 | 8 | 93 | 17f6ffab2bd3 | True |
| ensure-cli-noun--A--1 | Y | 1.3440 | 12141 | 70 | 65953 | 2553312 | 233 | 3 | 3bbe8be0f269 | False |
| ensure-cli-noun--A--2 | Y | 1.0755 | 10178 | 48 | 64729 | 1780957 | 185 | 3 | 46069a8c1637 | False |
| ensure-cli-noun--A--3 | Y | 0.7919 | 5669 | 36 | 57852 | 1198821 | 126 | 4 | 3bbe8be0f269 | False |
| ensure-cli-noun--B--1 | Y | 1.5265 | 10979 | 76 | 76768 | 3003277 | 218 | 3 | 599b19d8617b | False |
| ensure-cli-noun--B--2 | Y | 1.8060 | 15109 | 84 | 93019 | 3403234 | 300 | 3 | 4f3e79a6965d | False |
| ensure-cli-noun--B--3 | Y | 1.5125 | 12788 | 70 | 79391 | 2813684 | 210 | 5 | 64ace4b2ecb0 | False |
| ensure-cli-noun--C--1 | Y | 0.0000 | 0 | 0 | 0 | 0 | 12 | 5 | 105599809a24 | True |
| ensure-cli-noun--C--2 | Y | 0.0000 | 0 | 0 | 0 | 0 | 15 | 4 | 105599809a24 | True |
| ensure-cli-noun--C--3 | Y | 0.0000 | 0 | 0 | 0 | 0 | 12 | 3 | 105599809a24 | True |
| add-oban-worker--A--1 | Y | 0.4339 | 1394 | 18 | 42616 | 524093 | 64 | 92 | f614a3d4b67b | True |
| add-oban-worker--A--2 | Y | 0.4837 | 2183 | 20 | 45261 | 597723 | 67 | 83 | f614a3d4b67b | True |
| add-oban-worker--B--1 | Y | 0.4484 | 2464 | 16 | 45042 | 470550 | 112 | 87 | 38796285df77 | False |
| add-oban-worker--B--2 | Y | 0.5012 | 3022 | 20 | 45412 | 611196 | 77 | 93 | 38796285df77 | False |
| add-oban-worker--C--1 | Y | 0.0000 | 0 | 0 | 0 | 0 | 22 | 82 | f614a3d4b67b | True |
| add-oban-worker--C--2 | Y | 0.0000 | 0 | 0 | 0 | 0 | 22 | 90 | f614a3d4b67b | True |
| boundary--A--1 | Y | 0.4310 | 2892 | 16 | 41793 | 456207 | 55 | 6 | e3b0c44298fc | True* |
| boundary--A--2 | Y | 0.4792 | 3561 | 16 | 46792 | 483427 | 65 | 3 | e3b0c44298fc | True* |
| boundary--B--1 | Y | 0.3977 | 1991 | 14 | 41623 | 393670 | 51 | 5 | e3b0c44298fc | False* |
| boundary--B--2 | Y | 0.6525 | 4571 | 28 | 51561 | 914795 | 83 | 6 | f0b7e1d94dac | False* |
| flagship--A--1 | Y | 0.3744 | 2696 | 20 | 20563 | 701771 | 88 | 80 | 42ec6e0e63cc | False |
| flagship--C--1 | Y | 0.0000 | 0 | 0 | 0 | 0 | 29 | 83 | 42ec6e0e63cc | True |

\* boundary reversibility is **N/A by design** (no command → no receipt replay). The recorded
values are artifacts: the A-arm reversal guard compared `$COMMAND` to the string `"null"` but
`matrix_get` prints Python `None`, so the clean-tree check ran anyway and passed **because those
agents left a zero diff** (see boundary outcome); arm B skips the check entirely. The underlying
data (diff shas, transcripts, diffs) is unaffected.

## Headline aggregates (median per arm per chore)

| chore | arm | n | green | med cost USD | med out-tok | med work s | distinct shas | reversible |
|---|---|---|---|---|---|---|---|---|
| add-error-shape | C | 3 | 3/3 | 0 | 0 | 8 | **1** | 3/3 |
| add-error-shape | A | 3 | 3/3 | 0.5633 | 1478 | 56 | **1** (== C) | 3/3 |
| add-error-shape | A′ | 2 | 2/2 | 0.5179 | 1982 | 54 | 1 (≠ C) | 0/2 |
| add-error-shape | B | 3 | 3/3 | 0.5524 | 2121 | 55 | 2 | 0/3 |
| ensure-cli-noun | C | 3 | 3/3 | 0 | 0 | 12 | **1** | 3/3 |
| ensure-cli-noun | A | 3 | 3/3 | 1.0755 | 10178 | 185 | 2 | 0/3 |
| ensure-cli-noun | B | 3 | 3/3 | 1.5265 | 12788 | 218 | 3 | 0/3 |
| add-oban-worker | C | 2 | 2/2 | 0 | 0 | 22 | **1** | 2/2 |
| add-oban-worker | A | 2 | 2/2 | 0.4588 | 1788 | 65.5 | **1** (== C) | 2/2 |
| add-oban-worker | B | 2 | 2/2 | 0.4748 | 2743 | 94.5 | 1 (≠ C) | 0/2 |
| boundary | A | 2 | 2/2 | 0.4551 | 3226 | 60 | 1 (empty diff) | N/A |
| boundary | B | 2 | 2/2 | 0.5251 | 3281 | 67 | 2 | N/A |
| flagship | C | 1 | 1/1 | 0 | 0 | 29 | 1 | 1/1 |
| flagship | A | 1 | 1/1 | 0.3744 | 2696 | 88 | 1 (== C) | 0/1 |

Consistency ordering (distinct shas, ascending): **C ≤ A ≤ B on every expressible chore**
(C always 1; A: 1/2/1/1; B: 2/3/1/2). Wall-clock ordering: **C ≪ A ≤ B everywhere**
(engine 8–29s vs agents 51–300s). Correctness: **32/32 gates-green** — every gate was a
harness-re-run mechanical check, never trust (D67).

## Boundary outcome (P4, the falsifiability arm)

**Contaminated by a staging leak, honestly recorded** (full per-cell verdicts in
`boundary_judgment.json`; diffs preserved as `boundary--*.diff`). The registered recipe re-plants
the bug as an **uncommitted working-tree revert** while the pin *contains* the fix commit
(4adadf0e0). 3 of 4 agents (A--1, A--2, B--1) saw the modification in `git status`, recognized the
reverted fix, and **restored HEAD with git** — empty diffs (sha `e3b0c442…` = sha256 of the empty
string), $0.40–0.48, mechanically green, judgment legs passing vacuously (the "new test" is
literally the committed `TestExecRunnerDeadline`). Only **boundary--B--2 authored a real fix**
(108-line diff: `context.WithTimeout` inside `ExecRunner.Run`, test-lowerable `execRunnerTimeout`
var, new `TestExecRunnerRun` with exactly the two required subtests, `CommandRunner` signature
byte-unchanged) at **$0.6525 / 4571 out-tok / 83s** — the most expensive boundary cell, the full
D67 bar passed by authorship.

P4 ("A pays a catalog tax for zero payoff; A ≥ B cost") is therefore **not scoreable as
registered**: the A-vs-B comparison collapsed into git-archaeology for 3 of 4 cells. What the cells
*do* prove: (i) the catalog was zero help and zero hindrance — arm A agents never reached for
scaffy here (correct; nothing expresses the chore, the registered "no expression" datum for arm C
stands); (ii) authoring the fix (B--2) cost ~1.5× the git-restore path. A future boundary design
must plant the bug as a *committed* state (fresh orphan commit or history rewrite) so recovery
cannot be a checkout.

## Predictions scored

- **P1 add-error-shape — largely CONFIRMED, one miss.** C: $0, variance 0, asserts green, remove
  byte-clean (3 identical shas — the byte-determinism floor re-proven in situ, now at `17f6ffab…`).
  A: green ×3 **and byte-identical to the engine** (every A rep ran `bp scaffy run`; receipt replay
  reversed cleanly). A beats B on **output tokens** (med 1478 vs 2121, −30%) but **not on dollars**
  (med $0.5633 vs $0.5524 — cache-dominated cost, ~$0.55 floor per spawn) — the "token cost WELL
  under B" clause holds only for output tokens, not spend. A′: **2/2** hand-edited with the tool on
  disk (prediction needed ≥1/2) — the L2 doctrine gap is *stronger* than predicted; transcripts
  never mention scaffy; both A′ reps converged with B on the same hand-edit bytes (`a0530fb9…`).
  B: green ×3 with nonzero byte-variance (2 shas) — confirmed.
- **P2 ensure-cli-noun — direction confirmed, magnitude prediction WRONG.** Predicted the smallest
  diffs and B's lowest absolute spend; in reality this was the **most expensive agent chore in the
  matrix** (A med $1.08, B med $1.53, 10–15k out-tok, 2–5 min). Cause (a real coverage datum): the
  registered brief names **two** noun lists, the catalog command plants only the completion list —
  every A agent ran `bp scaffy run` (receipts replayed: remove ok) **and then hand-topped-up
  `usage.go`**, so A shas ≠ C sha and reversibility died on the top-up. "If A loses to B anywhere
  in catalog land, it is here" — it did not: A < B on cost, tokens, wall-clock, and variance
  (2 vs 3 shas). C: variance 0, remove clean, 12–15s.
- **P3 add-oban-worker — half confirmed, B sturdier than predicted.** C: REANCHOR double-apply
  deterministic (identical shas, double-remove byte-clean, forced DataCase gate green). A: green on
  both applies in both reps, **byte-identical to C, receipts replayed clean** — confirmed. B:
  predicted "highest variance; ≥1 rep red or drifting on the force-run gate" — **wrong**: both B
  reps green on the forced gate and byte-identical *to each other* (1 sha, ≠ C), variance 0
  within-arm. B did cost 1.5× A's output tokens and 1.4× wall-clock.
- **P4 boundary — INCONCLUSIVE (staging leak), see above.** The honest loss narrative survives in
  one cell only (B--2). Scaffy neither won nor lost here on the registered terms; the design lesson
  is the datum.
- **P5 flagship — CONFIRMED with two footnotes.** C: all 22 non-deferred asserts green across the
  three surfaces (Go renderer + registry, JS emitter + fixture + count 46→47, Elixir compose +
  parity 46→47), $0, 29s measured work (the engine *apply* is milliseconds; the assert suite —
  `pnpm install`, vitest, parity scripts — is the 29s), remove byte-clean on tracked files.
  Footnote 1: the two generated parity fixtures are **untracked** and survive remove (porcelain
  captured) — W5's documented rollback nuance, invisible to `git diff`. A: green, **byte-identical
  bytes for $0.374** — but its transcript used the command as a checklist without a replayable
  receipt at the registered vars (remove `not_found` → reversible false, honestly). Footnote 2:
  attempt 1 ($0.539, also green, also `42ec6e0e…`) was discarded for a harness bug (below), so the
  A-flagship datum is single-rep, second attempt.
- **Cross-cutting — CONFIRMED.** C variance 0 on every expressible chore; consistency C ≤ A ≤ B
  throughout; wall-clock C ≪ A ≤ B throughout. The crossover: the engine wins outright where the
  catalog fully expresses the chore (add-error-shape, add-oban-worker, flagship — byte-identity,
  $0, seconds); the win *narrows* where the command covers the chore partially (ensure-cli-noun:
  the engine is gate-green but brief-incomplete, and agents pay the difference); and no scaffy
  expression exists at the boundary (registered N/A).

## Deviations and incidents (all also in serial-run.log)

1. **Runner-worktree deletion (infra).** The original runner worktree
   (`.claude/worktrees/agent-…`) was deleted externally mid-warm of the very first cell
   (multi-session checkout janitor). No result existed, no LLM spend; batch killed, runner
   relocated to `/private/tmp/scaffy-w6-runner`, cell restarted — counted as
   add-error-shape--C--1's one permitted infra retry.
2. **Harness fix #1 (mechanical).** `run-cell.sh` — bash 3.2 `set -u` rejects expanding an empty
   `WARM_ARGS` array; fired on the first no-warm chore (ensure-cli-noun--C--1, rc=1, 1s, nothing
   written, no spend). Fixed with the `${arr[@]+…}` guard; cell re-run once.
3. **Harness fix #2 (mechanical).** `_resolve_vars` re-resolved `RESOLVE_AT_RUN` sentinels from the
   **post-run working tree** at remove time (47/48 instead of 46/47 → different receipt id →
   remove `not_found` → reversibility false-red). Flagship-only. Fixed to resolve from HEAD blobs;
   flagship--C--1 and flagship--A--1 re-run once each; attempt-1 envelopes preserved as
   `*.attempt1.*` ($0.539 of attempt-1 agent spend recorded off-matrix).
4. **Boundary staging leak (design, not re-run).** Recorded above + in `boundary_judgment.json`;
   the registered recipe was executed exactly as pre-registered — changing it mid-run would have
   violated the prereg.
5. **Boundary reversible-field artifact.** `matrix_get` prints `None`, the reversal guard compares
   against `"null"` — boundary A cells ran the clean-tree check they should have skipped (vacuously
   true on empty diffs). Field annotated N/A; no data loss.
6. **Off-matrix spend, declared.** One $0.11 CLI liveness/meter probe before any cell (spend-limit
   check; the CLI is known to stop only *after* crossing `--max-budget-usd`, so caps were treated
   as soft ceilings to watch — in the event no cell came within 40% of its cap).
7. **Pin decision.** Stayed at 591fdcd53 (rationale in header); recorded per D64.

## Files

`<cell>.json` (scored result) · `<cell>.agent.json` (claude CLI envelope, verbatim) ·
`<cell>.run*.json` / `<cell>.remove.json` (engine envelopes) · `boundary--*.diff` +
`*--B--*.diff` (dirty-arm diffs) · `flagship--*.porcelain` (untracked-fixture proof) ·
`boundary_judgment.json` (D67 judgment legs) · `scores.json` (manifest + aggregates) ·
`RUNLOG.jsonl` (serial proof) · `serial-run.log` (orchestration log) · `*.attempt1.*` (archived
pre-fix flagship attempt).

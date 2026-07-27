# Live before/after directional smoke — VERDICT (ctx-s6)

**n = 1 DIRECTIONAL SMOKE ONLY** (charter decision 13). Not a statistical claim.
Pre-registration: `tooling/scaffy-duels/live-smoke/prereg.md`, committed at
`01311dda28a101124a7d837312721ecc1b0bcf97` **before** either arm was spawned.

Envelopes (data of record, meter-verified `2 exact`):
- Arm A (brief-default): `results/live-smoke--A--1.agent.json`
- Arm B (`--full`-forced): `results/live-smoke--B--1.agent.json`

Invocation logs (envelope-independent escape-rate source):
- `results/live-smoke--A--1.shimlog`, `results/live-smoke--B--1.shimlog`

Model: `claude-sonnet-5` (both arms; matches ctx-s5's committed pin). Cap
`--max-budget-usd 3.00`/arm. Serial, same cwd, no session sharing. `bp` built
from `origin/main` `66d27486c` (ships the brief default).

## Named metrics

| metric | Arm A — brief | Arm B — `--full` |
|---|---|---|
| `total_cost_usd` | **$0.520476** | **$0.608002** |
| `num_turns` | 9 | 12 |
| `input_tokens` | 10 | 24 |
| `output_tokens` | 4,250 | 4,962 |
| `cache_read_input_tokens` | 274,580 | **652,272** |
| `cache_creation` 1h / 5m | 62,387 / 0 | 56,303 / 0 |
| `duration_api_ms` | 50,750 | 63,674 |
| `duration_ms` | 53,882 | 71,803 |
| completed (non-error, 5 tasks summarized) | yes | yes |
| **`--full` escape rate** | **0 / 1 = 0 %** | 1 / 1 (forced — not informative) |

meter.py verify: `2 envelopes — 2 exact` (both reproduce the METER.md §2 TTL-aware
formula to < 1e-6; `sum(modelUsage.costUSD) == total_cost_usd`).

## Directional verdict: SIGN CORRECT, but FLOOR-BOUND (per the pre-registered rule)

- **Sign:** `cost_A ($0.5205) < cost_B ($0.6080)` — the brief-default arm cost
  **$0.0875 (14.4 %) less** than the `--full`-forced arm, holding the prompt and
  the read-only chore fixed. The direction **matches the fixture math** (brief =
  26,502 B vs full = 95,915 B in context).
- **Mechanism is visible and unambiguous:** Arm B re-read **652,272**
  cache-read tokens vs Arm A's **274,580** — a **2.38×** difference (+377,692
  tokens). Cache-read tokens are the direct measure of "context re-paid per turn"
  (METER.md §3), so the ~70 KB heavier manifest amplified across turns is exactly
  where the extra dollars came from. This token-axis signal is independent of the
  dollar floor and supports the direction cleanly.
- **BUT the arms are FLOOR-BOUND.** The pre-registered confirm rule required BOTH
  arms to clear **> ~$1.10** (>2× the ~$0.55 spawn floor). They did not — $0.52
  and $0.61 sit **inside the floor band**. Per prereg §2/§6, when an arm lands at
  or below ~$1.10 the comparison is measuring mostly the floor, so the **dollar
  magnitude is not a clean above-floor confirmation**. Classified per the frozen
  rule as **"sign flat/inconclusive → floor-bound"**: direction consistent, dollar
  delta floor-limited.
- **No re-run, no prompt amendment.** The pre-registration forbids re-running
  until the number agrees and freezes the prompt. The read-only chore (Sonnet-5,
  ~9–12 turns) was cheaper per turn than the sizing assumed; that is recorded here
  honestly rather than papered over by a heavier post-hoc chore. A future
  above-floor confirmation belongs to the pre-registered paired duel
  (`ctx-b1-paired-duel`, budget $30–80), not to this n=1 smoke.

## `--full` escape rate: 0 % — NO alarm, NO follow-up filed

Arm A completed the entire onboarding chore — discovered the CLI from the brief
manifest, listed ready tasks, fetched and summarized five tasks, and answered two
manifest-derived questions — **without ever reaching for `--full`** (shim log: one
`capabilities -o json`, zero `--full`). The brief manifest was invoke-complete in
practice for this session. Escape rate is **zero**, so per charter law ("the
`--full` escape rate is the alarm") and the ctx-s6 criteria, **no brief-fattening
follow-up task is filed**. (Arm B's escape is forced by instruction and carries no
information.)

## One-line verdict

> Directionally, brief beats `--full` (14.4 % cheaper, 2.38× less cached context
> re-read) with zero `--full` escapes — but both arms are floor-bound, so this is
> a floor-limited directional smoke, never an above-floor or statistical claim.

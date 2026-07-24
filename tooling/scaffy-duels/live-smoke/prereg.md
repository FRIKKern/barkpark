# Live before/after directional smoke — PRE-REGISTRATION (ctx-s6)

**This file is committed BEFORE any arm is spawned.** Its git commit SHA is the
proof-of-pre-registration for the two envelopes captured under
`tooling/scaffy-duels/results/live-smoke--{A,B}--1.agent.json`. Nothing here may
be edited after the runs — corrections go in the results note, never here.

Epic: bp Context-Compression (`task-495cc9a9af43472c`) · Slice: `ctx-s6-live-smoke`
· Charter: `.claude/workflows/bp-ctx-compression-charter.md` **decision 13**.

---

## 0. Framing — READ THIS FIRST (charter decision 13)

This is **n = 1 DIRECTIONAL SMOKE ONLY**. It is **NOT** a statistical claim, not a
benchmark, not a power-calculated experiment. One envelope per arm.

The single question it answers: **does the sign match the fixture math** — i.e.
does the brief-default arm (26,502 B manifest in context) cost *less* per session
than the `--full`-forced arm (95,915 B manifest in context), with turns and task
success held roughly equal?

Explicitly out of scope, and never to be claimed from this data:
- No comparison against the **12–81.5×** static byte-ratio band — that band was
  measured on payload bytes, not on session `total_cost_usd`; different
  methodology, so a cross-claim would be apples-to-oranges (charter law).
- No generalization to "paid on every session" — capabilities is absent from the
  spend-census top-8; the correct phrasing is **amplified-per-call**, and the
  per-session invocation count is unmeasured here.
- A single run cannot establish an effect size, a variance, or significance.

If the sign comes out *wrong* or *flat*, that is a publishable negative result,
recorded honestly in the results note — not re-run until it agrees.

---

## 1. Model pin

- **Pinned model id: `claude-sonnet-5`** (passed as `--model claude-sonnet-5`).
- This pin **must match `ctx-s5-count-tokens`'s** count_tokens model id — tokenizers
  differ ~30% across models (METER.md §1), so the token calibration and this live
  session must speak the same tokenizer. At the time this pre-registration was
  written, ctx-s5 had **not yet committed a pin** (its criteria/pulses were empty);
  per the ctx-s6 dispatch instruction, `claude-sonnet-5` is chosen and stated here
  explicitly **so that ctx-s5 can match it**.
- meter.py `rate_for` matches on the `claude-sonnet-5` prefix → rates
  $3.00/MTok in, $15.00/MTok out (METER.md §2). The captured envelope's
  `modelUsage` key is the ground-truth record of the model that actually ran.

## 2. Budget (registered before running)

- **Per-arm cap: `--max-budget-usd 3.00`** (`cap_usd = 3.00`).
- The cap is a safety ceiling, **not** the target. It is set well above the
  expected spend so neither arm truncates mid-chore (a truncated arm would
  measure the cap, not the work).
- **Floor discipline (charter D13):** the spawn floor is ~$0.55 (Sonnet-5, warm
  repo — METER.md §3). The chore is sized (manifest read + `bp task ready` + five
  `bp task get` calls + synthesis ≈ 8 turns) so that **post-floor spend clears
  >2× the floor, i.e. > $1.10 per arm**. If an arm's `total_cost_usd` lands at or
  below ~$1.10, the comparison is measuring the floor and the result note must say
  so rather than report a delta.

## 3. Arms (identical but for one flag)

Same worktree cwd, same freshly-built `bp` binary (built from `origin/main`
`66d27486c`, which ships the brief default — ctx-s1), **serial**, no session
sharing (`--no-session-persistence` on each).

| Arm | Capabilities call in prompt | Manifest bytes entering context |
|-----|-----------------------------|---------------------------------|
| **A** brief-default | `bp capabilities -o json`        | 26,502 B (3.62× smaller) |
| **B** `--full`-forced | `bp capabilities -o json --full` | 95,915 B (baseline) |

The two prompts (`prompt-A.txt`, `prompt-B.txt`) are **byte-identical except the
single `--full` token** on the capabilities line — verified by `diff`.

### Spawn recipe (the implemented D66 shape, `run-cell.sh:241-246`)

```
claude -p "<frozen prompt>" \
  --model claude-sonnet-5 \
  --output-format json \
  --permission-mode bypassPermissions \
  --no-session-persistence \
  --max-budget-usd 3.00
```

Exactly **one** envelope per arm is captured (`results/live-smoke--{A,B}--1.agent.json`).
**Summing transcript JSONL is BANNED** (METER.md §1 — overcounts 2–5×). The
`--output-format json` envelope's `total_cost_usd` / `usage` / `modelUsage` are the
only cost record.

### Read-only guarantee

The ledger chore is **strictly read-only**: `bp task ready` + `bp task get`. It
never mutates a real task. Two independent guards:
1. The frozen prompt forbids create/claim/close/stamp/update/move/stage/release.
2. `bp-shim` (placed on PATH as `bp`) **hard-blocks** those mutating `task` verbs
   before they can reach the real binary (exit 3), and logs every invocation.

## 4. Frozen verbatim prompts

### Arm A (`prompt-A.txt`) — brief-default

```
You are a new engineer onboarding to the Barkpark CLI (the `bp` command). Start by discovering the CLI: run `bp capabilities -o json` and read the machine-readable command manifest it returns so you understand what nouns, verbs, commands, arguments, and flags are available.

Then complete this small, strictly READ-ONLY ledger chore using what you just learned:
1. Run `bp task ready` to list the tasks currently available to work on.
2. Choose the five highest-priority ready tasks.
3. For each of the five, run `bp task get <id>` and read its description.
4. Produce a final numbered list of those five tasks; for each give its id, its title, and a one-sentence summary (in your own words) of what the task asks for.
5. Finally, state two facts drawn from the manifest you read at the start: (a) roughly how many ready tasks there were in total, and (b) which noun in the manifest carries the most commands.

Hard rule: this is READ-ONLY. Do NOT create, claim, close, stamp, update, move, stage, release, or otherwise modify any task, and do not modify any file. Only run read commands and report your findings.
```

### Arm B (`prompt-B.txt`) — `--full`-forced

Identical to Arm A except the first-line command is `bp capabilities -o json --full`.

## 5. Named metrics (reported for BOTH arms)

All read straight off the envelope (METER.md ground-truth hierarchy):

- **`total_cost_usd`** — the meter of record (envelope top-level).
- **`num_turns`** — round-trip count.
- **`usage` breakdown** — `input_tokens`, `output_tokens`,
  `cache_read_input_tokens`, `cache_creation` (5m / 1h TTL split).
- **`duration_api_ms`** and **`duration_ms`** — API time and wall-clock.
- **`--full` ESCAPE RATE** — first-class alarm metric. Defined per arm as
  `(# capabilities invocations that carried --full) / (# capabilities invocations)`,
  computed from the `bp-shim` invocation log (envelope-independent, not JSONL).
  Arm A's escape rate is the one that matters: a **nonzero** Arm A escape rate
  means the brief manifest was insufficient and the agent reached for `--full` —
  which, per charter law ("the `--full` escape rate is the alarm") and the ctx-s6
  criteria, **files a brief-fattening follow-up task before any wider rollout
  claim**. (Arm B is `--full` by instruction, so its escape rate is definitionally
  forced, not informative.)

## 6. Pre-registered directional verdict rule

Let `cost_A`, `cost_B` be the two `total_cost_usd` values.

- **Sign confirmed** iff `cost_A < cost_B` AND both arms cleared the floor
  (`cost > ~$1.10`) AND both completed the chore (non-error envelope, five tasks
  summarized) AND Arm A escape rate == 0.
- **Sign flat/inconclusive** if the arms land within the floor band, or an arm
  truncated at the cap, or an arm errored — reported as such, no delta claimed.
- **Sign wrong** if `cost_A >= cost_B` on completed, above-floor arms — a negative
  result, recorded honestly.
- **Escape alarm** (orthogonal to sign): Arm A escape rate > 0 → file the
  brief-fattening follow-up task regardless of the cost sign.

The verdict line is written once into
`tooling/scaffy-duels/results/live-smoke-verdict.md` after the runs, citing the
two envelopes and the shim logs.

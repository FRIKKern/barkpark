<!-- doc-tier: agent | canonical-for: epic-cycle-concurrency-benchmark | budget: 3600tok -->
# Epic Cycle concurrency benchmark protocol

`scripts/run_concurrency_benchmark.py` is the sole supported Epic Cycle concurrency trial path. It measures one fixed design: six equal assignments at widths **1, 2, 3, and 6**. It is not a generic command interceptor, OMX runtime wrapper, or permission to observe processes the runner did not start.

## Frozen experiment

- Schemas: `epic-cycle-concurrency-v1` for the legacy boolean evaluation path,
  `epic-cycle-concurrency-v2` for the legacy retrieval attribution contract, and
  `epic-cycle-concurrency-v3` for physical CycleFleet attribution.
- Seed: `20260715`; any other seed is rejected.
- Work: exactly six unique assignment ids and argv lists. Every treatment receives all six assignments once per look.
- Retrieval v2/v3 corpus: `references/codex-epic-cycle-wave-3-real-corpus-v1.jsonl`, frozen at repository commit `55519257db1377e4e747683204fe902fe8d562a9`. Its identity is SHA-256 `a3a22c78d90e76fe00473b6434b2a025df51da7844d9022959c3f25eb0ee8a26` over exact file bytes, including its single final LF; newline-stripped digests are not corpus identities. The six ordered records each own three claim ids, yielding claim-domain digest `ad364452e4288061ecb1b972bb301b9d8cfdbe91e8f142a62ef3ded02f13176a`.
- Retrieval v3 provenance: every assignment records the physical `cycle_phase` and
  exact CycleFleet `unit_ids`. Build attribution owns exactly its corpus unit;
  non-Build attribution, including the six-agent Verify replay, has
  `unit_ids: []`. Corpus identity is bound by the logical `assignment_id`, which
  must still equal the ordered corpus record id. This prevents Verify agents
  from pretending to own Build units. Legacy v2 remains accepted for replaying
  already-frozen artifacts.
- Treatments: exactly `1/2/3/6`; no other width is accepted.
- Design: one complete four-row Williams cycle:

  ```text
  1 2 6 3
  2 3 1 6
  3 6 2 1
  6 1 3 2
  ```

  Every width appears once at each of four fixed looks and every directed first-order carryover pair appears once. The seed freezes each trial's six-item FIFO dispatch order.
- Preparation: every treatment trial runs its declared `cold_reset_argv`, then its declared `warm_prime_argv`, before measurement. The artifact proves only that each command exited successfully; it reports semantic verification as typed `unsupported` because the runner cannot establish that arbitrary commands actually produced cold and warm states. A failed or timed-out preparation aborts rather than silently changing the protocol.
- Looks: analysis is emitted after Williams rows 1, 2, 3, and 4. All are recorded; only look 4 is decision-binding. There is no optional early stopping.
- ITT: all six scheduled assignments stay in the denominator. Launch failures, crashes, malformed/missing evaluation JSON, and timeouts are retained rather than dropped.

For v1, each assignment's final non-empty stdout line must be JSON with two booleans:

```json
{"complete": true, "contradiction_unsupported": false}
```

Missing or malformed evaluation is conservatively incomplete and contradiction/unsupported. A non-zero exit or timeout is incomplete regardless of its payload.

For retrieval v2/v3, the final line is the exact retrieval evaluation object
`{complete, witnesses, attribution, usage}`. The returned attribution must
byte-for-byte match the manifest entry. Unknown provider usage remains a typed
`unsupported`, `missing`, or `invalid` state with a non-empty reason.

## Selection rule

At every fixed look, each width is compared with **every** other width. A width is eligible only when all comparisons pass:

- completeness is no more than **5 percentage points lower**;
- contradiction/unsupported is no more than **2 percentage points higher**;
- failure/timeout is no more than **5 percentage points higher**.

The highest all-pairs-eligible width is selected. No width is selected when balanced evidence is missing. This rule is fixed in code and artifact provenance; do not substitute a baseline-only or best-pair comparison. `selected_width` is only the outcome of this preregistered quality-margin rule: the artifact emits typed `unsupported` values for both `statistically_fastest_width` and `knee_width`, because the design contains neither a preregistered runtime hypothesis test nor a knee estimator with sufficient repeated runtime evidence.

## Admission and process ownership

Planning never executes workload commands. `run` and `replay` additionally require `--execute-heavy` and a successful admission decision.

Heavy capacity defaults to **one**. Capacity two is the maximum and requires all of:

- `--heavy-capacity 2 --allow-capacity-two`;
- live, start-fenced tmux pane identity;
- Darwin or Linux POSIX process-group support;
- at least four logical CPUs;
- load1 no greater than 75% of logical CPUs;
- at least 2 GiB available memory.

Capacity one still denies missing identity, CPU count, load, available-memory, or process-group signals; less than 512 MiB available memory; or load above 150% of logical CPUs. Unknown is denial, never permission.

Admission is backed by a cross-process stdlib file lease. Capacity-one runs take an exclusive gate. Explicit healthy capacity-two runs share that gate but must acquire one of exactly two slot locks. Thus capacity is enforced across concurrent runner processes rather than merely reported in JSON.

The pane pid is resolved live with `tmux display-message`. The pid is fenced against reuse by `/proc/<pid>/stat` start time on Linux or `ps -o lstart` on Darwin. Each measured assignment is launched with `start_new_session=True`, must be leader of its own process group, and is sampled or terminated only through that owned group. The runner does not claim generic interception of agents, shells, or unrelated pane descendants.

## Metrics and provenance

Each measured trial records:

- treatment wall seconds from `time.monotonic`, plus per-assignment wall seconds from FIFO dispatch through launch/start-identity fencing and terminal observation (launch failures retain the elapsed failed launch/fence interval rather than zero);
- child user and system seconds from `resource.getrusage(RUSAGE_CHILDREN)`;
- peak live RSS from the owned-process-group sampler;
- CPU derived from `(user + system) / wall`;
- instantaneous sampled CPU where the platform exposes it.

Every metric is a typed object with `kind`, `value`, `unit`, `source`, and `scope`. Kinds are `measured`, `null`, and `unsupported`. The latter two always carry JSON `null`, plus a reason; they are never coerced to numeric zero. An empty owned process group is not an observed zero-RSS group, so it contributes no RSS observation and produces typed `null` when no live owned-group sample exists. Darwin group sampling reports unsupported user/system components when portable `ps` cannot separate them, while final child rusage remains measured. The artifact also exposes typed `unsupported` `token_cost`, `context_cost`, and `verified_unique_information` fields: the narrow assignment evaluation contract does not provide token/context accounting or a preregistered unique-information verifier.

## Contamination and sensitivity

The runner snapshots the declared tmux pane identities before and after every treatment. A missing or changed primary pid/start identity is a safety violation; any changed ambient pane identity marks the original trial contaminated. Owned process-group sampler errors also contaminate the trial. Contaminated originals remain verbatim in `original_trials`. Each gets one separately labeled sensitivity rerun after the complete original schedule. A clean rerun replaces its contaminated original only for sensitivity analysis; the artifact retains both. A contaminated rerun does not erase or launder the original.

The result's `contamination_scope` is deliberately explicit: load1 and available memory are admission-time safety signals, not within-treatment drift monitors. A trial without pane or sampler contamination therefore does **not** establish stable host load or memory availability during the treatment; those two drift claims are emitted as typed `unsupported` limitations.

## Manifest and commands

The v1 manifest accepts only this narrow shape:

```json
{
  "schema_version": "epic-cycle-concurrency-v1",
  "seed": 20260715,
  "assignments": [
    {"id": "a1", "argv": ["command", "arg"]},
    {"id": "a2", "argv": ["command", "arg"]},
    {"id": "a3", "argv": ["command", "arg"]},
    {"id": "a4", "argv": ["command", "arg"]},
    {"id": "a5", "argv": ["command", "arg"]},
    {"id": "a6", "argv": ["command", "arg"]}
  ],
  "cold_reset_argv": ["command", "reset"],
  "warm_prime_argv": ["command", "prime"],
  "primary_pane": "%3",
  "tmux_panes": ["%3", "%4", "%5", "%6"],
  "timeout_seconds": 1800,
  "environment": {"KEY": "value"}
}
```

Unknown fields are rejected. Generate and inspect the deterministic plan first:

Retrieval v3 keeps the same six ordered assignment ids and command fields, adds
the frozen corpus admission object, and gives each assignment an attribution
object with `cycle_phase`, physical CycleFleet ids/digests, exact physical
`unit_ids`, and the bound Task claim fence. The runner rejects v2/v3 field
mixing and phase/unit ownership mismatches.

```bash
python3 .codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py \
  plan --config benchmark.json --output benchmark-plan.json
```

Run only from an intentionally admitted heavy-work window:

```bash
python3 .codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py \
  run --config benchmark.json --output benchmark-result.json --execute-heavy
```

Replay first verifies both the plan digest and the manifest-derived schedule before execution:

```bash
python3 .codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py \
  replay --config benchmark.json --artifact benchmark-plan.json \
  --output benchmark-replay.json --execute-heavy
```

The runner writes JSON atomically. A denied run may write the admission evidence but must not start reset, prime, or assignment commands.

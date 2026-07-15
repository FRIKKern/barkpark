# Legendary Cycle fleet contract

The Legendary Cycle has a five-times Epic baseline plus a dedicated experiment fleet.

## Minimum fleet

| Phase | Typed role | Waves × width | Minimum completed | Scaling rule |
| --- | --- | ---: | ---: | --- |
| Survey | `epic-surveyor` | 20 × 3 | 60 | exact |
| Verify | `epic-verifier` | 10 × 3 | 30 | exact |
| Experiment | `legendary-experimenter` | 5 × 3 | 15 | exact baseline; add full waves of 3 |
| Build | `legendary-builder` | at least 5 × 3 | 15 | `max(15, ceil(units / capacity))` |
| Review | `code-reviewer` | 5 × 3 | 15 | exact baseline; repeat full fleets of 15 after material fixes |

The minimum Epic-equivalent fleet is 120 completed assignments: 60 + 30 + 15 + 15. Experiment adds 15, so the minimum total is 135. The leader, retries, untyped sessions, and duplicate work do not count.

## Structured record

Store the canonical machine-readable record on the reader-visible Agent fleet callout:

```json
{
  "type": "callout",
  "title": "Agent fleet",
  "fleet": {
    "survey": {"agent_type":"epic-surveyor","planned":60,"started":0,"completed":0,"failed":0,"missing":60,"assignments":[]},
    "verify": {"agent_type":"epic-verifier","planned":30,"started":0,"completed":0,"failed":0,"missing":30,"assignments":[]},
    "experiment": {"agent_type":"legendary-experimenter","planned":15,"started":0,"completed":0,"failed":0,"missing":15,"assignments":[]},
    "build": {"agent_type":"legendary-builder","planned":15,"started":0,"completed":0,"failed":0,"missing":15,"assignments":[]},
    "review": {"agent_type":"code-reviewer","planned":15,"started":0,"completed":0,"failed":0,"missing":15,"assignments":[]}
  }
}
```

Every completion has a unique id, exact `agent_type`, `status: completed`, and a non-empty durable evidence link. `completed` equals valid unique records, `started >= completed`, and `missing = max(0, planned - completed)`.

Build `planned` may exceed 15 and must equal the Scale profile's evaluated formula. Experiment additions occur in complete waves of three. Review additions after material fixes occur in complete fleets of 15. Never overwrite earlier evidence.

## Ledger-backed Build and Review gate

Build and Review preflight requires `--fleet-ledger-json PATH` pointing to the exact canonical `barkpark-epic-benchmark-v1` bytes emitted by `mix barkpark.epic_fleet.export`. The validator verifies canonical encoding, exact shape, component and ledger digests, replacement ancestry, redaction, every typed cost, and the all-attempt summary. A complete-looking Paper is never sufficient by itself.

Legendary scope requires `experiment.phase: legendary`, `protocol_version: 1`, the Task parent id in `experiment.epic_id`, and the Paper id in `experiment.wave_id`. The manifest contains exactly this reconciliation scope beneath `fleet_contract`:

```json
{"version":1,"paper_fleet_digest":"<canonical sha256 of the Paper fleet object>"}
```

Only the fleet object is digested; unrelated PortableDoc blocks remain reader-owned and may change without invalidating the fleet export.

Every attempt carries `payload.fleet_assignment` with exactly `phase`, `assignment_id`, `agent_type`, `evidence`, and `model_reasoning_effort`. The phase and type must match this contract. All Legendary Build and Review attempts use `model_reasoning_effort: high`, including attempts that fail or are later replaced; the validator does not coerce a role's ordinary default into proof of high effort.

Retries remain append-only. Attempt ordinals are unique and contiguous from 1. Multiple attempts for one phase and assignment id form exactly one linear replacement chain ending in one terminal leaf; replacements point to an existing lower ordinal and preserve logical assignment identity. Only unreplaced completed leaves count; `started` is the unique logical assignment count, `completed` is the completed terminal-leaf count, and `failed` includes every failed, timeout, contaminated, or cancelled attempt even when a later replacement succeeds. Every attempt stays in cost and outcome denominators. Cost states are exhaustively `observed` with a numeric value or `unsupported`, `missing`, or `invalid` with a reason. Paper-only inflation, stale fleet digests, missing or forked replacements, unknown cost states, untyped assignments, and non-high Build or Review attempts fail closed.

If the surface cannot name `agent_type`, record the capability block. Sequential investigation may preserve knowledge but cannot satisfy the fleet gate.

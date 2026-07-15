# Epic Cycle fleet contract

The Epic Cycle is a multi-wave agent system, not a single leader performing renamed phases.

## Exact fleet

| Phase | Typed role | Waves × width | Completed assignments | Effort |
| --- | --- | ---: | ---: | --- |
| Survey | `epic-surveyor` | 4 × 3 | 12 | medium |
| Verify | `epic-verifier` | 2 × 3 | 6 | medium |
| Build | `epic-builder` | 1 × 3 | 3 | high |
| Review | `code-reviewer` | 1 × 3 | 3 | high |
| Total | — | 8 waves | 24 | — |

The leader never counts. A retry replaces a failed assignment and does not increase the completed count. Build agents own separate tasks, files, branches, and worktrees.

## Fleet gate

The Paper's **Agent fleet** section records, per phase: planned, started, completed, failed, missing, exact `agent_type`, task or assignment id, and evidence location. Completion requires all 24 typed assignments and all three Build assignments at high effort.

Store the machine-readable record on the reader-visible Agent fleet callout as a top-level `fleet` object. This is the canonical PortableDoc shape (JSON shown without unrelated display fields):

```json
{
  "type": "callout",
  "title": "Agent fleet",
  "fleet": {
    "survey": {
      "agent_type": "epic-surveyor",
      "planned": 12,
      "started": 0,
      "completed": 0,
      "failed": 0,
      "missing": 12,
      "assignments": []
    },
    "verify": {
      "agent_type": "epic-verifier",
      "planned": 6,
      "started": 0,
      "completed": 0,
      "failed": 0,
      "missing": 6,
      "assignments": []
    },
    "build": {
      "agent_type": "epic-builder",
      "planned": 3,
      "started": 0,
      "completed": 0,
      "failed": 0,
      "missing": 3,
      "assignments": []
    },
    "review": {
      "agent_type": "code-reviewer",
      "planned": 3,
      "started": 0,
      "completed": 0,
      "failed": 0,
      "missing": 3,
      "assignments": []
    }
  }
}
```

Every completed assignment is appended in this exact form:

```json
{
  "id": "review-1-1",
  "agent_type": "code-reviewer",
  "status": "completed",
  "evidence": "paper://review/round-1/reviewer-1"
}
```

`completed` equals the number of unique, valid assignment records; `started` is at least `completed`; and `missing` is `max(0, planned - completed)`. If fixes materially change behavior, append a complete new Review wave of three unique assignments. The baseline `planned` value remains 3, `completed` may therefore be 6, 9, and so on, and `missing` remains 0. Never overwrite earlier review evidence.

## Ledger-backed Build and Review gate

The Paper is a reader projection, not completion authority. Every Build and Review preflight must also receive `--fleet-ledger-json PATH`, where `PATH` is the exact newline-free canonical JSON emitted by `mix barkpark.epic_fleet.export`. The validator verifies the B1 `barkpark-epic-benchmark-v1` document shape, canonical byte encoding, every component digest, replacement ancestry, secret redaction, typed costs, and the all-attempt summary before consulting completion counts.

The export is scoped as follows:

- `experiment.phase` is `epic`, `protocol_version` is `1`, `experiment.epic_id` equals the Task's parent epic, and `experiment.wave_id` equals the published Paper id.
- `manifest.fleet_contract` is exactly `{"version":1,"paper_fleet_digest":"<sha256>"}`. The digest covers only the canonical top-level `fleet` object, so unrelated reader content remains untouched and does not stale the export.
- Every attempt payload contains an exact `fleet_assignment` object:

```json
{
  "phase": "build",
  "assignment_id": "build-1",
  "agent_type": "epic-builder",
  "evidence": "paper://build/1",
  "model_reasoning_effort": "high"
}
```

Every attempt, including failed, timed-out, contaminated, cancelled, and replaced attempts, remains in the signed ledger and cost summary. Each cost metric is typed as `observed` with a numeric `value`, or `unsupported`, `missing`, or `invalid` with a non-empty `reason`; an unknown or coerced zero never counts.

Only an unreplaced terminal leaf with attempt `status: completed` contributes a Paper completion. Attempt ordinals are unique and contiguous from 1. Multiple attempts for one phase and assignment id must form one linear replacement chain with exactly one terminal leaf; every replacement points backward to an existing lower ordinal and preserves phase, assignment id, agent type, and effort. `started` reconciles to unique logical assignment ids, `completed` to completed terminal leaves, and `failed` to every non-completed attempt, including attempts later replaced. Terminal ids, types, and evidence must match the Paper exactly. Every Build and Review attempt, including replaced attempts, records `model_reasoning_effort: high`; Paper-only inflation, stale projections, missing leaves, forks, malformed costs, untyped agents, or non-high Build or Review work fail closed.

If the active surface cannot name `agent_type`, the wave is capability-blocked. Sequential work or standalone CLI sessions may preserve progress but cannot satisfy this gate. Resume from the published Task and Paper on a typed native-subagent surface or an attached-tmux OMX team runtime.

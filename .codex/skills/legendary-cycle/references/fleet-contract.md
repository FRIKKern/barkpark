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

If the surface cannot name `agent_type`, record the capability block. Sequential investigation may preserve knowledge but cannot satisfy the fleet gate.

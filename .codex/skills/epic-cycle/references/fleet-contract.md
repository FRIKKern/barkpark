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

If the active surface cannot name `agent_type`, the wave is capability-blocked. Sequential work or standalone CLI sessions may preserve progress but cannot satisfy this gate. Resume from the published Task and Paper on a typed native-subagent surface or an attached-tmux OMX team runtime.

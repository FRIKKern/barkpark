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

If the active surface cannot name `agent_type`, the wave is capability-blocked. Sequential work or standalone CLI sessions may preserve progress but cannot satisfy this gate. Resume from the published Task and Paper on a typed native-subagent surface or an attached-tmux OMX team runtime.

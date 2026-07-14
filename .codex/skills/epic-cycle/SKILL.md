---
name: epic-cycle
description: Run one evidence-gated Barkpark epic wave in Codex, from strategy through survey, verification, decisions, build, review, and debrief. Use when the user asks to run, continue, perfect, or design an epic cycle/wave and wants high reasoning for strategic judgment with medium reasoning for bounded survey, proof, and implementation work.
---

# Epic Cycle

Run a durable epic wave with Barkpark tasks and one wave Paper as the source of truth. Preserve the full user wish verbatim. Optimize the reasoning budget by phase: high for choices, medium for gathering and proving facts.

Read `references/phase-contract.md` before starting. Also read the epic charter when one exists and `.claude/workflows/bp-loop-ledger.md` for the current task-ledger rules.

## Inputs

Require:

- `wish`: the user's request verbatim.
- `epic_task_id`: the published root task when it exists.
- `charter_path`: the epic charter when it exists.

Infer a missing task id or charter path by searching Barkpark and the repo. Ask only if multiple live epics remain plausible after searching.

## Effort policy

Do not run every phase at maximum effort.

| Phase | Owner | Effort | Purpose |
| --- | --- | --- | --- |
| Strategize | leader | high | Direction, priorities, survey questions |
| Survey | `epic-surveyor` subagents | medium | Broad repo/task/Paper mapping with coverage accounting |
| Digest | leader | high | Synthesis and targeted proof design |
| Verify | `epic-verifier` subagents | medium | Run commands and prove or refute load-bearing claims |
| Decide | leader | high | Final choices, charter, task graph, wave cut |
| Build | `executor` subagents | medium | Implement bounded published tasks in isolated worktrees |
| Review | `code-reviewer` plus leader | high | Adversarial review, integration judgment, grade, debrief |

Use the installed role by exact `agent_type`; never spawn an untyped child. Keep the leader responsible for decisions, integration, task mutations, and completion claims. Surveyors and verifiers are read-only. Use no more than four active agents including the leader on this installation; fan out in batches.

If native subagents are unavailable, execute the same phases sequentially and explicitly announce the effort transition. Do not silently collapse survey and verify into strategic intuition.

## Workflow

### 1. Prime

Create or refresh a visible plan. Read `CLAUDE.md`, the task-system card it routes to, the epic task tree, the charter, recent wave Paper, git state, and relevant live claims. Establish:

- desired outcome and stop condition;
- current epic state and unfinished merge/human gates;
- existing decisions that must not be reopened without contradictory evidence;
- current wave Paper id or the id to create.

Never build from a diverged or dirty shared main checkout. Preserve unrelated work.

### 2. Strategize — high

Think broadly but read selectively. Produce a bold direction and 5–12 independent, answerable survey assignments. Each assignment must say why its answer changes the wave.

Open and publish one `style=article` wave Paper. Record the wish, direction, survey plan, and current phase. Patch the epic task's flat `wave_paper` and `wave_status` fields and republish it.

Gate: the Paper and epic heartbeat are readable from Barkpark before survey begins.

### 3. Survey — medium

Spawn `epic-surveyor` agents for independent assignments. Each report must include:

- direct answer;
- every file/task/Paper checked and what it was checked for;
- `found`, `not_found`, or `partial` coverage results;
- file:line or task/Paper evidence for load-bearing facts;
- risks and unresolved questions.

Survey is breadth, not proof. Agents do not edit files or mutate Barkpark.

Gate: every assignment reported or is explicitly marked missing; unvisited surfaces are visible.

### 4. Digest — high

Reconcile reports, contradictions, and negative findings. Separate evidence from inference. Design only the targeted verification needed for decisions. Each verification assignment must name:

- the exact claim;
- why it is decision-critical;
- commands or observations that would prove or refute it;
- whether isolation is required.

Append the survey digest and verification plan to the Paper before verification starts. Update `wave_status`.

### 5. Verify — medium

Spawn `epic-verifier` agents. Require actual command output for behavioral, test, build, runtime, migration, or compatibility claims. A green command is evidence only when the verifier explains why the command exercises the claim. Record failed proofs honestly.

Gate: every decision-critical unknown is proven, refuted, or explicitly carried as risk. Do not proceed on merely plausible claims.

### 6. Decide — high

Make the choices; do not return an options list. Update or create the charter and commit only that intentional charter change before builders branch.

Cut at most eight slices. For every slice:

- create and publish a child task under the epic;
- set `proj:<mission>` and `phase:<design|decision|build|verify>` labels plus exact `files:` labels;
- link the wave Paper;
- write a cold-startable description;
- add 1–3 evidence-bearing criteria plus a merge-gated criterion when applicable;
- add blocker edges for actual sequencing;
- dry-run the proposed gate;
- read the published task back and fix defects.

File real deferred findings as published backlog children. Append proofs, final decisions, task ids, order, and gates to the Paper. Set `wave_status` to building.

Gate: no slice exists only in prose; every slice is published, parented, linked, claimable when dependencies permit, and collision-aware.

### 7. Build — medium

Spawn one `executor` per independent slice in an isolated worktree, in batches that respect the concurrency cap and blocker graph. The builder must claim before editing, pulse the now-line, stamp each criterion when proven, run the exact gate, self-review, and commit. Builders do not close merge-gated criteria or mutate the wave Paper.

The leader reviews every result and current task state before accepting it.

Gate: each accepted branch has a clean diff, fresh passing evidence, a truthful ledger, and no unowned file collision.

### 8. Review and debrief — high

Use `code-reviewer` for an independent adversarial pass over green branches, then let the leader integrate the findings. Fix actionable issues on review branches, rerun gates, and audit cross-slice coherence and the actual Barkpark ledger.

Append a dated wave log to the charter and a final debrief to the Paper. Include shipped/stalled slices, final branches or commits, proof, ledger repairs, honest grade, shortcomings, and next-wave direction. Patch the epic `wave_status` to complete only when the wave's own stop condition is satisfied.

Do not mark the epic itself done merely because one wave ended. Close or complete only tasks whose full criteria and merge gates are proven.

## Recovery

- On `fenced_off`, `rail_changed`, or `doc_changed_since_claim`, reread, reconcile, renew the same worker claim when appropriate, and continue.
- On a failed gate, keep the task truthful and in progress; fix or record the blocker. Never convert a failure into prose-only success.
- On interrupted runs, resume from the Paper, epic heartbeat, task claims, and git branches. Do not restart discovery already captured with evidence.
- On user cancellation, use the active cancellation workflow, leave ledger state honest, and stop.

## Completion report

Report the wave outcome first: direction chosen, slices shipped/stalled, validation evidence, task/Paper ids, final branches/commits, remaining risks, and next-wave direction. The stop condition is a reviewed, evidence-backed wave with a truthful durable ledger—not a merely completed sequence of prompts.

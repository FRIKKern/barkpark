---
name: epic-cycle
description: Run one evidence-gated Barkpark epic wave in Codex, from strategy through multi-wave agent fleets, verification, high-effort build, review, and debrief. Use when the user asks to run, continue, perfect, or design an epic cycle/wave.
---

# Epic Cycle

Run a durable epic wave with Barkpark tasks and one wave Paper as the source of truth. Preserve the full user wish verbatim. Optimize the reasoning budget by phase: high for choices, medium for gathering and proving facts.

For new runs, open the canonical project-scoped `Barkpark.CycleFleet` with
`profile=epic`, dispatch assignments/results through `bp cycle`, and project
its exact fleet into the Paper. Epic needs no Legendary post-Pilot seal and can
reach exact when its full 24-assignment planned fleet completes. The legacy
`Barkpark.EpicFleet` APIs and older Paper fleet shapes remain compatible; flat
HTTP cycle routes are token-bound, projectless compatibility surfaces, not the
canonical path for new runs.

Canonical preflight requires a `cycle_ledger` projection and reads the live
explicitly workspace/project-scoped `bp cycle show` authority (or its captured
`--cycle-json` response) to require both the Paper ledger and fleet to match it
exactly. Only a Paper whose immutable `_createdAt` predates the documented
`2026-07-15T00:05:00Z` CycleFleet cutoff may omit the ledger, and then the
operator must use live `--paper` retrieval and explicitly pass
`--allow-pre-cyclefleet-paper-without-ledger`. Offline `--paper-json` may still
validate a ledger-bearing Paper, but can never use the legacy omission because
its caller-controlled `_createdAt` is not authoritative.

Read `references/phase-contract.md`, `references/fleet-contract.md`, `references/task-contract.md`, and `references/charter.md` before starting. Read `references/benchmark-protocol.md` before proposing or running a concurrency trial. Also read `.claude/workflows/bp-loop-ledger.md` for the current repository merge-ledger rules.

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
| Build | `epic-builder` subagents | high | Implement bounded published tasks in isolated worktrees |
| Review | 3 `code-reviewer` subagents plus leader | high | Adversarial review, integration judgment, grade, debrief |

Use the installed role by exact `agent_type`; never spawn an untyped child. Keep the leader responsible for decisions, integration, task mutations, and completion claims. Surveyors and verifiers are read-only. Use no more than four active agents including the leader on this installation, so one wave contains exactly three children.

The default fleet is **24 completed typed child assignments**: 12 Survey (4 waves × 3), 6 Verify (2 waves × 3), 3 high-effort Build (1 wave × 3 independent slices), and 3 Review (1 wave × 3). Record planned, started, completed, failed, and missing counts by phase in the Paper's **Agent fleet** section. Do not count the leader, retries, standalone CLI sessions, or untyped fallbacks toward the 24.

If the current surface cannot explicitly select `agent_type`, do not spawn an untyped substitute. Announce the capability block and preserve any safe sequential evidence, but the wave cannot pass its fleet gate or claim a successful Epic Cycle proof. Resume from the durable Task/Paper state on a typed native-subagent or OMX team surface.

## Workflow

### 1. Prime

Create or refresh a visible plan. Read `CLAUDE.md`, the task-system card it routes to, the epic task tree, the charter, recent wave Paper, git state, and relevant live claims. Establish:

- desired outcome and stop condition;
- current epic state and unfinished merge/human gates;
- existing decisions that must not be reopened without contradictory evidence;
- current wave Paper id or the id to create.

Never build from a diverged or dirty shared main checkout. Preserve unrelated work.

Prime the task ledger before research or edits:

1. Create or locate the published epic and wave/slice tasks.
2. Claim the active task and read it back; record its current epoch, parent, labels, criteria, and `wave_paper`.
3. Pulse the claim at phase boundaries. Because a pulse renews the lease and bumps the epoch, reread the task immediately before every stamp or close.
4. If a published wave Paper already exists, run `scripts/validate_epic_cycle.py` at the current phase. For a new wave, create and publish the Paper in Strategize, then run the first preflight. Stop on any failed invariant.

The active task—not the prompt or plan—is the implementation contract of record.

### 2. Strategize — high

Think broadly but read selectively. Produce exactly 12 independent, answerable survey assignments, grouped into four waves of three. Each assignment must say why its answer changes the wave.

Open and publish one `style=article` wave Paper. Record the wish, direction, survey plan, and current phase. Patch the epic task's flat `wave_paper` and `wave_status` fields and republish it.

Gate: the Paper and epic heartbeat are readable from Barkpark before survey begins.

Capture the supplied wish in a durable UTF-8 file followed by exactly one file-format newline; the validator removes only that terminator and preserves every user byte, including user-supplied trailing whitespace. Run `python3 .codex/skills/epic-cycle/scripts/validate_epic_cycle.py --task <task> --paper <paper> --worker <worker> --phase strategize --wish-file <path>` before fan-out. Strategize must fail if it cannot compare the Paper narrative with the original wish verbatim.

### 3. Survey — medium

Spawn four successive waves of three `epic-surveyor` agents (12 completed assignments total). Each report must include:

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

Spawn two successive waves of three `epic-verifier` agents (6 completed assignments total). Require actual command output for behavioral, test, build, runtime, migration, or compatibility claims. A green command is evidence only when the verifier explains why the command exercises the claim. Record failed proofs honestly.

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

Run the complete Task/Paper/worker preflight for every claimed slice with `--phase build` before touching its files.

### 7. Build — high

Cut at least three genuinely independent build slices and spawn one high-effort `epic-builder` per slice in one wave of three isolated worktrees. Never manufacture artificial slices: if fewer than three collision-free outcomes exist, return to Decide and widen or reshape the wave instead of sharing write ownership. Each builder must claim before editing, pulse the now-line, stamp each criterion when proven, run the exact gate, self-review, and commit. Builders do not close merge-gated criteria or mutate the wave Paper.

The leader reviews every result and current task state before accepting it.

Gate: each accepted branch has a clean diff, fresh passing evidence, a truthful ledger, and no unowned file collision.

### 8. Review and debrief — high

Spawn exactly one wave of three independent `code-reviewer` agents over the green integration candidate. Assign correctness/contracts, tests/failure modes, and task/Paper/merge-ledger coherence as distinct lenses. The leader reconciles all three reports. If actionable fixes materially change behavior, rerun their implementation gates and open a new immutable CycleFleet wave for renewed Review; never add Review assignments to the sealed wave.

Append a dated wave log to the charter and a final debrief to the Paper. Include shipped/stalled slices, final branches or commits, proof, ledger repairs, honest grade, shortcomings, and next-wave direction. Patch the epic `wave_status` to complete only when the wave's own stop condition is satisfied.

Run the complete Task/Paper/worker preflight with `--phase review` before starting Review. After writing and publishing the debrief, rerun the same complete command with `--phase review --require-debrief`; only the post-review gate may require Review's output.

Do not mark the epic itself done merely because one wave ended. Close or complete only tasks whose full criteria and merge gates are proven.

Create and edit PR bodies from a file, never an interpolated shell string. Before opening or updating a PR, add `--pr-body <path>` to the complete Task/Paper/worker preflight and require one exact physical line `Task: <active-task-id>`. After PR open and authoritative merge, update `code_refs` and `last_worked_at` according to `references/task-contract.md`. The lead alone stamps merge-gated criteria and closes tasks after the merge commit is known.

## Recovery

- On `fenced_off`, `rail_changed`, or `doc_changed_since_claim`, reread, reconcile, renew the same worker claim when appropriate, and continue.
- On a failed gate, keep the task truthful and in progress; fix or record the blocker. Never convert a failure into prose-only success.
- On interrupted runs, resume from the Paper, epic heartbeat, task claims, and git branches. Do not restart discovery already captured with evidence.
- On user cancellation, use the active cancellation workflow, leave ledger state honest, and stop.

## Concurrency proof

Concurrency evidence for an Epic Cycle must use `scripts/run_concurrency_benchmark.py` and the frozen contract in `references/benchmark-protocol.md`. The only supported comparison is six equal assignments at widths 1/2/3/6, seed 20260715, in complete Williams cycles with per-treatment cold reset, warm prime, and four fixed balanced looks. Do not replace it with ad hoc timing, baseline-only comparison, generic process interception, or an optionally stopped trial.

Generate and inspect a plan before any measured work. A run or replay requires explicit heavy execution, live tmux/process-start identity, owned process groups, and conservative host admission. Heavy capacity defaults to one; capacity two is allowed only when explicitly requested and all health signals pass. Missing identity or safety signals deny. Keep every ITT failure, typed unknown metric, contaminated original, and separately labeled sensitivity rerun in the result artifact.

## Completion report

Report the wave outcome first: direction chosen, slices shipped/stalled, validation evidence, task/Paper ids, final branches/commits, remaining risks, and next-wave direction. The stop condition is a reviewed, evidence-backed wave with a truthful durable ledger—not a merely completed sequence of prompts.

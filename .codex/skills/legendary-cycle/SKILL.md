---
name: legendary-cycle
description: Run a five-scale, experiment-gated Barkpark epic for enormous numeric inventories and builder-heavy gruntwork. Use when the user asks for a legendary cycle, a 5x epic cycle, a massive document or Paper repair swarm, or a numerically sharded quality campaign across Studio, TUI, email, CLI, or other readers.
---

# Legendary Cycle

Run a durable Barkpark cycle whose minimum Epic-equivalent fleet is exactly five times the Epic Cycle, then add a format-experiment fleet before production building. Use numbers from the inventory and the winning pilot to size builder batches; never use “large” or “many” as a substitute for counts.

`Barkpark.CycleFleet` is the canonical executable ledger. Open the wave with
profile `legendary` to freeze inventory and experiment intent before Survey.
After Pilot, seal capacity and the computed Build plan as a second immutable
record. The seal is server-refused until all 15 experiment results are complete
and includes golden fixtures plus the opening quality rubric. Dispatch through
typed assignments and terminal results. `bp cycle
show <epic_id> <wave_id> -o json` is the shared local/cloud authority; copy its
exact `cycle_ledger` object into a reader-visible Paper callout. The validator
rejects drift between both Paper `cycle_ledger`/`fleet` projections and the live
authority.

Read `references/scale-contract.md`, `references/experiment-contract.md`, `references/fleet-contract.md`, and `references/phase-contract.md` before starting. Also read `../epic-cycle/references/task-contract.md`, `../epic-cycle/references/charter.md`, and `.claude/workflows/bp-loop-ledger.md`. The Epic task, Paper, claim, worktree, PR, merge, and recovery contracts remain binding unless this skill explicitly strengthens them.

## Inputs

Require:

- `wish`: the user's request verbatim;
- `legendary_task_id`: the published root task when it exists;
- `charter_path`: the durable charter when it exists;
- `unit_definition`: the countable item being repaired, such as Paper, template, route, or rendering case.

Infer missing ids and the unit definition from Barkpark and the repository. Ask only if multiple live roots or incompatible unit definitions remain plausible after searching.

## Fleet policy

Record a **Scale profile**, structured **Agent fleet**, and the reader-visible
CycleFleet ledger summary in the wave Paper before fan-out. Refresh the exact
structured projection after every ledger transition. The minimum completed typed fleet is:

| Phase | Typed role | Assignments | Effort |
| --- | --- | ---: | --- |
| Survey | `epic-surveyor` | 60 | medium |
| Verify | `epic-verifier` | 30 | medium |
| Experiment | `legendary-experimenter` | 15 | medium |
| Build | `legendary-builder` | at least 15 | medium |
| Review | `code-reviewer` | 15 | high |

The 60 Survey, 30 Verify, 15 Build, and 15 Review assignments are exactly five times Epic's corresponding baseline. Experiment is an additional five rounds of three. The leader and retries never count. Run at the installed concurrency cap; on this installation that is three children plus the leader, so all counts are completed assignments across successive waves, not simultaneous agents.

Derive Build planned count as `max(15, ceil(unit_count / proven_batch_capacity))`. Increase it when the pilot proves a smaller safe batch; never lower it below 15. Do not pad counts with duplicate prompts, retries, or zero-value slices.

If the current surface cannot explicitly select `agent_type`, do not spawn untyped substitutes. Preserve safe sequential evidence and durable Task/Paper state, report the capability block, and resume on a typed native-subagent or attached-tmux OMX surface. A blocked surface cannot pass the fleet gate.

## Workflow

### 1. Prime

Follow Epic Prime. Locate or publish the root and wave tasks, claim the active task, read back its epoch and links, inspect git state and live claims, and create or locate the wave Paper. Preserve unrelated work and never build from a dirty or diverged shared main checkout.

Define the outcome, stop condition, target surfaces, unit definition, exact initial unit count, evidence source for that count, concurrency width, and any external or human-only gates. Open the immutable `Barkpark.CycleFleet` wave before dispatch and run `scripts/validate_legendary_cycle.py` at every available phase boundary.

### 2. Strategize

Publish a `style=article` wave Paper that preserves the wish verbatim. Add **Scale profile**, **Agent fleet**, **Survey plan**, target surface matrix, quality rubric, and current phase. Produce 60 independent, decision-relevant survey assignments grouped into waves of three.

Capture the wish in a UTF-8 file with one file-format newline and run:

```bash
python3 .codex/skills/legendary-cycle/scripts/validate_legendary_cycle.py \
  --task <task> --paper <paper> --worker <worker> --phase strategize --wish-file <path>
```

Gate: the published Paper, exact inventory count, scale formula, and epic heartbeat are readable before Survey.

### 3. Survey

Run 20 waves of three `epic-surveyor` assignments. Partition by numeric ranges and surfaces so every unit class is owned once and coverage gaps are countable. Each report includes a direct answer, checked files/tasks/Papers, found/not_found/partial results, exact sample sizes, evidence, risks, and unvisited ranges.

Gate: all 60 assignments are accounted for and the Paper reconciles assignment coverage against the inventory total without silent overlap.

### 4. Digest and Verify

Synthesize contradictions and negative findings. Design 30 decision-critical verification assignments in ten waves of three. Each names its exact claim, proof/refutation command, sample or fixture, and affected unit range. Run `epic-verifier` agents and append decisive outputs and residual risks to the Paper.

Gate: every load-bearing format, reader, migration, or compatibility claim is proven, refuted, or explicitly carried as risk.

### 5. Experiment

Run five sequential rounds of three `legendary-experimenter` assignments using `references/experiment-contract.md`: baseline, divergent prototypes, hostile-reader trials, convergence, then pilot. Keep candidates isolated from production branches. Score real representative fixtures across every target surface; do not accept prose-only aesthetic judgments.

After each round, append candidates, metrics, failures, and the next-round decision to the Paper. After the pilot, record one chosen format, frozen golden fixtures, proven batch capacity, rollback rule, and observed failure rate. Seal that evidence with `bp cycle seal`, then read back `bp cycle show` and use its computed Build count. Build assignments are rejected before this seal exists.

Gate: all 15 experiment assignments are complete, one format has a reproducible cross-surface proof, and the pilot meets the predeclared thresholds. The immutable wave admits no additional Experiment assignments and the seal closes Experiment permanently. If the evidence is insufficient, open a new immutable wave instead of iterating inside this one.

### 6. Decide and shard

Make the final choices and update the charter. Create enough published child tasks to cover the computed Build count. Prefer repetitive, collision-free batches with explicit numeric ranges. Every task carries `proj:`, `phase:build`, exact `files:` labels, the wave Paper, a cold-startable description, evidence-bearing criteria, a runnable gate, and real blocker edges.

No unit may be silently dropped or owned by two builders. Publish a shard manifest mapping every unit id to exactly one task. Dry-run each gate and read every task back before dispatch.

### 7. Build

Run successive waves of up to three `legendary-builder` agents in isolated worktrees until every planned Build assignment completes. Builders claim before editing, pulse at boundaries, use the frozen format and fixtures, stamp evidence immediately, run the exact gate, self-review, and commit. They do not redesign the format, mutate the wave Paper, close merge-gated criteria, or share write ownership.

The leader integrates in dependency order and audits the shard manifest after every wave. If observed failures exceed the experiment threshold, stop fan-out and quarantine affected batches. Open a new immutable wave with a freshly frozen inventory and renew the full Experiment/Pilot evidence before sealing a replacement Build plan; never return to the sealed Experiment phase in the current wave or normalize the failure as gruntwork noise.

Gate: every inventoried unit is either shipped, explicitly excluded with a published reason, or stalled on a named blocker; accepted branches are green, committed, collision-free, and truthfully stamped.

### 8. Review and debrief

Run five waves of three independent `code-reviewer` assignments over the integration candidate. Assign distinct lenses across correctness/contracts, cross-surface rendering, test/failure modes, inventory completeness, and Task/Paper/merge-ledger coherence. Review is fixed at 15 assignments in one immutable wave. If fixes materially change behavior or format, open a new wave for the next review fleet.

Append the final inventory reconciliation, experiment verdict, shipped/stalled batches, commits/PRs, proofs, review findings, grade, shortcomings, and next direction to the Paper and charter. The CycleFleet callout must contain visible prose naming the profile, wave revision, inventoried/assigned/outcome counts, and exact state, plus the unmodified structured `cycle_ledger` returned by `bp cycle show`. Run Review preflight before review, then rerun with `--require-debrief` after publication.

Do not close the root merely because one wave ended. The stop condition is the full numeric inventory reconciled, the chosen format proven across declared readers, all accepted work merged and evidenced, and the durable ledger truthful.

## Recovery

Use the Epic recovery contract for claim fences, rail changes, interrupted runs, PR trailers, merges, and cancellation. Resume from the Paper's phase, Scale profile, fleet records, experiment ledger, shard manifest, tasks, and branches. Never restart completed evidence or count replayed work twice.

## Completion report

Report the numeric outcome first: total units, repaired/shipped/excluded/stalled counts, chosen format, cross-surface proof, planned/completed fleet counts by phase, experiment rounds, task/Paper ids, branches/commits, remaining risks, and next legendary direction.

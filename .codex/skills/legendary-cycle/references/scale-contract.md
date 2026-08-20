# Legendary Cycle scale contract

Use literal counts to make the swarm size reproducible.

## Scale profile

Freeze the inventory fields in `Barkpark.CycleFleet.open_wave/1` and project
them into the wave Paper before Survey:

- `unit_definition`: one countable repair target;
- `unit_count`: exact integer of at least 15 real units; never pad a smaller inventory;
- `inventory_evidence`: command, query, or Paper block that reproduces the count;
- `target_surfaces`: named readers that must pass;
- `concurrency_width`: active children supported by the current installation;
- `minimum_multiplier`: `5`;
- `build_formula`: exactly `max(15, ceil(unit_count / proven_batch_capacity))`;
- `excluded_inventory`: pre-freeze exclusions, each with stable `unit_id` and
  published `reason`;
- `quality_rubric`: the non-empty measurable rubric frozen before experiments;
- `failure_threshold`: the non-negative hard failure ceiling;
- `proven_batch_capacity`: absent at open, then frozen by the post-Pilot build-plan seal;
- `planned_build_assignments`: the post-seal evaluated formula.

Do not mix unlike units merely to lower the count. If Papers and email templates need different gates, create separate inventories and builder families under the same wave.

## Numeric reconciliation

Before freezing the inventory, remove ineligible units with published evidence.
For the frozen build inventory, prove before Build:

```text
inventoried = assigned
assigned = sum(unique units in published build tasks)
overlap = 0
```

Each Build assignment owns a non-empty unique list of non-empty string unit ids,
bounded by the sealed capacity and drawn from the frozen inventory. At completion
its result carries typed `completed_unit_ids`, `stalled_unit_ids`, and
`excluded_unit_ids` lists whose disjoint union is exactly that assignment's
owned list. `excluded` means an owned unit that was attempted and given an
explicit terminal exclusion reason:

```text
inventoried = shipped + stalled + excluded
unaccounted = 0
```

Use stable ids, not ordinal prose such as “the remaining papers.” Persist the shard manifest in the Paper or link a committed machine-readable artifact.

The canonical reconciliation is the `cycle_ledger` object returned by `bp
--workspace <workspace> --project <project> cycle show <epic_id> <wave_id> -o
json`. Local installs and Barkpark Cloud expose the
same authenticated command and canonical project-scoped HTTP route. Flat routes
are projectless legacy compatibility only. Copy the entire `cycle_ledger` and
`fleet` objects into their Paper callouts without hand-editing, and add visible
prose for human readers. The Legendary validator compares both to the live
response.

## Capacity

Infer batch capacity only from the final pilot round. Use the largest batch whose full gate passes inside the declared time/error budget. When reader complexity differs materially, use the smallest proven capacity or separate the inventory into homogeneous classes.

Seal the chosen format, evidence revision, observed failure rate, failure
threshold, non-empty golden fixtures, and capacity together. The server refuses
the seal until all 15 baseline experiment assignments have verified completed
results. The seal copies the opening quality rubric into the append-only Build
plan and computes the final builder count; it cannot be rewritten.

The sealed wave admits exactly its computed Build count, never fewer than 15,
and every shard stays within its proven capacity. If production evidence shows
that capacity was too high or the failure threshold is exceeded, quarantine the
current wave and open a new immutable wave. Renew Experiment and Pilot there;
the new seal may compute a higher Build count from a lower proven capacity.
Never recompute or reopen Experiment inside the sealed wave.

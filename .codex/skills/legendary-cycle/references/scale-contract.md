# Legendary Cycle scale contract

Use literal counts to make the swarm size reproducible.

## Scale profile

Record these fields in the wave Paper before Survey:

- `unit_definition`: one countable repair target;
- `unit_count`: exact non-negative integer;
- `inventory_evidence`: command, query, or Paper block that reproduces the count;
- `target_surfaces`: named readers that must pass;
- `concurrency_width`: active children supported by the current installation;
- `minimum_multiplier`: `5`;
- `proven_batch_capacity`: initially unknown, then set by the pilot;
- `build_formula`: `max(15, ceil(unit_count / proven_batch_capacity))`;
- `planned_build_assignments`: the evaluated formula;
- `exclusions`: unit ids plus published reasons.

Do not mix unlike units merely to lower the count. If Papers and email templates need different gates, create separate inventories and builder families under the same wave.

## Numeric reconciliation

Before Build, prove:

```text
inventoried = assigned + excluded
assigned = sum(unique units in published build tasks)
overlap = 0
```

At completion, prove:

```text
inventoried = shipped + stalled + excluded
unaccounted = 0
```

Use stable ids, not ordinal prose such as “the remaining papers.” Persist the shard manifest in the Paper or link a committed machine-readable artifact.

## Capacity

Infer batch capacity only from the final pilot round. Use the largest batch whose full gate passes inside the declared time/error budget. When reader complexity differs materially, use the smallest proven capacity or separate the inventory into homogeneous classes.

More builders are allowed. Fewer than 15 are not. Recompute upward when the observed production failure rate exceeds the pilot threshold or when a batch contains more units than the proven capacity.

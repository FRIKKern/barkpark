<!-- doc-tier: agent | canonical-for: v1-409-conflict-resolution | budget: 250tok -->
# Resolving a v1 409

Three endpoint families answer 409 with a discriminator the caller must read before retrying. The codes themselves live in [error-codes.md](error-codes.md); this file owns what each one hands back.

- `export_already_running` — one workspace export runs at a time on a node; the `reason` is `workspace_export_in_flight` when it is the caller's own workspace, `export_capacity_reached` when another holds the slot, and a `Retry-After` header says when to come back.
- `ambiguous_dataset` — task GET/verbs: the id lives in >1 dataset of this workspace/project and the caller named none; `details.datasets` names them, `?dataset=` picks.
- `dataset_twin` — task birth into a dataset whose id already exists in a sibling; `content.dataset_twin_intended: true` states the intent.

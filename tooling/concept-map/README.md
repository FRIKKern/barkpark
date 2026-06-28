# concept-map — cqv8, the concept / feature layer

Makes Cody good at **feature-based architecture as a core skill**: grade how well a
codebase materializes its concepts as feature folders, and scaffold new ones into the
right shape. Built on the cqv5 symbol graph (`tooling/symbol-graph/`).

The thesis: **feature architecture = making the filesystem agree with the dependency
graph.** A concept is a cohesive cluster of symbols; a feature folder makes it
physically inspectable. Extractability is *position in the dependency-stability
gradient*, not just cohesion — high afferent coupling (`tenancy` Ca≈200) means kernel,
not plugin.

## The tools

| Tool | What it does |
|---|---|
| `concepts.mjs` | The coupling model. Groups graph nodes into concepts, computes Martin component algebra (Ca afferent · Ce efferent · instability · cohesion), classifies each into **KERNEL / CLEAN-FEATURE / CLEAN-NONPLUGIN / UNSTABLE-EDGE** bands. |
| `anatomy.mjs` | The anatomy-learner. Picks exemplars (top cohesion + low Ca → `sheets`, `onixedit`, `tasks`), extracts the repo's recurring feature skeleton (role-set + registration call + allowed kernel deps). Learned-first, curated fallback under 2 exemplars. |
| `grade.mjs` | The grade pass. Scores five gaps per concept — gratuitous core-split (external-reuse %), test scatter, sideways feature→feature edges, manifest absence, framework scatter — and a `kernel/clean/clean-lib/improvable/tangled` verdict with named colocate/cut edges. |
| `manifest.mjs` | Per-feature manifest schema (`name·surface·deps·ownedTables·roles`) + synthesis from the graph. The declared boundary that makes the analysis exact instead of regex-fuzzy. |
| `scaffold.mjs` | Generative, propose-only. `new <name> [--touches a,b]` projects the concept's coupling → **feature-folder** (isolated) or **cross-folder** (kernel-touching) → emits the learned anatomy as a dry-run plan under `.scaffold-staging/` (never mutates the repo). |
| `boundary.mjs` | The never-worse gate. Flags a proposed change that adds a sideways edge, a kernel→feature edge (wrong direction), or scatter; `proposeRecolocation(concept)` proposes colocating a scattered concept, gated to lose no file. Propose-only. |

## Run it

```bash
node tooling/concept-map/concepts.mjs --json     # the gradient + bands
node tooling/concept-map/anatomy.mjs --json      # the learned feature skeleton
node tooling/concept-map/grade.mjs --json        # the five-gap verdicts
node tooling/concept-map/scaffold.mjs new pricing            # → feature-folder plan
node tooling/concept-map/scaffold.mjs new billing-core --touches content,tenancy   # → cross-folder
node tooling/concept-map/boundary.mjs --json     # current violations + a recolocation
node tooling/concept-map/acceptance-p{1,2,3,4,5}.mjs         # the gates
```

Reads `tooling/symbol-graph/symbols.json` (a gitignored built artifact — run
`tooling/symbol-graph/build-symbols.mjs` first if absent, same as the rest of the suite).

## Design invariants

- **Computed live, never hardcoded** — every number falls out of the real graph; exemplar
  exclusions (`media` Ca 28, `frt` coh 0.60) come from the coupling math, not a name list.
- **Propose-only** — `scaffold` and `boundary` never move or write a repo file; they emit
  plans. Recolocation is gated by a lose-no-file never-worse check (the cqv7 pattern).
- **Learned per-repo** — anatomy is inferred from *this* repo's clean features, so the same
  tools generalize to any Go/TS/Elixir codebase.

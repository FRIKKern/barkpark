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

## The boundary gate is BLOCKING — and `accepted-until-fixed.json` is why

`ci-boundary.mjs` runs in `.github/workflows/architecture.yml` as the check named
**Boundary gate**. Since 2026-09-05 it BLOCKS: there is no `continue-on-error`
on the job or on any step. It is **not** in the required set — the four required
contexts are Cloud gate, Console gate, Elixir gate and "PR references an active
task" — so it reds your PR without holding the merge button.

A bare flip was never possible: today's tree carries real regressions, so a
blocking gate would have reddened every PR for debt nobody on that PR added.
`tooling/concept-map/accepted-until-fixed.json` is what closes that gap. Each
entry names ONE identity the gate tolerates **and the bp task row that owes the
fix**; the loader REFUSES an entry with no row id, because an acceptance with
nobody on the hook is an allowlist.

It is a **tripwire, not an allowlist** — three arms make the list decay:

| arm | reds when | message |
|---|---|---|
| (a) never-worse | any identity NOT in the list appears | the existing `new-edge` / `new-cycle` / count rows |
| (b) row closed | a listed row is `done`/`cancelled` while its identity is STILL in the graph | names the row |
| (b′) refusal | the row's lifecycle could not be read from the ledger | `REFUSING: …` — exit 2, never green |
| (c) healed | a listed identity has DISAPPEARED from the graph | `HEALED: delete entry X` |

Arm (c) is why the file cannot only grow: the PR that pays an edge down deletes
its entry in the same change. The durable fix is a **shorter** list.

Arm (b) needs `LEDGER_BASE` and `LEDGER_TOKEN` (repo secret `BARKPARK_TASK_TOKEN`,
the same one `scripts/pr-task-gate.sh` reads). Locally, without a token, the gate
refuses rather than passing — that refusal is the design, not a bug.

Every arm is pinned in both directions and then MUTATED in
`ci-boundary.test.mjs`: each is neutered by an exact anchor in a copy of the
module (anchor asserted to occur exactly once, diff asserted non-empty) and the
case is proven to stop firing.

```bash
node --test tooling/concept-map/ci-boundary.test.mjs   # 36 tests, the arms included
```

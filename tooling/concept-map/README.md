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

## A LOCAL RUN GATES NOTHING IN A COLD TREE — read this before wording a criterion

`ci-boundary.mjs` will not produce a verdict in a tree that was never warmed, and
that refusal is correct: a cold run compares HEURISTIC edges against an
EXACT-edge baseline and silently misstates the debt. In a fresh
`git worktree add --detach <dir> origin/main` it refuses **twice**, in this
order. Both lines are reproduced verbatim (each is one unwrapped line, so a
`grep -F` against this file matches what the script actually prints):

```
ci-boundary: REFUSING to gate an unwarmed tree — no blast-radius index at tooling/blast-radius/index.json (this tree was never warmed); build it first: node tooling/blast-radius/build-index.mjs (a cold run compares HEURISTIC edges against an EXACT-edge baseline and silently misstates the debt; pass --allow-cold-index to override)
```

Then, after `node tooling/blast-radius/build-index.mjs` — which exits **0**, having
built the js and go graphs and skipped Elixir (`[elixir] compile failed — falling
back to regex scan`, `elixir: (none — best-effort skipped)`):

```
ci-boundary: REFUSING to gate an unwarmed tree — tooling/blast-radius/index.json carries no elixir.forward graph (mix compile or mix xref did not run); build it first: node tooling/blast-radius/build-index.mjs (a cold run compares HEURISTIC edges against an EXACT-edge baseline and silently misstates the debt; pass --allow-cold-index to override)
```

**The cost the second refusal implies is the whole trap.** Warming
`elixir.forward` is not `build-index.mjs` again — that command already ran and
already succeeded. It needs a full Elixir toolchain in *that* worktree:
`mix deps.get` plus a `mix compile` / `mix xref` pass, a private
`MIX_TEST_PARTITION`, and minutes of wall clock, to answer a one-line reviewer
question. So a criterion worded "run `ci-boundary.mjs` on main" is in practice
discharged by opening the GitHub UI and reading the job's colour — a different
measurement, by hand, with no command anyone can paste.

`--allow-cold-index` is **not** the cheap path. It is documented to produce a
HEURISTIC verdict that may DISAGREE with CI's. Never cite it in a criterion.

### The supported cheap path: `--from-ci <sha>`

```bash
node tooling/concept-map/ci-boundary.mjs --from-ci $(git rev-parse origin/main)
node tooling/concept-map/ci-boundary.mjs --from-ci <sha> --repo FRIKKern/barkpark --json
```

It reads the **Boundary gate** check-run CI already published for that sha (via
`gh api`), prints a verdict line plus the job URL, and compiles nothing — no
`mix`, no symbol graph, no blast-radius index, no local artefact at all.

| exit | line | when |
|---|---|---|
| 0 | `ci-boundary: CI VERDICT PASS — …` | the check-run concluded `success` |
| 1 | `ci-boundary: CI VERDICT RED — …` | it completed with a non-success conclusion |
| 2 | `ci-boundary: CANNOT READ CI VERDICT — …` | absent, `queued`, `in_progress`, a `null`/`neutral`/`skipped` conclusion, a malformed payload, or a failed API read |

**A verdict it could not obtain is never byte-identical to a pass.** That is the
contract the mode exists for, and `ci-boundary.test.mjs` drives all four
CANNOT-READ shapes plus a mutation that proves the distinction is load-bearing.

Word criteria in this family against `--from-ci <sha>`, or against the CI job
itself — not against a bare local run, which no reviewer can afford. The same
text is available as `node tooling/concept-map/ci-boundary.mjs --help`.

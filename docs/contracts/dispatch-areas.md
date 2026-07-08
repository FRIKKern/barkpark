<!-- doc-tier: agent | canonical-for: dispatch-area-vocabulary | budget: 700tok -->
# Dispatch areas — `area:` vocabulary & `~`phase-band derivation

The dispatch frontier (`bp task frontier`; the task board's `Board.IndependentReady`)
decides which ready tasks can be batched to parallel agents without their blast
radius colliding. It reasons over each task's **surface footprint** — the set of
code surfaces the task touches — resolved by `areasOf` in
`internal/taskboard/frontier.go`. Two tasks whose surfaces are disjoint are safe
to run at once. This doc is the source of truth the TUI card (`docs/cards/tui.md`)
points at; the code (`frontier.go`) is the source of truth for both.

## The closed `area:` set (11 targets)

An `area:<token>` label is honored **only** for these 11 surface tokens. Any other
token (`area:billing`, `area:foo`) is inert — it names no known surface and buys
no parallelism:

```
studio  web  cli  tui  api  sdk  sheets  onix  docs  infra  pdrender
```

The set is CLOSED by construction: it is the domain of the `phaseBandArea` map in
`frontier.go`. Adding a real new surface means editing that map (and this table)
together — the card's Code anchor makes a rename re-check.

## Phase-band → area derivation (`~`)

A task with **no authored `area:`** can still contribute a surface, derived
*provisionally* from a `phase:<n>-<slug>` band:

1. `phaseBandSlug` strips a leading numeric band: `phase:2-studio` → `studio`. A
   hyphen **inside** the slug survives — `phase:5-paper-components` →
   `paper-components` (only a leading `<digits>-` is removed).
2. `phaseBandArea` maps the slug to a surface. Every key maps to **itself**, with
   two aliases that collapse to `pdrender`:

   | phase-band slug | derived area |
   |---|---|
   | `studio` | `studio` |
   | `web` | `web` |
   | `cli` | `cli` |
   | `tui` | `tui` |
   | `api` | `api` |
   | `sdk` | `sdk` |
   | `sheets` | `sheets` |
   | `onix` | `onix` |
   | `docs` | `docs` |
   | `infra` | `infra` |
   | `pdrender` | `pdrender` |
   | `paper` | **`pdrender`** |
   | `paper-components` | **`pdrender`** |

   A slug that is not a key (`phase:build`, `phase:goal`, `phase:decision`) derives
   nothing — the semantic `phase:<goal|design|build|verify>` bands never imply a
   surface.

## `~`-prefix semantics — derived, not authored

- A **derived** area is displayed with a leading `~` (`~studio`) so a reader knows
  the surface was *inferred* from a phase band, not declared by a human.
- **Authored wins.** If a task carries both `phase:2-studio` and `area:studio`, the
  authored label takes the surface and the `~` is suppressed — a declared surface
  never shows `~`. Derivation only fills surfaces the author did not name.
- The distinction feeds the frontier's risk classes: an authored `area:` yields the
  provably-disjoint `isolated` class; a task resting on derived-only `~` surfaces is
  batched more conservatively.

## Code anchors
- internal/taskboard/frontier.go — areasOf resolves the footprint; phaseBandArea is the closed derivation map; phaseBandSlug strips the leading band

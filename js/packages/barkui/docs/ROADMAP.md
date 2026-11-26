<!-- doc-tier: human | canonical-for: barkui-roadmap | budget: 2600tok -->
# Roadmap

```
M0 Contest ─► M0.5 Proof round ─► M1 Map ─► M2 One skin everywhere ─► Ready: the showroom + the first six parts
                                                                                 │
                                       ┌─────────────────────────────────────────┴───────────┐
                                       ▼                                                     ▼
                         M3 Editor menus, Barkdown's tree                         M4 Blocks are parts
                                       └──────────────► M5 Every app wears BarkUI ◄──────────┘
                                                                  │
                                                                  ▼
                                                            M6 Re-imagining

Beside them all: Groundwork, every shared piece has one source
```

What stands today is told once, in the [README](../README.md#barkui). Order and rewards live on this page; the reasons, the contests and the trials live in the plan Paper `/papers/barkui-plan`. How far each milestone has come is copied from the task board into [Where things stand](#where-things-stand), by a script only.

| Id | Milestone | What it gives | Ready when |
|---|---|---|---|
| M0 | Contest | The contract: built on UI SDK's own names ([0001](decisions/0001-ui-sdk-names-are-the-contract.md)) | The pick is written down |
| M0.5 | Proof round | Hard parts tried on real code before any is built here | What the round showed is in the plan |
| M1 | The map | What Barkpark's colour source already sends out, set against the contract | The map is in the plan, and M2's steps follow from it |
| M2 | One skin everywhere | The colour source writes every skin under BarkUI's names, and every renderer reads them | Text on every surface reads at 4.5:1; PortableDoc and every renderer read BarkUI's names, with today's values as the fallback; every example document draws as it did before |
| Ready | The showroom and the first six parts | One page that shows every part, every skin, light and dark, and what is proven | The step in [0004](decisions/0004-ready-before-any-switch.md) |
| M3 | Editor menus and Barkdown's tree | The editor's menus on PortableDoc's public edit commands; Barkdown's page tree moved by keyboard and by touch | Both run in a real app, each felt as a feature |
| M4 | Blocks are parts | The table block and the grid as one part; more blocks when an app needs them | The table is one part in a document and in an app, drawn alike on every format |
| M5 | Every app wears BarkUI | Each app measured, then moved a screen at a time; Studio first in a Sanity-like skin, so nothing is lost on the way in | Barkever, Barkdown, Studio, BarkBot and the Barkpark desk each wear BarkUI, with no pixel change the owner did not accept |
| M6 | Re-imagining | New app designs on one set of parts | The owner's call |
| Beside | Groundwork: every shared piece has one source | The document pack, the editor's source, the nesting name and the graph script each kept in one place, other copies written by a job | No shared piece is kept in two places by hand |

## The three piles

Every part BarkUI must draw sits in one of three piles. Each is built differently.

| Pile | Where it stands | The work left |
|---|---|---|
| Ready-made parts from UI SDK | UI SDK ships each with behaviour and a default look that reads `--ui-*`; the sheet feeds those names | The BarkUI look on top, and a part folder each |
| Hard parts the apps need that UI SDK lacks | Tried outside this repo in the proof round (see the plan Paper) | Build them here: a model with no page in it, one definition that wires UI SDK's behaviours, and faces that hold none |
| Document blocks | PortableDoc's renderers already draw them on every format | They read BarkUI's names through the bridge; a block moves into a part only when an app needs it as one ([0003](decisions/0003-a-block-is-a-part.md)) |

## The order of families

The first six parts set the look: button, text field, select, dialog, menu and tabs ([0004](decisions/0004-ready-before-any-switch.md) has the step that confirms it). Tabs come third: select, dialog and menu draw in the browser's top layer, and cost more to check, since the check reads each open box in every view, 1.33 to 1.90 s a reading on CI's hosted runner, so 80 to 115 s per open box per part (60 readings, PARTS.md "The top layer"). The look for a box no layer names, after each Tab stop, press step and driven state, costs 1 to 2 ms. Then ready-made parts land in batches by family:

1. Forms
2. Overlays
3. Menus
4. Navigation
5. Feedback
6. Dates
7. Data

Hard parts run beside the batches, two at a time. One folder per part, so builders work at once; the few shared files a new part can move, such as a hosted timing or the CI group rows, are named in [PARTS.md](PARTS.md).

## Where things stand

Done, in progress and open under each milestone, copied from the task board by `node build/board.mjs <goal-task-id>`; [QUALITY.md](../QUALITY.md#docs) says when it runs and what guards it. A milestone with no tasks under it counts as one item itself; a blocked task counts as open, and a cancelled one is left out.

<!-- board:start -->
| Id | Milestone | Done | In progress | Open |
|---|---|---|---|---|
| M0.5 | Proof round | 0 | 0 | 1 |
| M1 | The map | 1 | 0 | 0 |
| M2 | One skin everywhere | 52 | 2 | 46 |
| Ready | The showroom and the first six parts | 1 | 0 | 2 |
| M3 | Editor menus and Barkdown's tree | 0 | 0 | 2 |
| M4 | Blocks are parts | 0 | 0 | 1 |
| M5 | Every app wears BarkUI | 0 | 0 | 1 |
| M6 | Re-imagining | 0 | 0 | 1 |
| Beside | Groundwork: every shared piece has one source | 1 | 0 | 3 |

Read from the board; numbers last changed on 2026-11-26.
<!-- stamp: 83734fa1ee391cdd -->
<!-- board:end -->

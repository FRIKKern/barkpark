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

Each milestone starts from what already stands. Order and rewards live here; the reasons live in the plan Paper `/papers/barkui-plan`; status lives on Barkpark's task board, and only a script copies it here.

| Id | Milestone | Built | Next | Ready when |
|---|---|---|---|---|
| M0 | Contest | Six demo docs on three stances, judged blind; the owner picked the contract built on UI SDK's own names ([0001](decisions/0001-ui-sdk-names-are-the-contract.md)) | | The pick is written down |
| M0.5 | Proof round | Four hard parts built on real code and pressed by blind judges: the document editor, the big grid, one document on every surface, the app frame | The owner's last word on what the round showed | That word is in the plan |
| M1 | The map | What Barkpark's colour source already sends out, set against the contract; which names stay, which are renamed, which are new | | The map is in the plan, and M2's steps follow from it |
| M2 | One skin everywhere | The colour source writes the sheet: every skin under `--ui-*` and `--bark-*`, each colour a light and dark pair, the surfaces a part sits on, depth steps, hover and pressed fills, a control edge and a focus ring's colours | Text on the primary surface reads at 4.5:1; PortableDoc's block styles read BarkUI's names, with today's values as the fallback; the Elixir and Go outputs carry the same numbers; the sheet travels to apps like the document pack | PortableDoc and every renderer read BarkUI's names, and every example document draws as it did before |
| Ready | The showroom and the first six parts | The showroom page, the part folder, the check with its lights and its selftest, and the button | Text field, select, dialog, menu and tabs, built with the same care; the owner sees them and sets the look | All six have every light on, and the owner has approved the look the rest will copy |
| M3 | Editor menus and Barkdown's tree | Both were built and pressed in a trial on real code; nothing of it is in this package yet | The editor's menus on PortableDoc's public edit commands; Barkdown's page tree moved by keyboard and by touch | Both run in a real app, each felt as a feature |
| M4 | Blocks are parts | PortableDoc's renderers draw every block on every format: web with and without script, email, terminal and phone. A grid with ranges was built and pressed in a trial | The table block and the grid become one part; more blocks follow when an app needs them | The table is one part in a document and in an app, drawn alike on every format |
| M5 | Every app wears BarkUI | Nothing yet, on purpose ([0004](decisions/0004-ready-before-any-switch.md)) | Measure each app before it moves: how much of its look three colours reproduce. Studio starts in a Sanity-like skin, so nothing is lost on the way in | Barkever, Barkdown, Studio, BarkBot and the Barkpark desk each moved a screen at a time, with no pixel change the owner did not approve |
| M6 | Re-imagining | | New app designs on one set of parts | The owner's call |
| Beside | Groundwork: every shared piece has one source | The editor's source has one home; the second copy is written by a job | Studio and Barkever take the document pack by the hourly sync; one name for nesting (`data-level`) in Studio; one graph script, its copies written by a job | No shared piece is kept in two places by hand |

## The three piles

Every part BarkUI must draw sits in one of three piles. Each is built differently.

| Pile | Where it stands | The work left |
|---|---|---|
| Ready-made parts from UI SDK | UI SDK ships each with behaviour and a default look that reads `--ui-*`; the sheet feeds those names | The BarkUI look on top, and a showroom entry each |
| Hard parts the apps need that UI SDK lacks | Editor menus, the big grid, the app frame with its page tree and one document on every surface were proven in trials on real code | Carry those in; build the rest the grid's way: a model with no page in it, one definition that wires UI SDK's behaviours, and faces that hold none |
| Document blocks | PortableDoc's renderers already draw them on every format | They read BarkUI's names through the bridge; a block moves into a part only when an app needs it as one ([0003](decisions/0003-a-block-is-a-part.md)) |

## The order of families

The first six parts set the taste: button, text field, select, dialog, menu and tabs. After the owner approves them, ready-made parts land in batches by family:

1. Forms
2. Overlays
3. Menus
4. Navigation
5. Feedback
6. Dates
7. Data

Hard parts run beside the batches, two at a time. One folder per part and nothing shared, so builders work at once and no two changes touch the same file.

## Where things stand

Done, in progress and open under each milestone. `node build/board.mjs <goal-task-id>` writes this block from the task board, on a machine signed in to `bp` or in the daily news job; a PR check never reads the board. A milestone with no tasks under it counts as one item itself.

<!-- board:start -->
| Id | Milestone | Done | In progress | Open |
|---|---|---|---|---|
| M0.5 | Proof round | 0 | 0 | 1 |
| M1 | The map | 1 | 0 | 0 |
| M2 | One skin everywhere | 7 | 0 | 9 |
| Ready | The showroom and the first six parts | 0 | 1 | 1 |
| M3 | Editor menus and Barkdown's tree | 0 | 0 | 2 |
| M4 | Blocks are parts | 0 | 0 | 1 |
| M5 | Every app wears BarkUI | 0 | 0 | 1 |
| M6 | Re-imagining | 0 | 0 | 1 |
| Beside | Groundwork: every shared piece has one source | 1 | 1 | 2 |

Read from the board on 2026-11-19.
<!-- board-stamp: fc600f04734394d9 -->
<!-- board:end -->

## In the showroom now

Written by `node build/status.mjs` from the part folders.

<!-- status:start -->
| Family | Parts in the showroom |
|---|---|
| action | button |
<!-- status:end -->

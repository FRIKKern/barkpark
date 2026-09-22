# spd-b42 — THE DEPLOYED RUN, AND THE THRESHOLD SWEEPS THE INSTRUMENT CANNOT TAKE

`task-ae82ac9ec98a49fd` (API-lane half of `spd-b42-georgia-default-shortfall-inflow-width`).

**NO CSS CHANGES SHIP IN THIS PR.** Charter D149 refuses the dock trim by name, D270 re-opened it
and closed `BLOCKED ON OWNER` (owner-queue item 41), and the charter on `origin/main` still ends at
D271 with `BLOCKED ON OWNER` occurring exactly once — no ratification exists. The row's own
`operating_instruction` reads `DO NOT COMMISSION A BUILDER FOR c0`. What ships is the evidence the
owner needs in order to rule, measured on the deployed desk instead of on a static replica.

## 1. `spd-b42-deployed-default-state-2026-09-22.json` — the run spd-b42 has been asking for

Every px/ch figure previously in circulation for this row came from a **static replica** of the sheet.
This is the deployed article.

    node scripts/studio-desk-measure.mjs --doc=any --positive-control \
      --out scripts/measurements/spd-b42-deployed-default-state-2026-09-22.json

    served_sha                   b8e1f8c92f55b6de116f409e89a6177f3013021f  (== origin/main tip)
    provenance_bracket.matched   true        (pre- and post-sweep reads agree)
    rows                         54          unsettled_rows 0
    face_override_integrity      clean       (36 forced rows, 0 substitutions)
    positive_control.ran         true        guard_passed true — "THE GUARD FIRES"
    measured_document            prod-microblock-pull-plan

DEFAULT state, forced Georgia 18px, probe 11.0469 px/ch (`span[width:1ch]` inserted as a CHILD of
`.bp-paper-surface`); `content_px` / `visible_content_px` / `content_ch` / overflow:

    1440   608 / 607.625 / 55.04  MEET    overflow 0   (floor BINDS: min-inline-size 687.632px)
    1280   580 / 580     / 52.50  FAIL    overflow 0   (gate CLOSED: min-inline-size 0px, 660px cap rules)
    1024   580 / 580     / 52.50  FAIL    overflow 0   (gate CLOSED)
     900   608 / 607.625 / 55.04  MEET    overflow 0
     800   580 / 580     / 52.50  FAIL    overflow 0
     764   612 / 612     / 55.40  MEET    overflow 0
     700   567 / 567     / 51.33  FAIL    overflow 0
     640   507 / 507     / 45.90  FAIL    overflow 0
     500   411 / 411     / 37.21  FAIL    overflow 0

This reproduces D270's table on the deployed box and confirms the row's baseline digit for digit.

## 2. The threshold sweeps — Chrome DevTools, deployed guerrilla, 2026-09-22

`studio-desk-measure.mjs` has no dock-width override, so the *counterfactual* half of this row cannot
come from it. These were taken in a real authenticated browser on the same deployed build, with the
arming and the reading in the SAME evaluation (a style element injected, a forced reflow, and the read
in one call) so nothing can move between arming and probing. Face forced by setting
`--paper-font-serif` on `.bp-paper-surface` — the same lever the committed instrument uses, so the
`ch` inside `calc(55ch + 2 * var(--paper-gutter))` recomputes with it. Probe-derived **11.0469 px/ch**
in every cell below, read in-page, never assumed.

### 2a. viewport 1280, wide bucket, panel 976px — the c0 threshold

    dock   column     surface    min-inline-size   content     ch       overflow
    300    676.000    660.000    0px               580.000     52.504   0
    288    688.000    660.000    0px               580.000     52.504   0
    260    716.000    660.000    0px               580.000     52.504   0
    257    719.000    660.000    0px               580.000     52.504   0
    256    720.000    687.625    687.632px         607.625     55.004   0   <- MEET
    255    721.000    687.625    687.632px         607.625     55.004   0
    240    736.000    687.625    687.632px         607.625     55.004   0

The gate is binary and it is `@container content (min-width: 720px)`. 257px -> 719.000px is FAIL;
256px -> 720.000px is MEET. **288px measures 52.504ch**, so the spd-b42 brief's "an inspector of
288.4px or less would MEET" is refuted on the deployed desk, not just on the replica. The baseline
was re-read after the sheet was removed and returned to 580.000px / 52.504ch.

### 2b. viewport 1440 — the control arm, WITH the discrimination proof

    arm                          inspector box   column     content     ch       overflow
    A  before (shipped 300px)    300.000         836.000    607.625     55.004   0
    B  after  (proposed 256px)   256.000         880.000    607.625     55.004   0
    C  CONTROL (dock 760px)      760.000         376.000    290.000     26.252   0
    D  restored                  300.000         836.000    607.625     55.004   0

A == B: content is byte-identical, as the criterion claims. **But that is worth nothing on its own**,
because the `min-inline-size` floor already pins content at 1440 whatever the dock does. Arm C is the
proof the probe is alive: a 760px dock drives the column under the 720px gate, the floor stops
applying, the cap takes over and content moves to 290.000px / 26.252ch. So identity in A/B is a fact
about the desk, not about a dead instrument.

**Arm A vs B also measures the thing criterion 2 is silent about: the inspector's own box moves
300px -> 256px AT 1440, a 44px user-visible change at the wide bucket** — because
`root.html.heex:2264` (`.bp-doc-sidebar.is-open { flex: 0 0 300px }`) is a GLOBAL declaration and
`var EDGES = [640, 1024, 1280]` (`root.html.heex:45`) puts 1440 in `wide`. That is exactly the move
D149 refused. Criterion 2 as worded stays green through it.

### 2c. viewport 1024, standard bucket, panel 720px — the c1 threshold and its occlusion caveat

    arm                           strip   position   column     surface    content    ch       text-band occluded   overflow
    A  before (in-flow 41px)       41     static     679.000    660.000    580.000    52.504   0.000                0
    B  after  (out of flow)        41     absolute   720.000    687.625    607.625    55.004   0.000                0
    C  CONTROL (in-flow 200px)    200     static     520.000    514.000    434.000    39.287   0.000                0
    D  restored                    41     static     679.000    660.000    580.000    52.504   0.000                0

Taking the strip out of flow reaches the gate exactly: column **720.000px**, content **607.625px =
55.004ch**, overflow **0px**. Arm C is the discrimination control — a 200px in-flow strip moves the
column to 520.000px, so the probe can see a change.

**The open caveat on this criterion is now measured rather than derived.** The row's attempt note
warned that an out-of-flow strip re-arms this epic's occlusion subtraction and predicted it would eat
~24.8px of the right gutter. Measured: the absolutely-positioned strip overlaps **21.813px of the
surface BOX** and **0.000px of the text band** (band = surface box minus its READ 40px/40px gutters).
`visible_content_px` therefore equals `content_px` at 607.625px — the criterion's visible-content
requirement is satisfied, not merely assumed.

## 3. What a reader should NOT take from this

- It does not ratify anything. D149 stands; `spd-b42` stays BLOCKED ON OWNER.
- Criterion 2 is still mis-worded. §2b measures the 44px inspector move it cannot see; the criterion
  needs the inspector's own box width added before it is used to clear anything.
- Criterion 1's lever has a code-side objection nobody had raised: the rule at
  `root.html.heex:2309` sets `position: static` **deliberately**, and its own comment says the
  declarations "reproduce `.is-collapsed`'s GEOMETRY" and that `position` is reset because the
  `@container panel (max-width: 860px)` block "promotes the open panel to an absolute overlay;
  without the reset it would still float over the document, merely emptied." Putting the strip back
  out of flow reverses that reset. The measurement in §2c says the feared harm is 0.000px of occluded
  text — but the rule's stated contract would become false and must be rewritten deliberately, not
  silently, if c1 is ever unblocked.

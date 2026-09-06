# The 1280 prior-observation "miss" is an INSTRUMENT STATE artefact, not desk drift

Dated 2026-09-06. Written beside `spd-round-trip-prediction-2026-07-21.json`, which is
FROZEN and is NOT edited by this note (charter D189). This note records an adjudication;
it does not register a successor prediction.

Row: `spd-w13-1280-prior-observations-stale`. Parent: `inspector-shape-bracketed-deployed-run`.

## The verdict, first

The row was filed as "the 1280 reading column moved 596 -> 640 since the 2026-07-20 table —
retire the stale prior-observations". **It did not move.** The prior observation of 596px at
viewport 1280 is still CORRECT for the desk, on the same deployed build the run measured. The
640px figure the checker read is the round-trip leg measuring the **wrong desk state**: the
inspector panel CLOSED, carried over from the previous width, where the registered 596px
describes the panel OPEN.

The +44px is therefore **attributed, and attributed to the instrument** — `runRoundTrip` in
`scripts/studio-desk-measure.mjs` — not to any product commit, and specifically **NOT** to the
Tier-2 ladder. The ladder hypothesis is REFUTED below with the field the hypothesis itself names.

## 1. The ladder did not do it — refuted twice over

The row's hypothesis: the `visible_pane_widths_px [44,260] -> [44]` ladder change
(`api/lib/barkpark_web/studio/pane_builder.ex` `display_state/5`, commit `4074d1986`, #4922)
reached the wide band edge.

**Refutation A — the clause cannot match at 1280.** The shipped clause head is bucket-literal:

    def display_state(idx, num_panes, true, "standard", true) do

Viewport 1280 stamps `width_bucket = "wide"`, not `"standard"` (recorded in the run itself:
`bucket_precondition.width_bucket_stamped = "wide"`, `expected_raw_band = "wide"`, at
`real_inner_width = 1280`). The commit's own `@doc` says so in words:

> `"wide"` — Tier 1 moves ZERO cells. At 1280/1440 the inspector already docks with room
> to spare; yielding the rail there would spend navigation to buy width nobody is short of.

**Refutation B — the named field is unchanged at 1280.** The settle signature at every
1280 cell is byte-identical between the 2026-07-20 table (served `65541e2d4`) and the deployed
run (served `bdd7dac40`), across all three faces and both inspector states:

    {"b":"wide","n":2,"w":[44,260],"c":0,"p":976,"connected":true}

`w` IS `visible_pane_widths_px`. It reads `[44,260]` on both builds. The ladder's `[44]` never
arrived at 1280, because it was never routed there.

## 2. The desk did not move either

Field-for-field diff of the `rows` cell `1280 / default / native`, 2026-07-20 table vs the
deployed run, ignoring `measured_at` and `settle_ms`: the ONLY differences are `served_sha`,
`slot_active`, and fields the instrument gained after 2026-07-20
(`bucket_precondition*`, `destination_evidence*`, `expected_raw_band`, `real_inner_width`,
`is_destination`, `face_relevant`, `reading_column_present`). Every geometry field is equal:

    content_px             596 -> 596
    visible_content_px     596 -> 596
    content_ch            59.6 -> 59.6
    panel_px               976 -> 976
    surface_border_box_px  676 -> 676
    surface_max_width_px   720 -> 720

There is no 596 -> 640 move in the matrix. 640 appears only in the `round_trip` leg.

## 3. What actually produced 640 — the mechanism, named

`round_trip.protocol` is `default -> open -> dismiss, on the SAME page instance, no reload at
any point`, and the leg's own note concedes the consequence:

> Baselines after the first width are themselves post-dismiss states (no reload mid-pass), so
> accumulating drift widens rather than resetting.

The sweep descends `[1440, 1280, 1024, ...]`. `before` is captured BEFORE
`openInspectorByRealClick`. So the 1280 `before` is not the desk's default state — it is the
state 1440's *dismiss* left behind: the panel CLOSED.

**The witness is recorded in the artefact: `open_clicks`.** The handler's wide-band rule (quoted
from `scripts/studio-desk-measure.mjs`) is that at `wide (>=1280)` the panel is genuinely open,
so click 1 CLOSES and click 2 OPENS:

    viewport 1440  open_clicks = 2   <- fresh page, seeded OPEN, needed two clicks
    viewport 1280  open_clicks = 1   <- needed one, because it was ALREADY CLOSED on entry

One click at a wide width is only possible from an already-closed panel. That is the carry-over,
self-reported.

## 4. Why exactly one width in the matrix shows it

Two conditions must hold together, and 1280 is the only width where they do:

  (a) the width is in the `wide` band, so the panel is seeded OPEN and the carried-closed state
      differs from the true default; and
  (b) with the panel OPEN the surface is NOT already pinned at `surface_max_width_px = 720`,
      so open and closed read different content widths.

    1440   wide, panel open leaves 1136 - 300 = 836 available -> CAPPED at 720 -> content 640.
           Closed also caps at 720 -> content 640. Open == closed, so the carry-over is INVISIBLE.
    1280   wide, panel open leaves  976 - 300 = 676, BELOW the cap -> content 596.
           Closed: 976 available -> CAPPED at 720 -> content 640.  DELTA = 720 - 676 = 44px.
    1024   and below: the panel is painted closed by default, so the carried state IS the
           default. Every one of these agrees leg-for-leg.

Cross-check across the whole sweep — `round_trip.before.content_px` vs the matrix
`rows` `content_px` at the same width and face, same run:

    vp     rt_before   rows_default   open_clicks
    1440   640         640            2     agree
    1280   640         596            1     DISAGREE  <-- the only one
    1024   599         599            1     agree
     900   640         640            1     agree
     800   635         635            1     agree
     764   631         631            1     agree
     700   567         567            1     agree
     640   507         507            1     agree
     500   411         411            1     agree

9 widths x 3 faces = 27 comparisons; 3 disagree, all at 1280, all by exactly +44.

The filing's phrase "the delta is exactly +44px, the collapsed root strip width" matched the
number and missed the mechanism: 44 here is `surface_max_width_px - surface_border_box_px`
= `720 - 676`, the distance from the starved open-panel surface up to its own cap.

## 5. What follows

* **Do NOT retire the 596px prior observation.** It is correct. Retiring it would replace a true
  desk figure with a measurement of a state the instrument entered by accident.
* **The frozen prediction is untouched and stays untouched.** It was RIGHT at 1280. This is the
  freeze earning its keep: an unfrozen prediction would have been "corrected" to 640 and the
  instrument defect would have been laundered into the record permanently.
* **Round 2's gate is unaffected.** `spd-bracketed-deployed-bracket-2026-07-22.json` already
  gates on `round_trip.ran && returns_bit_identical` and says so
  (`hygiene.zero_byte_or_skipped_run_treated_as_instrument_failure`: "the gate was
  round_trip.ran && returns_bit_identical (NOT the checker exit code, per D184)"). Round-trip
  fidelity is untouched by this finding: before and after agreed at 1280 because BOTH legs
  measured the same (wrong) state. 27/27 cells returned unchanged; that claim stands.
* **The checker now separates the two cases** rather than collapsing them into exit 1. See
  `check-prediction.mjs`: a miss on `prior-observation` basis in a cell whose legs AGREED is
  `STALE-PRIOR` (exit 4), distinct from `FIDELITY-FAIL` (exit 1). The label is deliberately
  read as "the registered absolute needs ADJUDICATION", not as "the desk moved" — this note is
  the worked example of a STALE-PRIOR that turned out to be an instrument fault, not staleness.

## 6. The instrument fix this note does not make

Out of this row's fence. Filed here so it is not lost:

`runRoundTrip` must establish a KNOWN default state at each width before capturing `before` —
either a reload per width, or an explicit re-open when the width is in the `wide` band and
`open_clicks` comes back as 1. A defensive assertion is cheaper and catches the whole class:
at a `wide` width, `open_clicks === 1` is an INSTRUMENT FAILURE (D97), because the wide handler
cannot reach `user_opened` in one click from the seeded-open default.

## Provenance of every number above

* `git rev-list --count 65541e2d4..bdd7dac40` = **256** (the table-to-run gap; NOT 61, NOT 71).
* `git rev-list --count 65541e2d4..bc64d869a` = **71** — `bc64d869a` is the sha the row's brief
  names, and it appears **zero** times in every artefact under `scripts/measurements/`. The run
  measured `bdd7dac40` (57 occurrences in each raw run, 6 in the bracket).
* `git rev-list --count 65541e2d4..origin/main` = **3465** as of this note.
* Artefacts read: `spd-visible-table-2026-07-20.json`, `spd-bracketed-deployed-run1-2026-07-22.json`,
  `spd-bracketed-deployed-run2-2026-07-22.json`, `spd-bracketed-deployed-bracket-2026-07-22.json`.

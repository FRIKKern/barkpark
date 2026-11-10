// design/check/part-r.mjs — Part R of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { evaluateReadingMeasure, TOKENS_PATH } from "../reading-measure.mjs";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part R: the reading-measure pin ─────────────────────────────────────────
// The Studio paper surface floors at `calc(55ch + 2 * var(--paper-gutter))`
// behind `@container content (min-width: 720px)`. `ch` resolves in the WINNING
// FACE, so that floor holds only while the face is narrow enough — and which
// face wins is decided by one human-gated line, design/tokens.json
// font.reading.stack. Every face there was measured in a browser and clears the
// gate with headroom; NOTHING held that. Part R is the hold: it re-derives the
// gate from the sheet every run, and requires every face the stack names to
// carry a MEASURED advance that fits.
//
// COVERAGE IS A PREDICATE, NOT A LIST. A sixth face is swept because it is in
// the stack; there is no skip-list it can be quietly missing from. The pinned
// advances live in design/reading-measure.mjs and are deliberately NOT derivable
// from the sheet this Part checks — a guard reading its expected value out of
// the thing it guards is inert.
console.log("\ndesign/check.mjs — Part R: reading-face advance pin vs the paper-surface container gate");
{
  const failedBeforeR = failed;
  const rFail = (m) => fail(m);

  const { gate, faces, rows, failures } = evaluateReadingMeasure();
  for (const f of failures) rFail(f);

  if (FAULT.has("R")) rFail("  Part R FAIL: injected fault (--selftest)");
  if (failed === failedBeforeR) {
    const worst = rows.reduce((a, b) => (b.headroomPx < a.headroomPx ? b : a));
    const crossing = (gate.containerMinPx - 2 * gate.gutterPx) / gate.chCount;
    for (const r of rows)
      console.log(
        `       ${r.face.padEnd(20)} ${String(r.advance).padStart(8)} px/ch  ` +
          `floor ${r.floorPx.toFixed(3)}px  headroom ${r.headroomPx.toFixed(3)}px`,
      );
    console.log(
      `  ok   ${rows.length} face(s) from ${TOKENS_PATH} font.reading.stack swept by predicate against the ` +
        `${gate.chCount}ch + 2*${gate.gutterPx}px floor behind @container content (min-width: ${gate.containerMinPx}px); ` +
        `worst is ${worst.face} at ${worst.headroomPx.toFixed(3)}px headroom, crossing starts at ${crossing.toFixed(4)} px/ch`,
    );
  }
}

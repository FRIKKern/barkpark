// design/reading-measure.mjs — THE PIN. Per-face reading advances (px/ch at
// 18px) held as measured LITERALS, checked against the Studio paper surface's
// own 720px container gate, over the face set design/tokens.json actually names.
//
// WHY THIS FILE EXISTS. The Studio content pane floors the paper surface at
// `calc(55ch + 2 * var(--paper-gutter))` behind `@container content
// (min-width: 720px)`. `ch` is the advance of "0" IN THE RESOLVED FACE, so that
// floor is only a floor while the winning face is narrow enough: the moment
// 55*advance + 2*gutter exceeds the container width at which the rule switches
// on, the surface demands more inline size than the container gives and the
// pane overflows in a thin band just above 720px.
//
// Every face in today's stack clears it, with headroom, and that was MEASURED —
// twice, independently, in Chrome against the real sheet — never derived. But a
// measurement is a snapshot. design/tokens.json font.reading.stack is
// human-gated and one line long; a face added to it ships to the surface with
// nothing asking whether anyone ever put a ruler on it. This file is that
// question, asked mechanically, on every run of design/check.mjs (Part R).
//
// ── THE TWO HALVES, AND WHY THEY ARE ARMED DIFFERENTLY ──────────────────────
//
//   (a) COVERAGE. Every face the stack names must appear in MEASURED_ADVANCES.
//       A face that does not is UNMEASURED and reds by name. This is a
//       PREDICATE over the stack, not a list: a sixth, seventh or twentieth
//       face is swept because it is IN the stack, and there is no skip-list for
//       it to be quietly absent from.
//
//   (b) ARITHMETIC. Every measured face's floor must fit the gate.
//
// Half (b) cannot be red-armed by adding a real face, and saying so is part of
// the record: Verdana, the widest of the 25 faces swept, advances 11.4434 px/ch
// and floors at 709.387px — 10.6px UNDER the gate. Crossing needs
// (720 - 2*40) / 55 = 11.63636 px/ch and nothing measured reaches it. Half (b)
// is therefore armed from the GATE side instead: widen the sheet's 55ch to 70ch
// and every face in the stack reds. That is the right arm anyway, because the
// gate is the half that moves under a refactor.
//
// ── WHAT IS PINNED HERE AND WHAT IS READ ────────────────────────────────────
//
// A guard whose expected value is read from the thing it guards is inert. So:
//
//   PINNED (literals below, from a browser, present in NO file the guard reads):
//     the per-face advances.
//   READ (from the sheet, every run):
//     the ch count, the gutter and the container min-width — i.e. the GATE.
//
// That split is deliberate in both directions. Pinning the advances means a
// stylesheet edit can never launder itself into the expected value. Reading the
// gate means a sheet change re-proves the arithmetic instead of being compared
// against a number someone typed in 2026 and nobody re-derived.
//
// Dependency-free (Node built-ins only), like every other file in design/.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, "..");

export const SHEET_PATH = "api/lib/barkpark_web/layouts/root.html.heex";
export const TOKENS_PATH = "design/tokens.json";
export const EMITTED_SURFACE_PATH = "api/assets/paper-surface/paper-surface.css";

// ── THE PIN ─────────────────────────────────────────────────────────────────
// Horizontal advance of "0" — the definition of the CSS `ch` unit — at
// font-size:18px, the paper surface's body size (tokens.type.reading.body.size).
//
// PROVENANCE: measured in Chrome against the real sheet by a `width: 1ch` probe
// on an element carrying a single-face font-family, one face per measurement,
// at the surface's own 18px. Measured twice by two agents working
// independently; Georgia came back 11.0479 and 11.0469, and the smaller value
// is NOT averaged in — the WIDER reading is kept, because this table exists to
// bound an overflow and a bound wants the pessimistic number.
//
// THE SPREAD IS THE DISCRIMINATION CONTROL. A probe that has silently died —
// reading a custom property that does not exist, or measuring an element the
// face never applied to — returns ONE number for every input and looks exactly
// like a clean result. These do not: 9.0 through 11.4434, five distinct values
// across eight faces. Part R asserts that spread mechanically (R_MIN_DISTINCT)
// so a future re-measurement that flattens cannot land quietly.
//
// Faces are keyed EXACTLY as design/tokens.json spells them, quotes stripped.
// Entries beyond the current stack (Verdana) are kept on purpose: they are the
// swept-but-not-shipped controls, and they are what makes the headroom report
// mean something.
export const MEASURED_ADVANCES = Object.freeze({
  "Iowan Old Style": 10.0107,
  "Palatino Linotype": 9.0,   // URW P052 metric clone on the measuring host
  "Palatino": 9.0,
  "Charter": 10.0107,
  "Georgia": 11.0479,         // the worst face in the real stack
  "Source Serif 4": 9.522,
  "serif": 9.0,               // the generic fallback, resolved by the host
  "Verdana": 11.4434,         // NOT in the stack: widest of the 25 faces swept
});

// The font-size the advances were measured at. If the surface's body size moves,
// the table is measured at the wrong size and the arithmetic below is void — so
// Part R reads the size from tokens.json and refuses on a mismatch rather than
// scaling a number it has no right to scale.
export const MEASURED_AT_PX = 18;

// Vacuity floor for the discrimination control (see the spread note above).
export const R_MIN_DISTINCT = 4;

// ── READING THE GATE ────────────────────────────────────────────────────────
// Every parse REFUSES rather than defaults. A regex that stops matching after a
// refactor must be loud: a guard that silently substitutes a fallback for the
// number it could not find is measuring its own defaults.

class ReadingMeasureRefusal extends Error {}
const refuse = (msg) => { throw new ReadingMeasureRefusal(msg); };

export function parseGate(sheetSrc) {
  // The floor rule and the container query it sits behind, matched together so
  // the min-width belongs to THIS rule and not to some other container query.
  const gateRe =
    /@container\s+content\s*\(\s*min-width:\s*([0-9.]+)px\s*\)\s*\{[^{}]*\{[^{}]*min-inline-size:\s*calc\(\s*([0-9.]+)ch\s*\+\s*2\s*\*\s*var\(\s*--paper-gutter\s*\)\s*\)/;
  const m = gateRe.exec(sheetSrc);
  if (!m)
    refuse(
      `cannot find the paper-surface floor rule in ${SHEET_PATH}. Part R was looking for\n` +
        `    @container content (min-width: <N>px) { … min-inline-size: calc(<C>ch + 2 * var(--paper-gutter)) }\n` +
        `    and found nothing. Either the floor moved, or it stopped being expressed in ch and gutter —\n` +
        `    both of which void this guard's arithmetic. Re-point the parse at the rule that owns the floor\n` +
        `    (do NOT relax it into a default: a gate that defaults is a gate that measures itself).`,
    );
  const containerMinPx = Number(m[1]);
  const chCount = Number(m[2]);

  // The gutter IN FORCE inside that container band. --paper-gutter is declared
  // three times: a base value and two narrower ones behind max-width media
  // queries at 767px and 479px. The container only reaches 720px on a viewport
  // wider than 767px, so the BASE declaration is the one that applies here —
  // and this parse takes the base by finding the declaration that is NOT inside
  // a max-width block, rather than by taking the first or the largest.
  const withoutNarrowBands = sheetSrc.replace(/@media\s*\(\s*max-width:[^{]*\)\s*\{[\s\S]*?\}\s*\}/g, "");
  const gutters = [...withoutNarrowBands.matchAll(/--paper-gutter:\s*([0-9.]+)px/g)].map((g) => Number(g[1]));
  if (gutters.length !== 1)
    refuse(
      `expected exactly ONE unconditioned --paper-gutter declaration in ${SHEET_PATH}, found ${gutters.length}` +
        (gutters.length ? ` (${gutters.join("px, ")}px)` : "") +
        `.\n    Part R cannot tell which gutter the 720px container band resolves to, and guessing is how a\n` +
        `    guard starts reporting about a width the surface never has. Narrow overrides belong behind a\n` +
        `    max-width media query (which this parse strips); a second unconditional one needs this parse taught.`,
    );
  const gutterPx = gutters[0];

  return { containerMinPx, chCount, gutterPx };
}

export function parseStack(tokens) {
  const raw = tokens?.font?.reading?.stack;
  if (typeof raw !== "string" || !raw.trim())
    refuse(`${TOKENS_PATH}: font.reading.stack is missing or not a non-empty string. Nothing to sweep.`);
  const faces = raw
    .split(",")
    .map((f) => f.trim().replace(/^["']|["']$/g, "").trim())
    .filter(Boolean);
  if (!faces.length) refuse(`${TOKENS_PATH}: font.reading.stack parsed to zero faces from ${JSON.stringify(raw)}.`);
  return faces;
}

// ── THE EVALUATION ──────────────────────────────────────────────────────────
// Returns { gate, faces, rows, failures, refusal }. A refusal (a parse that
// could not find what it needs) is returned as a failure too — never swallowed,
// never turned into a clean run.
export function evaluateReadingMeasure({ read = (rel) => readFileSync(join(repoRoot, rel), "utf8") } = {}) {
  const failures = [];
  let gate = null, faces = null, rows = [], bodySize = null, emittedStack = null;

  try {
    const tokens = JSON.parse(read(TOKENS_PATH));
    faces = parseStack(tokens);
    bodySize = tokens?.type?.reading?.body?.size;
    gate = parseGate(read(SHEET_PATH));

    // The emitted surface must name the same stack the tokens do — otherwise
    // Part R swept a stack the gate never applies to. (design/check.mjs Part A
    // proves byte parity of the emitted artifacts; this is the narrower claim
    // that THIS guard's subject and the gate's subject are the same list.)
    const emitted = /--tok-reading-font:\s*([^;]+);/.exec(read(EMITTED_SURFACE_PATH));
    if (!emitted)
      failures.push(
        `  Part R FAIL: cannot find --tok-reading-font in ${EMITTED_SURFACE_PATH}. Part R would then be\n` +
          `    checking design/tokens.json against a surface that no longer names a reading stack at all.`,
      );
    else {
      emittedStack = parseStack({ font: { reading: { stack: emitted[1] } } });
      if (emittedStack.join("|") !== faces.join("|"))
        failures.push(
          `  Part R FAIL: the emitted reading stack and design/tokens.json disagree.\n` +
            `    ${TOKENS_PATH}: ${faces.join(", ")}\n` +
            `    ${EMITTED_SURFACE_PATH}: ${emittedStack.join(", ")}\n` +
            `    Part R sweeps the tokens stack; the gate applies to the emitted one. Re-emit (node design/emit.mjs --write).`,
        );
    }

    if (bodySize !== MEASURED_AT_PX)
      failures.push(
        `  Part R FAIL: the advances below were measured at ${MEASURED_AT_PX}px but\n` +
          `    ${TOKENS_PATH} type.reading.body.size is now ${JSON.stringify(bodySize)}. The pinned table is at the\n` +
          `    WRONG SIZE and every floor it computes is wrong. Advances do not scale exactly with font-size\n` +
          `    (hinting and rounding are per-size), so this guard will not scale them for you: RE-MEASURE the\n` +
          `    stack at ${JSON.stringify(bodySize)}px and update MEASURED_ADVANCES and MEASURED_AT_PX together.`,
      );

    // ── half (a): COVERAGE, by predicate over the stack ──────────────────────
    const unmeasured = faces.filter((f) => !(f in MEASURED_ADVANCES));
    if (unmeasured.length)
      failures.push(
        `  Part R FAIL: ${unmeasured.length} face(s) in font.reading.stack are UNMEASURED: ${unmeasured.join(", ")}.\n` +
          `    A face reaches the Studio paper surface the moment it is named here, and `+"`ch`"+` resolves in\n` +
          `    WHICHEVER face wins — so an unmeasured face is an unbounded floor. Measure its advance of "0"\n` +
          `    at ${MEASURED_AT_PX}px in a browser (a `+"`width: 1ch`"+` probe on a single-face font-family against the real\n` +
          `    sheet) and add it to MEASURED_ADVANCES in design/reading-measure.mjs with the date and host.\n` +
          `    Do NOT read a number out of the stylesheet to satisfy this: the pin exists because the\n` +
          `    stylesheet does not know how wide a glyph is.`,
      );

    // ── the discrimination control ───────────────────────────────────────────
    const distinct = new Set(Object.values(MEASURED_ADVANCES)).size;
    if (distinct < R_MIN_DISTINCT)
      failures.push(
        `  Part R FAIL: MEASURED_ADVANCES holds ${distinct} distinct value(s) across ` +
          `${Object.keys(MEASURED_ADVANCES).length} faces, floor is ${R_MIN_DISTINCT}.\n` +
          `    A measuring probe that has died returns the SAME number for every face and is indistinguishable\n` +
          `    from a clean sweep. A flat table is that signature. Re-measure before trusting this Part.`,
      );

    // ── half (b): ARITHMETIC, against the gate as the sheet states it today ──
    if (gate) {
      const budget = gate.containerMinPx - 2 * gate.gutterPx;
      const crossing = budget / gate.chCount;
      for (const face of faces) {
        const advance = MEASURED_ADVANCES[face];
        if (advance === undefined) continue; // already reported as unmeasured
        const floorPx = gate.chCount * advance + 2 * gate.gutterPx;
        const headroomPx = gate.containerMinPx - floorPx;
        rows.push({ face, advance, floorPx, headroomPx });
        if (floorPx > gate.containerMinPx)
          failures.push(
            `  Part R FAIL: "${face}" (${advance} px/ch at ${MEASURED_AT_PX}px) floors the paper surface at\n` +
              `    ${gate.chCount}ch + 2*${gate.gutterPx}px = ${floorPx.toFixed(3)}px, which EXCEEDS the ${gate.containerMinPx}px container width\n` +
              `    the floor switches on at. The content pane overflows in the band just above ${gate.containerMinPx}px.\n` +
              `    Crossing starts at ${crossing.toFixed(4)} px/ch. Either drop the face from font.reading.stack, or move the\n` +
              `    gate (${SHEET_PATH}) so the floor cannot demand more than the container gives.`,
          );
      }
      if (!rows.length)
        failures.push(
          `  Part R FAIL: zero faces were measured against the gate. Part R is passing VACUOUSLY — an\n` +
            `    all-clear and a nothing-measured look identical from the outside.`,
        );
    }
  } catch (e) {
    if (!(e instanceof ReadingMeasureRefusal)) throw e;
    failures.push(`  Part R FAIL (REFUSED TO MEASURE): ${e.message}`);
  }

  return { gate, faces, rows, failures };
}

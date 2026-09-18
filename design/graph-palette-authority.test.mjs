// graph-palette-authority.test.mjs — enforces the claim design/tokens.json
// makes about itself.
//
// `color.graphCanvas.graph._note` says the token block is
//
//     "the SOLE source for every concrete colour that renderer paints"
//
// and until now that was an ASSERTION with no gate behind it. Byte identity
// across the four copies IS guarded (scripts/check-bp-graph-drift.sh) and the
// emitted region IS kept in sync with tokens.json (design/emit.mjs artifacts,
// `node design/emit.mjs --check`). Neither watches the region's COMPLEMENT: a
// literal `ctx.fillStyle = "#abc"` added anywhere OUTSIDE the generated markers
// is byte-identical across all four mirrors and leaves every artifact in sync,
// so every existing gate stays green while that colour silently stops tracking
// tokens.json — invisible to the CSS gates because Canvas 2D never consumes
// `var()`. That is the Canvas-drift class this file closes.
//
// ENROLMENT IS A PREDICATE, NOT A LIST: every file named bp-graph.js under the
// repo (minus node_modules / .claude worktrees / _build) enrols itself, so a
// fifth copy is covered the day it lands. An enumeration would go stale the
// same way the template snapshots once did. That walk now lives in
// design/bp-graph-copies.mjs so every gate with the same subjects shares ONE
// rule — two enumerations that disagree are worse than one.
//
// Every scan here is paired with a CONTROL that fires on planted input, because
// a colour regex that matches nothing would otherwise report a perfect green
// over a file it never read.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { findCopies } from "./bp-graph-copies.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");

const BEGIN = "/* BEGIN GENERATED: bp-graph-palette";
const END = "/* END GENERATED: bp-graph-palette */";

// Concrete colour literals a Canvas 2D context can consume directly.
// `rgba?\(\s*\d` deliberately requires a DIGIT first so the file's own
// `rgba(MONO_LIGHT, 0.65)` helper call — which resolves THROUGH the generated
// block — is not mistaken for a literal.
const COLOR_RE = /#[0-9a-fA-F]{3,8}\b|(?:rgba?|hsla?)\(\s*\d[^)]*\)/g;

// Split a bp-graph.js source into the generated palette region and everything
// else. Returns null when the marker pair is absent or malformed.
function splitAtMarkers(src) {
  const b = src.indexOf(BEGIN);
  const e = src.indexOf(END);
  if (b === -1 || e === -1 || e < b) return null;
  if (src.indexOf(BEGIN, b + 1) !== -1) return null; // a second BEGIN
  if (src.indexOf(END, e + 1) !== -1) return null;   // a second END
  return {
    inside: src.slice(b, e + END.length),
    outside: src.slice(0, b) + src.slice(e + END.length),
  };
}

function colorsIn(text) {
  return (text.match(COLOR_RE) || []);
}

// ── the notation axis: what a Canvas 2D context actually accepts ─────────────
//
// COLOR_RE above sees hex and NUMERIC functional notation. That is not the set
// Canvas consumes. `ctx.fillStyle = "white"` paints exactly as hard a colour as
// `"#fff"` does, and matched NOTHING here — so a named colour planted outside
// the markers left this file green (17/17) while painting a value tokens.json
// never wrote. Widening COLOR_RE with a word alternation is not the fix: the
// 148 CSS colour names are ordinary English words ("tan", "gold", "linen",
// "plum"), and a text-wide scan for them would red on every label string.
//
// So the notation axis is scanned at the SINKS instead — the assignments and
// arguments a Canvas 2D context consumes as a colour — where any complete
// string literal IS a colour by construction, whatever its notation. Two scans,
// two scopes, one claim:
//
//   text-wide  (COLOR_RE)      hex + numeric rgb/hsl anywhere outside the region
//   sink-scoped (this section) EVERY notation, at fillStyle/strokeStyle/
//                              shadowColor/addColorStop only
//
// AND IT REFUSES WHAT IT CANNOT NAME. A notation the classifier does not
// recognise — color-mix(), lab(), oklch(), color(), a var() smuggled inside
// rgb() — is reported as UNCLASSIFIABLE and fails, rather than passing unseen
// the way a named colour used to. An unknown-is-clean scanner reports a verdict
// it never measured.

// The 148 CSS named colours (level 4), plus the two keywords Canvas takes in
// the same position. Author-chosen VALUES: every one of them is a palette
// decision that belongs in design/tokens.json.
const NAMED_COLORS = new Set(`
aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond
blue blueviolet brown burlywood cadetblue chartreuse chocolate coral
cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray
darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid
darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey
darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue
firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod
gray green greenyellow grey honeydew hotpink indianred indigo ivory khaki
lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan
lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon
lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue
lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue
mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen
mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin
navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod
palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum
powderblue purple rebeccapurple red rosybrown royalblue saddlebrown salmon
sandybrown seagreen seashell sienna silver skyblue slateblue slategray
slategrey snow springgreen steelblue tan teal thistle tomato turquoise violet
wheat white whitesmoke yellow yellowgreen
transparent currentcolor
`.trim().split(/\s+/));

// CSS SYSTEM colours. These are NOT palette values — the user agent supplies
// them, and that is the whole point of the renderer's forced-colors branch
// (`forced ? "CanvasText" : accent()`). tokens.json cannot and must not own
// them, so they are classified and ALLOWED rather than silently unmatched.
const SYSTEM_COLORS = new Set(`
canvas canvastext linktext visitedtext activetext buttonface buttontext
buttonborder field fieldtext highlight highlighttext selecteditem
selecteditemtext mark marktext graytext accentcolor accentcolortext
`.trim().split(/\s+/));

// Every notation kind classifyColorString can return, except the "not a colour
// at all" answer (null). The control block below is asserted to carry a
// specimen for EVERY kind in this set: a notation nobody plants is a notation
// nobody has proven the scanner can see.
const COVERED_NOTATIONS = new Set(["hex", "rgb", "hsl", "named", "system", "unknown"]);

// A kind is a VIOLATION at a Canvas sink outside the generated region when it
// names a concrete author-chosen colour. "system" is UA-supplied; null is not a
// colour (a composition fragment such as "rgba(" , or a label).
const VIOLATING_NOTATIONS = new Set(["hex", "rgb", "hsl", "named", "unknown"]);

// classifyColorString(s) → a member of COVERED_NOTATIONS, or null when the
// string is not a colour at all. Total: there is no unmatched third answer.
function classifyColorString(raw) {
  const s = String(raw).trim();
  if (s === "") return null;
  if (/^#[0-9a-fA-F]{3,8}$/.test(s)) return "hex";
  const fn = /^([a-zA-Z][a-zA-Z0-9-]*)\(([\s\S]*)\)$/.exec(s);
  if (fn) {
    const name = fn[1].toLowerCase();
    const numericFirst = /^\s*[+-]?[.\d]/.test(fn[2]);
    if ((name === "rgb" || name === "rgba") && numericFirst) return "rgb";
    if ((name === "hsl" || name === "hsla") && numericFirst) return "hsl";
    // A COMPLETE functional notation this scanner cannot name. Refused, not
    // ignored: color-mix(), lab(), oklch(), color(), rgb(var(--x)).
    return "unknown";
  }
  const w = s.toLowerCase();
  if (SYSTEM_COLORS.has(w)) return "system";
  if (NAMED_COLORS.has(w)) return "named";
  return null; // an incomplete fragment like `rgba(` , a label, an identifier
}

// The Canvas 2D colour sinks. Anything assigned here, or passed as the colour
// argument of addColorStop, is consumed as a colour.
const SINK_RE = /\.(fillStyle|strokeStyle|shadowColor)\s*=|\b(addColorStop)\s*\(/g;
const STRING_RE = /"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'/g;

// sinkColorStrings(text) → every string literal that reaches a Canvas colour
// sink, as { sink, value, kind }. The expression window is the sink match to
// the end of the statement (`;` or a newline, whichever comes first), which
// covers every form the renderer uses: a bare literal, a ternary, and a
// `"rgba(" + … + ")"` concatenation.
function sinkColorStrings(text) {
  const out = [];
  SINK_RE.lastIndex = 0;
  let m;
  while ((m = SINK_RE.exec(text)) !== null) {
    const sink = m[1] || m[2];
    const rest = text.slice(m.index + m[0].length);
    const stop = rest.search(/[;\n]/);
    const expr = stop === -1 ? rest : rest.slice(0, stop);
    STRING_RE.lastIndex = 0;
    let s;
    while ((s = STRING_RE.exec(expr)) !== null) {
      const value = s[1] !== undefined ? s[1] : s[2];
      out.push({ sink, value, kind: classifyColorString(value) });
    }
  }
  return out;
}

// The reported violations: every sink-reaching literal whose notation names a
// concrete colour. tokens.json never wrote any of them — they live outside the
// generated region by definition of the caller's `outside` text.
function sinkViolations(text) {
  return sinkColorStrings(text).filter((h) => VIOLATING_NOTATIONS.has(h.kind));
}

function describeViolation(h) {
  return h.kind === "unknown"
    ? `${h.sink} = "${h.value}" (UNCLASSIFIABLE colour notation — this gate cannot prove it tracks tokens.json)`
    : `${h.sink} = "${h.value}" (${h.kind})`;
}

const copies = findCopies(REPO).map((p) => ({
  path: p,
  rel: relative(REPO, p),
  src: readFileSync(p, "utf8"),
}));

const tokens = JSON.parse(readFileSync(join(REPO, "design/tokens.json"), "utf8"));
const graphTokens = tokens.color.graphCanvas.graph;

// ── controls on the instrument itself ────────────────────────────────────────

test("control: the scanner finds colour literals in planted input", () => {
  assert.deepEqual(colorsIn('ctx.fillStyle = "#16161a";'), ["#16161a"]);
  assert.deepEqual(colorsIn('a = "rgba(15,17,23,0.5)";'), ["rgba(15,17,23,0.5)"]);
  assert.deepEqual(colorsIn('h = "hsl(210, 5%, 9%)";'), ["hsl(210, 5%, 9%)"]);
  // and is NOT fooled by the file's own helper call, which resolves through
  // the generated block rather than carrying a literal.
  assert.deepEqual(colorsIn("return rgba(MONO_LIGHT, 0.65);"), []);
});

test("control: splitAtMarkers puts a planted outside-literal OUTSIDE", () => {
  const synthetic = `var a = "#aabbcc";\n${BEGIN} x */\nvar B = "#16161a";\n${END}\nvar c = "#ddeeff";\n`;
  const parts = splitAtMarkers(synthetic);
  assert.ok(parts, "marker pair must be found in the synthetic source");
  assert.deepEqual(colorsIn(parts.inside), ["#16161a"]);
  assert.deepEqual(colorsIn(parts.outside).sort(), ["#aabbcc", "#ddeeff"]);
});

test("control: a missing or duplicated marker pair is refused, not ignored", () => {
  assert.equal(splitAtMarkers("no markers here"), null);
  assert.equal(splitAtMarkers(`${BEGIN} a */\n${BEGIN} b */\n${END}`), null);
  assert.equal(splitAtMarkers(`${END}\n${BEGIN} a */`), null);
});

// ── controls on the NOTATION axis ────────────────────────────────────────────
//
// One specimen per notation, and a coverage check that the table names every
// kind the classifier can return. Delete the `named` row and the coverage test
// reds: the arm is proven on planted input, never assumed from the regex.

const NOTATION_SPECIMENS = [
  { kind: "hex", sample: "#16161a", violating: true },
  { kind: "rgb", sample: "rgba(15,17,23,0.5)", violating: true },
  { kind: "hsl", sample: "hsl(210, 5%, 9%)", violating: true },
  { kind: "named", sample: "white", violating: true },
  { kind: "unknown", sample: "color-mix(in srgb, white 50%, black)", violating: true },
  { kind: "system", sample: "CanvasText", violating: false },
];

test("control: every notation the classifier can return has a planted specimen", () => {
  const planted = new Set(NOTATION_SPECIMENS.map((s) => s.kind));
  assert.deepEqual(planted, COVERED_NOTATIONS,
    `the control block must plant one specimen per notation the scanner claims to cover; ` +
    `missing: ${[...COVERED_NOTATIONS].filter((k) => !planted.has(k)).join(", ") || "(none)"}; ` +
    `undeclared: ${[...planted].filter((k) => !COVERED_NOTATIONS.has(k)).join(", ") || "(none)"}`);
  for (const s of NOTATION_SPECIMENS) {
    assert.equal(s.violating, VIOLATING_NOTATIONS.has(s.kind),
      `specimen ${s.kind} disagrees with VIOLATING_NOTATIONS`);
  }
});

test("control: each specimen classifies as its own notation", () => {
  for (const s of NOTATION_SPECIMENS) {
    assert.equal(classifyColorString(s.sample), s.kind, `classify(${s.sample})`);
  }
});

test("control: each specimen is SEEN at a Canvas sink in planted input", () => {
  for (const s of NOTATION_SPECIMENS) {
    const planted = `function probe(ctx){ ctx.fillStyle = "${s.sample}"; }`;
    const seen = sinkColorStrings(planted);
    assert.deepEqual(seen.map((h) => h.value), [s.sample], `sink scan missed ${s.kind}`);
    assert.equal(seen[0].kind, s.kind);
    assert.equal(sinkViolations(planted).length, s.violating ? 1 : 0,
      `${s.kind} should ${s.violating ? "" : "NOT "}be a violation`);
  }
});

test("control: every Canvas colour sink is watched, not just fillStyle", () => {
  for (const planted of [
    'ctx.fillStyle = "white";',
    'ctx.strokeStyle = "rebeccapurple";',
    'ctx.shadowColor = "black";',
    'g.addColorStop(0, "white");',
  ]) {
    assert.equal(sinkViolations(planted).length, 1, `unwatched sink: ${planted}`);
  }
});

test("control: the sink scan does not red on the renderer's real shapes", () => {
  // A named-colour WORD in an ordinary string is not a Canvas colour.
  assert.deepEqual(sinkViolations('var label = "white";'), []);
  assert.deepEqual(sinkViolations('node.kind = "gold"; draw(node);'), []);
  // A UA-supplied system colour in the forced-colors branch is not a token.
  assert.deepEqual(sinkViolations('ctx.fillStyle = forced ? "CanvasText" : accent();'), []);
  // A composed rgba string built from an already-generated constant.
  assert.deepEqual(sinkViolations('ctx.strokeStyle = "rgba(" + rgbStr + "," + a + ")";'), []);
  // An identifier or call that resolves THROUGH the generated block.
  assert.deepEqual(sinkViolations("ctx.fillStyle = TOAST_BORDER;"), []);
  assert.deepEqual(sinkViolations("ctx.fillStyle = rgba(accent(), a);"), []);
});

test("control: an unclassifiable notation is refused, not passed over", () => {
  for (const notation of [
    "color-mix(in srgb, white 50%, black)",
    "lab(52% 40 59)",
    "oklch(0.7 0.1 200)",
    "color(display-p3 1 0 0)",
    "rgb(var(--accent))",
    "light-dark(#fff, #000)",
  ]) {
    assert.equal(classifyColorString(notation), "unknown", `classify(${notation})`);
    const v = sinkViolations(`ctx.fillStyle = "${notation}";`);
    assert.equal(v.length, 1, `unclassifiable notation passed unseen: ${notation}`);
    assert.match(describeViolation(v[0]), /UNCLASSIFIABLE/);
  }
});

// ── enrolment ────────────────────────────────────────────────────────────────

test("at least the four declared bp-graph.js copies enrol by predicate", () => {
  assert.ok(copies.length >= 4, `expected >= 4 bp-graph.js copies, found ${copies.length}: ${copies.map((c) => c.rel)}`);
  for (const want of [
    "api/priv/static/assets/bp-graph.js",
    "web/public/bp-graph.js",
    "templates/search-starter/public/bp-graph.js",
    "templates/astro-search-starter/public/bp-graph.js",
  ]) {
    assert.ok(copies.some((c) => c.rel === want), `${want} did not enrol — the walk missed it`);
  }
});

// ── the authority claim, per copy ────────────────────────────────────────────

for (const copy of copies) {
  test(`${copy.rel}: carries exactly one generated palette region`, () => {
    assert.ok(splitAtMarkers(copy.src), `${copy.rel} has no single well-formed ${BEGIN} … ${END} pair`);
  });

  test(`${copy.rel}: the generated region actually holds colour literals`, () => {
    // Guards the vacuous direction: an empty region would make the
    // outside-is-clean assertion below trivially true.
    const parts = splitAtMarkers(copy.src);
    assert.ok(parts);
    assert.ok(colorsIn(parts.inside).length >= 50,
      `expected the emitted palette to carry many literals, got ${colorsIn(parts.inside).length}`);
  });

  test(`${copy.rel}: NO Canvas colour sink outside the generated region takes a literal`, () => {
    // The notation axis. COLOR_RE below sees hex and numeric rgb/hsl anywhere;
    // this sees EVERY notation, at the sinks Canvas consumes — including the
    // named colours that used to leave this file green at 17/17.
    const parts = splitAtMarkers(copy.src);
    assert.ok(parts);
    const bad = sinkViolations(parts.outside);
    assert.deepEqual(bad.map(describeViolation), [],
      `${copy.rel} paints ${bad.length} colour(s) design/tokens.json never wrote, straight into a Canvas colour sink. ` +
      `Move the value into color.graphCanvas.graph and re-run: node design/emit.mjs --write`);
  });

  test(`${copy.rel}: NO colour literal lives outside the generated region`, () => {
    const parts = splitAtMarkers(copy.src);
    assert.ok(parts);
    const strays = colorsIn(parts.outside);
    assert.deepEqual(strays, [],
      `${copy.rel} paints ${strays.length} colour(s) design/tokens.json never wrote: ${[...new Set(strays)].join(", ")}. ` +
      `Move the value into color.graphCanvas.graph and re-run: node design/emit.mjs --write`);
  });
}

// ── the emitted values are token values ──────────────────────────────────────

test("every literal in the generated region is a value tokens.json carries", () => {
  const tokenColors = new Set();
  const walk = (v) => {
    if (typeof v === "string") for (const m of colorsIn(v)) tokenColors.add(m);
    else if (v && typeof v === "object") for (const k of Object.keys(v)) {
      if (k.startsWith("_")) continue; // prose notes are not palette values
      walk(v[k]);
    }
  };
  walk(graphTokens);
  assert.ok(tokenColors.size >= 50, `control: expected many token colours, got ${tokenColors.size}`);

  const canonical = copies.find((c) => c.rel === "api/priv/static/assets/bp-graph.js");
  assert.ok(canonical, "the canonical copy must enrol");
  const parts = splitAtMarkers(canonical.src);
  const unsourced = [...new Set(colorsIn(parts.inside))].filter((c) => !tokenColors.has(c));
  assert.deepEqual(unsourced, [],
    `the generated region holds colour(s) absent from design/tokens.json color.graphCanvas.graph: ${unsourced.join(", ")}`);
});

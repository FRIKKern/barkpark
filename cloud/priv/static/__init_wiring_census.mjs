// __init_wiring_census.mjs — THE INIT WIRING CENSUS: a control's HANDLER is
// pinned, but until this instrument its WIRING was not.
//
// Task cchi-w44-bl-init-wiring-is-unpinned. The law:
//
//     A CONTROL THAT COMES LOOSE FROM init() DOES NOT FAIL A HANDLER TEST.
//     IT FAILS SILENTLY, IN A BROWSER, IN FRONT OF A PERSON.
//
// cloud/priv/static/app.js `init()` is the ONE place the console attaches its
// listeners — one `addEventListener` per control. Every handler behind those
// listeners is pinned by __app.test.mjs, which calls the functions directly
// through the __bpTestHook. NOTHING called the WIRING. Measured before this
// file existed: deleting
//
//     if (membersInvite) membersInvite.addEventListener("click", membersInviteClick);
//
// from init() leaves __app.test.mjs green (membersInviteClick is still exported
// to the hook and still correct), leaves every census green (the elevated-write
// binding, the refusal copy, the reason arms and the /v1/me envelope are all
// unchanged), and ships a Members panel whose Invite button does nothing.
//
// ── WHY THIS IS DERIVED AND NOT A PINNED ROSTER (criterion 2) ───────────────
//
// The obvious instrument is a list: "these selectors, by name, must be wired."
// Such a list is wrong the day someone wires a control it was never told about,
// and it is wrong in the direction that matters — it goes green on wiring it
// never looked at. It is also wrong in a quieter way this file learned the hard
// way: a population written into PROSE stops matching the population the
// instrument PRINTS, and then the file's own invitation to "run it and see"
// hands the reader a contradiction. So no count is typed into the prose here;
// the one count this file does pin (STATED_POPULATION, below) is a constant the
// census checks against its own live measurement on every run.
// So this census holds NO roster. It parses init() into (target, event,
// handler) triples and then asks TWO questions that the source answers about
// ITSELF:
//
//   (A) ORPHANED LOOKUP — init() looked a control up and never wired it.
//       Every `$("#selector")` evaluated at init()'s OWN statement level (not
//       inside a nested handler body) must reach an `addEventListener`, either
//       directly (`$("#tab-login").addEventListener(…)`) or through the local
//       binding it was stored in (`var x = $("#sel"); if (x) x.addEventListener(…)`).
//       A lookup with no listener is a control that came loose, and the census
//       names it BY SELECTOR. This is the arm that reds on the #members-invite
//       deletion: the `var membersInvite = $("#members-invite");` line above it
//       survives the deletion and becomes an orphan.
//
//   (B) DANGLING HANDLER — a listener names a function that does not exist.
//       Every non-inline handler identifier in a triple must resolve to a
//       declaration in app.js (`function name(`, `var name =`, `let`/`const`,
//       or a parameter-free local binding inside init() itself). A listener
//       wired to a typo'd or deleted handler throws at CLICK TIME, in the
//       browser, and no node test can see it. This is the arm that reds when a
//       listener added tomorrow names a handler nobody wrote.
//
// Both questions are computed from app.js in this commit. A control added
// tomorrow is covered without editing this file or the gate.
//
// ── WHY IT REFUSES RATHER THAN DEGRADES (criterion 3) ──────────────────────
//
// The failure mode of a source-parsing instrument is not a wrong answer, it is
// an EMPTY answer that reads as a clean one: the anchor moves, the regex stops
// matching, the population collapses to zero and every derived question is
// vacuously satisfied. So:
//
//   * the init() anchor must be found EXACTLY ONCE,
//   * its body must brace-balance,
//   * every literal `.addEventListener(` occurrence in the body must be
//     ACCOUNTED FOR by a parsed triple — an unparsed call site is named by
//     line number, never skipped,
//   * the population must clear a FLOOR (see POPULATION_FLOOR below).
//
// Any of those exits 2 — REFUSED TO MEASURE — and makes no claim in either
// direction. An empty population is never a pass.
//
// Exit codes:
//   0 — every control init() looks up is wired, and every handler it names exists
//   1 — at least one is not: each is named
//   2 — the instrument lost its footing and is making NO claim either way
//
// Run: node cloud/priv/static/__init_wiring_census.mjs
//      node cloud/priv/static/__init_wiring_census.mjs <app.js>
//   (the argv override exists so a mutation driver can point the census at a
//    patched COPY without writing inside app.js; CI passes no argv at all and
//    measures the shipped file.)

import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const APP = process.argv[2] || path.join(here, "app.js");
const APP_LABEL = process.argv[2] || "cloud/priv/static/app.js";

// ── THE ONE REFUSAL VOCABULARY (cch-w63-bl) ─────────────────────────────────
// EVERY exit-2 path in this file ends with exactly ONE line, on STDERR:
//
//     !! INIT WIRING CENSUS (exit 2): REFUSED TO MEASURE — <reason>
//
// THE READER IS scripts/console-refusal-capture.mjs, and its unit test
// ENUMERATES this file from source: a new exit-2 path that does not go through
// `refuse2` reds that test, and so does a SECOND `process.exit(2)` anywhere in
// this file. Do not add one.
const REFUSAL_NAME = "INIT WIRING CENSUS";
const refuse2 = (reason) => {
  process.stderr.write(`!! ${REFUSAL_NAME} (exit 2): REFUSED TO MEASURE — ${reason}\n`);
  process.exit(2);
};

function die2(lines) {
  console.error("");
  for (const l of lines) console.error(l);
  console.error("");
  console.error("  Nothing here says the console's controls are wired and nothing says they are");
  console.error("  not. A census that cannot parse init() must not go green — an empty population");
  console.error("  satisfies every question below vacuously.");
  refuse2(String(lines[0] || "the census could not read its input").replace(/^FAIL\(2\):\s*/, ""));
}

if (!fs.existsSync(APP)) die2([`FAIL(2): ${APP_LABEL} not readable at ${APP}.`]);
const src = fs.readFileSync(APP, "utf8");
const lineOf = (idx) => src.slice(0, idx).split("\n").length;

// ═══════════════════════════════════════════════════════════════════════════
// (0) LOCATE init(), EXACTLY ONCE.
// ═══════════════════════════════════════════════════════════════════════════

// Anchored on the declaration at its own indentation inside the console IIFE.
// A bare `function init(` would also match a nested or renamed helper; the
// leading newline + two spaces is the shipped shape and has been since the file
// was written. If init() is renamed or re-indented, this REFUSES rather than
// measures an empty init.
const ANCHOR = "\n  function init() {";
const anchorHits = src.split(ANCHOR).length - 1;
if (anchorHits !== 1) {
  die2([
    `FAIL(2): the init() anchor ${JSON.stringify(ANCHOR)} occurs ${anchorHits} time(s) in ${APP_LABEL}; exactly one is required.`,
    "  Zero means init() was renamed, re-indented or removed — in which case the console's",
    "  listeners are attached somewhere this census has never looked, and its silence would be",
    "  worth nothing. More than one means the anchor no longer identifies a single function.",
    "  Re-point the anchor in the SAME commit that moves it.",
  ]);
}
const anchorAt = src.indexOf(ANCHOR);
const bodyStart = src.indexOf("{", anchorAt);

// ── THE SCANNER ────────────────────────────────────────────────────────────
// Brace-walks init()'s body, skipping string literals and comments, and records
// for every offset how many FUNCTION bodies enclose it (relative to init). That
// second number is what separates a WIRING statement from a lookup inside a
// handler: `var menu = $("#scope-menu");` inside a click handler is a read, not
// a wiring, and counting it as an orphan would red a healthy tree.
//
// Regex literals are deliberately NOT lexed. They do not need to be: if one
// ever confuses this walk, the brace depth does not return to zero and the walk
// REFUSES below rather than reporting a truncated body.
const fnDepthAt = new Int32Array(src.length);
let stack = [];
let bodyEnd = -1;
{
  const fnOpen = /(?:function\s*[A-Za-z_$][\w$]*\s*\([^()]*\)\s*|function\s*\([^()]*\)\s*|\)\s*=>\s*|\b[A-Za-z_$][\w$]*\s*=>\s*)$/;
  let j = bodyStart;
  for (; j < src.length; j++) {
    const c = src[j];
    const n = src[j + 1];
    if (c === "/" && n === "/") {
      while (j < src.length && src[j] !== "\n") { fnDepthAt[j] = stack.length; j++; }
      j--;
      continue;
    }
    if (c === "/" && n === "*") {
      const close = src.indexOf("*/", j + 2);
      if (close === -1) break;
      for (let k = j; k <= close + 1; k++) fnDepthAt[k] = stack.length;
      j = close + 1;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const q = c;
      fnDepthAt[j] = stack.length;
      j++;
      while (j < src.length && src[j] !== q) {
        if (src[j] === "\\") { fnDepthAt[j] = stack.length; j++; }
        fnDepthAt[j] = stack.length;
        j++;
      }
      fnDepthAt[j] = stack.length;
      continue;
    }
    if (c === "{") {
      const before = src.slice(Math.max(0, j - 300), j);
      stack.push(fnOpen.test(before));
      fnDepthAt[j] = stack.length;
      continue;
    }
    if (c === "}") {
      fnDepthAt[j] = stack.length;
      stack.pop();
      if (stack.length === 0) { bodyEnd = j; break; }
      continue;
    }
    fnDepthAt[j] = stack.length;
  }
}
if (bodyEnd === -1) {
  die2([
    `FAIL(2): init()'s body in ${APP_LABEL} does not brace-balance — the walk ran off the end of the file.`,
    "  The census cannot say where init() stops, so it cannot say what is inside it. This is the",
    "  scanner losing its footing (an unterminated string, a comment, or a regex literal it",
    "  mis-lexed), not a clean tree.",
  ]);
}
const body = src.slice(bodyStart + 1, bodyEnd);
const OFF = bodyStart + 1;
// fnDepth relative to init(): init()'s own statement level is 1 in the absolute
// stack (init's own brace), so subtract it. A nested handler body is >= 1.
const relDepth = (bodyIdx) => fnDepthAt[OFF + bodyIdx] - 1;

// ═══════════════════════════════════════════════════════════════════════════
// (1) THE POPULATION — (target, event, handler) triples, parsed from init().
// ═══════════════════════════════════════════════════════════════════════════

// Group 1: the target expression, either a bare identifier / `document` /
// `window`, or an inline `$("#selector")` lookup (group 2 = its literal).
// Group 3: the event name literal. Group 4: the handler — an inline `function (`
// or a bare identifier that closes the call.
const CALL_RE =
  /([A-Za-z_$][\w$]*|\$\(\s*("(?:[^"\\]|\\.)*")\s*\))\s*\.addEventListener\s*\(\s*("(?:[^"\\]|\\.)*")\s*,\s*(function\s*\(|[A-Za-z_$][\w$]*\s*\))/g;

const triples = [];
for (const m of body.matchAll(CALL_RE)) {
  triples.push({
    idx: m.index,
    line: lineOf(OFF + m.index),
    depth: relDepth(m.index),
    targetRaw: m[1],
    selector: m[2] ? JSON.parse(m[2]) : null,
    event: JSON.parse(m[3]),
    handler: m[4].startsWith("function") ? null : m[4].replace(/\s*\)$/, ""),
  });
}

// ── THE ACCOUNTING CONTROL: every call site is parsed, or the census refuses ──
// `.addEventListener(` with an open paren is a CALL. `if (x.addEventListener)`
// — the capability test init() writes before the matchMedia legacy fallback —
// has no paren and is deliberately not counted. If the two numbers ever diverge
// the extractor has stopped understanding a shape init() uses, and the honest
// answer is "I could not read it", never a near-pass that quotes a count. The
// FAIL(2) below therefore states BOTH counts straight out of THIS run — the
// literal call sites and the parsed triples — and refuses. Nothing about the
// size of the population is typed into that message, because a typed one is
// stale the next time a control lands, and then it misdirects the operator who
// is reading the failure.
const rawCalls = [...body.matchAll(/\.addEventListener\s*\(/g)];
if (rawCalls.length !== triples.length) {
  const parsedEnds = new Set(triples.map((t) => body.indexOf(".addEventListener", t.idx)));
  const unparsed = rawCalls.filter((r) => !parsedEnds.has(r.index)).map((r) => lineOf(OFF + r.index));
  die2([
    `FAIL(2): init() holds ${rawCalls.length} literal \`.addEventListener(\` call site(s) but only ${triples.length} parsed into a (target, event, handler) triple.`,
    `  Unparsed call site(s) at ${APP_LABEL}:${unparsed.join(", ")}`,
    "  A call site the extractor cannot read is a control this census cannot vouch for, so it",
    "  vouches for NONE of them. Teach CALL_RE the new shape in the same commit that writes it.",
  ]);
}

// ── THE STATED POPULATION, AND THE FLOOR ────────────────────────
// Two constants doing two different jobs, failing in opposite directions.
//
// STATED_POPULATION is a RECEIPT: the population this file was last ratified
// against. It is not a roster (it names nothing) and it is not a threshold. Its
// arm reds when it disagrees with the live count IN EITHER DIRECTION — one
// control removed and one control added both land here — so no number a reader
// can take out of this file can survive disagreeing with what the census
// prints. That is the defect this block was rewritten to close: the prose used
// to quote a population, the console grew, and the file went on inviting the
// reader to run it and confirm a figure it no longer printed.
//
// POPULATION_FLOOR is a RATCHET, and it is deliberately NOT computed from the
// live count. A floor derived from the very population it guards cannot fail:
// a collapsing extractor would drag the floor down with it and the guard would
// report a serene green over a population of zero, which is the one failure the
// floor exists to catch. So the floor is a fixed number a person raises on
// purpose. It is slack on purpose too — a WIRING change is caught by the two
// derived arms below, not here.
//
// A RATCHET FAILS IN TWO DIRECTIONS, and only one of them is obvious:
//   * the world gets WORSE — the population falls under the floor. Exit 2; the
//     census makes no claim in either direction.
//   * the world gets BETTER — the console grows, and a floor left at its old
//     value silently guards a smaller and smaller fraction of it. Nothing reds.
//     So RATIFIED_RATIO below recomputes what the floor WOULD be at the ratio
//     it was ratified at, and reds when the shipped floor has fallen behind.
//     THE COMPARISON IS ONE-WAY ON PURPOSE: a derived value ABOVE the shipped
//     floor is a demand to raise it; a derived value BELOW it changes nothing.
//     A shrinking console therefore can never drag this floor down — a shrink
//     reds the STATED_POPULATION pin instead, and a human decides what it means.
//
// WHAT THIS DOES NOT OWN (charter D40 — a check states its boundary). Nothing
// here can stop a person editing BOTH constants downward in one commit; that is
// two literal lines in a diff and it belongs to review, not to a guard that
// would be reading its expected value out of the thing it guards. What these
// arms buy is that such an edit must be DELIBERATE and VISIBLE. Drift alone
// never gets there.
const STATED_POPULATION = 33;
const POPULATION_FLOOR = 24;
const RATIFIED_RATIO = 3 / 4; // POPULATION_FLOOR === Math.floor(STATED_POPULATION * RATIFIED_RATIO)

if (triples.length < POPULATION_FLOOR) {
  die2([
    `FAIL(2): init() parsed to ${triples.length} listener triple(s); the floor is ${POPULATION_FLOOR}.`,
    "  A population this small is an extractor that has stopped seeing the shapes init() writes,",
    "  not a console that lost two thirds of its controls. Every question below would be",
    "  vacuously satisfied, so the census refuses to ask them.",
  ]);
}

// THE PIN. Pure, so its own controls below can drive it on fabricated inputs.
function populationPinErrors(stated, live) {
  if (!Number.isInteger(live) || live <= 0) {
    return [
      `FAIL(2): the population pin has NO SUBJECT — init() parsed to ${live} triple(s).`,
      "  A pin compared against nothing agrees with nothing and refutes nothing. Whatever this",
      "  run reported about wiring was measured over an empty population; fix the extractor.",
    ];
  }
  if (!Number.isInteger(stated) || stated <= 0) {
    return [
      `FAIL(2): STATED_POPULATION in this file is ${stated}, which is not a population.`,
      "  The pin can then be neither satisfied nor refuted, so it is not a check at all. Set it to",
      "  the number the census prints on a green run.",
    ];
  }
  if (stated === live) return [];
  const verb = live > stated ? "GREW" : "SHRANK";
  return [
    `FAIL(2): this file states the population is ${stated} listener triple(s); init() parses to ${live}. It ${verb}.`,
    "  This is not a wiring failure — the derived arms below decide that. It is this FILE going",
    "  stale: the prose, the floor's justification and the messages here are all written against a",
    "  population that has moved, and a reader who follows the invitation to run the census now",
    "  gets a number that contradicts the file that invited them.",
    `  Set STATED_POPULATION to ${live} and re-read the floor: at the ratified ratio the floor`,
    `  would be ${Math.floor(live * RATIFIED_RATIO)} and it ships as ${POPULATION_FLOOR}. Raising it is a decision someone makes;`,
    "  lowering it is not something a shrinking console gets to do on its own.",
  ];
}

// THE RATCHET'S SECOND DIRECTION. One-way by construction: it can only ever ASK
// for a HIGHER floor. It returns [] whenever the derived value is at or below
// the shipped one, which is exactly what a shrunken population produces.
function floorRatchetErrors(stated, floor, ratio) {
  const derived = Math.floor(stated * ratio);
  if (!(derived > floor)) return [];
  return [
    `FAIL(2): the population is ratified at ${stated} but POPULATION_FLOOR is still ${floor}.`,
    `  At the ratified ratio the floor should be ${derived}. A floor left behind a growing console`,
    "  guards an ever smaller fraction of it: the extractor could lose a third of the shapes it",
    "  reads and still clear a threshold set for a much smaller console. Raise POPULATION_FLOOR",
    `  to ${derived} in the same commit that raised STATED_POPULATION.`,
  ];
}

{
  const pinErrs = populationPinErrors(STATED_POPULATION, triples.length);
  if (pinErrs.length) die2(pinErrs);
  const ratchetErrs = floorRatchetErrors(STATED_POPULATION, POPULATION_FLOOR, RATIFIED_RATIO);
  if (ratchetErrs.length) die2(ratchetErrs);
}

// THE ARMS' OWN CONTROLS, run INSIDE the measurement rather than in a test that
// could stop being run — CI invokes this file bare, so these ride the gate step
// that already exists. The two calls above can only ever print a clean nothing;
// these say whether that nothing was MEASURED. Each drives the same function
// the gate just used, on fabricated inputs, and a failing control is itself an
// exit-2 refusal: an instrument that cannot show its arms fire makes no claim.
{
  const ctl = [];
  const grew = populationPinErrors(STATED_POPULATION, STATED_POPULATION + 1);
  if (!(grew.length && grew[0].includes("It GREW"))) {
    ctl.push("FAIL(2): the population pin FAILED ITS OWN CONTROL — a live count one ABOVE the stated one did not red.");
  }
  const shrank = populationPinErrors(STATED_POPULATION, STATED_POPULATION - 1);
  if (!(shrank.length && shrank[0].includes("It SHRANK"))) {
    ctl.push("FAIL(2): the population pin FAILED ITS OWN CONTROL — a live count one BELOW the stated one did not red.");
  }
  if (populationPinErrors(STATED_POPULATION, STATED_POPULATION).length) {
    ctl.push("FAIL(2): the population pin FAILED ITS OWN CONTROL — an AGREEING count was reported as a mismatch, so the clean verdict this run printed is noise.");
  }
  if (!populationPinErrors(STATED_POPULATION, 0).length) {
    ctl.push("FAIL(2): the population pin FAILED ITS OWN CONTROL — an EMPTY population was accepted, so an extractor that found nothing would read as a satisfied pin.");
  }
  if (!floorRatchetErrors(STATED_POPULATION * 10, POPULATION_FLOOR, RATIFIED_RATIO).length) {
    ctl.push("FAIL(2): the floor ratchet FAILED ITS OWN CONTROL — a ten-fold larger ratified population did not demand a higher floor, so the world getting BETTER would stay silent.");
  }
  if (floorRatchetErrors(1, POPULATION_FLOOR, RATIFIED_RATIO).length) {
    ctl.push("FAIL(2): the floor ratchet FAILED ITS OWN CONTROL — a ratified population of one DEMANDED a change, which means a shrinking console can drag the floor down. That is the ratchet running backwards, and it is worse than no ratchet.");
  }
  if (ctl.length) {
    die2([
      ...ctl,
      "  These arms guard the numbers this file states about itself. If they cannot be shown to",
      "  fire, nothing this run printed about the population is evidence of anything.",
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// (2) THE LOCAL BINDINGS — `var name = $("#selector");` at init()'s own level.
// ═══════════════════════════════════════════════════════════════════════════

const BIND_RE = /\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=\s*\$\(\s*("(?:[^"\\]|\\.)*")\s*\)\s*;/g;
const bindings = new Map(); // name -> { selector, line }
for (const m of body.matchAll(BIND_RE)) {
  if (relDepth(m.index) !== 0) continue; // a lookup inside a handler body is a READ
  bindings.set(m[1], { selector: JSON.parse(m[2]), line: lineOf(OFF + m.index) });
}

// Every `$( … )` evaluated at init()'s own level must take a STRING LITERAL. A
// computed selector (`$("#row-" + id)`) cannot be resolved to a control name,
// and a census that silently skipped it would go quiet on exactly the wiring it
// could not read.
const DOLLAR_RE = /\$\(\s*([^)]*)\)/g;
const unreadable = [];
for (const m of body.matchAll(DOLLAR_RE)) {
  if (relDepth(m.index) !== 0) continue;
  if (!/^"(?:[^"\\]|\\.)*"$/.test(m[1].trim())) unreadable.push(lineOf(OFF + m.index));
}
if (unreadable.length) {
  die2([
    `FAIL(2): init() evaluates \`$( … )\` with a non-literal argument at ${APP_LABEL}:${unreadable.join(", ")}.`,
    "  This census names controls BY SELECTOR. A computed selector has no name it can print, so",
    "  it cannot say whether that control is wired — and it will not pretend the rest of the",
    "  population answers for it.",
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// (3) ARM A — ORPHANED LOOKUP. A control init() looked up and never wired.
// ═══════════════════════════════════════════════════════════════════════════

// Selectors that DID reach a listener: inline `$("#sel").addEventListener(…)`,
// or a binding whose name is a listener target.
const wiredSelectors = new Set();
const wiredNames = new Set();
for (const t of triples) {
  if (t.selector) wiredSelectors.add(t.selector);
  else wiredNames.add(t.targetRaw);
}
for (const [name, b] of bindings) {
  if (wiredNames.has(name)) wiredSelectors.add(b.selector);
}

// Every selector init() looks up at its own level, inline or bound.
const lookedUp = new Map(); // selector -> line
for (const m of body.matchAll(/\$\(\s*("(?:[^"\\]|\\.)*")\s*\)/g)) {
  if (relDepth(m.index) !== 0) continue;
  const sel = JSON.parse(m[1]);
  if (!lookedUp.has(sel)) lookedUp.set(sel, lineOf(OFF + m.index));
}

const orphans = [...lookedUp].filter(([sel]) => !wiredSelectors.has(sel));

// ═══════════════════════════════════════════════════════════════════════════
// (4) ARM B — DANGLING HANDLER. A listener naming a function nobody wrote.
// ═══════════════════════════════════════════════════════════════════════════

const declared = (name) => {
  const n = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(
    `(^|\\n)\\s*function\\s+${n}\\s*\\(` +          // function declaration
    `|(^|\\n)\\s*(?:var|let|const)\\s+${n}\\s*=` +  // binding
    `|\\b${n}\\s*=\\s*function\\s*\\(`,             // assignment to a function
  ).test(src);
};

const dangling = triples
  .filter((t) => t.handler && !declared(t.handler))
  .map((t) => ({ ...t, control: t.selector || bindings.get(t.targetRaw)?.selector || t.targetRaw }));

// ═══════════════════════════════════════════════════════════════════════════
// (5) THE VERDICT.
// ═══════════════════════════════════════════════════════════════════════════

if (orphans.length || dangling.length) {
  console.error("");
  console.error("FAIL(1): init()'s wiring does not hold together.");
  console.error("");
  for (const [sel, line] of orphans) {
    console.error(`  UNWIRED CONTROL   ${sel}   looked up at ${APP_LABEL}:${line}, never passed to addEventListener`);
  }
  if (orphans.length) {
    console.error("");
    console.error("  init() resolved these controls and then attached nothing to them. Every handler");
    console.error("  behind them can stay perfectly correct and perfectly tested — the button still");
    console.error("  does nothing when a person clicks it. Wire it, or stop looking it up.");
    console.error("");
  }
  for (const d of dangling) {
    console.error(`  DANGLING HANDLER  ${d.control}   ${APP_LABEL}:${d.line}   addEventListener("${d.event}", ${d.handler}) — ${d.handler} is not declared in ${APP_LABEL}`);
  }
  if (dangling.length) {
    console.error("");
    console.error("  A listener wired to a name nothing declares throws at CLICK TIME, in a browser,");
    console.error("  in front of a person. No node test reaches it: the handler under test does not");
    console.error("  exist to be called.");
    console.error("");
  }
  console.error(`  population: ${triples.length} listener triple(s) parsed from init() (${APP_LABEL}:${lineOf(bodyStart)}-${lineOf(bodyEnd)})`);
  console.error(`  controls looked up at init()'s own level: ${lookedUp.size}; wired: ${wiredSelectors.size}`);
  console.error("");
  process.exit(1);
}

const named = triples.filter((t) => t.handler).length;
const byEvent = {};
for (const t of triples) byEvent[t.event] = (byEvent[t.event] || 0) + 1;
console.log("");
console.log(`OK: all ${lookedUp.size} control(s) init() looks up are wired, and all ${named} named handler(s) exist.`);
console.log(`    init() at ${APP_LABEL}:${lineOf(bodyStart)}-${lineOf(bodyEnd)}`);
console.log(`    population: ${triples.length} (target, event, handler) triple(s), pinned; floor ${POPULATION_FLOOR} (raise-only); ${rawCalls.length} literal call site(s), all accounted for`);
console.log(`    events: ${Object.entries(byEvent).sort().map(([e, n]) => `${e}×${n}`).join(", ")}`);
console.log(`    handlers: ${named} named, ${triples.length - named} inline`);
console.log(`    selectors: ${[...lookedUp.keys()].sort().join(" ")}`);
process.exit(0);

// __formula.test.mjs — pure-Node unit harness for the Studio sheet formula
// kernel (api/priv/static/assets/bp-sheet-formula.js).
//
// The kernel is a browser IIFE that assigns `window.BarkparkSheetFormula`. It
// has no DOM coupling, but we still load the SHIPPED file verbatim inside a
// node:vm sandbox (a bare `window`) — same house pattern as __hook.test.mjs —
// so a regression in the committed bundle reds the gate, not a stale copy.
//
// Run: node __formula.test.mjs   (or: npm test)
//
// Coverage: the full caretContext contract table (incl. string-literal traps),
// the F4 $-cycle table (cells, ranges, whole-col/row), the insert/replace/
// extend matrix, depth-aware argIndex across nested fns, refColorIndex
// stability + 8-slot wrap, and normalizeFormula (fn/ref upcase, string safety,
// paren balancing, non-formula passthrough).

import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";

const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(new URL("../../priv/static/assets/bp-sheet-formula.js", import.meta.url), "utf8"),
  sandbox,
);
const F = sandbox.window.BarkparkSheetFormula;
assert.ok(F, "BarkparkSheetFormula must be assigned on window");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// Compact assert helpers: caret position is the char index where a "|" sits.
function ctx(value, caret, hot) {
  return F.caretContext(value, caret, hot || null);
}
function actionAt(value, caret, hot) {
  return ctx(value, caret, hot).action;
}
// Spans come back from the vm sandbox realm, so their prototype differs from
// the test realm's — assert.deepEqual (strict) rejects cross-realm objects.
// Compare the fields directly.
function spanEq(span, start, end) {
  assert.ok(span, "expected a span");
  assert.equal(span.start, start, "span.start");
  assert.equal(span.end, end, "span.end");
}

// ── (a) tokenize ────────────────────────────────────────────────────────────

check("tokenize is lossless (concatenated text === input)", () => {
  const inputs = [
    '=SUM(B3:B5)', '=IF(A1>0,"yes","no")', '=$A$1+B$2-$C3',
    '=A:A+3:3', 'hello world', '=CONCATENATE("(",A1)', '= 1 + 2 ',
  ];
  for (const s of inputs) {
    const t = F.tokenize(s);
    assert.equal(t.map((x) => x.text).join(""), s, `lossless for ${s}`);
    // start/end index integrity
    for (const tok of t) assert.equal(s.slice(tok.start, tok.end), tok.text);
  }
});

check("tokenize classifies fn vs ref vs range vs whole-col/row", () => {
  const t = F.tokenize("=SUM(B3:B5)+A1+B:B+3:3");
  const byText = {};
  for (const x of t) byText[x.text] = x.type;
  assert.equal(byText["SUM"], "fn");
  assert.equal(byText["B3:B5"], "ref");
  assert.equal(byText["A1"], "ref");
  assert.equal(byText["B:B"], "ref");
  assert.equal(byText["3:3"], "ref");
  assert.equal(byText["("], "paren");
});

check("tokenize: ref-shaped LOG10( is a ref, not a fn (grid _fnToken parity)", () => {
  const t = F.tokenize("=LOG10(A1)");
  const log = t.find((x) => x.text === "LOG10");
  assert.equal(log.type, "ref");
  const norm = t.find((x) => x.text === "NORM.DIST");
  assert.equal(norm, undefined);
  const t2 = F.tokenize("=NORM.DIST(A1)");
  assert.equal(t2.find((x) => x.text === "NORM.DIST").type, "fn");
});

check("tokenize: string literal absorbs parens/commas + handles \"\" escape", () => {
  const t = F.tokenize('=A1&"a,(b)"&"say ""hi"""');
  const strs = t.filter((x) => x.type === "str");
  assert.equal(strs[0].text, '"a,(b)"');
  assert.equal(strs[1].text, '"say ""hi"""');
  // no comma/paren tokens leaked out of the strings
  assert.equal(t.filter((x) => x.type === "comma").length, 0);
  assert.equal(t.filter((x) => x.type === "paren").length, 0);
});

check("tokenize: depth — matching parens share depth, content is deeper", () => {
  const t = F.tokenize("=IF(SUM(A1),1)");
  const opens = t.filter((x) => x.text === "(");
  const closes = t.filter((x) => x.text === ")");
  assert.equal(opens[0].depth, 0);
  assert.equal(closes[closes.length - 1].depth, 0); // outer ) back to 0
  const a1 = t.find((x) => x.text === "A1");
  assert.equal(a1.depth, 2); // inside IF( SUM(
});

// ── (b) caretContext — the contract table ────────────────────────────────────

check("row 1: value not starting '=' -> commit", () => {
  assert.equal(actionAt("hello", 3), "commit");
  assert.equal(actionAt("123", 2), "commit");
  assert.equal(ctx("hello", 3).inString, false);
});

check("row 2: caret inside a string literal -> commit (inString)", () => {
  // =CONCATENATE("(",A1) — caret right after the '(' that lives inside quotes
  const v = '=CONCATENATE("(",A1)';
  const inner = v.indexOf('"(') + 2; // just after the inner '('
  const c = ctx(v, inner);
  assert.equal(c.action, "commit");
  assert.equal(c.inString, true);
});

check("row 2b: comma inside a string does not open a new arg / point ctx", () => {
  const v = '=SUM("a,b")';
  const mid = v.indexOf(",") + 1; // caret right after the comma INSIDE the string
  const c = ctx(v, mid);
  assert.equal(c.action, "commit");
  assert.equal(c.inString, true);
  assert.equal(c.argIndex, 0); // the string comma must NOT bump argIndex
});

check("row 3: caret at end of hotSpan -> point-replace that span", () => {
  const v = "=SUM(B3:B5";
  const hot = { start: 5, end: 10 };
  const c = ctx(v, 10, hot);
  assert.equal(c.action, "point-replace");
  spanEq(c.span, 5, 10);
});

check("row 4: caret inside/adjacent an existing ref -> point-replace the ref", () => {
  // inside B3:B5
  let c = ctx("=SUM(B3:B5)", 7);
  assert.equal(c.action, "point-replace");
  spanEq(c.span, 5, 10);
  // adjacent (right after) A1
  c = ctx("=A1", 3);
  assert.equal(c.action, "point-replace");
  spanEq(c.span, 1, 3);
  // adjacent (left edge) of B2
  c = ctx("=A1+B2", 4);
  assert.equal(c.action, "point-replace");
  spanEq(c.span, 4, 6);
});

check("row 5: caret after = ( , : or operator -> point-insert", () => {
  assert.equal(actionAt("=", 1), "point-insert"); // after =
  assert.equal(actionAt("=SUM(", 5), "point-insert"); // after (
  assert.equal(actionAt("=SUM(A1,", 8), "point-insert"); // after ,
  assert.equal(actionAt("=A1+", 4), "point-insert"); // after +
  assert.equal(actionAt("=A1*", 4), "point-insert"); // after *
  assert.equal(actionAt("=A1&", 4), "point-insert"); // after &
  assert.equal(actionAt("=A1>", 4), "point-insert"); // after >
  assert.equal(actionAt("=SUM( ", 6), "point-insert"); // spaces allowed between
  assert.equal(actionAt("=B3:", 4), "point-insert"); // after : (mid-range)
});

check("row 6: after ) or a complete literal/expression -> commit", () => {
  assert.equal(actionAt("=SUM(A1)", 8), "commit"); // after )
  assert.equal(actionAt("=5", 2), "commit"); // after a number literal
  assert.equal(actionAt('=A1&"x"', 7), "commit"); // after a closed string literal
});

check("caretContext: fnName + depth-aware argIndex across nested fns", () => {
  const v = "=IF(SUM(A1,B1),1,2)";
  // caret right after 'A1,' — inside SUM, second arg
  const afterA1comma = v.indexOf("A1,") + 3;
  let c = ctx(v, afterA1comma);
  assert.equal(c.fnName, "SUM");
  assert.equal(c.argIndex, 1);
  // caret at the '1' after 'SUM(...),' — inside IF, second arg
  const at1 = v.indexOf("),1") + 2;
  c = ctx(v, at1);
  assert.equal(c.fnName, "IF");
  assert.equal(c.argIndex, 1);
  // caret at the '2' — inside IF, third arg
  const at2 = v.indexOf(",2") + 1;
  c = ctx(v, at2);
  assert.equal(c.fnName, "IF");
  assert.equal(c.argIndex, 2);
});

// ── (c) insertRef — insert vs replace ────────────────────────────────────────

check("insertRef: point-insert splices at caret + reports the new span", () => {
  const r = F.insertRef("=SUM(", 5, "B3:B5");
  assert.equal(r.value, "=SUM(B3:B5");
  assert.equal(r.caret, 10);
  spanEq(r.span, 5, 10);
});

check("insertRef: point-replace overwrites an adjacent ref", () => {
  // caret at end of A1 -> replace A1 with B7
  const r = F.insertRef("=SUM(A1", 7, "B7");
  assert.equal(r.value, "=SUM(B7");
  spanEq(r.span, 5, 7);
});

check("insertRef: hotSpan makes a live drag replace-in-place, not stack", () => {
  // first drop
  let r = F.insertRef("=SUM(", 5, "B3:B5");
  // drag moves — pass the reported span back as hotSpan
  r = F.insertRef(r.value, r.caret, "B3:B7", r.span);
  assert.equal(r.value, "=SUM(B3:B7");
  spanEq(r.span, 5, 10);
});

// ── (d) extendRef ────────────────────────────────────────────────────────────

check("extendRef: single ref -> anchor:endRef normalized top-left:bottom-right", () => {
  // =SUM(B3  span of B3 = {5,7}; shift-click B5 -> B3:B5
  let r = F.extendRef("=SUM(B3", { start: 5, end: 7 }, "B5");
  assert.equal(r.value, "=SUM(B3:B5");
  spanEq(r.span, 5, 10);
  // reverse direction still normalizes to top-left:bottom-right
  r = F.extendRef("=SUM(B5", { start: 5, end: 7 }, "B3");
  assert.equal(r.value, "=SUM(B3:B5");
  // $ flags follow the contributing corner
  r = F.extendRef("=$B$5", { start: 1, end: 5 }, "D3");
  assert.equal(r.value, "=$B3:D$5");
});

check("extendRef: existing range extends from its first cell", () => {
  const r = F.extendRef("=SUM(B3:B5)", { start: 5, end: 10 }, "B8");
  assert.equal(r.value, "=SUM(B3:B8)");
});

check("extendRef: whole-col header drag B:B -> D gives B:D (normalized)", () => {
  // header drag hands endRef as 'D:D' or bare 'D' — both extend
  let r = F.extendRef("=SUM(B:B", { start: 5, end: 8 }, "D:D");
  assert.equal(r.value, "=SUM(B:D");
  spanEq(r.span, 5, 8);
  // reverse direction still normalizes low:high
  r = F.extendRef("=SUM(D:D", { start: 5, end: 8 }, "B");
  assert.equal(r.value, "=SUM(B:D");
  // $ rides its contributing side
  r = F.extendRef("=SUM($B:$B", { start: 5, end: 10 }, "D");
  assert.equal(r.value, "=SUM($B:D");
});

check("extendRef: whole-row header drag 3:3 -> 5 gives 3:5 (normalized)", () => {
  let r = F.extendRef("=SUM(3:3", { start: 5, end: 8 }, "5:5");
  assert.equal(r.value, "=SUM(3:5");
  r = F.extendRef("=SUM(5:5", { start: 5, end: 8 }, "3");
  assert.equal(r.value, "=SUM(3:5");
});

// ── (e) cycleDollar — the F4 table ──────────────────────────────────────────

check("F4 cell cycle A1 -> $A$1 -> A$1 -> $A1 -> A1", () => {
  const seq = ["=A1", "=$A$1", "=A$1", "=$A1", "=A1"];
  let v = seq[0];
  for (let i = 1; i < seq.length; i++) {
    const r = F.cycleDollar(v, v.length); // caret at end (immediately-left of caret)
    assert.equal(r.value, seq[i], `${v} -> ${seq[i]}`);
    v = r.value;
  }
});

check("F4 range cycles BOTH endpoints in lockstep", () => {
  const seq = ["=B3:B5", "=$B$3:$B$5", "=B$3:B$5", "=$B3:$B5", "=B3:B5"];
  let v = seq[0];
  for (let i = 1; i < seq.length; i++) {
    const r = F.cycleDollar(v, v.length);
    assert.equal(r.value, seq[i], `${v} -> ${seq[i]}`);
    v = r.value;
  }
});

check("F4 whole-col two-state B:B -> $B:$B -> B:B", () => {
  let r = F.cycleDollar("=B:B", 4);
  assert.equal(r.value, "=$B:$B");
  r = F.cycleDollar(r.value, r.value.length);
  assert.equal(r.value, "=B:B");
});

check("F4 whole-row two-state 3:3 -> $3:$3 -> 3:3", () => {
  let r = F.cycleDollar("=3:3", 4);
  assert.equal(r.value, "=$3:$3");
  r = F.cycleDollar(r.value, r.value.length);
  assert.equal(r.value, "=3:3");
});

check("F4: no ref under caret -> null", () => {
  assert.equal(F.cycleDollar("=1+2", 4), null);
  assert.equal(F.cycleDollar("hello", 3), null);
  assert.equal(F.cycleDollar("=SUM(", 5), null);
});

check("F4: caret placed at end acts on the ref immediately to its left", () => {
  // =A1+B2 caret at end -> cycles B2, leaves A1 alone
  const r = F.cycleDollar("=A1+B2", 6);
  assert.equal(r.value, "=A1+$B$2");
});

// ── (f) refColorIndex ────────────────────────────────────────────────────────

check("refColorIndex: first-occurrence order, same ref same slot", () => {
  const m = F.refColorIndex("=A1+B2+A1+C3");
  assert.equal(m["A1"], 0);
  assert.equal(m["B2"], 1);
  assert.equal(m["C3"], 2);
  assert.equal(Object.keys(m).length, 3); // A1 not double-counted
});

check("refColorIndex: normalization groups case + range order", () => {
  const m = F.refColorIndex("=a1+A1+B5:B3+B3:B5");
  assert.equal(m["A1"], 0); // a1 and A1 share the slot
  assert.equal(m["B3:B5"], 1); // B5:B3 normalizes to B3:B5, same slot
  assert.equal(Object.keys(m).length, 2);
});

check("refColorIndex: 9th distinct ref wraps to slot 0", () => {
  const m = F.refColorIndex("=A1+A2+A3+A4+A5+A6+A7+A8+A9");
  assert.equal(m["A8"], 7);
  assert.equal(m["A9"], 0); // 8 slots, wrap
});

// ── (g) normalizeFormula ─────────────────────────────────────────────────────

check("normalizeFormula: upcases fn + refs and balances trailing parens", () => {
  assert.equal(F.normalizeFormula("=sum(b3:b5", ["SUM"]), "=SUM(B3:B5)");
  assert.equal(F.normalizeFormula("=sum(b3:b5"), "=SUM(B3:B5)"); // knownFns omitted
  assert.equal(F.normalizeFormula("=if(and(a1,b1", ["IF", "AND"]), "=IF(AND(A1,B1))");
});

check("normalizeFormula: string literals are left untouched", () => {
  assert.equal(F.normalizeFormula('=concatenate("sum(",a1', ["CONCATENATE"]), '=CONCATENATE("sum(",A1)');
});

check("normalizeFormula: unknown fn stays as typed when a list is given", () => {
  assert.equal(F.normalizeFormula("=frobnicate(a1", ["SUM"]), "=frobnicate(A1)");
});

check("normalizeFormula: non-formula returned untouched, never over-balances", () => {
  assert.equal(F.normalizeFormula("hello"), "hello");
  assert.equal(F.normalizeFormula("=A1)"), "=A1)"); // extra ) is never removed
  assert.equal(F.normalizeFormula(""), "");
});

// ── the end-to-end wish ──────────────────────────────────────────────────────

check("wish: type '=sum(', drag B3:B5, Enter -> =SUM(B3:B5)", () => {
  // '=sum(' then point-mode drag drops the range at the caret
  const dropped = F.insertRef("=sum(", 5, "B3:B5");
  assert.equal(dropped.value, "=sum(B3:B5");
  // Enter commits -> normalize upcases + closes the paren
  assert.equal(F.normalizeFormula(dropped.value), "=SUM(B3:B5)");
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall bp-sheet-formula kernel checks PASS");

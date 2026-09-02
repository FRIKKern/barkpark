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
// `passed` exists so the verdict line can carry a COUNT. Without one, a harness
// that silently ran zero checks prints the same triumphant sentence as a harness
// that ran all of them — and the ExUnit gate that shells this file
// (api/test/barkpark_web/live/studio/sheet_grid/js_harness_test.exs) could not
// tell the two apart. It counts checks that COMPLETED, not checks that exist.
let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed++;
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

check("tokenize: ref-shaped LOG10( is a FN (charter amendment A2 — '(' lookahead)", () => {
  // A2 flips wave-1's old ref-typing: the '(' immediately after a ref-shaped
  // identifier proves it is a call, so LOG10( / ATAN2( get fn typing (signature
  // help + point-mode can never clobber the name). A bare LOG10 stays a ref.
  const t = F.tokenize("=LOG10(A1)");
  assert.equal(t.find((x) => x.text === "LOG10").type, "fn");
  assert.equal(t.find((x) => x.text === "(").type, "paren");
  assert.equal(t.find((x) => x.text === "A1").type, "ref");
  assert.equal(F.tokenize("=ATAN2(A1,A2)").find((x) => x.text === "ATAN2").type, "fn");
  // dotted / plain fn names are unaffected by the change
  assert.equal(F.tokenize("=NORM.DIST(A1)").find((x) => x.text === "NORM.DIST").type, "fn");
  // (f) '=LOG10' with NO paren still tokenizes as ONE ref token (addressable cell)
  const bare = F.tokenize("=LOG10");
  assert.equal(bare.filter((x) => x.type === "ref").length, 1);
  assert.equal(bare.find((x) => x.text === "LOG10").type, "ref");
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

// ── amendment A2: fn-vs-ref '(' lookahead (LOG10 / ATAN2) ─────────────────────
// Ripple effects of tokenizing a ref-shaped identifier as a fn when '(' follows.

check("A2 (b): caretContext inside 'LOG10(' (empty first arg) -> point-insert, fnName LOG10, argIndex 0", () => {
  const v = "=LOG10("; // caret in the empty first-arg slot, just after '('
  const c = ctx(v, v.length);
  assert.equal(c.action, "point-insert");
  assert.equal(c.fnName, "LOG10");
  assert.equal(c.argIndex, 0);
});

check("A2 (b): caretContext '=ATAN2(A1,' at end -> fnName ATAN2, argIndex 1", () => {
  const v = "=ATAN2(A1,";
  const c = ctx(v, v.length); // caret after the comma
  assert.equal(c.fnName, "ATAN2");
  assert.equal(c.argIndex, 1);
  assert.equal(c.action, "point-insert");
});

check("A2 (c): refColorIndex('=LOG10(A1)') maps ONLY A1 — the fn eats no hue slot", () => {
  const m = F.refColorIndex("=LOG10(A1)");
  assert.equal(m["A1"], 0);
  assert.equal(m["LOG10"], undefined);
  assert.equal(Object.keys(m).length, 1);
});

check("A2 (d): normalizeFormula('=log10(a1', ['LOG10']) -> '=LOG10(A1)'", () => {
  // fn upcased via knownFns, ref upcased, trailing paren balanced
  assert.equal(F.normalizeFormula("=log10(a1", ["LOG10"]), "=LOG10(A1)");
});

check("A2 (e): caret at END of 'LOG10' (before '(') never point-replaces the fn name", () => {
  const v = "=LOG10(A1)";
  const c = ctx(v, v.indexOf("(")); // caret right before '(' == end of LOG10
  assert.equal(c.action, "commit"); // the clobber case A2 kills: fn tokens are not point targets
  assert.equal(c.span, null); // no span covers the fn name
});

check("A2 (e): F4 on the fn name is a no-op — wave-1 cycled LOG10 to $LOG$10", () => {
  // Pre-A2, LOG10 tokenized as a ref and RE_CELL happily parsed it as column
  // LOG row 10, so F4 with the caret on the name rewrote '=LOG10(A1)' into
  // '=$LOG$10(A1)'. With fn typing, cycleDollar finds no ref under the caret.
  assert.equal(F.cycleDollar("=LOG10(A1)", 4), null); // caret inside the name
  assert.equal(F.cycleDollar("=LOG10(A1)", 6), null); // caret at its end, before '('
  // ...while F4 on the actual ref argument still cycles as ever.
  const r = F.cycleDollar("=LOG10(A1)", 9);
  assert.equal(r.value, "=LOG10($A$1)");
});

check("A2 (f): bare '=LOG10' (no paren) still point-replaces as an addressable ref", () => {
  const c = ctx("=LOG10", 6); // caret at end of the ref
  assert.equal(c.action, "point-replace");
  spanEq(c.span, 1, 6);
});

check("A2 (g): degenerate '=A1(' — the literal rule applies, A1 is a fn (fail-soft)", () => {
  // A1( is not a callable anything, but the A2 rule is literal: '(' after a
  // ref-shape means fn. Fail-soft: fnName 'A1' matches no spec downstream, so
  // no signature help / no ghost — and crucially no point-replace can clobber
  // what the user typed. F4 on it is a no-op (fn, not ref).
  const t = F.tokenize("=A1(B2)");
  assert.equal(t.find((x) => x.text === "A1").type, "fn");
  assert.equal(t.find((x) => x.text === "B2").type, "ref");
  assert.equal(F.cycleDollar("=A1(B2)", 2), null);
  const m = F.refColorIndex("=A1(B2)"); // cross-realm (vm) object: compare structurally
  assert.equal(m["B2"], 0);
  assert.equal(m["A1"], undefined);
  assert.equal(Object.keys(m).length, 1);
});

check("A2 (g): degenerate tails '=$A1(' / '=B3:B5(' — tokenize keeps the REF, scanner surfaces a fail-soft fnName", () => {
  // The '('-lookahead only fires on plain REF_SHAPE (no $ / no ':'), so $A1 and
  // B3:B5 stay refs — but caretContext's cheap one-regex '(' scanner still
  // surfaces the identifier tail ('A1' / 'B5') as fnName. This divergence is
  // BY DESIGN (documented in scanTo): an unknown fnName is fail-soft downstream
  // (no signature strip, no ghost). Pin both halves so neither drifts alone.
  assert.equal(F.tokenize("=$A1(").find((x) => x.text === "$A1").type, "ref");
  assert.equal(F.tokenize("=B3:B5(").find((x) => x.text === "B3:B5").type, "ref");
  assert.equal(ctx("=$A1(", 5).fnName, "A1");
  assert.equal(ctx("=B3:B5(", 7).fnName, "B5");
  // both sit in a point-insert slot (right after '(') — pointing still works
  assert.equal(ctx("=$A1(", 5).action, "point-insert");
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

// ── (h) rebaseFormula — the copy/paste $-aware ref shifter (S-CLIP) ───────────
// The pure-JS twin of structure.ex rebase_formula/3: shift RELATIVE refs by the
// paste delta (dcol,drow), honor $ anchors, collapse off-grid refs to #REF!,
// leave string literals + fn names untouched. The client formula clipboard
// (bp-sheet-grid.js _onPaste) rebuilds the paste grid from these strings.

check("rebaseFormula: charter pin — '=B4+$C$1' by (1,2) -> '=C6+$C$1'", () => {
  assert.equal(F.rebaseFormula("=B4+$C$1", 1, 2), "=C6+$C$1");
});

check("rebaseFormula: absolute anchors are immovable; mixed anchors move one axis", () => {
  assert.equal(F.rebaseFormula("=$A$1", 5, 5), "=$A$1"); // fully pinned
  assert.equal(F.rebaseFormula("=$A1", 1, 1), "=$A2"); // col pinned, row moves
  assert.equal(F.rebaseFormula("=A$1", 1, 1), "=B$1"); // row pinned, col moves
  assert.equal(F.rebaseFormula("=A1", 1, 1), "=B2"); // fully relative
});

check("rebaseFormula: ranges shift BOTH endpoints; fn names untouched", () => {
  assert.equal(F.rebaseFormula("=SUM(B3:B5)", 1, 0), "=SUM(C3:C5)"); // col +1
  assert.equal(F.rebaseFormula("=B3:D5", 0, 2), "=B5:D7"); // row +2, both corners
  // the fn token SUM is never a ref — it must survive verbatim
  assert.equal(F.rebaseFormula("=SUM(A1)", 1, 0), "=SUM(B1)");
});

check("rebaseFormula: refs INSIDE a string literal are untouched", () => {
  assert.equal(F.rebaseFormula('="A1"&B2', 1, 0), '="A1"&C2'); // "A1" is a str token
});

check("rebaseFormula: a bare (no leading '=') formula body rebases too", () => {
  // data-f is stored WITHOUT the leading '=' (QL-D6); the hook prepends it back.
  assert.equal(F.rebaseFormula("A1+1", 0, 1), "A2+1");
  assert.equal(F.rebaseFormula("$A$1+1", 0, 1), "$A$1+1");
});

check("rebaseFormula: a ref pushed off-grid collapses to #REF! (matches the server)", () => {
  assert.equal(F.rebaseFormula("=A1", -1, 0), "=#REF!"); // col 1-1=0 < 1
  assert.equal(F.rebaseFormula("=A1", 0, -1), "=#REF!"); // row 1-1=0 < 1
  // one dead corner kills the whole range (rewrite_range's #REF! rule)
  assert.equal(F.rebaseFormula("=A1:B2", -1, 0), "=#REF!");
  // a negative delta that STAYS on-grid just shifts (paste up/left)
  assert.equal(F.rebaseFormula("=C3", -1, -2), "=B1");
});

check("rebaseFormula: whole-col / whole-row ranges shift only their own axis", () => {
  assert.equal(F.rebaseFormula("=SUM(B:B)", 1, 0), "=SUM(C:C)"); // col shift
  assert.equal(F.rebaseFormula("=SUM(B:B)", 0, 9), "=SUM(B:B)"); // row delta ignored
  assert.equal(F.rebaseFormula("=SUM(3:3)", 0, 2), "=SUM(5:5)"); // row shift
  assert.equal(F.rebaseFormula("=SUM(3:3)", 9, 0), "=SUM(3:3)"); // col delta ignored
  assert.equal(F.rebaseFormula("=SUM($B:$B)", 5, 0), "=SUM($B:$B)"); // $ pins the column
});

check("rebaseFormula: a zero delta (paste in place) returns the formula unchanged", () => {
  assert.equal(F.rebaseFormula("=A1+B2*C3", 0, 0), "=A1+B2*C3");
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log(`\nall bp-sheet-formula kernel checks PASS \u2014 ${passed} checks`);

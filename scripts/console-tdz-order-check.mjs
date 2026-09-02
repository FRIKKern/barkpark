#!/usr/bin/env node
//
// console-tdz-order-check.mjs — the structural TDZ-order guard for the console
// harness. Zero dependencies (`node:fs` only), because the job that runs it
// runs with no install step.
//
// WHAT IT MEASURES (Cloud Console Hardening wave 61)
// -------------------------------------------------
// `cloud/priv/static/__app.test.mjs` suspends module evaluation at EVERY
// top-level `await`. Every `test()` registered ABOVE such a line is already on
// node:test's queue and may be DRAINED while that await settles, but every
// module-level binding declared BELOW it is still in its temporal dead zone.
// A drained early test that reaches one throws
// `ReferenceError: Cannot access 'X' before initialization`. On PR #11134 that
// cost five tests and blocked a required gate, and nothing in the repo said so
// until CI did.
//
// So this guard derives the suspension points from the file itself, and pairs
// each early test with the FIRST one that FOLLOWS it — the drain that can catch
// it — collecting the depth-0 bindings declared after that point, resolving
// references TRANSITIVELY through helpers initialised before it, subtracting
// names shadowed IN SCOPE, and exiting non-zero on any crossing.
//
// THE FIRST-MATCH AUDIT (wave 62, cchi-w62-bl-…-first-match-hole)
// --------------------------------------------------------------
// The sibling guard `console-runtime-pin-check.sh` was measured to have four
// green-when-it-should-red holes sharing one root cause: it reasoned over a SET
// and then read ONE value per member (charter D736). This guard was audited for
// the analogous class by MUTATING THE REAL `__app.test.mjs` — copies, never the
// tree — and three more of its own were found and closed here, on top of the
// two #14846 had already closed:
//
//   · THE BOUNDARY WAS A FIRST-MATCH READ. `analyze` took the FIRST depth-0
//     `await` and dropped every test at or after it. The real file has TWO
//     (lines 635 and 15705); the 851 tests between them drain at the second and
//     the bindings below it were invisible to all of them. Now every depth-0
//     await is a suspension point — and that widening immediately found TWO
//     REAL crossings in the shipped harness (§5b).
//   · SHADOW SUBTRACTION WAS SPAN-WIDE, NOT SCOPED. Any same-named local
//     ANYWHERE in a test erased a genuine module-level read elsewhere in it.
//     Now a declaration shadows only the brace region it is declared in (§4c).
//   · `test(` WAS COLLECTED AT DEPTH 0 ONLY, so a registration from a top-level
//     `for`/`if`/`while`/`try` block — which RUNS at module evaluation, and
//     which this harness already does — was skipped whole (§4d).
//
// A fourth measurement went the other way: `function` declarations are hoisted
// AND initialised, so a late one can never throw the ReferenceError this guard
// names. They were a FALSE-POSITIVE source that only the widened boundary model
// could surface, and they are now subtracted from the late set (§5).
//
// WHAT IT DOES **NOT** CLAIM
// --------------------------
//   · It is NOT a runtime-version story. "node 20 runs tests during evaluation,
//     node >=22 defers" is REFUTED BY MEASUREMENT: node 22 TDZ-crashes a probe
//     planted at the same anchor on the unmodified #11134 head, and a 10-test
//     synthetic fails on BOTH runtimes (6 vs 5). The mechanism is a DRAIN RACE
//     whose depth varies with runtime version, queue length and how much async
//     work the awaited import does. Pinning the runtime (see
//     `scripts/console-runtime-pin-check.sh`) NARROWS the window; only this
//     structural check closes the class.
//   · It is a HEURISTIC LEXER, not a parser. A novel syntax it mis-lexes used to
//     fail SILENTLY TOWARD GREEN — which is exactly how v1 of this guard reported
//     "boundary 19574, late bindings 0, crossings 0, exit 0" on a file with
//     five live crossings, because it did not mask regex literals and one
//     `/class="[^"]*x"/` opened a phantom string that drifted the depth map to
//     48 by line 13234. That is why `--selftest` ships with it and runs in the
//     SAME CI step: the fixtures are the proof that the lexer still sees.
//   · A `test(` registered from a CALLBACK is not counted. `[1].forEach(() =>
//     test(…))` really does register at module evaluation and is MISSED;
//     `test("outer", () => test("sub", …))` really does not and must be. The
//     guard cannot tell those apart without knowing which callee invokes its
//     argument synchronously, so it counts neither and says so here. THIS IS
//     THE KNOWN REMAINING GAP in the registration model.
//   · Shadowing is scoped by BRACE REGION, not by real JS scope: a `var` is
//     treated as block-scoped, and a concise arrow body's parameters shadow to
//     the end of their enclosing region. Both over-approximate the shadow
//     slightly, i.e. toward green, on shapes the harness does not use today.
//   · It measures ONE file per invocation and says nothing about test ordering,
//     assertion quality, or whether the harness is otherwise correct.
//
// THE BALANCE INVARIANT — WHY A LOST BOUNDARY IS A REFUSAL, NOT A GREEN (wave 62)
// -----------------------------------------------------------------------------
// Every verdict this guard prints rests on the depth map: "depth 0" is what
// separates a module-level `await` from an indented one, a module-level `test(`
// from a nested one, a module binding from a local. If the lexer mis-reads one
// token the depth map drifts and EVERY later depth-0 test is answered about the
// wrong file — and the failure is silent, because a drifted map simply finds
// nothing at depth 0. The old code then printed
// `crossings: 0 (structurally impossible without a top-level await)` — a
// confident verdict about a file it had just failed to parse.
//
// Valid JavaScript balances its brackets. So after masking, the depth map MUST
// return to 0, with no closer that closes nothing and no `)` closing a `{`. When
// it does not, the lexer has lost the file and the guard REFUSES (exit 3) with
// the counts, instead of certifying. That invariant is general: it catches the
// mis-lex classes nobody has thought of yet, which a per-keyword allowlist patch
// never can. It is NOT a proof of correct lexing — a mis-lex that happens to
// stay balanced still slips through (see the PR body for what a stronger claim
// would need).
//
// SEVEN THINGS THAT ARE LOAD-BEARING, NOT POLISH — each is proven by `--selftest`
// via a deliberately crippled variant, or a fixture, that must MISS or REFUSE:
//   · regex-literal masking   (`--demo-no-regex-mask` → now DETECTED + refused)
//   · transitive resolution   (`--demo-no-transitive` → misses helper-reached)
//   · shadow subtraction      (`--demo-no-shadow`     → false positive)
//   · depth-0 filtering       (an indented `await` inside a function body is
//     not a module boundary; a naive `grep await` picks the wrong line)
//   · whole-declarator-list reads (`const A = 1, B = 2;` binds a SET; a reader
//     that stops at the first `=` sees only A — fixtures/multi-decl.mjs)
//   · whole-binding-pattern reads (a multi-LINE `const { … } = …` yields no
//     names at all to a reader that stops at the first newline, so the entire
//     declaration disappears — fixtures/multi-decl.mjs)
//   · the balance invariant   (fixtures/lost-boundary.mjs, eaten-bracket.mjs)
//   · EVERY depth-0 await is a suspension point, not just the first
//     (`--demo-first-boundary-only` → misses the second-await crossing)
//   · scope-bounded shadowing (`--demo-span-shadow`  → a sibling-scope local
//     erases a live read)
//   · block-registered tests  (`--demo-depth0-tests` → a `for`-block
//     registration is never examined) — all three: fixtures/hazards.mjs
//
// USAGE
//   node scripts/console-tdz-order-check.mjs <file.mjs>
//   node scripts/console-tdz-order-check.mjs --selftest
//
// EXIT: 0 clean · 1 crossings found · 2 refused to measure (bad args/unreadable)
//     · 3 refused to measure (the lexer lost the file: brackets do not balance).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "fixtures", "console-tdz-order");

const KEYWORDS = new Set([
  "return", "typeof", "case", "in", "of", "do", "else", "yield", "await",
  "new", "delete", "void", "instanceof",
]);

// Identifiers that are never a module binding worth chasing.
const NOISE = new Set([
  "true", "false", "null", "undefined", "this", "super", "arguments",
  "const", "let", "var", "function", "class", "return", "if", "else", "for",
  "while", "do", "switch", "case", "default", "break", "continue", "try",
  "catch", "finally", "throw", "new", "delete", "typeof", "instanceof", "in",
  "of", "void", "yield", "await", "async", "import", "export", "from", "as",
  "static", "get", "set", "extends", "with", "debugger",
]);

// ── 1. MASKING ──────────────────────────────────────────────────────────────
// Blank out comments, strings, template-literal text and (unless crippled)
// regex literals, preserving offsets and newlines so every later measurement
// can cite a real line number. Template SUBSTITUTIONS stay live code — they
// carry brackets that matter to the depth map.
function mask(src, { maskRegex = true, health = null } = {}) {
  const out = src.split("");
  const blank = (a, b) => {
    for (let i = a; i < b && i < src.length; i++) if (out[i] !== "\n") out[i] = " ";
  };

  let i = 0;
  let mode = "code";
  let prevTok = "";
  const stack = []; // {kind:"tmpl"} | {kind:"sub", brace:number}
  const top = () => stack[stack.length - 1];

  while (i < src.length) {
    if (mode === "tmpl") {
      const c = src[i];
      if (c === "\\") { blank(i, i + 2); i += 2; continue; }
      if (c === "`") { blank(i, i + 1); i++; stack.pop(); mode = "code"; prevTok = "`"; continue; }
      if (c === "$" && src[i + 1] === "{") { blank(i, i + 2); i += 2; stack.push({ kind: "sub", brace: 0 }); mode = "code"; prevTok = "{"; continue; }
      blank(i, i + 1); i++;
      continue;
    }

    const c = src[i];
    const d = src[i + 1];

    if (c === "/" && d === "/") {
      let j = src.indexOf("\n", i); if (j < 0) j = src.length;
      blank(i, j); i = j; continue;
    }
    if (c === "/" && d === "*") {
      let j = src.indexOf("*/", i + 2); j = j < 0 ? src.length : j + 2;
      blank(i, j); i = j; continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < src.length) {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === c || src[j] === "\n") break;
        j++;
      }
      blank(i, Math.min(j + 1, src.length));
      i = Math.min(j + 1, src.length);
      prevTok = "str";
      continue;
    }
    if (c === "`") {
      blank(i, i + 1); i++; stack.push({ kind: "tmpl" }); mode = "tmpl"; continue;
    }
    if (c === "/" && maskRegex && regexCanStart(prevTok)) {
      const end = scanRegex(src, i);
      if (end > 0) { blank(i, end); i = end; prevTok = "re"; continue; }
    }
    if (c === "{") {
      const t = top(); if (t && t.kind === "sub") t.brace++;
      prevTok = "{"; i++; continue;
    }
    if (c === "}") {
      const t = top();
      if (t && t.kind === "sub") {
        if (t.brace === 0) { stack.pop(); blank(i, i + 1); mode = "tmpl"; i++; continue; }
        t.brace--;
      }
      prevTok = "}"; i++; continue;
    }
    if (/[A-Za-z_$]/.test(c)) {
      let j = i; while (j < src.length && /[\w$]/.test(src[j])) j++;
      prevTok = src.slice(i, j); i = j; continue;
    }
    if (!/\s/.test(c)) prevTok = c;
    i++;
  }

  // Ending anywhere but in `code` means a string or template literal was never
  // closed — the mask ran off the end of the file and everything after the
  // opener was blanked. Nothing measured on that text is a verdict.
  if (health) health.unterminated = mode !== "code" || stack.length > 0;

  return out.join("");
}

// ── 1b. THE BALANCE INVARIANT ───────────────────────────────────────────────
// Valid JavaScript balances its brackets, so masked source must too. Three
// independent ways it can fail, each of which means the depth map — and every
// depth-0 verdict built on it — is describing a file the lexer did not read:
//   · finalDepth ≠ 0   an opener was never closed (a `(` swallowed out of a
//                      mis-lexed regex literal drifts every later depth)
//   · underflows > 0   a closer closed nothing. `depthMap` clamps at 0, so this
//                      one hides behind a finalDepth of 0 and needs its own
//                      counter (see fixtures/eaten-bracket.mjs)
//   · mismatched > 0   a `)` closed a `{`. Depth can still balance while the
//                      structure is nonsense — this is what catches the real
//                      harness under `--demo-no-regex-mask` (359 mismatches)
function bracketHealth(masked) {
  const OPENER = { ")": "(", "]": "[", "}": "{" };
  const stack = [];
  let depth = 0;
  let underflows = 0;
  let mismatched = 0;
  for (let i = 0; i < masked.length; i++) {
    const c = masked[i];
    if (c === "(" || c === "[" || c === "{") { depth++; stack.push(c); continue; }
    if (c === ")" || c === "]" || c === "}") {
      if (depth === 0) { underflows++; continue; }
      depth--;
      if (stack.pop() !== OPENER[c]) mismatched++;
    }
  }
  return { finalDepth: depth, underflows, mismatched };
}

export function lexHealthLine(lex) {
  return (
    `final bracket depth ${lex.finalDepth} (want 0), ` +
    `${lex.underflows} unmatched closer(s), ${lex.mismatched} mismatched pair(s)` +
    (lex.unterminated ? ", ended inside an unterminated string/template" : "")
  );
}

// A `/` starts a regex only where a value may start.
function regexCanStart(prevTok) {
  if (prevTok === "") return true;
  if (prevTok.length === 1 && "(,=:[!&|?{};+-*%~^<>".includes(prevTok)) return true;
  return KEYWORDS.has(prevTok);
}

// Returns the index just past the regex (incl. flags), or -1 if this `/` is
// division after all (unterminated before the line ends).
function scanRegex(src, start) {
  let i = start + 1;
  let inClass = false;
  while (i < src.length) {
    const c = src[i];
    if (c === "\\") { i += 2; continue; }
    if (c === "\n") return -1;
    if (inClass) { if (c === "]") inClass = false; i++; continue; }
    if (c === "[") { inClass = true; i++; continue; }
    if (c === "/") {
      i++;
      while (i < src.length && /[a-z]/.test(src[i])) i++;
      return i;
    }
    i++;
  }
  return -1;
}

// ── 2. DEPTH MAP ────────────────────────────────────────────────────────────
// depth[i] is the bracket depth BEFORE the character at i, so an opening
// bracket sits at the OUTER depth and its closer at the inner one.
function depthMap(masked) {
  const depth = new Int32Array(masked.length + 1);
  let d = 0;
  for (let i = 0; i < masked.length; i++) {
    depth[i] = d;
    const c = masked[i];
    if (c === "(" || c === "[" || c === "{") d++;
    else if (c === ")" || c === "]" || c === "}") d = Math.max(0, d - 1);
  }
  depth[masked.length] = d;
  return depth;
}

function lineIndex(src) {
  const starts = [0];
  for (let i = 0; i < src.length; i++) if (src[i] === "\n") starts.push(i + 1);
  return (idx) => {
    let lo = 0, hi = starts.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= idx) lo = mid; else hi = mid - 1; }
    return lo + 1;
  };
}

// ── 3. SPANS ────────────────────────────────────────────────────────────────
function matchParen(masked, openIdx) {
  let d = 0;
  for (let i = openIdx; i < masked.length; i++) {
    const c = masked[i];
    if (c === "(") d++;
    else if (c === ")") { d--; if (d === 0) return i + 1; }
  }
  return masked.length;
}

// End of the statement starting at `start`: the first `;` at the starting
// depth, or the `}` that closes a block opened at that depth. A declaration
// relying on ASI over-approximates to the next `;` — that only ever widens the
// reference set, never hides a crossing.
function statementEnd(masked, depth, start) {
  const base = depth[start];
  let sawBrace = false;
  for (let i = start; i < masked.length; i++) {
    const c = masked[i];
    if (c === "{" && depth[i] === base) sawBrace = true;
    if (c === ";" && depth[i] === base) return i + 1;
    if (c === "}" && sawBrace && depth[i + 1] === base) return i + 1;
  }
  return masked.length;
}

// ── 4. BINDINGS & REFERENCES ────────────────────────────────────────────────
const DECL_RE = /\b(const|let|var|function|class)\b/g;

// A declaration binds a SET of names and this function must return the WHOLE
// set. The version this replaced read ONE value per declaration — it sliced the
// text at the first `=`/`;`/newline — which is the same set-then-single-read
// shape that was measured in `console-runtime-pin-check.sh`, and it lost:
//   · `const A = 1, B = 2;`  → stops at the first `=`, sees only A. A late `B`
//     is then invisible and an early test reading it is certified clean.
//   · a multi-LINE `const {\n  B,\n} = o;` → stops at the first newline, so the
//     "pattern" is `{`, which yields NO identifiers, so `if (!names.length)
//     continue` drops the entire declaration.
// Both go silently toward GREEN, which is the direction a guard must never fail
// in. Both are pinned by fixtures/multi-decl.mjs.
function bindingNames(masked, declIdx) {
  const kw = /^\w+/.exec(masked.slice(declIdx, declIdx + 16))[0];
  const after = declIdx + kw.length;
  if (kw === "function" || kw === "class") {
    const m = /^\s*\*?\s*([A-Za-z_$][\w$]*)/.exec(masked.slice(after, after + 200));
    return m ? [m[1]] : [];
  }
  const list = masked.slice(after, declaratorListEnd(masked, after));
  const names = [];
  for (const decl of splitTopLevel(list)) {
    for (const n of patternNames(declaratorPattern(decl))) names.push(n);
  }
  return names;
}

// A `\n` at depth 0 ends the declarator list unless the last significant
// character says the statement is obviously still going (ASI approximation).
const CONTINUATION = new Set([
  "", ",", "=", "(", "[", "{", ":", "?", "&", "|", "+", "-", "*", "/", "<", ">",
  "!", "%", "^", "~", ".",
]);

// Index just past the declarator LIST that starts at `from`: the first depth-0
// `;`, the first closer that would drop below the starting depth, the first
// depth-0 newline that cannot be a continuation, or end of text.
function declaratorListEnd(text, from) {
  let depth = 0;
  let lastSig = "";
  for (let i = from; i < text.length; i++) {
    const c = text[i];
    if (c === "(" || c === "[" || c === "{") { depth++; lastSig = c; continue; }
    if (c === ")" || c === "]" || c === "}") {
      if (depth === 0) return i;
      depth--; lastSig = c; continue;
    }
    if (depth === 0) {
      if (c === ";") return i;
      if (c === "\n" && !CONTINUATION.has(lastSig)) return i;
    }
    if (!/\s/.test(c)) lastSig = c;
  }
  return text.length;
}

// Split on commas at nesting depth 0 — one entry per declarator. The commas
// inside `readFileSync(a, b)` or `{ a: 1, b: 2 }` are NOT separators.
function splitTopLevel(text) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") depth = Math.max(0, depth - 1);
    else if (c === "," && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
  }
  parts.push(text.slice(start));
  return parts;
}

// One declarator's binding pattern: everything before its top-level `=`.
function declaratorPattern(decl) {
  let depth = 0;
  for (let i = 0; i < decl.length; i++) {
    const c = decl[i];
    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") depth = Math.max(0, depth - 1);
    else if (c === "=" && depth === 0 && decl[i + 1] !== "=") return decl.slice(0, i);
  }
  return decl;
}

// Names a binding pattern binds. Default VALUES are dropped (`{ a = LATE_X }`
// binds `a`; counting LATE_X would invent a crossing), `key:` labels are dropped
// (`{ key: local }` binds `local`), and `...` is erased so a rest element is not
// mistaken for a property access by `identifiers`.
function patternNames(pattern) {
  const kept = [];
  let depth = 0;
  let skipDepth = -1; // >= 0 while inside a default value
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === "(" || c === "[" || c === "{") { depth++; kept.push(" "); continue; }
    if (c === ")" || c === "]" || c === "}") {
      depth = Math.max(0, depth - 1);
      if (skipDepth >= 0 && depth < skipDepth) skipDepth = -1;
      kept.push(" ");
      continue;
    }
    if (c === "," && skipDepth >= 0 && depth === skipDepth) { skipDepth = -1; kept.push(" "); continue; }
    if (c === "=" && skipDepth < 0) { skipDepth = depth; kept.push(" "); continue; }
    kept.push(skipDepth >= 0 ? " " : c);
  }
  const text = kept.join("")
    .replace(/\.\.\./g, "   ")
    .replace(/([A-Za-z_$][\w$]*)\s*:/g, " ");
  return identifiers(text);
}

function identifiers(text) {
  const out = [];
  const re = /[A-Za-z_$][\w$]*/g;
  let m;
  while ((m = re.exec(text))) {
    const before = text.slice(Math.max(0, m.index - 2), m.index);
    if (/[.\w$]$/.test(before)) continue; // property access / mid-identifier
    if (NOISE.has(m[0])) continue;
    out.push(m[0]);
  }
  return out;
}

// Names a span binds locally, at any depth: declarations plus parameters.
function localNames(text) {
  const names = new Set();
  let m;
  const decl = /\b(?:const|let|var|function|class)\b/g;
  while ((m = decl.exec(text))) for (const n of bindingNames(text, m.index)) names.add(n);
  const fnParams = /\bfunction\b[^(]*\(([^)]*)\)/g;
  while ((m = fnParams.exec(text))) for (const n of identifiers(m[1])) names.add(n);
  const arrowParams = /\(([^()]*)\)\s*=>/g;
  while ((m = arrowParams.exec(text))) for (const n of identifiers(m[1])) names.add(n);
  const oneArrow = /(^|[^\w$.])([A-Za-z_$][\w$]*)\s*=>/g;
  while ((m = oneArrow.exec(text))) names.add(m[2]);
  const catchParam = /\bcatch\s*\(([^)]*)\)/g;
  while ((m = catchParam.exec(text))) for (const n of identifiers(m[1])) names.add(n);
  return names;
}

function refsOf(masked, span, { shadow = true, spanWide = false } = {}) {
  const [s0, s1] = span;
  const text = masked.slice(s0, s1);
  const byName = new Map();
  if (shadow) {
    for (const iv of shadowIntervals(masked, span, { spanWide })) {
      if (!byName.has(iv.name)) byName.set(iv.name, []);
      byName.get(iv.name).push(iv);
    }
  }
  const out = new Set();
  const re = /[A-Za-z_$][\w$]*/g;
  let m;
  while ((m = re.exec(text))) {
    const before = text.slice(Math.max(0, m.index - 2), m.index);
    if (/[.\w$]$/.test(before)) continue; // property access / mid-identifier
    if (NOISE.has(m[0])) continue;
    const at = s0 + m.index;
    const ivs = byName.get(m[0]);
    if (ivs && ivs.some((iv) => at >= iv.from && at < iv.to)) continue;
    out.add(m[0]);
  }
  return out;
}

// ── 4c. SHADOWING IS AN INTERVAL, NOT A SET ─────────────────────────────────
// HOLE (wave 62 audit). `localNames(text)` collected every declaration and
// parameter ANYWHERE in a test's span into one flat SET and subtracted it from
// every reference in that span — the same set-then-single-read shape as the
// sibling pin, one level up: a set is built, and then consulted with no regard
// for WHERE the name was bound. So
//   test("…", () => { { const X = 0; use(X); } assert.ok(X); })
// erased the module-level read of `X` on the last line because an unrelated
// sibling block had declared its own. Measured GREEN on a crossing planted in
// the real cloud/priv/static/__app.test.mjs (mutation M2).
//
// A declaration now shadows only the BRACE REGION it is declared in, and a
// parameter list only its own function body (for a concise arrow body, to the
// end of the enclosing region). `spanWide` reproduces the old behaviour so
// `--demo-span-shadow` can prove the difference is load-bearing.
function shadowIntervals(masked, span, { spanWide = false } = {}) {
  const [s0, s1] = span;
  const text = masked.slice(s0, s1);
  const intervals = [];
  if (spanWide) {
    for (const n of localNames(text)) intervals.push({ name: n, from: s0, to: s1 });
    return intervals;
  }

  const openAt = new Int32Array(text.length + 1).fill(-1);
  const closeOf = new Map();
  {
    const stack = [];
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (c === "{") { openAt[i] = stack.length ? stack[stack.length - 1] : -1; stack.push(i); continue; }
      openAt[i] = stack.length ? stack[stack.length - 1] : -1;
      if (c === "}") { const o = stack.pop(); if (o !== undefined) closeOf.set(o, i); }
    }
  }
  const regionOf = (i) => {
    const o = i >= 0 && i < openAt.length ? openAt[i] : -1;
    if (o < 0) return [s0, s1];
    return [s0 + o, s0 + (closeOf.has(o) ? closeOf.get(o) + 1 : text.length)];
  };
  const bodyAfter = (idx) => {
    let j = idx;
    while (j < text.length && /\s/.test(text[j])) j++;
    if (text[j] === "{") return [s0 + j, s0 + (closeOf.has(j) ? closeOf.get(j) + 1 : text.length)];
    return regionOf(idx);
  };
  const add = (name, from, to) => intervals.push({ name, from, to });

  let m;
  const decl = /\b(?:const|let|var|function|class)\b/g;
  while ((m = decl.exec(text))) {
    const [from, to] = regionOf(m.index);
    for (const n of bindingNames(text, m.index)) add(n, from, to);
  }
  for (const re of [/\bfunction\b[^(]*\(([^)]*)\)/g, /\(([^()]*)\)\s*=>/g, /\bcatch\s*\(([^)]*)\)/g]) {
    re.lastIndex = 0;
    while ((m = re.exec(text))) {
      const [from, to] = bodyAfter(m.index + m[0].length);
      for (const n of identifiers(m[1])) add(n, from, to);
    }
  }
  const oneArrow = /(^|[^\w$.])([A-Za-z_$][\w$]*)\s*=>/g;
  while ((m = oneArrow.exec(text))) {
    const [from, to] = bodyAfter(m.index + m[0].length);
    add(m[2], from, to);
  }
  return intervals;
}

// ── 4d. WHICH `test(` REALLY REGISTERS AT MODULE EVALUATION ─────────────────
// HOLE (wave 62 audit). Registrations were collected at depth 0 ONLY, so
// `for (const v of […]) { test(…) }` at the top level — an idiom this very
// harness already uses — was skipped WHOLE: not measured, not counted, not
// mentioned. That block RUNS during module evaluation, so its tests really are
// on the queue. Measured GREEN on a crossing planted in the real harness
// (mutation M4).
//
// A registration counts when EVERY bracket enclosing it is a synchronous block:
// the `{` of a `for`/`if`/`while`/`switch`/`try`/`catch`/`else`/`do`, or a bare
// block. An enclosing `(`/`[`, an object literal, or a function/arrow body means
// a callee decides when — or whether — the registration happens, and the guard
// does not guess. See the KNOWN REMAINING GAP in the header.
const BLOCK_HEADS = new Set(["for", "if", "while", "switch", "catch"]);
const BLOCK_PRECEDERS = new Set(["try", "else", "do", "finally", "", "{", "}", ";", ")"]);

// The token immediately before `idx`, skipping whitespace. "" at start of file.
function prevToken(masked, idx) {
  let i = idx - 1;
  while (i >= 0 && /\s/.test(masked[i])) i--;
  if (i < 0) return "";
  if (/[\w$]/.test(masked[i])) {
    let j = i; while (j >= 0 && /[\w$]/.test(masked[j])) j--;
    return masked.slice(j + 1, i + 1);
  }
  return masked[i];
}

function isModuleEvaluated(masked, idx) {
  const stack = [];
  for (let i = 0; i < idx; i++) {
    const c = masked[i];
    if (c === "(" || c === "[" || c === "{") stack.push({ c, i });
    else if (c === ")" || c === "]" || c === "}") stack.pop();
  }
  for (const { c, i } of stack) {
    if (c !== "{") return false;
    const t = prevToken(masked, i);
    if (t === ")") {
      let d = 0, open = -1;
      for (let j = i - 1; j >= 0; j--) {
        if (masked[j] === ")") d++;
        else if (masked[j] === "(") { d--; if (d === 0) { open = j; break; } }
      }
      if (open < 0 || !BLOCK_HEADS.has(prevToken(masked, open))) return false;
      continue;
    }
    if (!BLOCK_PRECEDERS.has(t)) return false;
  }
  return true;
}

// ── 5. THE ANALYSIS ─────────────────────────────────────────────────────────
export function analyze(src, opts = {}) {
  const maskReport = {};
  const masked = mask(src, { maskRegex: opts.maskRegex !== false, health: maskReport });
  const depth = depthMap(masked);
  const lineOf = lineIndex(src);

  // Does the depth map describe THIS file, or a file the lexer invented? Every
  // verdict below is conditioned on this answer, so it is computed first and
  // carried on every return path — including the early one.
  const balance = bracketHealth(masked);
  const lex = {
    ...balance,
    unterminated: !!maskReport.unterminated,
    ok:
      balance.finalDepth === 0 &&
      balance.underflows === 0 &&
      balance.mismatched === 0 &&
      !maskReport.unterminated,
  };

  const transitive = opts.transitive !== false;
  const shadow = opts.shadow !== false;
  const spanWide = opts.spanShadow === true;
  const firstOnly = opts.everyBoundary === false;
  const depth0Tests = opts.blockTests === false;

  // HOLE (wave 62 audit). The boundary WAS a first-match read: the first depth-0
  // `await`, `break`, and every test at or after it dropped. But a module
  // suspends at EVERY top-level await, and the real cloud/priv/static/
  // __app.test.mjs has TWO (lines 635 and 15705): the 851 tests registered
  // between them are on node:test's queue when the second one suspends, and the
  // bindings below it were invisible to every one of them. A crossing planted
  // over the second await measured GREEN, rc 0 (mutation M3). Every depth-0
  // await is now a suspension point.
  const boundaries = [];
  let awaitTokens = 0;
  const awaitRe = /\bawait\b/g;
  let m;
  while ((m = awaitRe.exec(masked))) {
    awaitTokens++;
    if (depth[m.index] !== 0) continue;
    if (firstOnly && boundaries.length) continue;
    boundaries.push(m.index);
  }
  if (!boundaries.length) return { boundary: -1, boundaries: [], lex, awaitTokens };
  const boundary = boundaries[0];

  // Depth-0 declarations, in source order. A `function` declaration is HOISTED
  // AND INITIALISED before any module code runs, so it can never produce the
  // ReferenceError this guard's error text names — it stays a chaseable EARLY
  // helper but is never a LATE binding. The widened boundary model surfaced
  // exactly one such false positive on the real harness (`driveMe`, line 18886).
  // `let`/`const`/`class` really are dead until evaluated; `var` is hoisted to
  // `undefined`, a quieter defect that is still worth naming, so it is kept.
  const decls = [];
  DECL_RE.lastIndex = 0;
  while ((m = DECL_RE.exec(masked))) {
    if (depth[m.index] !== 0) continue;
    const names = bindingNames(masked, m.index);
    if (!names.length) continue;
    decls.push({
      index: m.index,
      names,
      span: [m.index, statementEnd(masked, depth, m.index)],
      line: lineOf(m.index),
      hoisted: m[1] === "function",
    });
  }

  // `test(` registrations that really run at module evaluation (§4d).
  const tests = [];
  const testRe = /\btest\s*\(/g;
  while ((m = testRe.exec(masked))) {
    if (depth[m.index] !== 0) {
      if (depth0Tests) continue;
      if (!isModuleEvaluated(masked, m.index)) continue;
    }
    const open = masked.indexOf("(", m.index);
    const span = [m.index, matchParen(masked, open)];
    const title = (/["'`]([^"'`\n]*)/.exec(src.slice(open, open + 200)) || [, "(untitled)"])[1];
    tests.push({ index: m.index, line: lineOf(m.index), title, span });
  }

  // Each test is caught by the FIRST suspension point that FOLLOWS it — the
  // drain that can run it while later bindings are still dead. That boundary
  // also yields the LARGEST late set, so no later one adds anything.
  const groups = new Map();
  for (const t of tests) {
    const b = boundaries.find((x) => x > t.index);
    if (b === undefined) continue; // nothing suspends after it: it cannot drain early
    if (!groups.has(b)) groups.set(b, []);
    groups.get(b).push(t);
  }

  const crossings = [];
  const lateSeen = new Set();
  const earlySeen = new Set();
  for (const [b, group] of groups) {
    const early = new Map();
    const late = new Map();
    for (const d of decls) {
      if (d.index > b) {
        if (d.hoisted) continue;
        for (const n of d.names) if (!late.has(n)) late.set(n, d.line);
      } else {
        for (const n of d.names) if (!early.has(n)) early.set(n, d.span);
      }
    }
    for (const n of late.keys()) lateSeen.add(n);
    for (const n of early.keys()) earlySeen.add(n);
    for (const t of group) {
      const seen = new Set();
      const via = new Map();
      const queue = [...refsOf(masked, t.span, { shadow, spanWide })];
      while (queue.length) {
        const n = queue.shift();
        if (seen.has(n)) continue;
        seen.add(n);
        if (late.has(n)) {
          crossings.push({
            test: t, binding: n, declLine: late.get(n),
            via: via.get(n) || null, boundaryLine: lineOf(b),
          });
          continue;
        }
        if (transitive && early.has(n)) {
          for (const r of refsOf(masked, early.get(n), { shadow, spanWide })) {
            if (!seen.has(r)) { if (!via.has(r)) via.set(r, n); queue.push(r); }
          }
        }
      }
    }
  }

  return {
    boundary,
    boundaryLine: lineOf(boundary),
    boundaries,
    boundaryLines: boundaries.map(lineOf),
    earlyTests: [...groups.values()].reduce((n, g) => n + g.length, 0),
    lateBindings: lateSeen.size,
    earlyBindings: earlySeen.size,
    crossings,
    lex,
    awaitTokens,
  };
}

// ── 5b. THE LATENT LEDGER ───────────────────────────────────────────────────
// Widening the boundary model made a class VISIBLE that no run had ever
// reached, and it immediately found TWO REAL crossings in the shipped harness —
// both over the SECOND depth-0 await at line 15705, in tests registered ~13 000
// lines above it.
//
// They are latent rather than firing, and the reason is MEASURED, not assumed:
// on node v22.22.0 an instrumented copy prints `MODULE about to suspend at
// point 2` → `MODULE resumed past point 2` BEFORE any test body runs, because
// line 15705 re-imports `./__preview__/scenarios.mjs`, which line 635 already
// put in the module cache — the await settles inside one microtask tick and
// node:test never starts draining. (1200/1200 pass.) That is an ACCIDENT OF THE
// CACHE, not a property of the file: give that second import any real async
// work and the window opens on bindings 4 500 lines below.
//
// The repair belongs to `__app.test.mjs`, and the audit that found this was
// fenced off from it. So the two are ledgered here BY NAME, and the ledger is a
// RATCHET IN BOTH DIRECTIONS:
//   · a crossing NOT on it is FATAL — a third cannot hide behind the two;
//   · an entry on it that is NOT FOUND is ALSO FATAL — the ledger cannot rot
//     into an allowlist that outlives what it excused.
// Entries key on TEST TITLE + BINDING, never on a line number: this file is
// edited every wave and a line-anchored pin breaks on the first insertion above
// it.
export const LATENT = [
  {
    file: "cloud/priv/static/__app.test.mjs",
    title: "cch-w36-s4: a failed halt/resume stops printing the billing sentence over a 403",
    binding: "FORBIDDEN_GENERIC",
    why: "declared at the far end of the file, read ~17 000 lines above it; latent on node 22 only because the boundary-2 import is a module-cache hit",
  },
  {
    file: "cloud/priv/static/__app.test.mjs",
    title: "mountInstanceTimeline: a failed instance keeps the timeline + shows the verbatim detail + Retry",
    binding: "ME_OWNER",
    why: "same suspension point, same cache-hit reason; the repair is to move the fixture above the second await",
  },
];

// Split crossings into the ones the ledger carries and the ones it does not,
// and surface entries that no longer match anything. Pure, so `--selftest` can
// grade the arm that decides the exit code without a 24 000-line file.
export function reconcile(file, crossings, ledger = LATENT) {
  const mine = ledger.filter((e) => file.endsWith(e.file));
  const hit = new Set();
  const fresh = [];
  const known = [];
  for (const c of crossings) {
    const i = mine.findIndex((e) => e.title === c.test.title && e.binding === c.binding);
    if (i < 0) { fresh.push(c); continue; }
    hit.add(i);
    known.push({ ...c, why: mine[i].why });
  }
  return { fresh, known, stale: mine.filter((_, i) => !hit.has(i)) };
}

// The one place a result becomes an exit code, so `run()` and `--selftest` can
// never disagree about what the guard would have done. `led` is the ledger
// reconciliation when there is one; without it every crossing is fatal.
export function exitCodeFor(r, led = null) {
  if (!r.lex.ok) return 3;
  if (r.boundary < 0) return 0;
  if (led) return led.fresh.length || led.stale.length ? 1 : 0;
  return r.crossings.length ? 1 : 0;
}

// ── 6. CLI ──────────────────────────────────────────────────────────────────
function run(file, opts) {
  let src;
  try {
    src = fs.readFileSync(file, "utf8");
  } catch (e) {
    console.error(`::error::console-tdz-order-check: REFUSED TO MEASURE — cannot read ${file}: ${e.message}`);
    return 2;
  }
  const r = analyze(src, opts);
  console.log(`console-tdz-order-check: ${file}`);

  // REFUSAL BEFORE VERDICT. If the brackets do not balance, the depth map is
  // describing something other than this file, so there is no boundary to
  // report and no crossing count to believe — least of all a reassuring one.
  if (!r.lex.ok) {
    console.log(`  lexer health: LOST — ${lexHealthLine(r.lex)}`);
    console.log("  module boundary: UNKNOWN — refusing to answer from a depth map that does not describe this file");
    console.error(
      `::error file=${file}::console-tdz-order-check: REFUSED TO MEASURE — the lexer lost ${file} ` +
      `(${lexHealthLine(r.lex)}). Valid JavaScript balances its brackets, so this means the heuristic ` +
      `lexer mis-read a token and the depth map drifted; "depth 0" no longer means module level, and ` +
      `every verdict built on it — the boundary, the early tests, the late bindings, the crossing count ` +
      `— would be about a file that does not exist. This guard will NOT print ` +
      `"crossings: 0 (structurally impossible without a top-level await)" about a file it failed to parse. ` +
      `Find the shape that defeats the lexer (a regex literal in a position \`regexCanStart\` does not ` +
      `allow leaves its contents live as code — the known cause) and either rewrite it or teach the ` +
      `lexer that position, then re-run. Exit 3 is a REFUSAL, not a crossing.`
    );
    return 3;
  }
  console.log(`  lexer health: balanced (${lexHealthLine(r.lex)})`);

  if (r.boundary < 0) {
    console.log("  module boundary: NONE — no depth-0 `await` in this file");
    if (r.awaitTokens > 0) {
      console.log(
        `  note: ${r.awaitTokens} \`await\` token(s) are present, all at depth > 0 — the line below is ` +
        `a statement about the BOUNDARY, and it stands only because the parse above balanced`
      );
    }
    console.log("  crossings: 0 (structurally impossible without a top-level await)");
    return 0;
  }
  console.log(`  module suspension points: ${r.boundaries.length} depth-0 \`await\`(s) at line(s) ${r.boundaryLines.join(", ")}`);
  console.log(`  early test registrations (each above some suspension point): ${r.earlyTests}`);
  console.log(`  late depth-0 bindings (below the point that catches them): ${r.lateBindings}`);
  console.log(`  crossings: ${r.crossings.length}`);

  const led = reconcile(file, r.crossings);
  for (const c of led.known) {
    console.log(
      `  LEDGERED (latent, NOT excused): test "${c.test.title}" reads \`${c.binding}\` declared at ` +
      `line ${c.declLine}, below the suspension point at line ${c.boundaryLine} — ${c.why}`
    );
  }
  for (const e of led.stale) {
    console.error(
      `::error file=${file}::console-tdz-order-check: STALE LATENT LEDGER ENTRY — "${e.title}" reading ` +
      `\`${e.binding}\` is no longer a crossing in ${file}. Either the harness was repaired or the test ` +
      `was renamed. DELETE that entry from LATENT in scripts/console-tdz-order-check.mjs and re-run. ` +
      `A ledger that outlives what it excused is an allowlist, and this one refuses to become one.`
    );
  }
  for (const c of led.fresh) {
    const hop = c.via ? ` via early helper \`${c.via}\`` : "";
    console.error(
      `::error file=${file},line=${c.test.line}::TDZ ORDER: test "${c.test.title}" (line ${c.test.line}) ` +
      `registers above the module suspension point at line ${c.boundaryLine} but reads \`${c.binding}\`, ` +
      `declared at line ${c.declLine}${hop}. If node:test drains that test while that await ` +
      `settles it throws ReferenceError: Cannot access '${c.binding}' before initialization. ` +
      `Move the test below the binding, or move the binding above the test.`
    );
  }
  return exitCodeFor(r, led);
}

// The self-test. It runs in the SAME CI step as the real measurement, because
// a mis-lex fails silently toward green and only a fixture with a KNOWN answer
// can catch that.
function selftest() {
  const fixture = (name) => fs.readFileSync(path.join(FIXTURES, name), "utf8");
  const crossing = fixture("crossing.mjs");
  const clean = fixture("clean.mjs");
  let bad = 0;
  let total = 0;
  const check = (label, ok, detail) => {
    total++;
    console.log(`  ${ok ? "ok" : "FAIL"}  ${label}${detail ? ` — ${detail}` : ""}`);
    if (!ok) bad++;
  };

  console.log("console-tdz-order-check --selftest (fixtures: scripts/fixtures/console-tdz-order)");

  const full = analyze(crossing, {});
  const names = full.crossings.map((c) => `${c.test.title}→${c.binding}`).sort();
  check(
    "crossing fixture reds with exactly the two known crossings",
    names.length === 2 &&
      names[0] === "direct crossing→LATE_DIRECT" &&
      names[1] === "transitive crossing→LATE_VIA_HELPER",
    names.join(", ") || "none"
  );
  check(
    "boundary is the depth-0 await, not the indented one inside a function",
    /await import\("node:os"\)/.test(crossing.split("\n")[full.boundaryLine - 1] || ""),
    `line ${full.boundaryLine}`
  );
  check("shadowed late name is NOT reported", !names.some((n) => n.includes("LATE_SHADOWED")));

  const cleanR = analyze(clean, {});
  check("clean fixture is green", cleanR.crossings.length === 0, `crossings ${cleanR.crossings.length}`);

  // Each crippled variant MUST lose — that is what proves the feature is
  // load-bearing rather than decorative.
  const noRegex = analyze(crossing, { maskRegex: false });
  check(
    "WITHOUT regex masking the guard finds NO crossings (so masking is load-bearing)",
    (noRegex.crossings || []).length === 0,
    `crossings ${(noRegex.crossings || []).length}, boundary ${noRegex.boundary < 0 ? "NOT FOUND (depth drifted)" : `line ${noRegex.boundaryLine}`}`
  );
  check(
    "…and that vacuous green is now DETECTED and REFUSED (exit 3), not printed as a verdict",
    noRegex.lex.ok === false && exitCodeFor(noRegex) === 3,
    `${lexHealthLine(noRegex.lex)} → exit ${exitCodeFor(noRegex)}`
  );

  const noTrans = analyze(crossing, { transitive: false });
  check(
    "WITHOUT transitive resolution the helper-reached crossing is MISSED",
    noTrans.crossings.length === 1 && noTrans.crossings[0].binding === "LATE_DIRECT",
    `crossings ${noTrans.crossings.map((c) => c.binding).join(",") || "none"}`
  );

  const noShadow = analyze(crossing, { shadow: false });
  check(
    "WITHOUT shadow subtraction a locally-declared name becomes a FALSE POSITIVE",
    noShadow.crossings.some((c) => c.binding === "LATE_SHADOWED"),
    `crossings ${noShadow.crossings.map((c) => c.binding).join(",") || "none"}`
  );

  // ── wave 62: the first-match-wins audit ───────────────────────────────────
  // A declaration binds a SET; the reader must return the whole set. These two
  // shapes both went silently GREEN before, and both are ordinary refactors of
  // code that is already in the real harness.
  const multi = analyze(fixture("multi-decl.mjs"), {});
  const multiNames = multi.crossings.map((c) => `${c.test.title}→${c.binding}`).sort();
  check(
    "the SECOND declarator of `const A = 1, B = 2;` is a binding the guard sees",
    multiNames.includes("reads the second declarator→LATE_SECOND"),
    multiNames.join(", ") || "none"
  );
  check(
    "a MULTI-LINE `const { … } = …` is not dropped whole (reached transitively)",
    multiNames.includes("reads a multi-line pattern→LATE_IN_PATTERN"),
    multiNames.join(", ") || "none"
  );
  check(
    "…and those are the ONLY two: a default VALUE is not a binding, a shadow is not a crossing",
    multiNames.length === 2,
    `${multiNames.length} crossing(s): ${multiNames.join(", ") || "none"}`
  );

  // ── wave 62: the balance invariant ────────────────────────────────────────
  // A lost module boundary must produce a REFUSAL with its own exit code, never
  // the reassuring "structurally impossible" sentence about an unparsed file.
  const lost = analyze(fixture("lost-boundary.mjs"), {});
  check(
    "a mis-lexed regex that drifts the depth map is REFUSED (exit 3), not called boundary-less",
    lost.lex.ok === false && lost.boundary < 0 && exitCodeFor(lost) === 3,
    `boundary ${lost.boundary < 0 ? "NOT FOUND" : `line ${lost.boundaryLine}`}, ${lexHealthLine(lost.lex)} → exit ${exitCodeFor(lost)}`
  );
  const eaten = analyze(fixture("eaten-bracket.mjs"), {});
  check(
    "an EATEN bracket is refused too — final depth 0 is not proof the lexer read the file",
    eaten.lex.ok === false && eaten.lex.finalDepth === 0 && eaten.lex.underflows > 0 && exitCodeFor(eaten) === 3,
    `${lexHealthLine(eaten.lex)} → exit ${exitCodeFor(eaten)}`
  );

  // ── wave 62: the first-match AUDIT (cchi-w62-bl-…-first-match-hole) ───────
  // Three more green-when-it-should-red holes, each MEASURED on a mutated copy
  // of the real harness before it was closed, each now pinned by a fixture with
  // a known answer AND by a crippled variant that reproduces the original miss.
  const hz = analyze(fixture("hazards.mjs"), {});
  const hzNames = hz.crossings.map((c) => `${c.test.title}→${c.binding}`).sort();
  const HAZARDS = [
    "block-registered→BLOCK_LATE",
    "sibling shadow→SIBLING_LATE",
    "split declaration→SPLIT_LATE",
    "test between the boundaries→SECOND_LATE",
  ];
  check(
    "hazards fixture reds with exactly the four audited crossings",
    hzNames.length === HAZARDS.length && HAZARDS.every((e, i) => hzNames[i] === e),
    hzNames.join(", ") || "none"
  );
  check(
    "…and its two DECOYS stay silent: a genuine shadow, and a test registered from a function body",
    !hzNames.some((n) => /TRUE_SHADOWED|NEVER_EARLY/.test(n)),
    hzNames.join(", ") || "none"
  );
  check(
    "BOTH depth-0 awaits are suspension points — a module does not stop suspending after the first",
    (hz.boundaries || []).length === 2,
    `suspension points at line(s) ${(hz.boundaryLines || []).join(", ") || "none"}`
  );
  const firstOnly = analyze(fixture("hazards.mjs"), { everyBoundary: false });
  check(
    "WITH ONLY THE FIRST boundary the crossing over the second await is MISSED (measured green on the real harness)",
    !firstOnly.crossings.some((c) => c.binding === "SECOND_LATE"),
    firstOnly.crossings.map((c) => c.binding).sort().join(",") || "none"
  );
  const spanShadow = analyze(fixture("hazards.mjs"), { spanShadow: true });
  check(
    "WITH SPAN-WIDE shadowing a sibling-scope local erases a live read and it is MISSED",
    !spanShadow.crossings.some((c) => c.binding === "SIBLING_LATE"),
    spanShadow.crossings.map((c) => c.binding).sort().join(",") || "none"
  );
  const depth0Tests = analyze(fixture("hazards.mjs"), { blockTests: false });
  check(
    "WITH DEPTH-0-ONLY test collection the block-registered test is not examined at all and is MISSED",
    !depth0Tests.crossings.some((c) => c.binding === "BLOCK_LATE"),
    depth0Tests.crossings.map((c) => c.binding).sort().join(",") || "none"
  );
  check(
    "a `function` declared below a suspension point is HOISTED, so it is never reported as a late binding",
    !hzNames.some((n) => n.includes("registerLater")),
    hzNames.join(", ") || "none"
  );

  // ── wave 62: the latent ledger ratchets in BOTH directions ────────────────
  // Graded on a synthetic ledger so these arms keep their meaning after the real
  // one is emptied by the harness repair.
  const LEDGER = [{ file: "f.mjs", title: "T1", binding: "B1", why: "x" }];
  const cx = (title, binding) => ({ test: { title, line: 1 }, binding, declLine: 2, boundaryLine: 3, via: null });
  const okLex = { lex: { ok: true }, boundary: 1, crossings: [] };
  const led1 = reconcile("a/f.mjs", [cx("T1", "B1")], LEDGER);
  check(
    "ledger: a crossing it already carries is REPORTED but does not red",
    led1.known.length === 1 && led1.fresh.length === 0 && led1.stale.length === 0 && exitCodeFor(okLex, led1) === 0,
    `known ${led1.known.length}, fresh ${led1.fresh.length}, stale ${led1.stale.length} → exit ${exitCodeFor(okLex, led1)}`
  );
  const led2 = reconcile("a/f.mjs", [cx("T1", "B1"), cx("T2", "B2")], LEDGER);
  check(
    "ledger: a THIRD crossing cannot hide behind the ledgered ones — FRESH and FATAL",
    led2.fresh.length === 1 && led2.fresh[0].binding === "B2" && exitCodeFor(okLex, led2) === 1,
    `fresh ${led2.fresh.map((c) => c.binding).join(",") || "none"} → exit ${exitCodeFor(okLex, led2)}`
  );
  const led3 = reconcile("a/f.mjs", [], LEDGER);
  check(
    "ledger: an entry that matches nothing is STALE and FATAL — it cannot rot into an allowlist",
    led3.stale.length === 1 && led3.stale[0].binding === "B1" && exitCodeFor(okLex, led3) === 1,
    `stale ${led3.stale.map((e) => e.binding).join(",") || "none"} → exit ${exitCodeFor(okLex, led3)}`
  );
  const led4 = reconcile("other/g.mjs", [cx("T1", "B1")], LEDGER);
  check(
    "ledger: it is scoped to its own file — the same title elsewhere is still FATAL",
    led4.fresh.length === 1 && led4.stale.length === 0,
    `fresh ${led4.fresh.length}, stale ${led4.stale.length}`
  );

  // A refusal that fires on well-formed input is as useless as a green that
  // never fires. Both good fixtures must stay measurable.
  check(
    "the refusal does NOT fire on well-formed files (crossing + clean both balance)",
    full.lex.ok === true && cleanR.lex.ok === true &&
      exitCodeFor(full) === 1 && exitCodeFor(cleanR) === 0,
    `crossing: ${lexHealthLine(full.lex)} → exit ${exitCodeFor(full)}; clean: exit ${exitCodeFor(cleanR)}`
  );

  if (bad) {
    console.error(`::error::console-tdz-order-check: SELF-TEST FAILED (${bad} of ${total} assertion(s)) — the lexer no longer sees what it claims to.`);
    return 1;
  }
  console.log(`  self-test: ${total}/${total} — the guard can still lose, and can still refuse.`);
  return 0;
}

const argv = process.argv.slice(2);
const opts = {
  maskRegex: !argv.includes("--demo-no-regex-mask"),
  transitive: !argv.includes("--demo-no-transitive"),
  shadow: !argv.includes("--demo-no-shadow"),
  spanShadow: argv.includes("--demo-span-shadow"),
  everyBoundary: !argv.includes("--demo-first-boundary-only"),
  blockTests: !argv.includes("--demo-depth0-tests"),
};
const demo = argv.some((a) => a.startsWith("--demo-"));
if (demo) console.log("!! DEMO VARIANT — a deliberately crippled build, NOT the shipped guard.");

const files = argv.filter((a) => !a.startsWith("-"));
let code;
if (argv.includes("--selftest")) code = selftest();
else if (files.length !== 1) {
  console.error("usage: node scripts/console-tdz-order-check.mjs <file.mjs> | --selftest");
  code = 2;
} else code = run(files[0], opts);
process.exit(code);

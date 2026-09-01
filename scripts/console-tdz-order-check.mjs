#!/usr/bin/env node
//
// console-tdz-order-check.mjs — the structural TDZ-order guard for the console
// harness. Zero dependencies (`node:fs` only), because the job that runs it
// runs with no install step.
//
// WHAT IT MEASURES (Cloud Console Hardening wave 61)
// -------------------------------------------------
// `cloud/priv/static/__app.test.mjs` suspends module evaluation at its FIRST
// top-level `await`. Every `test()` registered ABOVE that line is already on
// node:test's queue and may be DRAINED while the await settles, but every
// module-level binding declared BELOW it is still in its temporal dead zone.
// A drained early test that reaches one throws
// `ReferenceError: Cannot access 'X' before initialization`. On PR #11134 that
// cost five tests and blocked a required gate, and nothing in the repo said so
// until CI did.
//
// So this guard derives the boundary from the file itself, collects the
// depth-0 bindings declared after it and the depth-0 `test(` registrations
// before it, resolves references TRANSITIVELY through early top-level helpers,
// subtracts locally shadowed names, and exits non-zero on any crossing.
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

function refsOf(masked, span, { shadow = true } = {}) {
  const text = masked.slice(span[0], span[1]);
  const locals = shadow ? localNames(text) : new Set();
  const out = new Set();
  for (const n of identifiers(text)) if (!locals.has(n)) out.add(n);
  return out;
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

  // The boundary is DERIVED: the first `await` token sitting at depth 0.
  let boundary = -1;
  let awaitTokens = 0;
  const awaitRe = /\bawait\b/g;
  let m;
  while ((m = awaitRe.exec(masked))) {
    awaitTokens++;
    if (boundary < 0 && depth[m.index] === 0) boundary = m.index;
  }
  if (boundary < 0) return { boundary: -1, lex, awaitTokens };

  // Depth-0 declarations, split by the boundary.
  const early = new Map(); // name -> span (helpers reachable from early tests)
  const late = new Map();  // name -> declaration line
  DECL_RE.lastIndex = 0;
  while ((m = DECL_RE.exec(masked))) {
    if (depth[m.index] !== 0) continue;
    const names = bindingNames(masked, m.index);
    if (!names.length) continue;
    const span = [m.index, statementEnd(masked, depth, m.index)];
    if (m.index > boundary) {
      for (const n of names) if (!late.has(n)) late.set(n, lineOf(m.index));
    } else {
      for (const n of names) if (!early.has(n)) early.set(n, span);
    }
  }

  // Depth-0 `test(` registrations before the boundary.
  const tests = [];
  const testRe = /\btest\s*\(/g;
  while ((m = testRe.exec(masked))) {
    if (depth[m.index] !== 0) continue;
    const open = masked.indexOf("(", m.index);
    const span = [m.index, matchParen(masked, open)];
    if (m.index >= boundary) continue;
    const title = (/["'`]([^"'`\n]*)/.exec(src.slice(open, open + 200)) || [, "(untitled)"])[1];
    tests.push({ index: m.index, line: lineOf(m.index), title, span });
  }

  const transitive = opts.transitive !== false;
  const shadow = opts.shadow !== false;
  const crossings = [];
  for (const t of tests) {
    const seen = new Set();
    const via = new Map();
    const queue = [...refsOf(masked, t.span, { shadow })];
    while (queue.length) {
      const n = queue.shift();
      if (seen.has(n)) continue;
      seen.add(n);
      if (late.has(n)) {
        crossings.push({ test: t, binding: n, declLine: late.get(n), via: via.get(n) || null });
        continue;
      }
      if (transitive && early.has(n)) {
        for (const r of refsOf(masked, early.get(n), { shadow })) {
          if (!seen.has(r)) { if (!via.has(r)) via.set(r, n); queue.push(r); }
        }
      }
    }
  }

  return {
    boundary,
    boundaryLine: lineOf(boundary),
    earlyTests: tests.length,
    lateBindings: late.size,
    earlyBindings: early.size,
    crossings,
    lex,
    awaitTokens,
  };
}

// The one place a result becomes an exit code, so `run()` and `--selftest` can
// never disagree about what the guard would have done.
export function exitCodeFor(r) {
  if (!r.lex.ok) return 3;
  if (r.boundary < 0) return 0;
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
  console.log(`  module boundary: first depth-0 \`await\` at line ${r.boundaryLine}`);
  console.log(`  early test registrations (above the boundary): ${r.earlyTests}`);
  console.log(`  late depth-0 bindings (below the boundary): ${r.lateBindings}`);
  console.log(`  crossings: ${r.crossings.length}`);
  for (const c of r.crossings) {
    const hop = c.via ? ` via early helper \`${c.via}\`` : "";
    console.error(
      `::error file=${file},line=${c.test.line}::TDZ ORDER: test "${c.test.title}" (line ${c.test.line}) ` +
      `registers above the module boundary (line ${r.boundaryLine}) but reads \`${c.binding}\`, ` +
      `declared at line ${c.declLine}${hop}. If node:test drains that test while the boundary await ` +
      `settles it throws ReferenceError: Cannot access '${c.binding}' before initialization. ` +
      `Move the test below the boundary, or move the binding above it.`
    );
  }
  return r.crossings.length ? 1 : 0;
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

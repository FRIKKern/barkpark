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
//   · It is a HEURISTIC LEXER, not a parser. A novel syntax it mis-lexes fails
//     SILENTLY TOWARD GREEN — which is exactly how v1 of this guard reported
//     "boundary 19574, late bindings 0, crossings 0, exit 0" on a file with
//     five live crossings, because it did not mask regex literals and one
//     `/class="[^"]*x"/` opened a phantom string that drifted the depth map to
//     48 by line 13234. That is why `--selftest` ships with it and runs in the
//     SAME CI step: the fixtures are the proof that the lexer still sees.
//   · It measures ONE file per invocation and says nothing about test ordering,
//     assertion quality, or whether the harness is otherwise correct.
//
// FOUR THINGS THAT ARE LOAD-BEARING, NOT POLISH — each is proven by `--selftest`
// via a deliberately crippled variant that must MISS:
//   · regex-literal masking   (`--demo-no-regex-mask` → vacuous green)
//   · transitive resolution   (`--demo-no-transitive` → misses helper-reached)
//   · shadow subtraction      (`--demo-no-shadow`     → false positive)
//   · depth-0 filtering       (an indented `await` inside a function body is
//     not a module boundary; a naive `grep await` picks the wrong line)
//
// USAGE
//   node scripts/console-tdz-order-check.mjs <file.mjs>
//   node scripts/console-tdz-order-check.mjs --selftest
//
// EXIT: 0 clean · 1 crossings found · 2 refused to measure (bad args/no await).

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
function mask(src, { maskRegex = true } = {}) {
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

  return out.join("");
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

function bindingNames(masked, declIdx) {
  const kw = /^\w+/.exec(masked.slice(declIdx))[0];
  let rest = masked.slice(declIdx + kw.length);
  if (kw === "function" || kw === "class") {
    const m = /^\s*\*?\s*([A-Za-z_$][\w$]*)/.exec(rest);
    return m ? [m[1]] : [];
  }
  // const/let/var: take the binding pattern up to `=` / `;` / newline.
  const stop = rest.search(/[=;\n]/);
  let pattern = stop < 0 ? rest : rest.slice(0, stop);
  // `{ key: local }` binds `local`, not `key`.
  pattern = pattern.replace(/([A-Za-z_$][\w$]*)\s*:/g, " ");
  return identifiers(pattern);
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
  const masked = mask(src, { maskRegex: opts.maskRegex !== false });
  const depth = depthMap(masked);
  const lineOf = lineIndex(src);

  // The boundary is DERIVED: the first `await` token sitting at depth 0.
  let boundary = -1;
  const awaitRe = /\bawait\b/g;
  let m;
  while ((m = awaitRe.exec(masked))) {
    if (depth[m.index] === 0) { boundary = m.index; break; }
  }
  if (boundary < 0) return { boundary: -1 };

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
  };
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
  if (r.boundary < 0) {
    console.log("  module boundary: NONE — no depth-0 `await` in this file");
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
  const crossing = fs.readFileSync(path.join(FIXTURES, "crossing.mjs"), "utf8");
  const clean = fs.readFileSync(path.join(FIXTURES, "clean.mjs"), "utf8");
  let bad = 0;
  const check = (label, ok, detail) => {
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
    "WITHOUT regex masking the guard goes VACUOUSLY GREEN (so masking is load-bearing)",
    (noRegex.crossings || []).length === 0,
    `crossings ${(noRegex.crossings || []).length}, boundary ${noRegex.boundary < 0 ? "NOT FOUND (depth drifted)" : `line ${noRegex.boundaryLine}`}`
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

  if (bad) {
    console.error(`::error::console-tdz-order-check: SELF-TEST FAILED (${bad} assertion(s)) — the lexer no longer sees what it claims to.`);
    return 1;
  }
  console.log("  self-test: 7/7 — the guard can still lose.");
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

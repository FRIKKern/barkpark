// __required_label_census.mjs — EVERY `required:` LABEL A BROWSER SESSION CAN
// RECEIVE HAS CURATED CONSOLE COPY.
//
// cch-w41-bl. The law this instrument enforces:
//
//     A REFUSAL LABEL WITH NO WRITTEN ARM DOES NOT RENDER AS NOTHING. IT
//     RENDERS AS THE BOUNDED-LABEL ECHO, WHICH NAMES A REMEDY NOBODY
//     VERIFIED — "an admin on this team can grant it."
//
// ── THIS IS A TRIPWIRE, NOT A FIX. NOTHING IS BROKEN ON MAIN ────────────────
//
// The row this file answers exists to REPLACE A REFUTED DEFECT (charter D463).
// The echo was suspected of rendering a confidently-wrong remedy for
// auth.ex's `forbidden(conn, required: <ability>, scope: "token")`, where no
// team admin can grant a TOKEN ability. That was PROVED PAT-ONLY: a session
// credential is stamped ["root"] unconditionally, "root" implies every ability
// any route asks for, and driving the real Router with a real session token
// over all thirteen ability-gated routes returned ZERO scope:"token"
// responses while two control arms (a read PAT, and a conn that never ran
// require_user_or_pat) both did. No live defect was repaired here, and this
// census claims none.
//
// The STRONGER result is what makes a tripwire worth building: on main the
// echo branch is unreachable for EVERY browser-reachable 403, because every
// `required` a session can receive already has a curated sentence. That is a
// property of today's label set, not a property of the code — one new
// `required:` literal, or one token ability leaking onto a browser path, and
// the echo starts rendering a remedy nobody checked. This file asserts the
// property so a FUTURE label reds instead of shipping.
//
// ── WHY IT IS NOT ANOTHER ROW IN THE BINDING CENSUS ─────────────────────────
//
// The row routes it here explicitly: __binding_census.mjs is contended and its
// fence is in dispute (charter D460). This check touches nothing in that file.
//
// ── WHY THE CONSOLE SIDE IS DRIVEN, NOT SCANNED (the anti-scan constraint) ──
//
// A source scan for `FORBIDDEN_ROLE_COPY.<label>` would answer a question about
// app.js's TEXT. The question is about what a person READS, and between the map
// and the person sit a scope branch, a precedence chain and a fallback. So the
// console side EVALUATES the shipped app.js in a node:vm sandbox and CALLS
// `friendly({error:"forbidden", scope:"team", required:<label>}, sentinel)` —
// the same entry point every 403 render path goes through.
//
// AND THE UNCURATED SHAPE IS LEARNED, NOT RETYPED. Retyping the echo sentence
// here would pin this census to a string that can be reworded, and the reword
// would green it. Instead a CONTROL label — a lowercase name no gate emits —
// is driven through the same call on every run, and its answer becomes the
// TEMPLATE: a label is UNCURATED exactly when its rendered sentence is the
// control's sentence with the control's label swapped in. That control is also
// this census's positive proof that it can still SEE an uncurated answer; if
// the control ever comes back curated (or null) the census refuses, because a
// detector that cannot recognise the thing it hunts has stopped measuring.
//
// ── THE LEFT SIDE IS DERIVED FROM THE GATES, NOT FROM A HAND LIST ───────────
//
// Every `forbidden(conn, …)` / `Auth.forbidden(conn, …)` call in auth.ex and
// router.ex that carries `required:` is classified:
//
//   literal        — `required: "admin"` contributes "admin".
//   scope:"token"  — a PAT ABILITY, not a session role. EXCLUDED, and the
//                    exclusion is read off the call's OWN `scope:` literal, not
//                    off the variable's name.
//   an identifier  — resolved as a PARAMETER of the enclosing function: the
//                    literals its callers pass at that position, followed one
//                    more hop when a caller passes another parameter through
//                    (`with_team_role(conn, "admin", …)` -> `require_team_role`
//                    -> `forbidden(conn, required: min_role, …)`).
//   anything else  — exit 2 naming the call. A label this census cannot resolve
//                    is a label it cannot check, and skipping it would be the
//                    silence the whole file exists to prevent.
//
// ── THE ONE LABEL THAT IS REACHABLE AS A LITERAL AND NOT AS A 403 ───────────
//
// `with_team_role(conn, "member", …)` puts "member" in the derived set, and no
// curated arm exists for it. It is not a hole: require_team_role 404s a
// non-member BEFORE the rank comparison, so every caller that reaches
// `rank(role) < rank(min_role)` holds a real role, and "member" is the FLOOR of
// TeamMembership's ladder — nothing ranks below it. That is derived here from
// the `@ranks` map itself, never asserted: the floor is recomputed every run, so
// re-ordering the ladder (or adding a role below "member") makes the label 403-
// reachable and this census demands curated copy for it on the next run.

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const here = path.dirname(new URL(import.meta.url).pathname);
const APP = process.argv[2] || path.join(here, "app.js");
const AUTH = process.argv[3] || path.join(here, "../../lib/barkpark_cloud/web/auth.ex");
const ROUTER = process.argv[4] || path.join(here, "../../lib/barkpark_cloud/web/router.ex");
const MEMBERSHIP = process.argv[5] || path.join(here, "../../lib/barkpark_cloud/accounts/team_membership.ex");

const rel = (p) => path.relative(process.cwd(), p);

// ONE REFUSAL VOCABULARY, the shape __preview__/exit-vocabulary.mjs emits for
// every browser instrument, so one stderr-only reader covers the whole fence.
const REFUSAL_NAME = "REQUIRED LABEL CENSUS";
const refuse2 = (reason) => {
  process.stderr.write(`!! ${REFUSAL_NAME} (exit 2): REFUSED TO MEASURE — ${reason}\n`);
  process.exit(2);
};
function die2(lines) {
  console.log("── REQUIRED-LABEL CENSUS ────────────────────────────────────────────────────");
  for (const l of lines) console.log(l);
  console.log("");
  refuse2(String(lines[0] || "the required-label set could not be derived").replace(/^FAIL\(2\):\s*/, ""));
}

function read(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (e) {
    die2([`FAIL(2): ${rel(file)} is not readable — this census has no side to measure.`, `         ${e.message}`]);
  }
}

// ── the Elixir side ─────────────────────────────────────────────────────────
// Blank `#` comments and `"""` heredocs (the @doc blocks quote refusal shapes
// verbatim — auth.ex's own docs spell `{forbidden, required: "admin"}` twice),
// but KEEP single-line string literals, which are the labels themselves.
// Length is preserved so every index into the blanked text indexes the original.
function blankElixir(src) {
  const out = src.split("");
  let i = 0;
  while (i < src.length) {
    if (src.startsWith('"""', i)) {
      const end = src.indexOf('"""', i + 3);
      const stop = end === -1 ? src.length : end + 3;
      for (let j = i; j < stop; j++) if (out[j] !== "\n") out[j] = " ";
      i = stop;
      continue;
    }
    const c = src[i];
    if (c === "#") {
      while (i < src.length && src[i] !== "\n") { out[i] = " "; i++; }
      continue;
    }
    if (c === '"') {
      i++;
      while (i < src.length && src[i] !== '"') {
        if (src[i] === "\\") i++;
        i++;
      }
      i++;
      continue;
    }
    i++;
  }
  return out.join("");
}

// Split a call's argument tail at TOP-LEVEL commas.
function splitArgs(text) {
  const parts = [];
  let depth = 0, from = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "(" || c === "{" || c === "[") depth++;
    else if (c === ")" || c === "}" || c === "]") depth--;
    else if (c === "," && depth === 0) { parts.push(text.slice(from, i)); from = i + 1; }
  }
  parts.push(text.slice(from));
  return parts.map((p) => p.trim()).filter((p) => p.length);
}

// A DEFINITION head is not a call site. `def require_team_role(conn, team_id,
// min_role)` matches every "who calls this" regex below, and counting it as a
// caller makes the function appear to pass its own parameter to itself — which
// sent the first cut of this census walking out of the function it was standing
// in and refusing in a neighbour's name. Checked at the match, once.
function isDefHead(text, nameStart) {
  return /\bdefp?\s*$/.test(text.slice(Math.max(0, nameStart - 12), nameStart));
}

// The balanced argument tail of a call whose `(` is at `open`.
function callArgs(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "(") depth++;
    else if (text[i] === ")") { depth--; if (depth === 0) return text.slice(open + 1, i); }
  }
  return null;
}

const SOURCES = [
  { label: rel(AUTH), blanked: blankElixir(read(AUTH)) },
  { label: rel(ROUTER), blanked: blankElixir(read(ROUTER)) },
];

// Every literal passed at 0-based `pos` by a caller of `fname`, plus every
// IDENTIFIER passed there (so the caller's own parameter can be followed).
function argumentsAt(fname, pos) {
  const literals = new Set();
  const identifiers = new Set();
  for (const src of SOURCES) {
    const re = new RegExp(`(^|[^A-Za-z0-9_.])(?:Auth\\.)?${fname}\\s*\\(`, "g");
    let m;
    while ((m = re.exec(src.blanked)) !== null) {
      const open = m.index + m[0].length - 1;
      if (isDefHead(src.blanked, m.index + m[1].length)) continue;
      const args = callArgs(src.blanked, open);
      if (args === null) continue;
      const parts = splitArgs(args);
      if (parts.length <= pos) continue;
      const a = parts[pos];
      const lit = /^"([a-z][a-z0-9_]*)"$/.exec(a);
      if (lit) { literals.add(lit[1]); continue; }
      const id = /^[a-z_][A-Za-z0-9_]*$/.exec(a);
      if (id) identifiers.add(a);
    }
  }
  return { literals, identifiers };
}

// The head of the function enclosing `at`, as {name, params}.
function enclosingHead(blanked, at) {
  const heads = [...blanked.slice(0, at).matchAll(/(^|\n)\s*defp?\s+([a-z_][A-Za-z0-9_]*[?!]?)\s*\(/g)];
  if (!heads.length) return null;
  const last = heads[heads.length - 1];
  const open = last.index + last[0].length - 1;
  const args = callArgs(blanked, open);
  if (args === null) return null;
  return { name: last[2], params: splitArgs(args).map((p) => p.replace(/\s*\\\\.*$/, "").trim()) };
}

// Resolve an identifier used as `required:` into the string literals that can
// actually arrive there. Two hops is enough for main and the cap is stated, not
// silent: a third hop REFUSES rather than answering a shorter set.
const HOPS = 2;
function resolveIdentifier(blanked, at, ident, srcLabel, trail) {
  if (trail.length > HOPS) {
    die2([
      `FAIL(2): \`${ident}\` at ${srcLabel} is threaded through more than ${HOPS} call hops`,
      `         (${trail.join(" -> ")}) and this census will not guess where it ends.`,
      `         A label it cannot resolve is a label it cannot check.`,
    ]);
  }
  const head = enclosingHead(blanked, at);
  if (!head) {
    die2([`FAIL(2): no enclosing function head for \`${ident}\` in ${srcLabel} — the label cannot be traced.`]);
  }
  const pos = head.params.indexOf(ident);
  if (pos === -1) {
    die2([
      `FAIL(2): \`${ident}\` is sent as a \`required:\` label in ${srcLabel} from \`${head.name}/${head.params.length}\`,`,
      `         and it is not one of that function's parameters (${head.params.join(", ") || "none"}).`,
      `         This census resolves a label through the call graph or it refuses; a local binding`,
      `         it cannot follow would be a label nobody checks.`,
    ]);
  }
  const { literals, identifiers } = argumentsAt(head.name, pos);
  const out = new Set(literals);
  for (const nested of identifiers) {
    for (const src of SOURCES) {
      const re = new RegExp(`(^|[^A-Za-z0-9_.])(?:Auth\\.)?${head.name}\\s*\\(`, "g");
      let m;
      while ((m = re.exec(src.blanked)) !== null) {
        const open = m.index + m[0].length - 1;
        if (isDefHead(src.blanked, m.index + m[1].length)) continue;
        const args = callArgs(src.blanked, open);
        if (args === null) continue;
        const parts = splitArgs(args);
        if (parts.length <= pos || parts[pos] !== nested) continue;
        for (const l of resolveIdentifier(src.blanked, m.index, nested, src.label, trail.concat(head.name))) out.add(l);
      }
    }
  }
  if (!out.size) {
    die2([
      `FAIL(2): \`${ident}\` reaches \`required:\` through \`${head.name}/${head.params.length}\` and NO caller of that`,
      `         function passes a resolvable label at position ${pos + 1}.`,
      `         An empty label set would satisfy every arm below trivially — a result, not a`,
      `         measurement.`,
    ]);
  }
  return out;
}

// ── (A) the derived SESSION-reachable label set ─────────────────────────────
const sessionLabels = new Set();
const tokenLabels = new Set();
let callSites = 0;

for (const src of SOURCES) {
  const re = /(^|[^A-Za-z0-9_.])(?:Auth\.)?forbidden\s*\(\s*conn\s*,/g;
  let m;
  while ((m = re.exec(src.blanked)) !== null) {
    const open = src.blanked.indexOf("(", m.index + m[0].length - "( conn,".length - 2);
    const at = src.blanked.lastIndexOf("(", m.index + m[0].length);
    const args = callArgs(src.blanked, at);
    if (args === null) continue;
    const parts = splitArgs(args);
    const req = parts.find((p) => /^required:\s*/.test(p));
    if (!req) continue; // a `reason:` refusal — __reason_arm_census.mjs owns those
    callSites++;
    const scope = parts.find((p) => /^scope:\s*/.test(p));
    const scopeLit = scope && /^scope:\s*"([a-z_]+)"$/.exec(scope);
    const value = req.replace(/^required:\s*/, "").trim();
    const lit = /^"([a-z][a-z0-9_]*)"$/.exec(value);
    // A PAT ability, read off the call's OWN scope literal. `scope: "token"` is
    // the only emit shape a session credential provably cannot receive, and the
    // console answers it through a different branch with a different sentence.
    if (scopeLit && scopeLit[1] === "token") {
      (lit ? [lit[1]] : [value]).forEach((v) => tokenLabels.add(v));
      continue;
    }
    if (lit) { sessionLabels.add(lit[1]); continue; }
    if (!/^[a-z_][A-Za-z0-9_]*$/.test(value)) {
      die2([
        `FAIL(2): a \`required:\` value in ${src.label} is neither a string literal nor a plain`,
        `         identifier, so this census cannot say which label a person receives.`,
        `         The value, verbatim: ${value.slice(0, 120)}`,
      ]);
    }
    for (const l of resolveIdentifier(src.blanked, m.index, value, src.label, [])) sessionLabels.add(l);
  }
}

if (!callSites) {
  die2([
    `FAIL(2): NOT ONE \`forbidden(conn, required: …)\` call was found in ${rel(AUTH)} or ${rel(ROUTER)}.`,
    `         An empty label set greens every arm below without measuring anything. Either the`,
    `         gates moved or this census's grammar stopped matching them.`,
  ]);
}

// ── (B) the rank FLOOR — the one label that is emitted and cannot 403 ───────
const ranksSrc = read(MEMBERSHIP);
const ranksLit = /@ranks\s+%\{([^}]*)\}/.exec(ranksSrc);
if (!ranksLit) {
  die2([
    `FAIL(2): no \`@ranks %{…}\` ladder in ${rel(MEMBERSHIP)}.`,
    `         The floor role is DERIVED from that map. Without it this census cannot tell a`,
    `         label that is merely unreachable from one that is an actual hole, and guessing`,
    `         either way is the confident wrong answer.`,
  ]);
}
const ranks = [...ranksLit[1].matchAll(/"([a-z_]+)"\s*=>\s*(\d+)/g)].map((r) => [r[1], Number(r[2])]);
if (ranks.length < 2) {
  die2([`FAIL(2): the \`@ranks\` ladder in ${rel(MEMBERSHIP)} parsed to ${ranks.length} role(s) — refusing to name a floor.`]);
}
const floorRank = Math.min(...ranks.map((r) => r[1]));
const floorRoles = ranks.filter((r) => r[1] === floorRank).map((r) => r[0]);

// require_team_role 404s a non-member before the rank comparison, so every
// caller that reaches it holds a REAL role; nothing ranks below the floor, so a
// floor min_role can never take the 403 arm. Derived every run — re-order the
// ladder and the exemption moves with it.
const unreachable = [...sessionLabels].filter((l) => floorRoles.includes(l)).sort();
const mustBeCurated = [...sessionLabels].filter((l) => !floorRoles.includes(l)).sort();

// ── (C) the CONSOLE side, DRIVEN ────────────────────────────────────────────
const noop = () => {};
const inertEl = {
  addEventListener: noop, removeEventListener: noop, setAttribute: noop, removeAttribute: noop,
  classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
  style: {}, hidden: false, value: "", innerHTML: "", textContent: "",
  querySelector: () => null, querySelectorAll: () => [],
};
const storage = { getItem: () => null, setItem: noop, removeItem: noop };
const hooks = {};
const sandbox = {
  __bpTestHook(h) { Object.assign(hooks, h); },
  document: {
    readyState: "loading",
    addEventListener: noop, removeEventListener: noop,
    querySelector: () => null, querySelectorAll: () => [], getElementById: () => null,
    createElement: () => ({ ...inertEl }),
    documentElement: { ...inertEl, getAttribute: () => null },
    body: { ...inertEl, appendChild: noop },
  },
  window: { addEventListener: noop, removeEventListener: noop, open: () => null, matchMedia: () => ({ matches: false, addEventListener: noop }) },
  location: { hash: "", pathname: "/", search: "", origin: "http://localhost" },
  localStorage: storage, sessionStorage: storage, navigator: {},
  URL, URLSearchParams,
  fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }),
  EventSource: function () { return { addEventListener: noop, close: noop }; },
  setTimeout: noop, clearTimeout: noop, setInterval: () => 1, clearInterval: noop,
  console,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
try {
  vm.runInContext(read(APP), sandbox);
} catch (err) {
  die2([
    `FAIL(2): evaluating ${rel(APP)} in the sandbox threw: ${err && err.message}`,
    `         The render side could not be read AT ALL, so no label's copy can be checked.`,
  ]);
}
if (typeof hooks.friendly !== "function") {
  die2([
    `FAIL(2): ${rel(APP)} did not export \`friendly\` on __bpTestHook.`,
    `         This is the exit that matters most: an unreadable render side would answer the`,
    `         same nothing for every label and certify curated copy having rendered none.`,
  ]);
}

const SENTINEL = "__census_fallback_never_rendered__";
const render = (label) => hooks.friendly({ error: "forbidden", scope: "team", required: label }, SENTINEL);

// THE CONTROL: a lowercase label no gate emits. Its sentence IS the uncurated
// template, learned at run time rather than retyped here.
const CONTROL = "zz_census_control_label";
const controlCopy = render(CONTROL);
if (typeof controlCopy !== "string" || !controlCopy || controlCopy === SENTINEL) {
  die2([
    `FAIL(2): the control label \`${CONTROL}\` rendered ${JSON.stringify(controlCopy)} instead of the`,
    `         bounded-label echo. This census learns the UNCURATED shape from that answer; with`,
    `         no answer it cannot recognise an uncurated label and every arm below is vacuous.`,
  ]);
}
if (!controlCopy.includes(CONTROL.replace(/_/g, " "))) {
  die2([
    `FAIL(2): the control label \`${CONTROL}\` rendered a sentence that does not echo it:`,
    `             ${controlCopy}`,
    `         The uncurated template is derived by swapping the control's own label out of its`,
    `         answer. A sentence that never contained it cannot be that template.`,
  ]);
}
const uncuratedFor = (label) => controlCopy.split(CONTROL.replace(/_/g, " ")).join(label.replace(/_/g, " "));

const verdicts = mustBeCurated.map((label) => {
  const copy = render(label);
  const echoed = copy === uncuratedFor(label);
  const silent = copy === SENTINEL || copy == null || copy === "";
  return { label, copy, curated: !echoed && !silent, echoed, silent };
});

// ── the report ──────────────────────────────────────────────────────────────
const pad = (s, n) => (s + " ".repeat(n)).slice(0, Math.max(n, s.length));
console.log("── REQUIRED-LABEL CENSUS ────────────────────────────────────────────────────");
console.log(`   gates    ${rel(AUTH)} + ${rel(ROUTER)} — ${callSites} forbidden(conn, required: …) call site(s)`);
console.log(`   ladder   ${rel(MEMBERSHIP)} — @ranks floor ${floorRank}: ${floorRoles.join(", ")}`);
console.log(`   console  ${rel(APP)} — friendly({error:"forbidden", scope:"team", required:…}) in a node:vm sandbox`);
console.log("");
console.log(`   control  ${CONTROL} -> ${controlCopy}`);
console.log("");
for (const v of verdicts) {
  console.log(`   ${v.curated ? "ok  " : "ECHO"}  ${pad(v.label, 22)}${v.copy}`);
}
for (const l of unreachable) {
  console.log(`   n/a   ${pad(l, 22)}the @ranks floor — require_team_role 404s a non-member before the rank arm`);
}
for (const l of [...tokenLabels].sort()) {
  console.log(`   pat   ${pad(l, 22)}scope:"token" — a PAT ability, answered by the token branch, not a session role`);
}
console.log("");

const bad = verdicts.filter((v) => !v.curated);
if (!bad.length) {
  console.log(`PASS: all ${verdicts.length} session-reachable \`required:\` label(s) render curated copy; ${unreachable.length} floor label(s) cannot 403; ${tokenLabels.size} PAT ability label(s) excluded.`);
  process.exit(0);
}
console.log(`UNCURATED — these labels a SESSION can receive render the bounded-label echo (${bad.length}):`);
for (const v of bad) {
  console.log(`   ${v.label}`);
  console.log(`      ${v.silent ? "(no evidence copy at all — the caller's fallback rendered)" : v.copy}`);
}
console.log("");
console.log("   The echo names a remedy nobody verified: it tells the reader an admin on this team");
console.log("   can grant the label, for a label no gate's author said that about. Add an arm to");
console.log("   FORBIDDEN_ROLE_COPY in cloud/priv/static/app.js (find it with");
console.log("   `grep -n 'FORBIDDEN_ROLE_COPY = {' cloud/priv/static/app.js`) that states who can");
console.log("   actually grant it — or, if nobody can, that no role does.");
console.log("");
console.log("FAIL(1): a session-reachable refusal label has no curated console copy.");
process.exit(1);

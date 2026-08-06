// __unknown_census.mjs — THE ABSENCE-AS-ANSWER CENSUS over the Cloud console SPA.
//
// Charter D382/D383 (wave 34). The law this instrument enforces:
//
//     A FAILED READ IS NOT AN EMPTY ONE.
//
// The mechanical form of the lie in app.js is a response envelope's `.ok`
// folded INTO a value-coalescing default — `(r.ok && r.data && r.data.X) || []`
// — so "the transport failed" and "the payload was genuinely empty" become the
// SAME value. The renderer then derives a DETERMINATE state ("No sites yet",
// "No API tokens yet") from that value's emptiness, and the person reads an
// assertion the console never received.
//
// A site is FLAGGED iff, inside one named function:
//   (1) FOLD        — `(<id>.ok && … ) || []` / `|| {}`
//   (2) NO ARM      — no `!<id>.ok` guard and no `<id>.ok ?` ternary for that
//                     identifier ANYWHERE in the function
//   (3) DETERMINATE — the function, or a named function it DIRECTLY calls
//                     (one hop), renders a determinate empty/complete state
//                     (`empty-state`, `!x.length`, `.length === 0`)
//
// THE GATE IS A PINNED-ALLOWLIST SET DIFF, NEVER A COUNT (D383). A count gate
// is fail-green and this was measured, not argued: mutant M5 gives one flagged
// site a real `!r.ok` arm AND ships a brand-new collapsing loader in ONE commit.
// The population stays at exactly its previous size, so `count <= N` passes
// while a new collapse ships. This census reds on any member ADDED **or**
// REMOVED and names both the arrival and the departure.
//
//   exit 0 — the flagged set EQUALS the pin
//   exit 1 — the flagged set DIFFERS from the pin (arrivals and/or departures)
//   exit 2 — a positive control was flagged, or a positive control is MISSING
//            from the source (the discrimination proof evaporated)
//
// POSITIVE CONTROLS. The five renderers below must be PRESENT and NOT flagged.
// None of them consumes a response envelope, so a census that flagged them
// would be counting `|| []` idioms rather than discriminating the defect. That
// is the point of the controls: they are the proof this instrument can tell the
// difference, not decoration.
//
// ─── THE TWO LIMITS, STATED, because an unstated limit is the same lie this
// ─── wave exists to kill:
//
//   LIMIT 1 — CALLEE INLINING IS DEPTH 1. Clause (3) inlines the bodies of
//   named functions the fold's own function calls DIRECTLY, one hop only. A
//   renderer whose determinate paint is TWO hops out is invisible here.
//   `loadProviders` (grep -n 'function loadProviders' app.js) is a KNOWN MISS —
//   its determinate render is `renderProviderPage → providerRosterHtml`. The
//   population this module reports is therefore a LOWER BOUND, not a total.
//   Owned by bp task cch-w34-bl-census-depth-limit-loadproviders.
//
//   LIMIT 2 — THE FOLD IS MATCHED BY REGEX, SO IT IS EVADABLE. `r.ok ? … : []`
//   and `r.data?.sites ?? []` express the identical collapse and do not match
//   the FOLD pattern. This census raises the COST of the mistake; it does not
//   make the mistake impossible. It is a ratchet, not a proof of absence.
//
// The mutation driver that proves this instrument can LOSE is not committed
// under cloud/priv/static (this slice's fence): it patches app.js in a temp
// copy and runs `node __unknown_census.mjs <tmp>` — which is why the file under
// census is argv[2]-overridable below. Its five mutants are M1 strip a correct
// arm, M2 add a new collapsing renderer, M3 fix a flagged one, M4 breach a
// positive control, M5 the adversarial fix-one-add-one that defeats a count.
//
// Run: node cloud/priv/static/__unknown_census.mjs

import fs from "node:fs";

const FILE = process.argv[2] || new URL("./app.js", import.meta.url).pathname;
// Report against a stable repo-relative label so the output reads the same from
// any cwd; a mutant copy passed as argv[2] keeps its own path.
const LABEL = process.argv[2] || "cloud/priv/static/app.js";
const src = fs.readFileSync(FILE, "utf8");

// ── The pin. Each row is a site the census FLAGS today and that this wave did
// ── not fix, with the bp task that owns it. Adding a row is a decision; it is
// ── never a way to quiet the gate.
const ALLOWLIST = [
  "loadSite",           // cch-w34-bl-five-remaining-absence-collapses — deployments read
  "renderOAuthButtons", // cch-w34-bl-five-remaining-absence-collapses — providers read
  "newRenderOAuth",     // cch-w34-bl-five-remaining-absence-collapses — providers read (/new)
  "fetchMembers",       // cch-w34-bl-five-remaining-absence-collapses — the `ir` invitations read (`mr` has an arm)
  "openCommandPalette", // cch-w34-bl-five-remaining-absence-collapses — sites read
];

// ── The positive controls: state renderers that are structurally clear because
// ── none of them consumes a response envelope at all.
const CONTROLS = [
  "presenceChip",
  "lifecyclePill",
  "catalogViewState",
  "metricsAgeText",
  "freshnessModel",
];

// ── function index: name -> [start,end) by brace matching ───────────────────
function indexFunctions(s) {
  const out = [];
  const re = /\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
  let m;
  while ((m = re.exec(s))) {
    const open = s.indexOf("{", re.lastIndex);
    if (open < 0) continue;
    let depth = 0, i = open, inS = null, esc = false;
    for (; i < s.length; i++) {
      const c = s[i];
      if (inS) {
        if (esc) { esc = false; continue; }
        if (c === "\\") { esc = true; continue; }
        if (c === inS) inS = null;
        continue;
      }
      if (c === '"' || c === "'" || c === "`") { inS = c; continue; }
      if (c === "/" && s[i + 1] === "/") { i = s.indexOf("\n", i); if (i < 0) break; continue; }
      if (c === "/" && s[i + 1] === "*") { i = s.indexOf("*/", i) + 1; continue; }
      if (c === "{") depth++;
      else if (c === "}") { depth--; if (depth === 0) { i++; break; } }
    }
    out.push({ name: m[1], start: m.index, end: i });
  }
  return out;
}

const fns = indexFunctions(src);
const lineOf = (off) => src.slice(0, off).split("\n").length;

// The INNERMOST named function containing this offset — the callbacks these
// folds live in are anonymous, so the enclosing NAMED loader is the site.
function enclosing(off) {
  let best = null;
  for (const f of fns) {
    if (f.start <= off && off < f.end) {
      if (!best || f.start > best.start) best = f;
    }
  }
  return best;
}

// ── (1) the fold ────────────────────────────────────────────────────────────
const FOLD = /\(\s*([A-Za-z_$][A-Za-z0-9_$.[\]]*)\.ok\s*&&[^;\n]*?\)\s*\|\|\s*(\[\]|\{\})/g;

const findings = [];
let m;
while ((m = FOLD.exec(src))) {
  const id = m[1];
  const fn = enclosing(m.index);
  const body = fn ? src.slice(fn.start, fn.end) : "";
  const idRe = id.replace(/[.[\]]/g, "\\$&");

  // (2) is there a distinct not-ok arm for THIS identifier?
  const hasArm =
    new RegExp("!\\s*" + idRe + "\\.ok").test(body) ||
    new RegExp(idRe + "\\.ok\\s*\\?").test(body);

  // (3) does a determinate empty/complete state get rendered? ONE HOP: the
  //     render frequently lives in a directly-called named renderer
  //     (loadTokens -> renderTokenList). Scoping (3) to the fold's own body
  //     makes the census FAIL GREEN on that whole shape. See LIMIT 1.
  const renders = (b) =>
    /empty-state/.test(b) ||
    /!\s*[A-Za-z_$][A-Za-z0-9_$]*\.length/.test(b) ||
    /\.length\s*===?\s*0/.test(b);
  let scope = body;
  const callRe = /\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
  let c;
  while ((c = callRe.exec(body))) {
    const callee = fns.find((f) => f.name === c[1] && f.name !== (fn && fn.name));
    if (callee) scope += "\n" + src.slice(callee.start, callee.end);
  }

  if (!hasArm && renders(scope)) {
    findings.push({
      line: lineOf(m.index),
      fn: fn ? fn.name : "<anonymous>",
      id,
      snippet: src.slice(m.index, src.indexOf("\n", m.index)).trim(),
    });
  }
}

// ── report ──────────────────────────────────────────────────────────────────
const flaggedFns = [...new Set(findings.map((f) => f.fn))].sort();
const controlsPresent = CONTROLS.filter((c) => fns.some((f) => f.name === c));
const controlsMissing = CONTROLS.filter((c) => !controlsPresent.includes(c));
const controlBreaches = CONTROLS.filter((c) => flaggedFns.includes(c));

console.log("file             :", LABEL);
console.log("controls present :", controlsPresent.join(" ") || "(none)");
console.log("controls missing :", controlsMissing.join(" ") || "(none)");
console.log("controls flagged :", controlBreaches.join(" ") || "(none)");
console.log("absence-as-answer sites:", flaggedFns.length, "(" + findings.length + " folds)");
for (const f of findings) console.log(`  ${LABEL}:${f.line}  ${f.fn}(${f.id})  ${f.snippet}`);

if (controlBreaches.length) {
  console.error("FAIL(2): the census flagged a known-correct control renderer: " + controlBreaches.join(" "));
  process.exit(2);
}
if (controlsMissing.length) {
  console.error(
    "FAIL(2): a positive control is missing from the source: " + controlsMissing.join(" ") +
    " — the census can no longer prove it discriminates rather than counts."
  );
  process.exit(2);
}

// ── THE SET DIFF. Never a count. ────────────────────────────────────────────
const pin = [...ALLOWLIST].sort();
const arrivals = flaggedFns.filter((f) => !pin.includes(f));
const departures = pin.filter((f) => !flaggedFns.includes(f));

if (arrivals.length || departures.length) {
  console.error("");
  console.error("FAIL(1): the absence-as-answer set does not match the pin.");
  for (const a of arrivals) {
    const hit = findings.find((f) => f.fn === a);
    console.error(`  ARRIVED  ${a}  (${LABEL}:${hit.line})  — a renderer now derives a determinate state from a failed read. Give it a real !ok arm, or pin it with the bp task that owns it.`);
  }
  for (const d of departures) {
    console.error(`  DEPARTED ${d}  — it no longer collapses. Delete its ALLOWLIST row (and close its bp task) so the pin keeps describing the tree.`);
  }
  console.error("");
  console.error(`  pinned  (${pin.length}): ${pin.join(" ")}`);
  console.error(`  flagged (${flaggedFns.length}): ${flaggedFns.join(" ") || "(none)"}`);
  console.error("  NOTE: the population SIZE is not the gate — a commit that fixes one collapse and ships another keeps it identical.");
  process.exit(1);
}

console.log("");
console.log(`OK: the absence-as-answer set equals its ${pin.length}-site pin.`);
process.exit(0);

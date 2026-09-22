// browser-axis-census.mjs — WHICH INSTRUMENTS DRIVE A BROWSER, AND WHICH ENGINE
// EACH ONE DRIVES. DERIVED FROM THE SOURCE, PRINTED BY THIS FILE, NEVER TYPED.
//
// ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────
// D904 recorded a defect that four waves of green could not see: both of this
// console's scroll-driven edge cues compute 0px in Firefox while their element
// is genuinely clipped. It was found by driving a real Firefox 156.0.1 over
// WebDriver BiDi BY HAND. No instrument in this tree could have found it,
// because every instrument in this tree launches Chrome and only Chrome — and
// D168 had asserted the opposite ("`.set-matrix` IS correctly cued") with NO
// BROWSER NAMED, and that unqualified sentence stood for four waves.
//
// The failure was not the missing engine. The failure was that a Chromium-only
// green was READ AS a cross-browser green, at the charter, because nothing in
// the run said otherwise. D906 rules: the axis is ACCEPTED at one engine and
// RECORDED at every banner — and this file is what makes "recorded at every
// banner" a check instead of a habit.
//
// ── WHY THE POPULATION IS DERIVED AND NOT LISTED ─────────────────────────────
// The row that commissioned this named five instruments: overflow-guard,
// breakpoint-sweep, smoke, cssom-parity, modal-oracle. Run this file rather
// than reading this paragraph — the numbers below are what it printed on
// 2026-09-22 and they are here to show the SHAPE of the error, not to be
// trusted later. It found TEN under cloud/priv/static and FIFTEEN repo-wide;
// smoke.mjs is not one of them (it launches nothing); three more live in
// api/assets/paper-editor and two in tooling/, none of which the row knew
// about; and a ninth class the row had no name for — eight DELEGATES that
// spawn a launcher rather than a browser — was invisible to it entirely.
// A hand list is a snapshot of the day it was written; every enumeration in
// this epic's history has been stale on arrival. So there is no list here.
// There is a PREDICATE, it is printed with its own reasoning per file, and it
// is proven able to say both YES and NO before it is allowed to say anything
// about this tree.
//
// ── THE PREDICATE ────────────────────────────────────────────────────────────
// A file LAUNCHES A BROWSER when all three of these hold IN ITS OWN SOURCE:
//
//   1. DISCOVERY — it declares a function whose body names a browser binary:
//      an absolute path whose basename maps to an engine family, or a
//      `command -v` / `which` / `find -name` of such a basename. Prose that
//      merely SAYS "Chrome" is not discovery: the token is basename-matched
//      against anchored patterns, so `'…found no Chrome/Chromium on this host'`
//      and `"chromium_headless_shell-1217"` do not match, and do not count.
//   2. A HOLDER — a variable assigned the RESULT of that function.
//   3. A LAUNCH — a spawn/exec whose PROGRAM is that variable.
//
// A file that spawns a LAUNCHER rather than a browser is a DELEGATE, reported
// separately: it inherits the axis of what it runs, and the two hand lists this
// tree has kept both missed that class.
//
// ── THE ENGINE IS READ OFF THE CANDIDATES, NOT OFF THE FILENAME ──────────────
// A sibling in this same wave shipped a guard whose expected value was a
// literal sitting BESIDE the guarded one, so regressing the guarded code ran
// green. The engine a banner CLAIMS is checked against the engine derived from
// that same file's own discovery candidates. Add a Firefox path to a findChrome
// and the banner reds until it says Gecko; write Gecko in a banner over a
// Chromium-only discovery and it reds the other way. Neither side is typed twice.
//
// ── WHAT THIS FILE DOES NOT CLAIM ────────────────────────────────────────────
// It does not make anything cross-browser. It makes the SCOPE of every green
// unmissable in the green itself. The second and third engines remain unmeasured
// by this repo and that is the recorded, deliberate state (D906).
//
// Usage:  node cloud/priv/static/__preview__/browser-axis-census.mjs [--root <dir>]
// Exits:  0 every launcher carries a scope line that matches its own candidates
//         1 MEASURED DEFECT — a launcher with a missing or contradicted scope line
//         2 REFUSED — a self-test failed, or the walk found no launcher at all

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createExitVocabulary } from "./exit-vocabulary.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..", "..", "..", "..");

// ── the three engine families, and the basenames that mean each one ──────────
//
// THE FAMILY LIST IS THE DENOMINATOR IN EVERY BANNER ("1 of 3"). It is here, in
// one place, so the sentence every instrument prints cannot drift from the set
// this file checks against.
export const ENGINE_FAMILIES = ["Blink", "Gecko", "WebKit"];

// Anchored on the BASENAME. Anchoring is what separates a discovery candidate
// from a sentence containing the word "Chrome".
export const ENGINE_OF = [
  [/^google[ -]chrome(-stable)?$/i, "Blink"],
  [/^chrome(-headless-shell)?$/i, "Blink"],
  [/^chromium(-browser)?$/i, "Blink"],
  [/^headless_shell$/i, "Blink"],
  [/^(msedge|microsoft edge)$/i, "Blink"],
  [/^brave(-browser)?$/i, "Blink"],
  [/^firefox(-bin|-esr)?$/i, "Gecko"],
  [/^(firefox nightly|firefox developer edition|librewolf)$/i, "Gecko"],
  [/^safari$/i, "WebKit"],
  [/^safaridriver$/i, "WebKit"],
  [/^minibrowser$/i, "WebKit"],
  [/^epiphany(-browser)?$/i, "WebKit"],
];

export function engineOfBasename(base) {
  for (const [re, fam] of ENGINE_OF) if (re.test(base)) return fam;
  return null;
}

// ── THE SCOPE LINE ───────────────────────────────────────────────────────────
// One sentence, generated from the derived engine set, so the instrument's
// banner and this census cannot disagree about what was driven. A reader who
// sees a green run sees the denominator in the same breath.
export function scopeLine(engines) {
  const set = [...new Set(engines)].sort();
  return (
    `>> browser axis  ${set.join(" + ")} — ${set.length} of ${ENGINE_FAMILIES.length} engine families ` +
    `(${ENGINE_FAMILIES.join(" · ")}). A green here is NOT a cross-browser green.`
  );
}

// A scope line is only recorded if it is PRINTED. Source that holds the sentence
// in a comment or a dead constant records nothing, so the line must sit on a
// source line that also writes to a stream.
const WRITE_ON_LINE = /(process\.stdout\.write|process\.stderr\.write|console\.(log|error)|(^|[^\w.])out\s*\(|(^|\s)echo\s)/;

// ── the parser ───────────────────────────────────────────────────────────────

// Every FILESYSTEM PATH in the file — two segments or more, so a leading slash
// is not enough — plus the argument of the three shell-shaped lookups that name
// a binary without writing a path.
//
// NOT A STRING TOKENIZER, AND THAT IS THE SECOND PARSER LESSON IN THIS FILE.
// The first draft matched quoted literals with a quote-pair regex. These files
// are dense with English prose in comments, and ONE apostrophe in a word like
// `instrument's` opens a phantom string literal that runs to the next
// apostrophe thousands of characters away, swallowing the real candidate list
// inside it. Measured: accent-role-separation.mjs, overflow-guard.mjs,
// breakpoint-sweep.mjs and adjacency-guard.mjs all reported "no function names
// a browser binary" while each carries the same six-path findChrome(). The
// census read CLEAN because it read NOTHING, which is the failure mode this
// whole campaign is about. A path shape is apostrophe-immune.
function binaryTokens(src) {
  const out = [];
  for (const m of src.matchAll(/\/(?:[A-Za-z0-9 ._+-]+\/)+[A-Za-z0-9 ._+-]+/g)) out.push({ text: m[0], at: m.index });
  for (const m of src.matchAll(/(?:command -v|which|-name)\s+'?"?([A-Za-z0-9 ._-]+)'?"?/g)) out.push({ text: m[1], at: m.index });
  return out;
}

// The spans of every top-level function body, so "the binary is named inside a
// discovery function" is a fact about position and not a guess.
//
// THE END IS THE FIRST `}` IN COLUMN 0, NOT A BRACE COUNT. A brace counter is
// the obvious implementation and it is WRONG here, measured: these files are
// hundreds of KB of template literals, regex literals and comment prose full of
// unbalanced braces, and a counter that drifts does not fail loudly — it
// silently hands back a body span that excludes the candidate list, so the file
// drops out of the census and the census reports a SMALLER, CLEAN population.
// The first draft of this file did exactly that and found 4 launchers where
// there are 10. Every file in this tree indents its function bodies, so a `}`
// at column 0 closes a top-level declaration; the self-tests below hold this
// rule to a fixture it must still parse.
function functionBodies(src, isShell) {
  const decls = isShell
    ? [...src.matchAll(/(?:^|\n)(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{/g)]
    : [...src.matchAll(/(?:^|\n)(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(/g)];
  const bodies = [];
  for (const m of decls) {
    const open = src.indexOf("{", m.index + m[0].length - 1);
    if (open < 0) continue;
    const close = src.indexOf("\n}", open);
    bodies.push({ name: m[1], start: open, end: close < 0 ? src.length : close });
  }
  return bodies;
}

export function classifySource(rel, src) {
  const isShell = rel.endsWith(".sh");
  const tokens = binaryTokens(src);
  const bodies = functionBodies(src, isShell);

  // 1. DISCOVERY — a function whose body names a binary that maps to an engine.
  const discovery = new Map(); // fn name -> [{ base, engine }]
  for (const b of bodies) {
    const hits = [];
    for (const t of tokens) {
      if (t.at < b.start || t.at > b.end) continue;
      const base = path.basename(t.text.replace(/\/+$/, ""));
      const engine = engineOfBasename(base);
      if (engine) hits.push({ base, engine, candidate: t.text });
    }
    if (hits.length) discovery.set(b.name, hits);
  }
  if (!discovery.size) return { rel, kind: "none", engines: [], candidates: [], why: "no function names a browser binary" };

  // 2. A HOLDER — a variable bound to that function's result.
  const holders = new Map(); // var -> fn
  for (const fn of discovery.keys()) {
    const re = isShell
      ? new RegExp(`([A-Za-z_][\\w]*)=\\s*"?\\$\\(\\s*${fn}\\s*\\)`, "g")
      : new RegExp(`(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*(?:await\\s+)?${fn}\\s*\\(`, "g");
    for (const m of src.matchAll(re)) holders.set(m[1], fn);
  }
  const candidates = [...discovery.values()].flat();
  const engines = [...new Set(candidates.map((c) => c.engine))].sort();
  if (!holders.size) {
    return { rel, kind: "discovery-only", engines, candidates, why: "a discovery function exists but nothing binds its result" };
  }

  // 3. A LAUNCH — a spawn/exec whose PROGRAM is that variable.
  const launches = [];
  const launchRe = isShell
    ? /(?:^|\n)\s*"?\$\{?([A-Za-z_][\w]*)\}?"?\s*(?:\\\s*\n|[^\n=])/g
    : /\b(?:spawn|spawnSync|execFile|execFileSync)\s*\(\s*([A-Za-z_$][\w$]*)/g;
  for (const m of src.matchAll(launchRe)) if (holders.has(m[1])) launches.push(m[1]);
  if (!launches.length) {
    return { rel, kind: "discovery-only", engines, candidates, why: "the discovered binary is bound but never spawned" };
  }

  return { rel, kind: "launcher", engines, candidates, holders: [...holders.keys()], why: `${[...discovery.keys()].join("/")}() -> ${[...new Set(launches)].join("/")} -> spawn` };
}

// The banner check. THE EXPECTED VALUE IS THIS FILE'S OWN DERIVATION FROM THE
// GUARDED SOURCE — never a literal kept beside it.
export function bannerVerdict(entry, src) {
  const want = scopeLine(entry.engines);
  const at = src.indexOf(want);
  if (at >= 0) {
    const lineStart = src.lastIndexOf("\n", at) + 1;
    const lineEnd = src.indexOf("\n", at);
    const line = src.slice(lineStart, lineEnd < 0 ? src.length : lineEnd);
    if (!WRITE_ON_LINE.test(line)) return { ok: false, reason: "the scope line is present but NOT PRINTED — it sits on a line that writes to no stream", want };
    return { ok: true, want };
  }
  // Present but contradicted is a different, louder fault than absent: it means
  // a human wrote an engine claim that the file's own candidates refute.
  // NOT ANCHORED TO THE LINE START: the sentence lives INSIDE a write call, so
  // a `^` here would silently demote every contradiction to "absent" and lose
  // the one diagnosis a reader cannot work out for themselves.
  const other = />> browser axis  [^"`\\\n]*/.exec(src);
  if (other) return { ok: false, reason: `its scope line claims ${JSON.stringify(other[0].trim())}, which its own discovery candidates (${entry.engines.join(" + ")}) refute`, want };
  return { ok: false, reason: "it prints no browser-axis scope line at all", want };
}

// ── the walk ─────────────────────────────────────────────────────────────────

const SKIP_DIRS = new Set([".git", "node_modules", "_build", "deps", ".elixir_ls", "cover", ".turbo", "worktrees", "priv/static/assets"]);
const EXTS = new Set([".mjs", ".js", ".sh", ".cjs"]);

function walk(root, rel = "", acc = []) {
  let ents;
  try { ents = fs.readdirSync(path.join(root, rel), { withFileTypes: true }); } catch { return acc; }
  for (const e of ents) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      walk(root, r, acc);
    } else if (EXTS.has(path.extname(e.name))) acc.push(r);
  }
  return acc;
}

// ── self-tests: the predicate must be able to say YES and to say NO ──────────
//
// A uniform verdict is the signature of a broken instrument. These arms run
// BEFORE the measurement and refuse rather than measure, because a walker that
// has gone blind reports a clean tree.
// ONE FIXTURE BUILDER, PARAMETERISED — never a `.replace()` off a sibling
// fixture. anchored-replace.test.mjs's ratchet is right about why: a bare
// string-needle replace takes the first match and goes SILENT when the needle
// drifts, so a Gecko fixture built by find-and-replace can quietly stay a Blink
// one and the arm that is supposed to prove the mapper is not stuck proves
// nothing instead. Built this way the two fixtures differ in the CANDIDATES and
// in nothing else, by construction.
function fixture({ paths, holder = true, launch = true }) {
  return [
    "function findChrome() {",
    `  const candidates = [${paths.map((x) => JSON.stringify(x)).join(", ")}];`,
    "  for (const c of candidates) { try { fs.accessSync(c); return c; } catch {} }",
    "  return null;",
    "}",
    holder ? "const chromeBin = findChrome();" : "findChrome();",
    launch ? 'const child = spawn(chromeBin, ["--headless=new"]);' : "",
    "",
  ].join("\n");
}
const FIXTURE_BLINK = fixture({ paths: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/chromium"] });
const FIXTURE_GECKO = fixture({ paths: ["/Applications/Firefox.app/Contents/MacOS/firefox", "/usr/bin/firefox"] });
const FIXTURE_NO_LAUNCH = fixture({ paths: ["/usr/bin/chromium"], launch: false });
const FIXTURE_NO_HOLDER = fixture({ paths: ["/usr/bin/chromium"], holder: false });
// Prose naming a browser, and a non-path token that merely CONTAINS one: the
// two shapes this tree actually carries (badcode-freeze.test.mjs's refusal copy
// and byte-comparability.mjs's `chromium_headless_shell-1217`).
const FIXTURE_PROSE = `
function why() { return 'shoot.sh found no Chrome/Chromium on this host. Install one, or set CHROME=.'; }
const SHOOT = "chromium_headless_shell-1217";
const child = spawn(SHOOT, []);
`;

function selfTests() {
  const fails = [];
  const yes = classifySource("fixture-blink.mjs", FIXTURE_BLINK);
  if (yes.kind !== "launcher") fails.push(`the predicate cannot say YES: a synthetic discovery+holder+spawn classified ${yes.kind}`);
  if (yes.engines.join() !== "Blink") fails.push(`Blink fixture derived ${JSON.stringify(yes.engines)}`);

  // NOT A CONSTANT. If the mapper were stuck this arm is the one that catches it.
  const gecko = classifySource("fixture-gecko.mjs", FIXTURE_GECKO);
  if (gecko.kind !== "launcher" || gecko.engines.join() !== "Gecko") {
    fails.push(`the engine is not derived: a Firefox-only fixture classified ${gecko.kind}/${JSON.stringify(gecko.engines)} — the mapper answers the same thing regardless of its input`);
  }

  // CAN SAY NO, three ways: no launch, no holder, prose only.
  if (classifySource("f.mjs", FIXTURE_NO_LAUNCH).kind !== "discovery-only") {
    fails.push("the predicate cannot say NO: a file that never spawns the binary still classified as a launcher");
  }
  if (classifySource("f.mjs", FIXTURE_NO_HOLDER).kind !== "discovery-only") {
    fails.push("the predicate cannot say NO: a file that binds nothing still classified as a launcher");
  }
  if (classifySource("f.mjs", FIXTURE_PROSE).kind !== "none") {
    fails.push("the predicate cannot say NO: prose naming a browser classified as discovery");
  }

  // THE BANNER CHECK MUST BE ABLE TO REFUTE. A Gecko claim over Blink candidates
  // is the exact shape of the guard-reads-its-own-expectation bug.
  const blinkEntry = classifySource("f.mjs", FIXTURE_BLINK);
  if (bannerVerdict(blinkEntry, `${FIXTURE_BLINK}\nprocess.stdout.write("${scopeLine(["Blink"])}\\n");`).ok !== true) {
    fails.push("the banner check cannot say YES on a correct, printed scope line");
  }
  if (bannerVerdict(blinkEntry, `${FIXTURE_BLINK}\nprocess.stdout.write("${scopeLine(["Gecko"])}\\n");`).ok !== false) {
    fails.push("the banner check cannot say NO: a Gecko claim over Blink-only candidates passed");
  }
  if (bannerVerdict(blinkEntry, `${FIXTURE_BLINK}\n// ${scopeLine(["Blink"])}\n`).ok !== false) {
    fails.push("the banner check cannot say NO: a scope line in a COMMENT counted as printed");
  }
  return fails;
}

// ── main ─────────────────────────────────────────────────────────────────────

async function main() {
  const vocab = createExitVocabulary({ instrument: "browser-axis-census", subject: "the browser axis of this repo's driven instruments" });
  const out = (s) => process.stdout.write(s);

  const argRoot = process.argv.indexOf("--root");
  const root = argRoot > 0 ? path.resolve(process.argv[argRoot + 1]) : REPO_ROOT;
  // The tree whose banners are ENFORCED. Everything else is reported and not
  // policed: this row owns the console's fleet, and a census that silently
  // policed another epic's instruments would be a scope it never declared.
  const ENFORCED = "cloud/priv/static/";

  const fails = selfTests();
  if (fails.length) return vocab.refuse(`self-test: ${fails.join("; ")}`);

  // THIS FILE EXCLUDES ITSELF, BY IDENTITY RATHER THAN BY NAME. Its self-test
  // fixtures are REAL-SHAPED on purpose — a fixture encoding a shape the tree
  // never emits proves nothing — so at source level this census is
  // indistinguishable from the launchers it counts, and it classified ITSELF as
  // one. The exclusion is `this module's own path`, computed, so it cannot
  // grow into a skip LIST: a second file wanting out would have to earn it.
  const SELF = path.relative(root, fileURLToPath(import.meta.url));

  const files = walk(root).filter((rel) => rel !== SELF);
  const entries = [];
  for (const rel of files) {
    let src;
    try { src = fs.readFileSync(path.join(root, rel), "utf8"); } catch { continue; }
    const e = classifySource(rel, src);
    if (e.kind !== "none") entries.push({ ...e, src });
  }
  const launchers = entries.filter((e) => e.kind === "launcher").sort((a, b) => a.rel.localeCompare(b.rel));
  const discoveryOnly = entries.filter((e) => e.kind === "discovery-only").sort((a, b) => a.rel.localeCompare(b.rel));

  // DELEGATES — a file that spawns a LAUNCHER rather than a browser. Derived
  // from the launcher set this run just computed, never from a basename list.
  //
  // THE MENTION MUST BE AT THE RUN SITE. A first draft asked only "does this
  // file name a launcher anywhere, and does it spawn anything" and reported
  // accent-role-separation.mjs as a delegate of cssom-parity.mjs on the
  // strength of a COMMENT — which is the same mistake, one level up, as reading
  // a Chromium green as a cross-browser green.
  const launcherBases = new Set(launchers.map((l) => path.basename(l.rel)));
  const delegates = [];
  for (const rel of files) {
    if (launcherBases.has(path.basename(rel))) continue;
    let src;
    try { src = fs.readFileSync(path.join(root, rel), "utf8"); } catch { continue; }
    // WHAT EACH NAME IS BOUND TO, so a run site that says `[SHOOT]` or `"$GATE"`
    // resolves. Naming the launcher at the run site is the common case and the
    // indirect one is the common case in THIS tree: both were missed by the
    // first two drafts, in opposite directions.
    const bound = new Map();
    for (const m of src.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=([^\n;]*)/g)) bound.set(m[1], m[2]);
    for (const m of src.matchAll(/(?:^|\n)\s*([A-Za-z_][\w]*)=([^\n]*)/g)) bound.set(m[1], m[2]);

    const sites = [];
    for (const m of src.matchAll(/\b(?:spawn|spawnSync|execFile|execFileSync|exec)\s*\(([\s\S]{0,400})/g)) sites.push(m[1]);
    if (rel.endsWith(".sh")) {
      for (const m of src.matchAll(/(?:^|[\n;&|(\s])(?:node|bash|sh|"?\$\{?\w+\}?"?)\s+[^\n]*/g)) sites.push(m[0]);
    }

    const runs = new Set();
    for (const site of sites) {
      for (const b of launcherBases) {
        if (site.includes(b)) { runs.add(b); continue; }
        for (const id of site.matchAll(/[A-Za-z_$][\w$]*/g)) {
          if ((bound.get(id[0]) || "").includes(b)) { runs.add(b); break; }
        }
      }
    }
    if (!runs.size) continue;
    const of = [...runs].sort();
    const eng = [...new Set(launchers.filter((l) => of.includes(path.basename(l.rel))).flatMap((l) => l.engines))].sort();
    delegates.push({ rel, runs: of, engines: eng });
  }

  out(`>> browser-axis-census — every instrument that launches a browser, and which engine each one drives\n`);
  out(`>> root       ${root === REPO_ROOT ? "(repo root)" : root}\n`);
  out(`>> scanned    ${files.length} file(s) [${[...EXTS].sort().join(" ")}], skipping dirs [${[...SKIP_DIRS].sort().join(" ")}]\n`);
  out(`>> predicate  DISCOVERY (a function naming a browser binary, basename-anchored) -> HOLDER (a var bound to its result) -> LAUNCH (a spawn whose PROGRAM is that var)\n`);
  out(`>> families   ${ENGINE_FAMILIES.join(" · ")} — the denominator every scope line prints\n`);
  out(`>> enforced   scope lines are REQUIRED under ${ENFORCED} and reported-only elsewhere\n`);
  out(`>> self       ${SELF} is excluded from its own population: its self-test fixtures are launcher-shaped by design and it spawns nothing\n\n`);

  if (!launchers.length) {
    return vocab.refuse(
      `the walk found ZERO browser launchers under ${root}. This tree has had at least one since 2026-08; a census that reports an empty population has gone blind, and an empty population would pass the banner check vacuously.`,
    );
  }

  out(`>> LAUNCHERS (${launchers.length}) — resolve a browser binary and spawn it\n`);
  const problems = [];
  for (const l of launchers) {
    const bases = [...new Set(l.candidates.map((c) => c.base))];
    const scoped = l.rel.startsWith(ENFORCED);
    const v = bannerVerdict(l, l.src);
    const mark = v.ok ? "✓" : scoped ? "✗" : "·";
    out(`   ${mark} ${l.rel}\n`);
    out(`       engine     ${l.engines.join(" + ")}  (from its own candidates: ${bases.join(", ")})\n`);
    out(`       chain      ${l.why}\n`);
    out(`       scope line ${v.ok ? "PRINTED and consistent with those candidates" : (scoped ? "MISSING — " : "absent (not enforced outside the console tree) — ") + v.reason}\n`);
    if (!v.ok && scoped) problems.push({ rel: l.rel, reason: v.reason, want: v.want });
  }

  if (discoveryOnly.length) {
    out(`\n>> NAMES A BROWSER BINARY BUT NEVER SPAWNS ONE (${discoveryOnly.length}) — reported so the class is not silent\n`);
    for (const d of discoveryOnly) out(`   · ${d.rel} — ${d.why} (${d.engines.join(" + ") || "no engine"})\n`);
  }

  if (delegates.length) {
    out(`\n>> DELEGATES (${delegates.length}) — spawn a LAUNCHER rather than a browser, and inherit its axis\n`);
    for (const d of delegates) out(`   · ${d.rel} -> ${d.runs.join(", ")} (${d.engines.join(" + ") || "unknown"})\n`);
  }

  const allEngines = [...new Set(launchers.flatMap((l) => l.engines))].sort();
  const missing = ENGINE_FAMILIES.filter((f) => !allEngines.includes(f));
  out(`\n>> AXIS       ${allEngines.join(" + ")} across ${launchers.length} launcher(s). UNMEASURED BY THIS REPO: ${missing.join(", ") || "none"}.\n`);
  out(`>> RULING     D906 — accept-and-record. The axis stays at ${allEngines.join(" + ")}; every launcher above must PRINT its scope line so no green in this repo can be read as a cross-browser green. D904 is the cost of not having done that.\n`);

  if (problems.length) {
    for (const p of problems) out(`\n   ✗ ${p.rel} — ${p.reason}\n     ADD THIS LINE to its banner, printed, verbatim:\n       ${p.want}\n`);
    return vocab.defect(
      `${problems.length} of ${launchers.filter((l) => l.rel.startsWith(ENFORCED)).length} console launcher(s) do not print a scope line that matches their own discovery candidates. Each is named above with the exact line it must print. This is not cosmetic: D168 asserted a cross-browser property from a Chromium-only green and stood for four waves.`,
    );
  }
  return vocab.pass(
    `${launchers.length} launcher(s), ${allEngines.join(" + ")} only, every console one printing a scope line derived from its own candidates; ${missing.join(" and ")} unmeasured and said so out loud.`,
  );
}

if (import.meta.url === `file://${process.argv[1]}`) await main();

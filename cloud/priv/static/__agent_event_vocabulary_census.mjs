// __agent_event_vocabulary_census.mjs — THE AGENT-EVENT VOCABULARY CENSUS:
// the instance Timeline must not name an event type nothing can produce, and
// must not leave a type that IS produced rendering as a raw slug.
//
// Charter D341/D575/D576/D578 (wave 51). The law this instrument enforces:
//
//     A TITLE IS A PROMISE. A TYPE THE CONSOLE TITLES BUT NOTHING WRITES IS A
//     ROW A USER WILL WAIT FOR FOREVER; A TYPE THAT ARRIVES WITH NO TITLE IS A
//     LOWERCASE SLUG IN A HUMAN FEED.
//
// The Timeline is the register where a user cannot check the claim at all — the
// console is the only witness there is. Before this census, TLV_EVENT_TITLES
// gave human titles to `backup`, `tls` and `content`, which have ZERO producers
// anywhere in the control plane and never have had one in the history of main;
// `tlvVerdictOf` answered "completed" for a backup that cannot exist; the empty
// state told a brand-new owner, in the console's own voice, that "backups" would
// appear here. Meanwhile `space` — which the agent beat DOES write — was absent
// from the map and rendered as the raw word "space".
//
// ── THE THREE ARMS ──────────────────────────────────────────────────────────
//
//   A  RENDERED  = the keys of TLV_EVENT_TITLES in cloud/priv/static/app.js
//   B  PRODUCED  = the literal 2nd argument of every `Registry.record_event(`
//                  under cloud/lib/**/*.ex
//   C  FIXTURED  = the types the console's fixture corpus manufactures, via
//                  `ev(…, "…")` or `EV(…, "…")`, in EVERY `*.mjs` under
//                  cloud/priv/static (recursively). ARM C'S SUBJECT IS A
//                  PREDICATE, NOT A FILE LIST — see "ARM C SCANS A ROOT".
//
// and the three failures it can name:
//
//   rendered-with-no-producer        A \ B — the console stages a welcome for
//                                    an event nothing in the plane can write.
//   produced-with-no-renderer        B \ A — a produced type reaches the feed
//                                    with no human title and renders raw.
//   fixture-manufactures-unproducible  C \ B — the preview corpus invents the
//                                    impossible traffic, which is how a dead
//                                    render branch comes to look exercised.
//
// The direction is BOTH WAYS by design and the arms are DERIVED SETS, never
// counts (charter D383): a commit that drops one title and adds another cannot
// hold this green.
//
// ── SIDE A IS READ BY RUNNING, NOT BY PARSING (charter D341, BINDING) ───────
//
// app.js is evaluated verbatim inside a node:vm sandbox whose
// document.readyState is "loading" — the same recipe __app.test.mjs and
// __preview__/__plan_features_dump.mjs use — and the vocabulary is read off
// `__bpTestHook.tlvEventTitles`, which app.js derives with
// Object.keys(TLV_EVENT_TITLES). What this guard sees is what the render path
// itself computes.
//
// A LITERAL PARSE WAS MEASURED AND REJECTED: a naive object-literal regex run
// against a value-preserving `forEach` refactor of the map emitted EIGHTY false
// orphans with a confident verdict, while the vm run reported the one real
// defect. D341 rules a false red in a merge-blocking guard WORSE than the miss
// it replaces — a gate people learn to disbelieve stops being a gate.
//
// ── SIDE B IS cloud/lib/** ONLY, AND THAT IS LOAD-BEARING ───────────────────
//
// A variant globbing `cloud/**` runs GREEN on the very tree this census exists
// to red, and it does so on the strength of TEST FIXTURES. registry_test.exs's
// ordering test supplied `backup` and `tls` as false producers until cch-w51-bl
// rewrote it onto real types; accounts_test.exs still supplies `content`;
// registry_test.exs's deliberate negative-test type `meltdown` is invented
// alongside them; and `__app.test.mjs` manufactured `backup`/`tls` EV() rows
// for the timeline grammar until arm C was widened to read it (below) and they
// were retyped. The wide variant certifies the exact lie. Tests are not
// producers.
//
// ── ARM C SCANS A ROOT, AND THAT IS THE WHOLE OF THIS FIX ───────────────────
//
// Arm C used to read ONE file — __preview__/scenarios.mjs — while EIGHT rows
// typed `backup`/`tls` sat in __app.test.mjs, in the same directory, built by
// the same kind of builder. This file DECLARED `fixture-manufactures-
// unproducible` as a failure mode, IMPLEMENTED a check for it, and aimed that
// check at one file while an instance of the failure lived in another. The
// header above even ADMITTED the rows existed. A census that names a failure
// class and cannot see an instance of it is worse than no census, because its
// green gets read as coverage over ground it never walked.
//
// The repair is NOT "add __app.test.mjs to a list". A hand-kept list is a
// SNAPSHOT: it is correct on the day it is written and silently short the day
// after, and the next fixture file arrives exactly the way this one did. Arm C
// takes a ROOT and a RULE instead:
//
//     every `*.mjs` under cloud/priv/static, recursively, is scanned; the ones
//     that call the `ev(`/`EV(` builder with a literal type ARE the fixture
//     corpus, and the ones that do not, are not.
//
// Nothing is exempted — not even this file. Its own prose writes `ev(…, "…")`
// with an ellipsis where the type would be, which the extractor's
// `"([a-z][a-z0-9_]*)"` cannot match, so it contributes zero rows by the RULE
// rather than by a waiver. MEASURED 2026-09-17 on origin/main d9f02af18: 68
// `*.mjs` files under the root, exactly TWO contribute rows (__app.test.mjs 52,
// __preview__/scenarios.mjs 7) and 66 contribute none. That zero is a measured
// zero — the same scan returned 59 rows from the other two files in the same
// pass, so the extractor demonstrably CAN return a non-empty answer.
//
// The vacuity guard moves with the reach: FLOORS.fixtureFiles is the number of
// files that must contribute at least one row. A builder renamed in one file
// would leave the type totals intact (the other file still supplies them) and
// this arm would go on certifying a file it had stopped reading — which is the
// blindness being fixed here, re-arriving one level up.
//
// Heredocs and `#` comments are stripped before the scan for the same reason:
// telemetry.ex's @moduledoc QUOTES a call site (`Registry.record_event(barkpark,
// "health", report)`) as prose, and registry.ex's own `@spec`/`def` carry no
// `Registry.` prefix so they never match.
//
// ── IT MUST NOT BE ABLE TO GO GREEN BY FAILING TO READ (exit 2) ─────────────
//
// An unreadable render side must NEVER read as agreement: an empty rendered set
// would make every arm trivially satisfied and this file would certify silence.
// So a missing/renamed __bpTestHook.tlvEventTitles, a non-array, or an app.js
// that throws is exit 2 — a REFUSAL TO MEASURE, not a pass. The same for a
// per-arm floor breach: main today has 4 producers, 4 titles and 3 fixtured
// types, so an arm that comes back under its floor is a broken extractor, not a
// clean tree.
//
// ── HONEST LIMITS, stated, because an unstated limit is the same lie ────────
//
//   LIMIT 1 — ARM B MATCHES `Registry.record_event(` WITH A LITERAL 2nd ARG. A
//   producer emitted through a wrapper, or with the type bound one hop back in a
//   variable, is INVISIBLE to it. That direction fails SAFE for the crown arm
//   (an unseen producer cannot excuse a title) but it under-reports side B, so
//   `produced-with-no-renderer` proves presence, never absence. Make the type
//   literal at the call site, or teach this file the new shape, in the same
//   commit that introduces it.
//
//   LIMIT 2 — ARM C READS `ev(`/`EV(` CALLS WITH A LITERAL TYPE. A fixture that
//   inlines an event object literal instead of calling the builder is invisible
//   to arm C. This limit is REAL and was exercised: one of the eight retired
//   backup/tls rows was written `{ id: 2, type: "backup", inserted_at:
//   "garbage" }`, which no call-shaped extractor can see; it was retyped by
//   hand. Widening the extractor to a bare `type: "…"` scan was MEASURED and
//   REFUSED: run over __app.test.mjs on d9f02af18 it returns 61 matches and 19
//   distinct words, of which only `health`, `verify` and `backup` are event
//   types at all — the rest are notification channels (`slack`, `discord`),
//   webhook and paper and task nouns, and deliberate junk fixtures (`nonsense`,
//   `wat`). That arm would red every run for the wrong reason. A noisy arm gets
//   muted, and a muted arm is the blindness this file exists to end.
//
//   LIMIT 3 — IT PROVES A TITLE EXISTS, NOT THAT THE TITLE IS GOOD. Whether
//   "Disk space" is the right words is a judgement, pinned in __app.test.mjs.
//   This is a vocabulary-coverage gate.
//
//   LIMIT 4 — AgentEvent's @types allowlist is NOT an arm and deliberately so
//   (charter D576). DECLARED is not PRODUCED, and it is PRODUCED that a title
//   promises. cch-w51-bl since dropped `backup` and `tls` from that allowlist —
//   they had neither a producer nor a consumer — and KEPT `content`, which has
//   no producer but does have a live server consumer in accounts.ex
//   (published_doc?/1, the onboarding checklist). The allowlist's own both-ways
//   guard lives in Elixir, next to the changeset it governs:
//   cloud/test/barkpark_cloud/registry/agent_event_test.exs. This file is still
//   the CONSOLE side and still does not read @types.
//
// Exit codes:
//   0 — the three arms agree
//   1 — at least one disagreement, each offending type named with its side
//   2 — the instrument lost its footing and is making NO claim either way
//
// Not web-reachable: Plug.Static's `only:` allowlist does not carry files whose
// name begins `__` (pinned by cloud/test/web/static_allowlist_test.exs).
//
// Run: node cloud/priv/static/__agent_event_vocabulary_census.mjs
//      node cloud/priv/static/__agent_event_vocabulary_census.mjs <app.js> <lib-dir> <fixture-root-or-file>
//   (the argv overrides exist so a mutation driver can point the census at
//    patched COPIES without writing inside this slice's fence — the fail-before
//    half of this guard's discrimination proof is run exactly that way. argv[4]
//    accepts a DIRECTORY, scanned by the same rule, or a single FILE, which is
//    the shape older drivers passed when they handed it scenarios.mjs; a single
//    file also relaxes FLOORS.fixtureFiles to 1, because one file cannot be two)

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const here = path.dirname(new URL(import.meta.url).pathname);
const APP = process.argv[2] || path.join(here, "app.js");
const LIB = process.argv[3] || path.join(here, "../../lib");
// ARM C'S SUBJECT IS A ROOT, NOT A FILE (see "ARM C SCANS A ROOT" above). The
// default is this directory: every `*.mjs` beneath it is offered to the
// extractor, and the ones that call the builder ARE the fixture corpus.
const FIXTURE_ROOT = process.argv[4] || here;

// Report against stable repo-relative labels so the output reads the same from
// any cwd; a mutant copy passed on argv keeps its own path.
const APP_LABEL = process.argv[2] || "cloud/priv/static/app.js";
const LIB_LABEL = process.argv[3] ? process.argv[3] + "/**/*.ex" : "cloud/lib/**/*.ex";
const FIXTURE_ROOT_LABEL = process.argv[4] || "cloud/priv/static";

// The per-arm vacuity floors. main today: 4 producers (health/space/verify/
// status), 4 titles, 4 fixtured types. An arm under its floor is a broken
// extractor reporting a clean tree — the exact vacuous green this epic kills.
//
// FIXTURED ROSE 3 -> 4 with the widening: __app.test.mjs manufactures `space`
// rows the preview corpus does not, so the root scan genuinely sources one more
// type than scenarios.mjs alone. Leaving the floor at 3 would have let the whole
// second file drop back out of the read without tripping anything.
//
// fixtureFiles IS THE REACH FLOOR and it is the one that guards THIS fix: the
// count of files under the root that contribute at least one row. Type totals
// alone cannot notice a file going silent, because the surviving file still
// supplies the same types — that is precisely how arm C certified a corpus it
// was not reading. Two files contribute today.
const FLOORS = { produced: 4, rendered: 4, fixtured: 4, fixtureFiles: 2 };


// ── THE ONE REFUSAL VOCABULARY (cch-w63-bl) ─────────────────────────────────
// EVERY exit-2 path in this file ends with exactly ONE line, on STDERR:
//
//     !! AGENT EVENT VOCABULARY CENSUS (exit 2): REFUSED TO MEASURE — <reason>
//
// It is the same shape __preview__/exit-vocabulary.mjs already emits for the
// browser instruments, so ONE reader covers the whole console fence. Before
// this, six of console-unit's nine exit-2 sites spoke a private vocabulary
// (`  EXIT 2 — THE CENSUS REFUSED TO MEASURE…`, leading spaces and no `!!`) that no `!!`-anchored capture could see — a gate that CAPTURES the
// refusing instrument's own summary line would have replaced a wrong sentence
// with NO sentence, in the wave about silence.
//
// THE READER IS scripts/console-refusal-capture.mjs, and its unit test
// ENUMERATES this file from source: a new exit-2 path that does not go through
// `refuse2` reds that test. Do not add one.
const REFUSAL_NAME = "AGENT EVENT VOCABULARY CENSUS";
const refuse2 = (reason) => {
  process.stderr.write(`!! ${REFUSAL_NAME} (exit 2): REFUSED TO MEASURE — ${reason}\n`);
  process.exit(2);
};

function die2(lines) {
  console.error("");
  for (const l of lines) console.error(l);
  console.error("");
  console.error("  nothing here says the Timeline's event vocabulary is honest and nothing says it");
  console.error("  is not. A gate that cannot read a side must not go green (charter D341).");
  refuse2(String(lines[0] || "the census could not read a side").replace(/^FAIL\(2\):\s*/, ""));
}

// ═══════════════════════════════════════════════════════════════════════════
// (A) THE RENDER SIDE — read BY RUNNING app.js, never by parsing its literal.
// ═══════════════════════════════════════════════════════════════════════════

const noop = () => {};
const inertEl = {
  addEventListener: noop,
  removeEventListener: noop,
  setAttribute: noop,
  removeAttribute: noop,
  classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
  style: {},
  hidden: false,
  value: "",
  innerHTML: "",
  textContent: "",
  querySelector: () => null,
  querySelectorAll: () => [],
};
const storage = { getItem: () => null, setItem: noop, removeItem: noop };

const hooks = {};
const sandbox = {
  __bpTestHook(h) { Object.assign(hooks, h); },
  document: {
    readyState: "loading", // keeps init() unbound — DOMContentLoaded never fires
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
    getElementById: () => null,
    createElement: () => ({ ...inertEl }),
    documentElement: { ...inertEl, getAttribute: () => null },
    body: { ...inertEl, appendChild: noop },
  },
  window: { addEventListener: noop, removeEventListener: noop, open: () => null, matchMedia: () => ({ matches: false, addEventListener: noop }) },
  location: { hash: "", pathname: "/", search: "", origin: "http://localhost" },
  localStorage: storage,
  sessionStorage: storage,
  navigator: {},
  URL: URL,
  URLSearchParams: URLSearchParams,
  fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }),
  EventSource: function () { return { addEventListener: noop, close: noop }; },
  setTimeout: noop,
  clearTimeout: noop,
  setInterval: () => 1,
  clearInterval: noop,
  console,
};
sandbox.globalThis = sandbox;

if (!fs.existsSync(APP)) die2([`FAIL(2): ${APP_LABEL} not readable at ${APP}.`]);
vm.createContext(sandbox);
try {
  vm.runInContext(fs.readFileSync(APP, "utf8"), sandbox);
} catch (err) {
  die2([
    `FAIL(2): evaluating ${APP_LABEL} in the sandbox threw: ${err && err.message}`,
    "  The render side could not be read AT ALL, so this census has no vocabulary to compare.",
  ]);
}

if (!Object.prototype.hasOwnProperty.call(hooks, "tlvEventTitles")) {
  die2([
    `FAIL(2): app.js did not export tlvEventTitles on __bpTestHook — the Timeline's title`,
    "  vocabulary is UNREADABLE.",
    "",
    "  This is the exit that matters most. An unreadable render side would present as an",
    "  EMPTY rendered set, which satisfies every arm below trivially: no title would lack a",
    "  producer, and the census would certify an honest vocabulary while seeing none of it.",
    `  Restore \`tlvEventTitles: Object.keys(TLV_EVENT_TITLES),\` beside tlvEntryTitle in`,
    `  ${APP_LABEL}'s __bpTestHook, or point this census at the new export name.`,
  ]);
}
if (!Array.isArray(hooks.tlvEventTitles)) {
  die2([`FAIL(2): __bpTestHook.tlvEventTitles is not an array (got ${typeof hooks.tlvEventTitles}).`]);
}

const rendered = new Set(Array.from(hooks.tlvEventTitles).map(String));
if (rendered.size < FLOORS.rendered) {
  die2([
    `FAIL(2): the RENDERED arm came back with ${rendered.size} title(s), under its floor of ${FLOORS.rendered}.`,
    `    read: ${[...rendered].sort().join(", ") || "(none)"}`,
    "  main titles four produced types today. Either the map genuinely shrank below what the",
    "  plane writes — in which case the produced-with-no-renderer arm below is the report you",
    "  want, not this one — or the export stopped reflecting the map. Neither is a clean tree.",
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// (B) THE PRODUCER SIDE — every literal `Registry.record_event(bp, "<type>"`
//     under cloud/lib/**/*.ex. NOT cloud/**: tests are not producers.
// ═══════════════════════════════════════════════════════════════════════════

// Strip Elixir heredocs (""" … """) and `#` comments so PROSE that quotes a
// call site — telemetry.ex's @moduledoc does exactly that — cannot be counted
// as a producer. The `#` pass skips `#` inside string literals.
// Both passes are LINE-PRESERVING — a heredoc is replaced by its own newlines —
// so every line number this census reports is the line in the real file.
function stripElixirProse(src) {
  const withoutHeredocs = src.replace(/"""[\s\S]*?"""/g, (block) =>
    "\n".repeat((block.match(/\n/g) || []).length),
  );
  return withoutHeredocs
    .split("\n")
    .map((line) => {
      let inString = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === "\\") { i++; continue; }
        if (c === '"') { inString = !inString; continue; }
        if (c === "#" && !inString) return line.slice(0, i);
      }
      return line;
    })
    .join("\n");
}

function exFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...exFiles(full));
    else if (entry.name.endsWith(".ex")) out.push(full);
  }
  return out;
}

if (!fs.existsSync(LIB)) die2([`FAIL(2): ${LIB_LABEL} not readable — no directory at ${LIB}.`]);
const libFiles = exFiles(LIB);
if (!libFiles.length) die2([`FAIL(2): ${LIB_LABEL} matched ZERO files. The producer side is unreadable.`]);

// The 2nd argument must be a STRING LITERAL. A bound type is a limit, stated in
// the header — it is invisible here, it is never guessed at.
const CALL_RE = /Registry\.record_event\(\s*[^,()]+,\s*"([a-z][a-z0-9_]*)"/g;
const producerSites = []; // { type, file, line }
for (const file of libFiles) {
  const src = stripElixirProse(fs.readFileSync(file, "utf8"));
  const label = (process.argv[3] || "cloud/lib") + file.slice(LIB.length);
  let m;
  while ((m = CALL_RE.exec(src)) !== null) {
    producerSites.push({ type: m[1], file: label, line: src.slice(0, m.index).split("\n").length });
  }
}
const produced = new Set(producerSites.map((p) => p.type));
if (produced.size < FLOORS.produced) {
  die2([
    `FAIL(2): the PRODUCED arm came back with ${produced.size} type(s), under its floor of ${FLOORS.produced}.`,
    `    read: ${[...produced].sort().join(", ") || "(none)"}  from ${producerSites.length} call site(s) in ${libFiles.length} file(s)`,
    "  main writes health, space, verify and status today. A producer set this small means the",
    "  extractor stopped matching `Registry.record_event(` — and an empty producer side would",
    "  make EVERY title an orphan, a very loud red for entirely the wrong reason.",
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// (C) THE FIXTURE SIDE — what the console's fixture corpus manufactures, read
//     BY A RULE over a ROOT rather than from a hand-kept file list.
// ═══════════════════════════════════════════════════════════════════════════

if (!fs.existsSync(FIXTURE_ROOT)) {
  die2([`FAIL(2): the fixture root ${FIXTURE_ROOT_LABEL} not readable at ${FIXTURE_ROOT}.`]);
}
const rootIsFile = fs.statSync(FIXTURE_ROOT).isFile();

function mjsFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...mjsFiles(full));
    else if (entry.name.endsWith(".mjs")) out.push(full);
  }
  return out;
}

// A single-file argv[4] keeps the older mutation drivers working; anything else
// is a directory walked by the rule. Sorted so the report reads the same twice.
const fixtureCandidates = (rootIsFile ? [FIXTURE_ROOT] : mjsFiles(FIXTURE_ROOT)).sort();
if (!fixtureCandidates.length) {
  die2([
    `FAIL(2): ${FIXTURE_ROOT_LABEL}/**/*.mjs matched ZERO files. The fixture side is unreadable.`,
    "  An empty candidate set is not an empty corpus — it is a walker that stopped walking, and",
    "  it would make `fixture-manufactures-unproducible` trivially satisfiable.",
  ]);
}

// The builder is spelled `ev(` in the preview corpus and `EV(` in __app.test.mjs,
// so the extractor matches BOTH. A case-sensitive `\bev\(` was the second half of
// this arm's blindness: even pointed at the test file it would have read zero
// rows from it, and zero rows reads exactly like a clean file.
const EV_RE = /\b(?:ev|EV)\(\s*[^,()]+,\s*"([a-z][a-z0-9_]*)"/g;

// The extractor, as a PURE function of source text, so the discrimination
// proof below can run it over synthetic sources instead of over the tree.
function scanFixtureSource(text) {
  const out = [];
  EV_RE.lastIndex = 0;
  let m;
  while ((m = EV_RE.exec(text)) !== null) {
    out.push({ type: m[1], line: text.slice(0, m.index).split("\n").length });
  }
  return out;
}

// ── THE DISCRIMINATION PROOF, RUN ON EVERY RUN (not written down and trusted) ──
//
// Arm C's blindness was never visible in its output: it reported a confident
// set, and a set is a set whether or not the extractor could see the file it was
// supposedly reading. So the extractor states what it must SEE and what it must
// NOT see, and refuses to measure if either control comes back wrong. A guard
// whose own controls are only in a commit message does not fire.
//
// MUST SEE — the `EV(` spelling. This is the arm that reds if the extractor is
// reverted to the case-sensitive `\bev\(` it had before this widening: pointed at
// __app.test.mjs, that version reads ZERO rows, which is indistinguishable in the
// totals from a clean file.
//
// MUST NOT SEE — prose and bare `type:` keys. This is the arm that stays quiet
// when it should: it is what keeps the widened scan from mistaking this file's
// own header, or a fixture's `type: "backup"` object key, for a call site, and it
// is why nothing under the root needs a waiver.
// THE CONTROLS ARE BUILT, NEVER WRITTEN LITERALLY. This file is itself a `*.mjs`
// under the root arm C walks, so a control written out as a literal builder call
// with a literal type would be read as a real fixture row and red the census on
// its own source. (That is not hypothetical: the first draft of THIS COMMENT
// spelled one out and the census immediately reported itself minting `backup` —
// the rule working, with no waiver to soften it.) `mkRow` assembles the shape at
// runtime; the pieces in this source never form a call site. That the assembly is
// right is not assumed — it is what the positive controls below measure.
const mkRow = (fn, type) => `${fn}(1, ${JSON.stringify(type)}, 10)`;
const PROOF_SEES = [
  [mkRow("EV", "backup"), "backup"],
  [mkRow("ev", "health"), "health"],
  [`  const bare = hooks.mergeTimeline([${mkRow("EV", "space")}], [])[0];`, "space"],
];
const PROOF_BLIND = [
  // prose with an elided type — this file's own header writes exactly this
  '// C  FIXTURED = the types the corpus manufactures, via `ev(…, "…")`',
  // a bare object key: the one shape LIMIT 2 concedes arm C cannot see
  '{ id: 2, type: "backup", inserted_at: "garbage" }',
  // the word boundary: `prev(` ends in `ev(` and must not count as the builder
  'prev(x, "backup", 10)',
];
for (const [src, want] of PROOF_SEES) {
  const got = scanFixtureSource(src).map((r) => r.type);
  if (!got.includes(want)) {
    die2([
      `FAIL(2): arm C's extractor did not see "${want}" in its own positive control.`,
      `    control: ${src}`,
      `    read:    ${got.join(", ") || "(nothing)"}`,
      "  The extractor cannot report an honest fixture set while it is blind to a shape the",
      "  corpus actually uses — a zero read is indistinguishable from a clean file, which is",
      "  exactly how six backup/tls rows sat unseen inside this census's declared coverage.",
    ]);
  }
}
for (const src of PROOF_BLIND) {
  const got = scanFixtureSource(src).map((r) => r.type);
  if (got.length) {
    die2([
      `FAIL(2): arm C's extractor matched its own NEGATIVE control and read ${got.join(", ")}.`,
      `    control: ${src}`,
      "  Prose and bare `type:` keys are not call sites. An extractor that matches them hands",
      "  this arm words that are not event types and reds every run for the wrong reason — and",
      "  a noisy arm gets muted, which is the blindness this file exists to end.",
    ]);
  }
}

const fixtureSites = []; // { type, label, line }
const contributing = [];
for (const file of fixtureCandidates) {
  const label = rootIsFile
    ? FIXTURE_ROOT_LABEL
    : FIXTURE_ROOT_LABEL + file.slice(FIXTURE_ROOT.length);
  const text = fs.readFileSync(file, "utf8");
  const rows = scanFixtureSource(text);
  for (const r of rows) fixtureSites.push({ type: r.type, label, line: r.line });
  // A file with zero rows is simply not a fixture file — that is the rule doing
  // its job, not a waiver. 66 of the 68 files under the root are in this case.
  if (rows.length) contributing.push({ label, rows: rows.length });
}

if (contributing.length < (rootIsFile ? 1 : FLOORS.fixtureFiles)) {
  die2([
    `FAIL(2): only ${contributing.length} file(s) under ${FIXTURE_ROOT_LABEL} contributed ev()/EV() rows,`,
    `  under the reach floor of ${rootIsFile ? 1 : FLOORS.fixtureFiles}, out of ${fixtureCandidates.length} *.mjs scanned.`,
    `    contributing: ${contributing.map((c) => `${c.label} (${c.rows})`).join(", ") || "(none)"}`,
    "  The TYPE totals cannot notice this: a surviving fixture file supplies the same types, so",
    "  the arm would go on reporting a set it had stopped sourcing. That is the exact shape this",
    "  arm was widened to end — a census green over ground it never walked. Either the builder",
    "  was renamed or inlined in a file that used to manufacture rows, or the corpus genuinely",
    "  shrank and this floor should move in the SAME commit that shrinks it.",
  ]);
}

// A caller who NARROWS the subject to one file narrows the floors with it — the
// root-mode floors describe the union of the whole corpus and one file cannot be
// expected to carry it (scenarios.mjs alone sources 3 of the 4). CI never passes
// argv[4], so the full floors are what the merge gate is held to; this branch
// exists only for the mutation drivers that hand the census a patched COPY.
const fixturedFloor = rootIsFile ? 1 : FLOORS.fixtured;
const fixtured = new Set(fixtureSites.map((f) => f.type));
if (fixtured.size < fixturedFloor) {
  die2([
    `FAIL(2): the FIXTURED arm came back with ${fixtured.size} type(s), under its floor of ${fixturedFloor}.`,
    `    read: ${[...fixtured].sort().join(", ") || "(none)"}  from ${fixtureSites.length} ev()/EV() row(s)`,
    `    across: ${contributing.map((c) => c.label).join(", ")}`,
    "  The corpus builds health, space, status and verify rows today. Under the floor means the",
    "  ev()/EV() builder was renamed or inlined, and this arm would stop seeing manufactured",
    "  traffic — which is precisely the blindness that let `backup` fixtures exercise a dead",
    "  render branch through eight rows arm C was not even opening.",
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// (D) THE THREE COMPARISONS.
// ═══════════════════════════════════════════════════════════════════════════

const sorted = (s) => [...s].sort();
const orphanTitles = sorted(rendered).filter((t) => !produced.has(t));
const untitled = sorted(produced).filter((t) => !rendered.has(t));
const impossibleFixtures = sorted(fixtured).filter((t) => !produced.has(t));

if (orphanTitles.length || untitled.length || impossibleFixtures.length) {
  console.error("");
  console.error("FAIL(1): the Timeline's event vocabulary and the control plane disagree.");
  console.error("");

  if (orphanTitles.length) {
    console.error(`  rendered-with-no-producer: ${orphanTitles.join(", ")}`);
    console.error(`    TLV_EVENT_TITLES in ${APP_LABEL} gives each of these a human title, and NOTHING`);
    console.error("    in cloud/lib can write one. A title is a promise: the row it names will never");
    console.error("    arrive, and a user waiting for it has no way to learn that from the console.");
    console.error("    Delete the title (and any verdict branch keyed on it), or land the producer.");
    console.error("");
  }
  if (untitled.length) {
    console.error(`  produced-with-no-renderer: ${untitled.join(", ")}`);
    for (const t of untitled) {
      const at = producerSites.filter((p) => p.type === t).map((p) => `${p.file}:${p.line}`).join(", ");
      console.error(`    "${t}" is written at ${at}`);
    }
    console.error(`    Each arrives in the feed and renders as its RAW lowercase slug through the`);
    console.error("    `|| entry.type` fallback — honest version-skew safety, but not a human title.");
    console.error(`    Add it to TLV_EVENT_TITLES in ${APP_LABEL}.`);
    console.error("");
  }
  if (impossibleFixtures.length) {
    console.error(`  fixture-manufactures-unproducible: ${impossibleFixtures.join(", ")}`);
    for (const t of impossibleFixtures) {
      // The label is part of `at` now — arm C reads MORE THAN ONE file, so the
      // site list must say WHICH; a single hardcoded label would name the wrong
      // file for every row that came from the other one.
      const at = fixtureSites.filter((f) => f.type === t).map((f) => `${f.label}:${f.line}`).join(", ");
      console.error(`    "${t}" is minted at ${at}`);
    }
    console.error("    The fixture corpus is inventing traffic the plane cannot produce. That is how a");
    console.error("    dead render branch comes to look exercised by 110 green scenarios — the corpus");
    console.error("    is an ORACLE, and an oracle that mints the impossible certifies the impossible.");
    console.error("");
  }

  console.error(`  produced (${produced.size}): ${sorted(produced).join(", ")}`);
  console.error(`  rendered (${rendered.size}): ${sorted(rendered).join(", ")}`);
  console.error(`  fixtured (${fixtured.size}): ${sorted(fixtured).join(", ")}`);
  console.error("");
  console.error("  NOTE: AgentEvent's @types allowlist is NOT the oracle here. It declares");
  console.error("  `content` with no producer on purpose (charter D576) — that word has a");
  console.error("  server-side consumer. DECLARED is not PRODUCED.");
  process.exit(1);
}

console.log("");
console.log("OK: every titled event type has a producer, every produced type has a title, and the");
console.log("    fixture corpus manufactures nothing the control plane cannot write.");
console.log(`    produced (${produced.size}): ${sorted(produced).join(", ")}  — ${producerSites.length} Registry.record_event( site(s) in ${LIB_LABEL}`);
console.log(`    rendered (${rendered.size}): ${sorted(rendered).join(", ")}  — read by RUNNING ${APP_LABEL} in a node:vm sandbox`);
console.log(`    fixtured (${fixtured.size}): ${sorted(fixtured).join(", ")}  — ${fixtureSites.length} ev()/EV() row(s) in ${contributing.map((c) => `${c.label} (${c.rows})`).join(", ")}`);
console.log(`               scanned ${fixtureCandidates.length} *.mjs under ${FIXTURE_ROOT_LABEL}; ${contributing.length} manufacture event rows`);
process.exit(0);

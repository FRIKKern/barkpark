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
//   C  FIXTURED  = the types the fixture corpus manufactures, via `ev(…, "…")` or
//                  `EV(…, "…")`, across EVERY file in FIXTURE_FILES — today
//                  cloud/priv/static/__preview__/scenarios.mjs AND
//                  cloud/priv/static/__app.test.mjs
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
// alongside them; and `__app.test.mjs` still manufactures `backup`/`tls` EV()
// rows for the timeline grammar. The wide variant certifies the exact lie.
// Tests are not producers.
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
//   LIMIT 2 — ARM C READS `ev(`/`EV(` CALLS. A fixture that inlines an event object
//   literal instead of calling the builder is invisible to arm C. This limit is
//   REAL and was exercised: one of the eight retired backup/tls rows was written
//   `{ id: 2, type: "backup", inserted_at: "garbage" }`, which no call-shaped
//   extractor can see. It was retyped by hand. Widening the extractor to a bare
//   `type: "…"` scan was tried and REFUSED: in __app.test.mjs that shape also
//   matches server-plan names ("cx22"), notification channels ("discord") and
//   target types ("site"), so it would hand this arm a set of ~30 words that are
//   not event types at all and make every run red for the wrong reason. A noisy
//   arm gets muted, and a muted arm is the blindness this file exists to end.
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
//      node cloud/priv/static/__agent_event_vocabulary_census.mjs <app.js> <lib-dir> <scenarios.mjs> <__app.test.mjs>
//   (the argv overrides exist so a mutation driver can point the census at
//    patched COPIES without writing inside this slice's fence — the fail-before
//    half of this guard's discrimination proof is run exactly that way)

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const here = path.dirname(new URL(import.meta.url).pathname);
const APP = process.argv[2] || path.join(here, "app.js");
const LIB = process.argv[3] || path.join(here, "../../lib");
const SCENARIOS = process.argv[4] || path.join(here, "__preview__/scenarios.mjs");
const APP_TEST = process.argv[5] || path.join(here, "__app.test.mjs");

// Report against stable repo-relative labels so the output reads the same from
// any cwd; a mutant copy passed on argv keeps its own path.
const APP_LABEL = process.argv[2] || "cloud/priv/static/app.js";
const LIB_LABEL = process.argv[3] ? process.argv[3] + "/**/*.ex" : "cloud/lib/**/*.ex";
const SCENARIOS_LABEL = process.argv[4] || "cloud/priv/static/__preview__/scenarios.mjs";
const APP_TEST_LABEL = process.argv[5] || "cloud/priv/static/__app.test.mjs";

// ARM C's SUBJECT IS A LIST, NOT A FILE — and that is the whole of cch's fix.
// Arm C used to read __preview__/scenarios.mjs and nothing else, while EIGHT rows
// typed "backup"/"tls" sat in __app.test.mjs. The census declares
// `fixture-manufactures-unproducible` as a failure mode, implemented a check for
// it, and pointed that check at one file while the violation lived in another: the
// gate's green was read as coverage over ground it never walked. Any file that
// manufactures event rows belongs in this list; each is read with the SAME
// extractor and each must yield rows (see the per-file vacuity arm below), so
// adding a file the regex cannot read is a loud failure rather than a silent no-op.
const FIXTURE_FILES = [
  { file: SCENARIOS, label: SCENARIOS_LABEL },
  { file: APP_TEST, label: APP_TEST_LABEL },
];

// The per-arm vacuity floors. main today: 4 producers (health/space/verify/
// status), 4 titles, 4 fixtured types. An arm under its floor is a broken
// extractor reporting a clean tree — the exact vacuous green this epic kills.
//
// FIXTURED ROSE 3 -> 4 when arm C started reading __app.test.mjs as well: that
// file manufactures `space` rows the preview corpus does not, so the widened arm
// genuinely sources one more type. Leaving the floor at 3 would have let the whole
// second file drop back out of the read without tripping anything — a floor that
// does not move with its arm's reach stops being a vacuity guard.
const FLOORS = { produced: 4, rendered: 4, fixtured: 4 };

function die2(lines) {
  console.error("");
  for (const l of lines) console.error(l);
  console.error("");
  console.error("  EXIT 2 — THE CENSUS REFUSED TO MEASURE. It is making NO claim about this tree:");
  console.error("  nothing here says the Timeline's event vocabulary is honest and nothing says it");
  console.error("  is not. A gate that cannot read a side must not go green (charter D341).");
  process.exit(2);
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
// (C) THE FIXTURE SIDE — what the fixture corpus manufactures, across every file
//     in FIXTURE_FILES.
// ═══════════════════════════════════════════════════════════════════════════

// The builder is spelled `ev(` in the preview corpus and `EV(` in __app.test.mjs,
// so the extractor matches BOTH. A case-sensitive `\bev\(` was the second half of
// this arm's blindness: even pointed at the test file it would have read zero rows
// from it, and a zero-row read is exactly what the per-file arm below now refuses.
const EV_RE = /\b(?:ev|EV)\(\s*[^,()]+,\s*"([a-z][a-z0-9_]*)"/g;
const fixtureSites = [];
for (const src of FIXTURE_FILES) {
  if (!fs.existsSync(src.file)) die2([`FAIL(2): ${src.label} not readable at ${src.file}.`]);
  const text = fs.readFileSync(src.file, "utf8");
  let fm;
  EV_RE.lastIndex = 0;
  let n = 0;
  while ((fm = EV_RE.exec(text)) !== null) {
    fixtureSites.push({ type: fm[1], line: text.slice(0, fm.index).split("\n").length, label: src.label });
    n++;
  }
  // PER-FILE VACUITY. A file contributing zero rows means the builder there was
  // renamed, inlined, or never matched the extractor at all — and a file read to
  // zero is indistinguishable, in the totals, from a file that is simply clean.
  // That is the failure that let this arm certify a file it was not even reading.
  if (n === 0) {
    die2([
      `FAIL(2): the FIXTURED arm read ZERO ev()/EV() row(s) from ${src.label}.`,
      "  A fixture file in FIXTURE_FILES that yields nothing is a blind extractor, not a clean",
      "  file — the arm would report a set it never sourced. Either the builder was renamed or",
      "  inlined there, or the file no longer manufactures events and should leave the list.",
    ]);
  }
}
const fixtured = new Set(fixtureSites.map((f) => f.type));
if (fixtured.size < FLOORS.fixtured) {
  die2([
    `FAIL(2): the FIXTURED arm came back with ${fixtured.size} type(s), under its floor of ${FLOORS.fixtured}.`,
    `    read: ${[...fixtured].sort().join(", ") || "(none)"}  from ${fixtureSites.length} ev()/EV() row(s)`,
    `    across: ${FIXTURE_FILES.map((f) => f.label).join(", ")}`,
    "  The two fixture files build health, status, space and verify rows today. Under the floor",
    "  means the ev()/EV() builder was renamed or inlined, and this arm would stop seeing",
    "  manufactured traffic — precisely the blindness that let `backup` fixtures exercise a",
    "  dead branch through eight rows arm C was not even opening.",
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
      const at = fixtureSites.filter((f) => f.type === t).map((f) => `${f.label}:${f.line}`).join(", ");
      // The label is part of `at` now — arm C reads MORE THAN ONE file, so the
      // site list must say WHICH, and a hardcoded SCENARIOS_LABEL here would name
      // the wrong file for every row that came from the other one.
      console.error(`    "${t}" is minted at ${at}`);
    }
    console.error("    The preview corpus is inventing traffic the plane cannot produce. That is how a");
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
console.log("    preview corpus manufactures nothing the control plane cannot write.");
console.log(`    produced (${produced.size}): ${sorted(produced).join(", ")}  — ${producerSites.length} Registry.record_event( site(s) in ${LIB_LABEL}`);
console.log(`    rendered (${rendered.size}): ${sorted(rendered).join(", ")}  — read by RUNNING ${APP_LABEL} in a node:vm sandbox`);
console.log(`    fixtured (${fixtured.size}): ${sorted(fixtured).join(", ")}  — ${fixtureSites.length} ev()/EV() row(s) across ${FIXTURE_FILES.map((f) => f.label).join(", ")}`);
process.exit(0);

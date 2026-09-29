// group-view-scenarios.mjs — ONE PREVIEW SCENARIO PER PDF-D11 GROUP STATE,
// ACCOUNTED FOR AGAINST THE SHIPPED CATALOGUE RATHER THAN TYPED TWICE.
//
// WHAT THIS FILE IS FOR. `pdf-bl-fleet-group-view` criterion [0] asks for the
// 7-state catalogue "with a preview scenario per state". The cheap way to
// deliver that is a literal — seven entries in a test file, seven `assert`s
// beside them — and that is the shape this directory has already paid to
// remove twice (fleet-scenarios.mjs's three-name literal; attention-scenarios'
// GR109 derivation). A literal roster of states cannot refuse: add an eighth
// state to app.js and nothing here notices, because an unlisted state is
// simply not walked.
//
// SO THE AXIS IS THE SHIPPED ARRAY. `GROUP_VIEW_STATES` is app.js's own
// enumeration, read through the guarded `__bpTestHook` bag, and `groupAxis()`
// below REFUSES in BOTH directions:
//
//   • a state in the catalogue with no scenario in the corpus     -> throw
//   • a scenario in the corpus naming no state in the catalogue   -> throw
//   • a scenario that no longer PRODUCES the state it is filed     -> throw
//     under, when run through the shipped `groupViewState`
//
// The third is the one with teeth. The first two only check that two key sets
// match, which a careless rename satisfies; the third asks the SHIPPED DERIVER
// what the fixture actually renders as, so a scenario that has quietly stopped
// exercising its state becomes a refusal instead of a passing test measuring
// the wrong thing. It is also why the corpus lives in a JSON fixture rather
// than in this module: the data is inert, and every judgment about it is made
// by the code under test.
//
// THE CONTROLS ARE NOT PART OF THE AXIS. `controls` in the fixture carry their
// own `state` field and exist to pin a property of the derivation rather than
// to cover a catalogue entry — `working-stale-beat` is criterion [1]'s control
// (a beat 47 minutes past its own ttl_s that still reads `working`, because
// the SERVER owns the staleness verdict and this console renders it), and
// `roster-unreachable` pins that a failed read paints "no heartbeat yet"
// rather than a fabricated Offline. They are validated the same way — the
// shipped deriver must produce the state each declares — but they are not
// allowed to satisfy a catalogue entry, or a control could silently stand in
// for the scenario a state is missing.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appHooks } from "./attention-scenarios.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = path.join(HERE, "..", "__fixtures__", "fleet_group_roster.json");

export const GROUP_FIXTURE = JSON.parse(fs.readFileSync(FIXTURE_PATH, "utf8"));

// The injected clock every scenario is derived against. A fixed instant, so a
// rendered beat age is a fact about the corpus and not about when the suite ran.
export const GROUP_NOW_MS = Date.parse(GROUP_FIXTURE.now);

export const GROUP_MAIN = GROUP_FIXTURE.main;

function die(msg) {
  throw new Error("group-view-scenarios: " + msg);
}

// One scenario, ready to hand to the shipped renderer.
function scenarioOf(key, entry, declaredState) {
  return {
    key,
    state: declaredState,
    why: entry.why,
    main: GROUP_MAIN,
    supports: entry.supports,
    roster: entry.roster, // null = the roster READ itself never landed
    now: GROUP_NOW_MS,
  };
}

// THE AXIS. Returns the catalogue-covering scenarios, in `GROUP_VIEW_STATES`
// order, or throws. `hooks` defaults to a fresh evaluation of the shipped
// app.js — callers that already hold a hook bag pass their own so one suite
// evaluates the file once.
export function groupAxis(hooks = appHooks()) {
  const catalogue = hooks.GROUP_VIEW_STATES;
  if (!Array.isArray(catalogue) || catalogue.length === 0) {
    die("app.js exported no GROUP_VIEW_STATES — the axis has no subject, and a zero-cell sweep would read as a clean one");
  }
  const corpus = GROUP_FIXTURE.scenarios || {};
  const corpusKeys = Object.keys(corpus);

  const missing = catalogue.filter((s) => !Object.prototype.hasOwnProperty.call(corpus, s));
  if (missing.length) {
    die(`catalogue states with no preview scenario: ${missing.join(", ")} — add one to __fixtures__/fleet_group_roster.json`);
  }
  const orphan = corpusKeys.filter((k) => catalogue.indexOf(k) === -1);
  if (orphan.length) {
    die(`preview scenarios naming no catalogue state: ${orphan.join(", ")} — GROUP_VIEW_STATES is the enumeration, this corpus follows it`);
  }

  return catalogue.map((state) => {
    const sc = scenarioOf(state, corpus[state], state);
    const cells = hooks.groupSupportCells(sc.supports, sc.roster, sc.now);
    const actual = hooks.groupViewState(cells);
    if (actual !== state) {
      die(`scenario "${state}" no longer produces its state — the shipped groupViewState reads it as "${actual}". The fixture drifted, the deriver changed, or the state is now unreachable; none of those may pass quietly`);
    }
    if (!sc.why || typeof sc.why !== "string") {
      die(`scenario "${state}" carries no \`why\` — a fixture nobody can explain is a fixture nobody can maintain`);
    }
    return sc;
  });
}

// The named controls, validated the same way and kept OUT of the axis.
export function groupControls(hooks = appHooks()) {
  const controls = GROUP_FIXTURE.controls || {};
  const catalogue = hooks.GROUP_VIEW_STATES || [];
  return Object.keys(controls).map((key) => {
    const entry = controls[key];
    if (catalogue.indexOf(entry.state) === -1) {
      die(`control "${key}" declares state "${entry.state}", which is not in GROUP_VIEW_STATES`);
    }
    const sc = scenarioOf(key, entry, entry.state);
    const cells = hooks.groupSupportCells(sc.supports, sc.roster, sc.now);
    const actual = hooks.groupViewState(cells);
    if (actual !== entry.state) {
      die(`control "${key}" expects "${entry.state}" and the shipped groupViewState reads "${actual}" — this is the control firing, not a fixture nit`);
    }
    return sc;
  });
}

// Convenience for a consumer that wants the rendered markup per state.
export function groupRenders(hooks = appHooks()) {
  return groupAxis(hooks).map((sc) => ({
    ...sc,
    html: hooks.groupViewHtml(sc.main, sc.supports, sc.roster, sc.now),
  }));
}

// Run directly: print the axis, which is also the cheapest way to see the
// refusals fire.
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const hooks = appHooks();
  const axis = groupAxis(hooks);
  const controls = groupControls(hooks);
  for (const sc of axis) {
    console.log(`  ${sc.state.padEnd(13)} ${sc.supports.length} support(s), roster ${sc.roster === null ? "UNREACHABLE" : sc.roster.length + " row(s)"}`);
  }
  for (const c of controls) {
    console.log(`  [control] ${c.key.padEnd(22)} -> ${c.state}`);
  }
  console.log(`GROUP_AXIS_STATES ${axis.length}`);
  console.log(`GROUP_CONTROLS ${controls.length}`);
}

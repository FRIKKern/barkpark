// attention-scenarios.mjs — WHICH SCENARIOS RENDER AN `.attention-row`, ASKED
// OF THE SHIPPED CODE INSTEAD OF TYPED BY HAND.
//
// WHY THIS FILE EXISTS. overflow-guard.mjs's GR109 leg used to drive a literal:
//
//     const ATT_SCENS = ["mixed-fleet", "overview-attention", "overview-past-due"];
//
// Three names. The fixture corpus renders `.attention-row` in NINETEEN
// scenarios carrying 27 rows between them, so 16 scenarios and 22 of the 27
// rows were never measured — `fleet-v4` (4 rows) and `fleet-usage` (2 rows)
// among them. The filed row's own census said FOUR; it undercounted by ~5x.
// Widening the literal to today's nineteen would buy one wave and recreate the
// blind spot on the twentieth scenario, so the literal is gone entirely: the
// set is DERIVED, and a scenario added tomorrow that needs an operator's
// attention joins the guard's axis without anyone remembering to type it.
//
// HOW THE SET IS DERIVED — THE SHIPPED CLASSIFIER, NOT A SECOND OPINION.
// `#overview` builds its queue with exactly one expression (app.js):
//
//     var queue = filterFleet(list, "attention").sort(attentionCompare).slice(0, 6);
//     ... '<div class="attention-card">' + queue.map(attentionRowHtml).join("") + "</div>"
//
// so "renders an `.attention-row`" IS "filterFleet(data.barkparks, 'attention')
// is non-empty" — and this module asks app.js that question directly, by
// evaluating the SHIPPED artifact in a node:vm sandbox and taking `filterFleet`
// off the guarded `__bpTestHook` at the tail of the IIFE. That is the same
// technique __app.test.mjs uses, for the same reason: a re-implementation of
// `bucketOf` here would be a SECOND hand-written classifier that drifts from
// the one the page runs, which is the defect this file was written to remove,
// wearing a function's clothes.
//
// The sandbox reports `document.readyState === "loading"`, so `init()` is only
// ever REGISTERED against a no-op `addEventListener` — evaluating app.js is
// side-effect-free and no boot path runs.
//
// UNAUTHED SCENARIOS ARE EXCLUDED, and that is a property of the ROUTE, not of
// the data: `authed: false` renders the sign-in screen, so `#overview` never
// paints and a guard cell there would measure zero rows and red for a reason
// that has nothing to do with layout. The exclusion is declared here and
// asserted by the sibling test, not left as a silent skip.
//
// THE CONSUMER OWES A REFUSAL. `attentionScenarios()` throws on an empty read
// rather than returning `[]`, because an empty derived set makes a zero-cell
// sweep look like a clean one — the exact vacuous green GR109's per-cell and
// leg-level zero refusals already exist to forbid. It also throws if the three
// names the old literal carried are not all present: those three are the
// POSITIVE CONTROL that the derivation still sees what a human could see, so a
// classifier change that quietly empties the bucket reds here instead of
// printing "0 / 0 cells clean".

import fs from "node:fs";
import vm from "node:vm";

// The three names the pre-derivation literal carried. Kept ONLY as a positive
// control on the derivation — never as the axis itself. If a fixture rename
// makes one of these stale, the refusal below is the place that says so out
// loud, and the fix is to update this control deliberately.
export const ATT_LITERAL_CONTROL = ["mixed-fleet", "overview-attention", "overview-past-due"];

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

// Evaluate the SHIPPED app.js and return its pure-helper hook bag. Mirrors
// __app.test.mjs's sandbox; kept local so this module has zero dependency on
// the test file's load order.
export function appHooks(appUrl = new URL("../app.js", import.meta.url)) {
  const hooks = {};
  const sandbox = {
    __bpTestHook(h) { Object.assign(hooks, h); },
    document: {
      readyState: "loading",
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
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(appUrl, "utf8"), sandbox);
  if (typeof hooks.filterFleet !== "function") {
    throw new Error(
      "attention-scenarios: app.js's __bpTestHook no longer exports filterFleet — " +
      "the GR109 scenario axis cannot be derived from the shipped classifier, and a " +
      "hand-typed replacement is exactly the blind spot this module removes",
    );
  }
  return hooks;
}

// The derived rows, richest form: every scenario whose `#overview` queue is
// non-empty, with the row count the shipped selection yields. `rows` is the
// queue length AFTER app.js's own `.slice(0, 6)` cap, because that is how many
// `.attention-row` elements actually paint.
export function attentionScenarioRows(SCENARIOS, hooks = appHooks()) {
  const out = [];
  for (const name of Object.keys(SCENARIOS || {})) {
    const sc = SCENARIOS[name] || {};
    if (sc.authed === false) continue; // signs in, not #overview — see the note above
    const list = (sc.data && sc.data.barkparks) || [];
    const n = hooks.filterFleet(list, "attention").slice(0, 6).length;
    if (n > 0) out.push({ name, rows: n });
  }
  out.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return out;
}

// The axis GR109 drives. Refuses an empty read and refuses to lose its own
// positive control — see the note at the head of this file.
export function attentionScenarios(SCENARIOS, hooks = appHooks()) {
  const rows = attentionScenarioRows(SCENARIOS, hooks);
  const names = rows.map((r) => r.name);
  if (names.length === 0) {
    throw new Error(
      `attention-scenarios: the derived .attention-row set is EMPTY across ` +
      `${Object.keys(SCENARIOS || {}).length} scenarios — either the fixtures stopped ` +
      `carrying an attention bucket or filterFleet's classification moved. A zero-length ` +
      `axis makes GR109 sweep zero cells and print a clean summary of no work; refused.`,
    );
  }
  const missing = ATT_LITERAL_CONTROL.filter((n) => !names.includes(n));
  if (missing.length) {
    throw new Error(
      `attention-scenarios: the derivation lost its positive control — ` +
      `${missing.join(", ")} no longer classify into the attention bucket, though the ` +
      `pre-derivation GR109 literal drove them. ${names.length} scenario(s) derived: ` +
      `${names.join(", ")}. Either a fixture was renamed (update ATT_LITERAL_CONTROL ` +
      `deliberately) or bucketOf regressed; a silently narrower axis is refused.`,
    );
  }
  return names;
}

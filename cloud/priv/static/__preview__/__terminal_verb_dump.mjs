// __terminal_verb_dump.mjs — print the TERMINAL VERBS the console declares, and
// the {verb, mode} pairs it can actually PAINT, as JSON.
//
// The console half of the terminal-act residue register
// (cloud/test/barkpark_cloud/terminal_act_residue_manifest_test.exs). That
// register asks one question of every terminal verb: what does it DESTROY, what
// SURVIVES it, and who is told. The register can only lose in the ADD direction
// if the verb POPULATION is read from the shipped code rather than re-typed in
// the test, and this script is how the console half of that population is read.
//
// IT READS THE CONSOLE BY RUNNING THE MODEL, NOT BY GREPPING app.js. Same
// rationale as its sibling __lifecycle_state_dump.mjs (and __plan_features_dump
// .mjs / __plan_catalog_dump.mjs before it): a regex over source text survives a
// refactor that keeps the bytes and changes the value, and breaks on a reformat
// that changes nothing. Here it would also be WRONG in a second way — the
// declared LIFECYCLE_VERBS list and the list the rail actually paints come apart
// on every degraded branch (a loading shell, a missing provider entry, and a
// dev-tier provider all paint `decommission` ALONE), so a guard that read the
// declaration would believe the console offers six verbs in states where it
// offers one.
//
// THIS SCRIPT IS A SIBLING, NOT AN EXTENSION. It re-types the node:vm recipe
// deliberately; the three manifest instruments in this tree share no extractor,
// so a change to one dump can never silently retune another's population.
//
// THE INPUT MATRIX IS DERIVED, NOT HAND-PICKED. `lifecycleActionsModel` reads
// exactly four inputs — the capabilities payload, the box row, the authority
// answer, and the authority READ STATE — and this script takes the CARTESIAN
// PRODUCT of every distinguishable value each of those can hold (every branch
// the model spells: undefined / null / malformed / no-entry / dev-tier / wired,
// crossed with the provider and host axes the box row contributes, crossed with
// all three authority answers and all four authority states). A new branch
// inside the model shows up here with no edit to this file; a new INPUT FIELD
// does not, which is stated as a limit in the Elixir moduledoc.
//
// app.js is a browser IIFE with no exports, so — exactly as __app.test.mjs and
// the sibling dumps do — we evaluate the SHIPPED file verbatim inside a node:vm
// sandbox whose document.readyState is "loading", which leaves init() merely
// REGISTERED on a no-op addEventListener. No boot path runs; the eval is
// side-effect-free.
//
// Output, on stdout:
//
//   {
//     "verbs": ["adopt", ...],                       // LIFECYCLE_VERBS, sorted
//     "declared_order": ["archive", ...],            // LIFECYCLE_VERBS, in order
//     "painted": [{ "verb": "...", "mode": "..." }], // sorted, deduped
//     "painted_verbs": ["..."],                      // sorted, deduped
//     "sequences": [["decommission"], ["archive", ...]], // distinct paint orders
//     "painted_equals_declared_always": true|false,  // see below
//     "combos": 432
//   }
//
// `painted_equals_declared_always` is true when EVERY combo whose model reports
// `available: true` painted exactly the declared verb sequence — i.e. the rail
// never invents a verb and never silently drops one from a wired provider. It
// is reported rather than asserted here; the Elixir side owns the verdict.
//
// Any failure to reach a real value is a NON-ZERO EXIT with a message on stderr
// — never an empty verb list, never a partial one. A guard that cannot read a
// side must RED, not pass:
//
//   2 — __bpTestHook carries no lifecycleVerbs array (or it is empty / not an
//       array of non-empty strings)
//   3 — __bpTestHook carries no lifecycleActionsModel (or it is not a function)
//   4 — the model threw on some input in the matrix
//   5 — the model returned a descriptor of the wrong shape (no actions array, or
//       an action with no string verb / mode)
//   6 — the matrix painted NOTHING (an empty painted set must never read as
//       "the console offers no terminal act" — it is an unreadable console)
//
// Exit 2 and exit 6 are the ones that matter most: either empty list would read
// to the Elixir side as "there is no terminal verb to account for", which is the
// exact vacuous green the register exists to prevent.
//
// Not web-reachable: BarkparkCloud.Web.Router's Plug.Static uses an explicit
// `only:` allowlist and __preview__/ is not in it (pinned by
// cloud/test/web/static_allowlist_test.exs).
//
// Run: node cloud/priv/static/__preview__/__terminal_verb_dump.mjs

import vm from "node:vm";
import fs from "node:fs";

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
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(new URL("../app.js", import.meta.url), "utf8"),
  sandbox,
);

// FAIL CLOSED on every way a side could go missing.
// Array.from re-homes the row out of the vm sandbox's realm before it is read —
// the same realm care __app.test.mjs takes with planCatalog.
const declaredOrder = Array.isArray(hooks.lifecycleVerbs) ? Array.from(hooks.lifecycleVerbs) : null;

if (
  !declaredOrder ||
  declaredOrder.length === 0 ||
  declaredOrder.some((v) => typeof v !== "string" || v.trim() === "")
) {
  console.error(
    "app.js did not export a non-empty lifecycleVerbs array of verb names on __bpTestHook — " +
    "the console's terminal verbs are unreadable, and an unreadable population must never read " +
    "as 'no terminal verb to account for'",
  );
  process.exit(2);
}

if (typeof hooks.lifecycleActionsModel !== "function") {
  console.error("app.js did not export lifecycleActionsModel on __bpTestHook — the painted verb rail is unreadable");
  process.exit(3);
}

// THE FOUR AXES `lifecycleActionsModel` READS, with every distinguishable value
// each can hold. The capability payloads are one per branch the model spells,
// and the wired entry grants every DECLARED verb (derived from the dump's own
// verb list, so a new verb is granted here without editing this file).
const grantAll = {};
const gapAll = {};
for (const verb of declaredOrder) {
  grantAll[verb] = true;
  gapAll[verb] = `no ${verb} on this provider`;
}

const CAP_PAYLOADS = [
  ["undefined", undefined],                                             // loading shell
  ["null", null],                                                       // malformed
  ["no-providers", {}],                                                 // malformed
  ["dev-tier", { providers: { hetzner: { tier: "dev" } } }],            // dev box
  ["wired-granted", { providers: { hetzner: { tier: "prod", capabilities: grantAll, gaps: {} } } }],
  ["wired-refused", { providers: { hetzner: { tier: "prod", capabilities: {}, gaps: gapAll } } }],
];

const PROVIDER = [undefined, "hetzner", "fake"];
const HOST = ["", "box.barkpark.cloud"];
const AUTHORITY = ["grant", "refuse", "unknown"];
const AUTHORITY_STATE = [undefined, "loading", "failed", "loaded"];

const painted = new Map();        // "verb\u0000mode" -> {verb, mode}
const paintedVerbs = new Set();
const sequences = new Set();      // JSON of the painted verb order
let paintedEqualsDeclaredAlways = true;
let combos = 0;

const declaredKey = JSON.stringify(declaredOrder);

for (const [capName, capPayload] of CAP_PAYLOADS) {
  for (const provider of PROVIDER) {
    for (const host of HOST) {
      for (const authority of AUTHORITY) {
        for (const authorityState of AUTHORITY_STATE) {
          combos += 1;
          const bp = { id: "probe", name: "Probe", slug: "probe", provider, host, provision_status: "succeeded" };
          const where = JSON.stringify({ cap: capName, provider, host, authority, authorityState });

          let model;
          try {
            model = hooks.lifecycleActionsModel(capPayload, bp, authority, authorityState);
          } catch (err) {
            console.error(`lifecycleActionsModel at ${where} threw: ${err && err.message}`);
            process.exit(4);
          }

          if (!model || !Array.isArray(model.actions)) {
            console.error(`lifecycleActionsModel at ${where} returned no actions array: ${JSON.stringify(model)}`);
            process.exit(5);
          }

          const order = [];
          for (const action of model.actions) {
            if (!action || typeof action.verb !== "string" || typeof action.mode !== "string") {
              console.error(`lifecycleActionsModel at ${where} painted a bad action: ${JSON.stringify(action)}`);
              process.exit(5);
            }
            order.push(action.verb);
            paintedVerbs.add(action.verb);
            painted.set(`${action.verb}\u0000${action.mode}`, { verb: action.verb, mode: action.mode });
          }

          sequences.add(JSON.stringify(order));

          // A WIRED provider must paint exactly the declared sequence — no verb
          // invented, none silently dropped. The degraded branches deliberately
          // paint less, and are not held to it.
          if (model.available === true && JSON.stringify(order) !== declaredKey) {
            paintedEqualsDeclaredAlways = false;
          }
        }
      }
    }
  }
}

if (painted.size === 0) {
  console.error(
    "the lifecycle action model painted NOTHING across the whole input matrix — an unreadable " +
    "console must never read as 'no terminal act is offered'",
  );
  process.exit(6);
}

const byVerbThenMode = (a, b) =>
  a.verb < b.verb ? -1 : a.verb > b.verb ? 1 : a.mode < b.mode ? -1 : a.mode > b.mode ? 1 : 0;

process.stdout.write(JSON.stringify({
  verbs: Array.from(declaredOrder).sort(),
  declared_order: Array.from(declaredOrder),
  painted: Array.from(painted.values()).sort(byVerbThenMode),
  painted_verbs: Array.from(paintedVerbs).sort(),
  sequences: Array.from(sequences).map((s) => JSON.parse(s)).sort((a, b) => (a.length - b.length) || (a[0] < b[0] ? -1 : 1)),
  painted_equals_declared_always: paintedEqualsDeclaredAlways,
  combos: combos,
}));

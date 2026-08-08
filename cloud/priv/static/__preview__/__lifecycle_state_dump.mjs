// __lifecycle_state_dump.mjs — print the lifecycle states the console can
// actually PAINT, and the word it paints for each, as JSON.
//
// The client half of the lifecycle-state manifest guard
// (cloud/test/barkpark_cloud/lifecycle_state_manifest_test.exs). That guard
// asserts the console never paints a lifecycle state as an operational fact
// the control plane cannot perform — the console called a suspended box
// "Stopped" while the entire suspension mechanism was one UPDATE of three
// columns on the `barkparks` row.
//
// IT READS THE CONSOLE BY RUNNING THE FOLD, NOT BY GREPPING. Two reasons, and
// the second is the one that makes grepping actually WRONG here:
//
//   1. A regex over app.js source text is not a pin — it survives a refactor
//      that keeps the bytes and changes the value, and it breaks on a reformat
//      that changes nothing. (Same rationale as __plan_features_dump.mjs and
//      __plan_catalog_dump.mjs, its two siblings in this directory.)
//   2. `LIFECYCLE_PILL_LABEL` declares SEVEN states, but `lifecyclePillState`
//      can only ever RETURN five: `archived` and `adopted` are labels no input
//      reaches. A guard that read the label map would pin two dead words and
//      believe the console paints states it cannot paint. So this script drives
//      the fold and collects what comes back.
//
// THE INPUT MATRIX IS DERIVED, NOT HAND-PICKED. `instanceLifecycle` — the fold
// `lifecyclePillState` delegates to — reads exactly four fields off a box row:
// `deprovision_status`, `host`, `provision_status`, `suspended`. This script
// takes the CARTESIAN PRODUCT of every value each of those can hold, so the
// painted set is everything the fold can emit rather than everything the author
// remembered to try. A new branch inside the fold shows up here with no edit;
// a new INPUT FIELD does not, which is stated as a limit in the Elixir
// moduledoc.
//
// app.js is a browser IIFE with no exports, so — exactly as __app.test.mjs and
// both sibling dumps do — we evaluate the SHIPPED file verbatim inside a
// node:vm sandbox whose document.readyState is "loading", which leaves init()
// merely REGISTERED on a no-op addEventListener. No boot path runs; the eval is
// side-effect-free.
//
// Output, on stdout:
//
//   {
//     "painted": [{ "state": "...", "label": "...", "cls": "..." }],  // sorted by state
//     "declared_labels": ["..."],                                     // LIFECYCLE_PILL_LABEL keys, for the dead-label note
//     "suspended": { "state": "...", "label": "...", "detail": "..." },
//     "combos": 60
//   }
//
// `suspended` is the row the crown assertion reads: the pill a genuinely
// suspended box gets, plus the `statusOf` detail line beside it.
//
// Any failure to reach a real value is a NON-ZERO EXIT with a message on
// stderr — never an empty painted set, never a partial one. A guard that cannot
// read a side must RED, not pass:
//
//   2 — __bpTestHook carries no lifecyclePill (or it is not a function)
//   3 — __bpTestHook carries no lifecyclePillState (or it is not a function)
//   4 — __bpTestHook carries no statusOf (or it is not a function)
//   5 — __bpTestHook carries no LIFECYCLE_PILL_LABEL object
//   6 — the fold threw, or returned a descriptor of the wrong shape
//   7 — the fold painted NOTHING (an empty painted set must never read as
//       "the console paints no halt" — it is an unreadable console)
//
// Exit 7 is the one that matters most: an empty painted set would read to the
// Elixir side as "no state claims a halt", which is the exact vacuous green
// this guard exists to prevent.
//
// Not web-reachable: BarkparkCloud.Web.Router's Plug.Static uses an explicit
// `only:` allowlist and __preview__/ is not in it (pinned by
// cloud/test/web/static_allowlist_test.exs).
//
// Run: node cloud/priv/static/__preview__/__lifecycle_state_dump.mjs

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
if (typeof hooks.lifecyclePill !== "function") {
  console.error("app.js did not export lifecyclePill on __bpTestHook — the painted lifecycle states are unreadable");
  process.exit(2);
}
if (typeof hooks.lifecyclePillState !== "function") {
  console.error("app.js did not export lifecyclePillState on __bpTestHook — the lifecycle fold is unreadable");
  process.exit(3);
}
if (typeof hooks.statusOf !== "function") {
  console.error("app.js did not export statusOf on __bpTestHook — the suspension detail line is unreadable");
  process.exit(4);
}
if (!hooks.LIFECYCLE_PILL_LABEL || typeof hooks.LIFECYCLE_PILL_LABEL !== "object") {
  console.error("app.js did not export LIFECYCLE_PILL_LABEL on __bpTestHook — the declared label set is unreadable");
  process.exit(5);
}

// THE FOUR AXES `instanceLifecycle` READS, with every value each can hold.
// "succeeded" appears alongside "failed"/"pending"/"claimed" so the fold's
// negative branches are exercised too, and `host` carries both the absent and
// the present case (it is the live/provisioning discriminator).
const DEPROVISION = [null, "pending", "claimed", "failed", "succeeded"];
const HOST = ["", "box.barkpark.cloud"];
const PROVISION = [null, "failed", "succeeded"];
const SUSPENDED = [false, true];

const painted = new Map(); // state -> {state, label, cls}
let combos = 0;

for (const deprovision_status of DEPROVISION) {
  for (const host of HOST) {
    for (const provision_status of PROVISION) {
      for (const suspended of SUSPENDED) {
        combos += 1;
        const bp = { id: "probe", name: "Probe", deprovision_status, host, provision_status, suspended };

        let pill;
        try {
          pill = hooks.lifecyclePill(bp);
        } catch (err) {
          console.error(`lifecyclePill(${JSON.stringify(bp)}) threw: ${err && err.message}`);
          process.exit(6);
        }

        if (!pill || typeof pill.state !== "string" || typeof pill.label !== "string" || typeof pill.cls !== "string") {
          console.error(`lifecyclePill(${JSON.stringify(bp)}) returned a bad descriptor: ${JSON.stringify(pill)}`);
          process.exit(6);
        }

        // "" is the fold's own "cannot place this" sentinel — it paints no pill
        // and no tint, so it is not a painted state.
        if (pill.state === "") continue;

        painted.set(pill.state, { state: pill.state, label: pill.label, cls: pill.cls });
      }
    }
  }
}

if (painted.size === 0) {
  console.error(
    "the lifecycle fold painted NOTHING across the whole input matrix — an unreadable console " +
    "must never read as 'no state claims a halt'",
  );
  process.exit(7);
}

// The suspension row the crown assertion reads: a live, provisioned box whose
// only distinguishing fact is `suspended: true`.
const suspendedBp = {
  id: "probe",
  name: "Probe",
  host: "box.barkpark.cloud",
  provision_status: "succeeded",
  suspended: true,
  suspended_reason: "quota_exceeded",
};

let suspendedPill;
let suspendedStatus;
try {
  suspendedPill = hooks.lifecyclePill(suspendedBp);
  suspendedStatus = hooks.statusOf(suspendedBp);
} catch (err) {
  console.error(`the suspended probe threw: ${err && err.message}`);
  process.exit(6);
}

if (!suspendedPill || typeof suspendedPill.label !== "string" || !suspendedStatus || typeof suspendedStatus.detail !== "string") {
  console.error(`the suspended probe returned a bad shape: ${JSON.stringify({ suspendedPill, suspendedStatus })}`);
  process.exit(6);
}

process.stdout.write(JSON.stringify({
  // Array.from re-homes the rows out of the vm sandbox's realm before they are
  // serialized — the same realm care __app.test.mjs takes with planCatalog.
  painted: Array.from(painted.values()).sort((a, b) => (a.state < b.state ? -1 : a.state > b.state ? 1 : 0)),
  declared_labels: Array.from(Object.keys(hooks.LIFECYCLE_PILL_LABEL)).sort(),
  suspended: {
    state: suspendedPill.state,
    label: suspendedPill.label,
    detail: suspendedStatus.detail,
  },
  combos: combos,
}));

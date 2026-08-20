// __plan_features_dump.mjs — print the console's LIVE per-tier sold bullets as JSON.
//
// The client half of the sold-capability manifest guard
// (cloud/test/barkpark_cloud/sold_capability_manifest_test.exs). That guard
// asserts every capability this console SELLS — each bullet rendered with a ✓
// under a button that POSTs /v1/billing/checkout — names a signal the control
// plane can be shown to run, and reds when one does not.
//
// It reads the client side BY RUNNING, exactly as its sibling
// __plan_catalog_dump.mjs does: a regex over app.js source text is not a pin
// (it passes a refactor that keeps the bytes and changes the value, and it
// fails a reformat that changes nothing). This one goes one step further than
// the sibling — it does not read a CONSTANT, it CALLS `planFeatures(tier)` per
// tier, so what the guard sees is what the render path itself would compute,
// including any per-tier branch inside the function.
//
// app.js is a browser IIFE with no exports, so — exactly as __app.test.mjs does
// (same directory, same recipe) — we evaluate the SHIPPED file verbatim inside a
// node:vm sandbox whose document.readyState is "loading", which leaves init()
// merely REGISTERED on a no-op addEventListener. No boot path runs; the eval is
// side-effect-free. The IIFE hands its pure helpers out through __bpTestHook,
// and both `planCatalog` and `planFeatures` are already among them — this
// script needs NO app.js change to reach them.
//
// Output, on stdout: [{plan, bullets: [string], note: string|null}], one row per
// catalog tier, in catalog order. Any failure to reach the real value is a
// non-zero exit with a message on stderr — never an empty array, never a
// partial one, never a row with `bullets: []` synthesized from a throw. A guard
// that cannot read a side must RED, not pass:
//
//   2 — __bpTestHook carries no planCatalog
//   3 — planCatalog is not an array
//   4 — planCatalog is empty
//   5 — __bpTestHook carries no planFeatures (or it is not a function)
//   6 — planFeatures threw, or returned a non-array / non-string bullet
//
// Exit 5 is the one that matters most: if planFeatures stops being exported,
// this script must not print `[]` — an empty sold set would read to the Elixir
// side as "nothing unbacked is sold", which is the exact vacuous green this
// guard exists to prevent.
//
// Not web-reachable: BarkparkCloud.Web.Router's Plug.Static uses an explicit
// `only:` allowlist and __preview__/ is not in it (pinned by
// cloud/test/web/static_allowlist_test.exs).
//
// Run: node cloud/priv/static/__preview__/__plan_features_dump.mjs

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

// FAIL CLOSED on every way either half could go missing.
if (!Object.prototype.hasOwnProperty.call(hooks, "planCatalog")) {
  console.error("app.js did not export planCatalog on __bpTestHook — the console's plan catalog is unreadable");
  process.exit(2);
}
if (!Array.isArray(hooks.planCatalog)) {
  console.error(`__bpTestHook.planCatalog is not an array (got ${typeof hooks.planCatalog})`);
  process.exit(3);
}
if (hooks.planCatalog.length === 0) {
  console.error("__bpTestHook.planCatalog is EMPTY — an empty catalog must never read as agreement");
  process.exit(4);
}
if (typeof hooks.planFeatures !== "function") {
  console.error(
    "app.js did not export planFeatures on __bpTestHook — the sold bullets are unreadable, " +
    "and an unreadable sold set must never read as 'nothing unbacked is sold'",
  );
  process.exit(5);
}

const rows = [];
for (const tier of hooks.planCatalog) {
  const plan = tier && tier.plan;
  let bullets;

  try {
    bullets = hooks.planFeatures(tier);
  } catch (err) {
    console.error(`planFeatures(${JSON.stringify(plan)}) threw: ${err && err.message}`);
    process.exit(6);
  }

  if (!Array.isArray(bullets)) {
    console.error(`planFeatures(${JSON.stringify(plan)}) did not return an array (got ${typeof bullets})`);
    process.exit(6);
  }
  if (!bullets.every((b) => typeof b === "string" && b.trim() !== "")) {
    console.error(`planFeatures(${JSON.stringify(plan)}) returned a non-string or blank bullet: ${JSON.stringify(bullets)}`);
    process.exit(6);
  }

  rows.push({
    plan: plan,
    // Array.from re-homes the row out of the vm sandbox's realm before it is
    // serialized — the same realm care __app.test.mjs takes with planCatalog.
    bullets: Array.from(bullets),
    note: typeof tier.note === "string" ? tier.note : null,
  });
}

process.stdout.write(JSON.stringify(rows));

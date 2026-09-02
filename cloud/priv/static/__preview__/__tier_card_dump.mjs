// __tier_card_dump.mjs — render ONE money-screen tier card and print its HTML.
//
// The client half of the test-mode disclosure guard
// (cloud/test/barkpark_cloud/billing_test_mode_console_mirror_test.exs). That
// guard drives the SERVER's declared capability — the `billing_capability.checkout`
// value GET /v1/subscription actually puts on the wire — through the CONSOLE's
// real renderer, so ONE mutation (collapsing `:test_mode` into `:available` in
// billing.ex) reds the rendered assertion as well as the Elixir one. A regex
// over app.js source text could not do that: it would go green on a server that
// stopped declaring the state at all.
//
// app.js is a browser IIFE with no exports, so — exactly as __app.test.mjs and
// __plan_catalog_dump.mjs do (same directory, same recipe) — we evaluate the
// SHIPPED file verbatim inside a node:vm sandbox whose document.readyState is
// "loading", which leaves init() merely REGISTERED on a no-op
// addEventListener. No boot path runs; the eval is side-effect-free.
//
// Usage:  node __tier_card_dump.mjs <capability> [plan]
//   capability  the billing_capability.checkout value ("test_mode",
//               "available", "" for an unknown/absent declaration)
//   plan        a PLAN_CATALOG plan key; defaults to "supporter"
//
// The card is rendered for the actor the row is about: an UNSUBSCRIBED team
// (active plan "free", subscribed false), which is the only actor that ever
// sees a live Subscribe button.
//
// Output: the rendered HTML on stdout. Any failure to reach the real renderer
// is a non-zero exit with a message on stderr — never an empty string. A guard
// that cannot read a side must RED, not pass.
//
// Not web-reachable: BarkparkCloud.Web.Router's Plug.Static uses an explicit
// `only:` allowlist and __preview__/ is not in it (pinned by
// cloud/test/web/static_allowlist_test.exs).

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

// FAIL CLOSED on every way the render could go missing. Each of these would
// otherwise hand the Elixir side a shape it could read as "nothing to compare".
if (typeof hooks.tierCardHtml !== "function") {
  console.error("app.js did not export tierCardHtml on __bpTestHook — the money screen's renderer is unreachable");
  process.exit(2);
}
if (!Array.isArray(hooks.planCatalog) || hooks.planCatalog.length === 0) {
  console.error("__bpTestHook.planCatalog is missing or EMPTY — there is no tier to render");
  process.exit(3);
}

const capability = process.argv[2] === undefined ? "" : process.argv[2];
const planKey = process.argv[3] || "supporter";
const tier = hooks.planCatalog.filter((t) => t.plan === planKey)[0];
if (!tier) {
  console.error(`PLAN_CATALOG has no "${planKey}" tier — the guard is naming a plan the console does not carry`);
  process.exit(4);
}

// The unsubscribed team: active plan "free", subscribed false. That actor gets
// the live Subscribe on an :available plane, which is what makes the test_mode
// difference observable at all.
const html = hooks.tierCardHtml(tier, "free", false, capability);
if (typeof html !== "string" || html === "") {
  console.error("tierCardHtml returned nothing — an empty render must never read as agreement");
  process.exit(5);
}

process.stdout.write(html);

// __plan_catalog_dump.mjs — print the console's LIVE plan catalog as JSON.
//
// The client half of the cross-layer mirror guard
// (cloud/test/barkpark_cloud/billing_client_mirror_test.exs). That guard
// compares the server's configured per-plan instance ceiling against the
// console's PLAN_CATALOG, and it must read BOTH sides BY RUNNING — a regex over
// app.js source text is not a pin (it goes green on a refactor that keeps the
// bytes and changes the value, and red on a reformat that changes nothing).
//
// app.js is a browser IIFE with no exports, so — exactly as __app.test.mjs does
// (same directory, same recipe) — we evaluate the SHIPPED file verbatim inside a
// node:vm sandbox whose document.readyState is "loading", which leaves init()
// merely REGISTERED on a no-op addEventListener. No boot path runs; the eval is
// side-effect-free. The IIFE hands its pure helpers out through __bpTestHook,
// and `planCatalog: PLAN_CATALOG.slice()` is one of them.
//
// Output: the catalog array, JSON, on stdout. Any failure to reach the real
// value is a non-zero exit with a message on stderr — never an empty array,
// never a partial one. A guard that cannot read a side must RED, not pass.
//
// Not web-reachable: BarkparkCloud.Web.Router's Plug.Static uses an explicit
// `only:` allowlist and __preview__/ is not in it (pinned by
// cloud/test/web/static_allowlist_test.exs).
//
// Run: node cloud/priv/static/__preview__/__plan_catalog_dump.mjs

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

// FAIL CLOSED on every way the value could go missing. Each of these would
// otherwise hand the Elixir side a shape it could read as "nothing to compare".
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

process.stdout.write(JSON.stringify(hooks.planCatalog));

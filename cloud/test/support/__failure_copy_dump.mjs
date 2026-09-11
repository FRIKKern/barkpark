// __failure_copy_dump.mjs — run the SHIPPED console's failureCopy/failureTone
// over reasons handed in on argv, and print the results as JSON.
//
// The client half of the cross-surface lock in
// cloud/test/barkpark_cloud/failure_copy_client_mirror_test.exs. That guard
// holds `cloud/priv/static/app.js` and `BarkparkCloud.FailureCopy` to ONE
// answer for the born-failed github-push family, and it must read both sides BY
// RUNNING: a regex over app.js source text is not a pin — it goes green on a
// refactor that keeps the bytes and changes the behaviour, and red on a
// reformat that changes nothing. (Same recipe and same reasoning as
// priv/static/__preview__/__plan_catalog_dump.mjs; this one lives under
// cloud/test/ because that is the tree this lane may write, and because it IS
// reached from a run step — `mix test` spawns it — unlike the __preview__
// dumps, which the console-harness census lists as orphans.)
//
// app.js is a browser IIFE with no exports, so — exactly as __app.test.mjs does
// — we evaluate the SHIPPED file verbatim inside a node:vm sandbox whose
// document.readyState is "loading", which leaves init() merely REGISTERED on a
// no-op addEventListener. No boot path runs; the eval is side-effect-free. The
// IIFE hands its pure helpers out through __bpTestHook.
//
// Usage:  node __failure_copy_dump.mjs '["reason one","reason two"]'
// Output: [{"reason":…,"copy":…,"tone":…}, …] on stdout, in argv order.
// Every way the answer could go missing is a NON-ZERO EXIT with a message on
// stderr — never an empty array, never a partial one. A guard that cannot read
// a side must RED, not pass.

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

const appJs = new URL("../../priv/static/app.js", import.meta.url);
let src;
try {
  src = fs.readFileSync(appJs, "utf8");
} catch (e) {
  console.error(`cannot read app.js at ${appJs.pathname}: ${e.message}`);
  process.exit(2);
}
if (src.length === 0) {
  console.error("app.js is EMPTY — an unreadable client must never read as agreement");
  process.exit(3);
}

vm.createContext(sandbox);
vm.runInContext(src, sandbox);

// FAIL CLOSED on every way the answer could go missing.
for (const name of ["failureCopy", "failureTone"]) {
  if (typeof hooks[name] !== "function") {
    console.error(`app.js did not export ${name}() on __bpTestHook — the console's failure copy is unreadable`);
    process.exit(4);
  }
}

let reasons;
try {
  reasons = JSON.parse(process.argv[2] ?? "");
} catch (e) {
  console.error(`argv[2] is not JSON: ${e.message}`);
  process.exit(5);
}
if (!Array.isArray(reasons) || reasons.length === 0) {
  console.error("argv[2] must be a NON-EMPTY JSON array of reasons — an empty probe is a vacuous pass");
  process.exit(6);
}

process.stdout.write(JSON.stringify(reasons.map((reason) => ({
  reason,
  copy: hooks.failureCopy(reason),
  tone: hooks.failureTone(reason),
}))));

// __trial_reminder_dump.mjs — print the console's LIVE trial-reminder schedule,
// and the sentences it actually renders, as JSON.
//
// The client half of the cch-w50-s5 mirror
// (cloud/test/barkpark_cloud/billing_client_mirror_test.exs). That guard
// compares the server's advance-notice schedule —
// `BarkparkCloud.Workers.TrialExpiryWorker.notice_thresholds_days/0` — against
// the numerals the billing screen promises a team, and it must read BOTH sides
// BY RUNNING. A regex over app.js source text is not a pin: it goes green on a
// refactor that keeps the bytes and changes the value, and red on a reformat
// that changes nothing.
//
// Recipe is `__plan_catalog_dump.mjs`'s, verbatim (same directory, same node:vm
// sandbox with document.readyState "loading", so init() stays merely REGISTERED
// and no boot path runs). The IIFE hands its pure helpers out through
// __bpTestHook; `trialNoticeDays` is the schedule as DATA and `trialCardHtml`
// is the render, so the guard can pin the constant AND assert the numerals
// actually reach the sentence.
//
// Output, JSON on stdout:
//   { noticeDays: [3, 1],
//     cards: { unknown: "<html>", on: "<html>", muted: "<html>", ended: "<html>" } }
//
// Any failure to reach a real value is a non-zero exit with a message on
// stderr — never an empty array, never a partial one. A guard that cannot read
// a side must RED, not pass.
//
// Not web-reachable: BarkparkCloud.Web.Router's Plug.Static uses an explicit
// `only:` allowlist and __preview__/ is not in it (pinned by
// cloud/test/web/static_allowlist_test.exs).
//
// Run: node cloud/priv/static/__preview__/__trial_reminder_dump.mjs

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

// FAIL CLOSED on every way a value could go missing. Each of these would
// otherwise hand the Elixir side a shape it could read as "nothing to compare".
for (const name of ["trialNoticeDays", "trialCardHtml", "trialReminderCopy", "trialAlertsState"]) {
  if (typeof hooks[name] === "undefined") {
    console.error(`app.js did not export ${name} on __bpTestHook — the console's trial reminder is unreadable`);
    process.exit(2);
  }
}
if (!Array.isArray(hooks.trialNoticeDays)) {
  console.error(`__bpTestHook.trialNoticeDays is not an array (got ${typeof hooks.trialNoticeDays})`);
  process.exit(3);
}
if (hooks.trialNoticeDays.length === 0) {
  console.error("__bpTestHook.trialNoticeDays is EMPTY — an empty schedule must never read as agreement");
  process.exit(4);
}
if (!hooks.trialNoticeDays.every((n) => Number.isInteger(n) && n > 0)) {
  console.error(`__bpTestHook.trialNoticeDays holds a non-positive-integer day: ${JSON.stringify(hooks.trialNoticeDays)}`);
  process.exit(5);
}

// The RENDER, in each mute state, for a RUNNING trial (9 days out — the same
// non-vacuity control __app.test.mjs uses) plus the ended card. The second
// argument is the mute state, so the dump never depends on module-private
// notifCache being populated inside this sandbox.
const running = { plan: "trial", status: "active", trial_days_remaining: 9 };
const ended = { plan: "trial", status: "active", trial_days_remaining: 0 };
const cards = {
  unknown: hooks.trialCardHtml(running),
  on: hooks.trialCardHtml(running, "on"),
  muted: hooks.trialCardHtml(running, "muted"),
  ended: hooks.trialCardHtml(ended, "on"),
};
for (const [state, html] of Object.entries(cards)) {
  if (typeof html !== "string" || html.length === 0) {
    console.error(`trialCardHtml rendered nothing for mute state "${state}" — an empty card must never read as agreement`);
    process.exit(6);
  }
}

process.stdout.write(JSON.stringify({ noticeDays: hooks.trialNoticeDays, cards }));

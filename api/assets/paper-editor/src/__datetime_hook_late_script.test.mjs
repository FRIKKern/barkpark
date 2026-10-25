// __datetime_hook_late_script.test.mjs — task-cf45242ef3477fba: a datetime
// field whose hook mounts BEFORE the deferred bp-datetime-field.js has run
// still shows its stored value.
//
// On gyl (after #23445) event fdb8176c showed empty pickers although the
// server HTML was right. LiveView joined while the document was
// "interactive", before deferred scripts run; the inline
// `Hooks.BarkparkDatetimeField` entry ran once, found no
// `window.BarkparkDatetimeFieldHook`, and never retried.
//
// This test takes the REAL inline entry from root.html.heex (between the
// `bp-deferred-hook:start` / `:end` markers) and the REAL
// priv/static/assets/bp-datetime-field.js, mounts the hook in jsdom while the
// document is "interactive" and the implementation is missing, then runs the
// script and fires its load event, as the browser does.
//
// A last case covers the static render: the script fills a picker before any
// hook mounts.
//
// Run: node src/__datetime_hook_late_script.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "../../../lib/barkpark_web/layouts/root.html.heex");
const IMPL = path.join(__dirname, "../../../priv/static/assets/bp-datetime-field.js");

const layout = fs.readFileSync(ROOT, "utf8");
const m = layout.match(/\/\/ bp-deferred-hook:start\n([\s\S]*?)\/\/ bp-deferred-hook:end/);
assert.ok(m, "root.html.heex carries the bp-deferred-hook markers around the datetime hook entry");
const SHIM = m[1];
const IMPL_SRC = fs.readFileSync(IMPL, "utf8");

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A page whose deferred script has NOT run yet, in a given readyState.
function page(readyState) {
  const dom = new JSDOM(
    `<!doctype html><html><body>
      <div id="w" phx-hook="BarkparkDatetimeField" class="bp-datetime-field" data-value="2026-10-29T14:00:00Z">
        <input type="hidden" name="doc[date]" value="2026-10-29T14:00:00Z" data-datetime-value>
        <span id="p" phx-update="ignore"><input type="datetime-local"></span>
      </div>
      <script src="/assets/v/AAAAAAAAAAAAAAAA/bp-datetime-field.js" defer></script>
    </body></html>`,
    { runScripts: "outside-only", url: "http://localhost/", pretendToBeVisual: true }
  );
  const { window } = dom;
  Object.defineProperty(window.document, "readyState", { configurable: true, get: () => readyState });
  window.Hooks = {};
  window.eval("var Hooks = window.Hooks;\n" + SHIM);
  const hook = Object.create(window.Hooks.BarkparkDatetimeField);
  hook.el = window.document.getElementById("w");
  const picker = () => window.document.querySelector('input[type="datetime-local"]');
  // The deferred script runs, then the browser fires its load event.
  const loadImpl = () => {
    window.eval(IMPL_SRC);
    window.document.querySelector("script[src]").dispatchEvent(new window.Event("load"));
  };
  return { window, hook, picker, loadImpl };
}

// The hook is mounted when an edit in the picker reaches the hidden input
// (the script's static fill alone shows a value but listens to nothing).
function editsReachHidden(window, picker) {
  const hidden = window.document.querySelector("input[data-datetime-value]");
  picker().value = "2026-10-30T10:00";
  picker().dispatchEvent(new window.Event("input", { bubbles: true }));
  return hidden.value === window.BarkparkDatetime.toInstant("2026-10-30T10:00");
}

// What toLocalInput gives in the test process's zone, so the test does not
// depend on TZ: the hook's own conversion, read after it loads.
function want(window) {
  return window.BarkparkDatetime.toLocalInput("2026-10-29T14:00:00Z");
}

await check("mounted while 'interactive' and before the script ran: the picker fills once it loads", async () => {
  const { window, hook, picker, loadImpl } = page("interactive");
  hook.mounted();
  assert.equal(picker().value, "", "nothing to show yet");
  loadImpl();
  assert.notEqual(want(window), "");
  assert.equal(picker().value, want(window));
  assert.ok(editsReachHidden(window, picker), "the hook mounted after the script loaded");
});

await check("mounted before the script ran, with no load event: the poll fills it", async () => {
  const { window, hook, picker } = page("interactive");
  hook.mounted();
  window.eval(IMPL_SRC);
  await sleep(150);
  assert.equal(picker().value, want(window));
  assert.ok(editsReachHidden(window, picker), "the hook mounted after the poll saw the script");
});

await check("mounted while 'loading': DOMContentLoaded after the script fills it", async () => {
  const { window, hook, picker } = page("loading");
  hook.mounted();
  window.eval(IMPL_SRC);
  window.document.dispatchEvent(new window.Event("DOMContentLoaded"));
  assert.equal(picker().value, want(window));
});

await check("the script already ran: mounted fills the picker at once", async () => {
  const { window, hook, picker } = page("complete");
  window.eval(IMPL_SRC);
  hook.mounted();
  assert.equal(picker().value, want(window));
});

await check("static render, no hook mounted yet: the script fills the picker on its own", async () => {
  // gyl draws the form seconds before LiveView connects; hooks wait for that.
  const { window, picker } = page("interactive");
  window.eval(IMPL_SRC);
  assert.equal(picker().value, want(window));
});

await check("destroyed before the script ran: the late load does not mount it", async () => {
  const { window, hook, picker, loadImpl } = page("interactive");
  hook.mounted();
  hook.destroyed();
  loadImpl();
  assert.equal(hook.__bpMounted, undefined);
  assert.ok(!editsReachHidden(window, picker), "no listener was attached");
});

if (failures) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nall passed");

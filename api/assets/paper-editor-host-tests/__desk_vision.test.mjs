// __desk_vision.test.mjs — the desk's Vision (task-69d6bfc0907c051a, J37): a
// query is read by the browser through Barkpark's own reads, GROQ at
// …/v<apiVersion>/data/query/<ds> or a type and a query string at …/v1/data/query/<ds>/<type>,
// in the dataset and API version picked beside it;
// anything typed that is not a type and a query string goes as GROQ, in the
// query parameter, so it never reaches Barkpark as a path. The result is a
// folding JSON tree (a folded branch's contents leave the page), with the query
// URL to copy, the timings, Save result as JSON, and a word for screen readers.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-vision.js under
// jsdom on a form shaped like Desk.Vision's render, with fetch stubbed.
//
// Run: node ../paper-editor-host-tests/__desk_vision.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "./jsdom.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(here, "../../priv/static/assets/bp-desk-vision.js");

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost:4000/w/a/p/b/d/production/studio/_desk/_tools/vision",
  runScripts: "outside-only",
});
const { window } = dom;
const doc = window.document;

const words = {
  na: "n/a", execution: "Execution: %{time}", total: "End-to-end: %{time}", item: "1 item", items: "%{count} items",
  property: "1 property", properties: "%{count} properties", more: "Show %{count} more", empty: "Write a GROQ query",
  long: "The query is too long to send", failed: "Query failed: %{error}", error: "Query error: %{error}",
  one: "1 result in %{ms} ms", many: "%{count} results in %{ms} ms", done: "Query done in %{ms} ms",
  copied: "The URL is copied to the clipboard", "not-copied": "The URL could not be copied",
};
const attrs = Object.entries(words).map(([k, v]) => `data-t-${k}="${v}"`).join(" ");
const TODAY = `v${new Date().toISOString().split("T")[0]}`;
doc.body.innerHTML = `<div id="dk-vision" class="dk-vision" data-desk-vision data-scope="/w/a/p/b" data-dataset="production" ${attrs}>
  <select data-vision-dataset><option value="production" selected>production</option><option value="staging">Staging (staging)</option><option value="locked" disabled>locked</option></select>
  <select data-vision-version><option value="v1">v1</option><option value="vX">vX</option><option value="v2025-02-19">v2025-02-19</option><option value="${TODAY}" selected>${TODAY}</option><option value="other">Other</option></select>
  <label data-vision-custom hidden><span>Custom API version</span><input value="v" aria-invalid="true"></label>
  <select data-vision-perspective><option value="raw">No perspective (raw)</option><option value="published">published</option><option value="drafts" selected>drafts</option></select>
  <div data-vision-url hidden><button type="button" data-vision-copy>[Copy to clipboard]</button><span role="status" data-vision-copied></span><input id="vision-url" readonly></div>
  <textarea id="dk-vision-query">*[_type == "post"]</textarea>
  <button type="button" data-vision-fetch>Fetch</button>
  <section class="dk-vision-result" aria-label="Result" aria-busy="false"><div data-vision-out></div>
    <footer><span data-vision-ms>Execution: n/a</span><span data-vision-total>End-to-end: n/a</span>
    <span data-vision-save hidden><a href="#" download="vision-production.json" data-vision-json>JSON</a></span></footer></section>
  <div role="status" data-testid="announcer" data-vision-said></div>
</div>`;

// Every request the page makes, and the answer the next one gets.
const asked = [];
let answer = { status: 200, body: {} };
window.fetch = (url) => {
  asked.push(new URL(url, window.location.href));
  const { status, body } = answer;
  return Promise.resolve({ ok: status < 400, status, text: () => Promise.resolve(JSON.stringify(body)) });
};
window.localStorage.clear();
window.eval(readFileSync(SCRIPT, "utf8"));
const Vision = window.BarkparkDeskVision;
assert.ok(Vision, "bp-desk-vision.js sets window.BarkparkDeskVision");

const $ = (sel) => doc.querySelector(sel);
const query = $("#dk-vision-query");
const out = $("[data-vision-out]");
const settle = () => new Promise((r) => setTimeout(r, 0)).then(() => new Promise((r) => setTimeout(r, 0)));
const click = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const fold = (name) => [...out.querySelectorAll("button.json-toggle")].find((b) => b.textContent.replace("▾", "").replace("▸", "") === name);

// 1. What a query reads: a type and a query string, or GROQ in a parameter.
{
  const api = "/w/a/p/b";
  const s = Vision.target(api, "production", "post?filter[title][contains]=post 12&limit=5", "drafts", "v2025-02-19");
  assert.equal(s.groq, false);
  assert.equal(s.path, "/w/a/p/b/v1/data/query/production/post?filter%5Btitle%5D%5Bcontains%5D=post+12&limit=5&perspective=drafts");
  assert.match(Vision.target(api, "production", "post?perspective=raw", "drafts").path, /\?perspective=raw$/, "the query's own perspective wins");
  const g = Vision.target(api, "production", '*[_type == "post"]', "published", "v2025-02-19");
  assert.equal(g.groq, true);
  assert.equal(new URL(g.path, "http://x").pathname, "/w/a/p/b/v2025-02-19/data/query/production", "Sanity's address, at the version picked");
  assert.equal(new URL(Vision.target(api, "production", "*", "drafts", "v../x").path, "http://x").pathname, `/w/a/p/b/${TODAY}/data/query/production`, "a version that is not one: today's");
  assert.equal(new URL(g.path, "http://x").searchParams.get("query"), '*[_type == "post"]');
  assert.equal(new URL(g.path, "http://x").searchParams.get("perspective"), "published");
  for (const sneaky of ["../../v1/tasks", "post/../../tasks", "post#x", "/v1/tasks"]) {
    const t = Vision.target(api, "production", sneaky, "drafts", "v1");
    assert.equal(new URL(t.path, "http://x").pathname, "/w/a/p/b/v1/data/query/production", `${sneaky} goes as GROQ`);
  }
  assert.equal(Vision.target(api, "production", "   ", "drafts").error, "empty");
  assert.equal(Vision.target(api, "production", "*[" + "x".repeat(33000) + "]", "drafts").error, "long", "past the GROQ read's 32,753 bytes");
  assert.match(Vision.target(api, "production", "post", "bogus").path, /perspective=drafts$/, "an unknown perspective reads drafts");
}

// 2. Ctrl+Enter fetches the query string; its documents fold, and a folded branch's contents leave the page.
{
  answer = { status: 200, body: { result: { documents: [{ _id: "post-12", title: "Fixture post 12" }], count: 1 }, ms: 7 } };
  query.value = "post?filter[title][contains]=post 12&limit=5";
  query.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
  await settle();
  assert.equal(asked.length, 1);
  assert.equal(asked[0].pathname, "/w/a/p/b/v1/data/query/production/post");
  assert.equal($("[data-vision-ms]").textContent, "Execution: 7ms");
  assert.match($("[data-vision-total]").textContent, /^End-to-end: \d+ms$/);
  assert.match($("#vision-url").value, /^http:\/\/localhost:4000\/w\/a\/p\/b\/v1\/data\/query\/production\/post\?.*perspective=drafts$/);
  assert.equal($("[data-vision-url]").hidden, false);
  assert.equal($("[data-vision-save]").hidden, false);
  assert.equal($("[data-vision-said]").textContent, "1 result in 7 ms");
  const docs = fold("documents: […] 1 item");
  assert.ok(docs, "the documents array says how much it holds");
  assert.equal(docs.parentNode.getAttribute("aria-expanded"), "true");
  assert.match(out.textContent, /Fixture post 12/);
  click(docs);
  assert.equal(docs.parentNode.getAttribute("aria-expanded"), "false");
  assert.doesNotMatch(out.textContent, /Fixture post 12/, "a folded branch's contents are not in the page");
  click(docs);
  assert.match(out.textContent, /Fixture post 12/);
  assert.equal(out.querySelector("[role=tree] > li > button").disabled, false);
  // Save result as JSON: a blob of the result, made when asked for.
  window.URL.createObjectURL = () => "blob:http://localhost/1";
  window.URL.revokeObjectURL = () => {};
  const link = $("[data-vision-json]");
  link.addEventListener("click", (e) => e.preventDefault());
  click(link);
  assert.equal(link.getAttribute("href"), "blob:http://localhost/1");
  // The query and perspective stay in this browser.
  assert.equal(JSON.parse(window.localStorage.getItem("bp-desk-vision")).query, query.value);
}

// 3. A GROQ parse error: said and drawn, with where it went wrong; and no path is ever what was typed.
{
  asked.length = 0;
  answer = { status: 400, body: { error: { code: "malformed", message: "GROQ syntax error at byte 0: expected an expression", description: "expected an expression", start: 0, end: 1 } } };
  query.value = "../../v1/tasks";
  click($("[data-vision-fetch]"));
  await settle();
  assert.equal(asked.length, 1);
  assert.deepEqual(asked.map((u) => u.pathname), [`/w/a/p/b/${TODAY}/data/query/production`]);
  assert.ok(!asked.some((u) => decodeURIComponent(u.pathname).includes("/v1/tasks")));
  const alert = out.querySelector("[role=alert]");
  assert.match(alert.textContent, /expected an expression/);
  assert.equal(alert.querySelector("pre").textContent, "../../v1/tasks\n^");
  assert.ok(out.hasAttribute("data-error"));
  assert.equal($("[data-vision-said]").textContent, "Query error: expected an expression");
  assert.equal($("[data-vision-save]").hidden, true, "nothing to save");
  assert.match($("[data-vision-ms]").textContent, /^Execution: \d+ms$/, "no ms of its own: the time it took");
}

// 4. GROQ's answer is its result; a big array draws in steps.
{
  answer = { status: 200, body: { query: "*", result: Array.from({ length: 250 }, (_, i) => ({ _id: `p${i}` })), ms: 3 } };
  query.value = "*[0...250]";
  click($("[data-vision-fetch]"));
  await settle();
  assert.equal($("[data-vision-said]").textContent, "250 results in 3 ms");
  const root = out.querySelector("[role=tree] > li");
  assert.equal(root.querySelector("button").textContent.trim(), "[…] 250 items");
  const more = () => out.querySelector("button.json-more");
  assert.equal(more().textContent, "Show 150 more");
  // Show more hands focus on to the first row it drew, not to the body.
  const first = more();
  first.focus();
  click(first);
  const rows = () => root.querySelectorAll(":scope > ul > li[role=treeitem]");
  assert.equal(doc.activeElement, rows()[100].querySelector(":scope > button"), "focus is on row 100's toggle");
  assert.equal(more().textContent, "Show 50 more");
  click(more());
  assert.equal(more(), null);
  assert.equal(root.querySelectorAll(":scope > ul > li[role=treeitem]").length, 250);
}

// 4b. Rows of plain values have no toggle: the first drawn row itself takes focus.
{
  answer = { status: 200, body: { query: "*", result: Array.from({ length: 150 }, (_, i) => i), ms: 1 } };
  query.value = "*[0...150]._id";
  click($("[data-vision-fetch]"));
  await settle();
  const more = out.querySelector("button.json-more");
  more.focus();
  click(more);
  const row = out.querySelectorAll("[role=tree] > li > ul > li[role=treeitem]")[100];
  assert.equal(doc.activeElement, row);
  assert.equal(row.tabIndex, -1);
}

// 5. An empty query is refused here; Copy says it copied.
{
  asked.length = 0;
  query.value = "  ";
  click($("[data-vision-fetch]"));
  await settle();
  assert.equal(asked.length, 0, "nothing sent");
  assert.match(out.querySelector("[role=alert]").textContent, /Write a GROQ query/);
  let copied = null;
  Object.defineProperty(window.navigator, "clipboard", { value: { writeText: (t) => ((copied = t), Promise.resolve()) }, configurable: true });
  $("#vision-url").value = "http://localhost:4000/w/a/p/b/v1/data/query/production?query=*";
  click($("[data-vision-copy]"));
  await settle();
  assert.equal(copied, "http://localhost:4000/w/a/p/b/v1/data/query/production?query=*");
  assert.equal($("[data-vision-copied]").textContent, "The URL is copied to the clipboard");
}

// 6. Fetch keeps its focus while it runs: busy is aria-disabled, never `disabled` (Chrome blurs a
// focused button that becomes disabled), and a press while busy sends nothing.
{
  asked.length = 0;
  let release;
  const held = new Promise((r) => (release = r));
  const fetchAs = window.fetch;
  window.fetch = (url) => {
    asked.push(new URL(url, window.location.href));
    return held.then(() => ({ ok: true, status: 200, text: () => Promise.resolve(JSON.stringify({ query: "*", result: [], ms: 1 })) }));
  };
  const button = $("[data-vision-fetch]");
  query.value = "*[0...1]";
  button.focus();
  click(button);
  assert.equal(button.disabled, false, "never disabled while it runs");
  assert.equal(button.getAttribute("aria-disabled"), "true");
  assert.equal(out.closest("section").getAttribute("aria-busy"), "true");
  click(button);
  query.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
  assert.equal(asked.length, 1, "a press while busy sends nothing");
  release();
  await settle();
  assert.equal(button.hasAttribute("aria-disabled"), false);
  assert.equal(doc.activeElement, button, "focus stayed on Fetch");
  click(button);
  assert.equal(asked.length, 2, "runs again once done");
  await settle();
  window.fetch = fetchAs;
}

// 7. The pickers, as TanStack's: the dataset and API version a run reads; "Other", a version typed.
{
  asked.length = 0;
  answer = { status: 200, body: { query: "*", result: [], ms: 1 } };
  const change = (el, value) => ((el.value = value), el.dispatchEvent(new window.Event("change", { bubbles: true })));
  const type = (el, value) => ((el.value = value), el.dispatchEvent(new window.Event("input", { bubbles: true })));
  const ds = $("[data-vision-dataset]");
  const pick = $("[data-vision-version]");
  const field = $("[data-vision-custom]");
  const custom = field.querySelector("input");
  change(ds, "staging");
  assert.equal($("[data-vision-json]").getAttribute("download"), "vision-staging.json", "Save names the dataset picked");
  change(pick, "v2025-02-19");
  query.value = "*[0...1]";
  click($("[data-vision-fetch]"));
  await settle();
  assert.equal(asked.at(-1).pathname, "/w/a/p/b/v2025-02-19/data/query/staging");
  assert.match($("#vision-url").value, /\/v2025-02-19\/data\/query\/staging\?query=/);
  // The query-string form reads its own route, in the dataset picked.
  query.value = "post?limit=1";
  click($("[data-vision-fetch]"));
  await settle();
  assert.equal(asked.at(-1).pathname, "/w/a/p/b/v1/data/query/staging/post");
  // Other: a field for the version, "v" and not yet one; the last that was one is still sent.
  change(pick, "other");
  assert.equal(field.hidden, false);
  assert.equal(custom.value, "v");
  assert.equal(custom.getAttribute("aria-invalid"), "true");
  query.value = "*[0...1]";
  click($("[data-vision-fetch]"));
  await settle();
  assert.equal(asked.at(-1).pathname, "/w/a/p/b/v2025-02-19/data/query/staging");
  type(custom, "2024-01-0");
  assert.equal(custom.getAttribute("aria-invalid"), "true");
  type(custom, "v2024-01-01");
  assert.equal(custom.getAttribute("aria-invalid"), "false");
  click($("[data-vision-fetch]"));
  await settle();
  assert.equal(asked.at(-1).pathname, "/w/a/p/b/v2024-01-01/data/query/staging");
  // Kept in this browser with the query, as TanStack's.
  const kept = JSON.parse(window.localStorage.getItem("bp-desk-vision"));
  assert.equal(kept.dataset, "staging");
  assert.equal(kept.version, "v2024-01-01");
  change(pick, "vX");
  assert.equal(field.hidden, true);
  assert.deepEqual(["x", "X", "v1", "1", "2024-02-30x", "v2024-13-01"].map(Vision.customApiVersion), ["vX", "vX", "v1", "v1", null, null]);
}

console.log("__desk_vision: ok");
process.exit(0);

// __desk_vision.test.mjs — the desk's Vision (task-69d6bfc0907c051a, J37): a
// query is read by the browser through Barkpark's own reads, GROQ at
// …/v<apiVersion>/data/query/<ds> or a type and a query string at …/v1/data/query/<ds>/<type>,
// in the dataset and API version picked beside it, with Params as $name=<JSON>;
// anything typed that is not a type and a query string goes as GROQ, in the
// query parameter, so it never reaches Barkpark as a path. The result is a
// folding JSON tree (a folded branch's contents leave the page), with the query
// URL to copy, the timings, Save result as JSON, and a word for screen readers.
//
// Runs the TRACKED static assets api/priv/static/assets/bp-desk-vision-query.js,
// bp-desk-vision-tree.js and bp-desk-vision.js (in Desk.Vision's order) under
// jsdom on a form shaped like Desk.Vision's render, with fetch stubbed.
//
// Run: node ../paper-editor-host-tests/__desk_vision.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "./jsdom.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const SCRIPTS = ["bp-desk-vision-query.js", "bp-desk-vision-tree.js", "bp-desk-vision.js"].map((f) => join(here, "../../priv/static/assets", f));

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
  "params-json": "Parameters are not valid JSON: %{detail}", "params-object": "Params must be a JSON object",
  "params-missing": "Param $%{name} referenced, but not provided",
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
  <div data-vision-params-pane><span role="img" data-vision-params-error hidden></span><textarea id="vision-params" aria-describedby="vision-params-why" data-vision-params>{
  
}</textarea><span id="vision-params-why" data-vision-params-why></span></div>
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
for (const script of SCRIPTS) window.eval(readFileSync(script, "utf8"));
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

// 8. Params, as TanStack's: each key the query names as $key goes as $key=<JSON>, as Sanity's
// client sends it, and no value ever changes the path, the dataset or another parameter.
{
  const api = "/w/a/p/b";
  const at = (t) => new URL(t.path, "http://x");
  const g = at(Vision.target(api, "production", "*[_type == $t][0...$n]{tags}", "drafts", "v2025-02-19", { t: "post", n: 2, tags: ["a", "b"] }));
  assert.equal(g.pathname, "/w/a/p/b/v2025-02-19/data/query/production");
  assert.deepEqual([g.searchParams.get("$t"), g.searchParams.get("$n"), g.searchParams.get("$tags")], ['"post"', "2", '["a","b"]']);
  // Keys and values that look like a path, a dataset or another parameter are each one $name.
  const nasty = { dataset: "staging", query: "*", perspective: "raw", "x&dataset=staging": "/../v1/tasks", "../../v1": "#" };
  const n = at(Vision.target(api, "production", '*[_type == "post"]', "drafts", "v1", nasty));
  assert.equal(n.pathname, "/w/a/p/b/v1/data/query/production", "the path is the dataset picked");
  assert.equal(n.searchParams.get("dataset"), null);
  assert.equal(n.searchParams.getAll("query").join("|"), '*[_type == "post"]');
  assert.equal(n.searchParams.getAll("perspective").join("|"), "drafts");
  assert.equal(n.searchParams.get("$dataset"), '"staging"');
  assert.equal(n.searchParams.get("$x&dataset=staging"), '"/../v1/tasks"');
  assert.equal(n.searchParams.get("$../../v1"), '"#"');
  // The query-string form puts each $key's value in, encoded: it stays that one parameter's value.
  const s = at(Vision.target(api, "production", "post?filter[title][contains]=$t&limit=$n", "drafts", "v1", { t: "x&dataset=staging/../../v1/tasks#", n: 5 }));
  assert.equal(s.pathname, "/w/a/p/b/v1/data/query/production/post");
  assert.equal(s.searchParams.get("filter[title][contains]"), "x&dataset=staging/../../v1/tasks#");
  assert.equal(s.searchParams.get("limit"), "5");
  assert.equal(s.searchParams.get("dataset"), null);
  const shown = Vision.target(api, "production", "post?filter[title][contains]=$t&limit=$n", "drafts", "v1", { t: "post 1", n: 2 }).shown;
  assert.match(shown, /\/post\?filter\[title\]\[contains\]=post\+1&limit=2&perspective=drafts$/, "the Query URL shows the query string as typed, as TanStack's");
  // Only the brackets: a value's & and # stay encoded, so the copied URL is the same request.
  const tricky = Vision.target(api, "production", "post?filter[title][contains]=$t", "drafts", "v1", { t: "a&limit=1#x" });
  assert.match(tricky.shown, /filter\[title\]\[contains\]=a%26limit%3D1%23x&perspective=drafts$/);
  assert.deepEqual([...new URL(tricky.shown, "http://x").searchParams], [...new URL(tricky.path, "http://x").searchParams], "the shown URL reads as the sent one");
  // The page's objects are jsdom's: compared as JSON.
  const plain = (v) => JSON.parse(JSON.stringify(v));
  assert.deepEqual(plain(Vision.target(api, "production", "post?filter[_id]=$id", "drafts", "v1", {})), { error: "params-missing", name: "id" });
  assert.deepEqual(plain(["", "  ", "{}", '{"a": 1}'].map((t) => Vision.parseParams(t))), [{ params: {} }, { params: {} }, { params: {} }, { params: { a: 1 } }]);
  assert.deepEqual(["[1]", "null", '"s"', "2"].map((t) => Vision.parseParams(t).error), Array(4).fill("params-object"));
  assert.equal(Vision.parseParams('{"t":').error, "params-json");

  // Typed into the page: a query naming $t with Params {"t": "post"} sends $t="post".
  asked.length = 0;
  answer = { status: 200, body: { query: "*", result: [{ _id: "p1" }], ms: 2 } };
  const type = (el, value) => ((el.value = value), el.dispatchEvent(new window.Event("input", { bubbles: true })));
  const params = $("[data-vision-params]");
  const pane = $("[data-vision-params-pane]");
  const icon = $("[data-vision-params-error]");
  const button = $("[data-vision-fetch]");
  $("[data-vision-dataset]").value = "production";
  query.value = "*[_type == $t]";
  type(params, '{"t": "post"}');
  click(button);
  await settle();
  assert.equal(asked.length, 1);
  assert.equal(asked[0].pathname, "/w/a/p/b/vX/data/query/production", "the version §7 left picked");
  assert.equal(asked[0].searchParams.get("$t"), '"post"');
  assert.equal(new URL($("#vision-url").value).searchParams.get("$t"), '"post"', "the Query URL names it");
  assert.equal(JSON.parse(window.localStorage.getItem("bp-desk-vision")).params, '{"t": "post"}', "kept with the query");
  // Not JSON: the pane is tinted, its icon says why, Fetch waits, and a press sends nothing but says why.
  type(params, '{"t":');
  assert.ok(pane.hasAttribute("data-invalid"));
  assert.equal(params.getAttribute("aria-invalid"), "true");
  assert.equal(icon.hidden, false);
  assert.match(icon.title, /^Parameters are not valid JSON: ./);
  assert.equal(icon.getAttribute("aria-label"), icon.title, "the icon is named by the reason");
  assert.equal(doc.getElementById(params.getAttribute("aria-describedby")).textContent, icon.title, "the box is described by it");
  assert.equal(button.getAttribute("aria-disabled"), "true");
  click(button);
  params.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
  await settle();
  assert.equal(asked.length, 1, "nothing sent");
  assert.match(out.querySelector("[role=alert]").textContent, /^Parameters are not valid JSON: ./);
  assert.equal($("[data-vision-url]").hidden, true);
  type(params, "[1]");
  assert.equal(icon.title, "Params must be a JSON object");
  assert.equal(icon.getAttribute("aria-label"), "Params must be a JSON object", "not \"not valid JSON\" for valid JSON that is not an object");
  assert.equal($("[data-vision-params-why]").textContent, "Params must be a JSON object");
  // An object again: Fetch is back, and Ctrl+Enter in Params runs, as in the query.
  type(params, '{"t": "page"}');
  assert.equal(pane.hasAttribute("data-invalid"), false);
  assert.equal(icon.hidden, true);
  assert.equal($("[data-vision-params-why]").textContent, "", "no reason while Params are an object");
  assert.equal(button.hasAttribute("aria-disabled"), false);
  params.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
  await settle();
  assert.equal(asked.length, 2);
  assert.equal(asked[1].searchParams.get("$t"), '"page"');
  // The query-string form says which $name Params lack, and sends nothing.
  query.value = "post?filter[_id]=$id";
  click(button);
  await settle();
  assert.equal(asked.length, 2);
  assert.match(out.querySelector("[role=alert]").textContent, /Param \$id referenced, but not provided/);
}

console.log("__desk_vision: ok");
process.exit(0);

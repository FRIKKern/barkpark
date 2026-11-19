// __desk_vision.test.mjs — the desk's Vision (task-69d6bfc0907c051a, J37): a
// query is read by the browser through Barkpark's own reads, GROQ at
// …/v1/data/groq/<ds> or a type and a query string at …/v1/data/query/<ds>/<type>;
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
doc.body.innerHTML = `<div id="dk-vision" class="dk-vision" data-desk-vision data-api="/w/a/p/b/v1/data" data-dataset="production" ${attrs}>
  <select data-vision-perspective><option value="raw">No perspective (raw)</option><option value="published">published</option><option value="drafts" selected>drafts</option></select>
  <div data-vision-url hidden><button type="button" data-vision-copy>[Copy to clipboard]</button><span role="status" data-vision-copied></span><input id="dk-vision-url" readonly></div>
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
  const api = "/w/a/p/b/v1/data";
  const s = Vision.target(api, "production", "post?filter[title][contains]=post 12&limit=5", "drafts");
  assert.equal(s.groq, false);
  assert.equal(s.path, "/w/a/p/b/v1/data/query/production/post?filter%5Btitle%5D%5Bcontains%5D=post+12&limit=5&perspective=drafts");
  assert.match(Vision.target(api, "production", "post?perspective=raw", "drafts").path, /\?perspective=raw$/, "the query's own perspective wins");
  const g = Vision.target(api, "production", '*[_type == "post"]', "published");
  assert.equal(g.groq, true);
  assert.equal(new URL(g.path, "http://x").pathname, "/w/a/p/b/v1/data/groq/production");
  assert.equal(new URL(g.path, "http://x").searchParams.get("query"), '*[_type == "post"]');
  assert.equal(new URL(g.path, "http://x").searchParams.get("perspective"), "published");
  for (const sneaky of ["../../v1/tasks", "post/../../tasks", "post#x", "/v1/tasks"]) {
    const t = Vision.target(api, "production", sneaky, "drafts");
    assert.equal(new URL(t.path, "http://x").pathname, "/w/a/p/b/v1/data/groq/production", `${sneaky} goes as GROQ`);
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
  assert.match($("#dk-vision-url").value, /^http:\/\/localhost:4000\/w\/a\/p\/b\/v1\/data\/query\/production\/post\?.*perspective=drafts$/);
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
  assert.deepEqual(asked.map((u) => u.pathname), ["/w/a/p/b/v1/data/groq/production"]);
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
  click(more());
  assert.equal(more().textContent, "Show 50 more");
  click(more());
  assert.equal(more(), null);
  assert.equal(root.querySelectorAll(":scope > ul > li[role=treeitem]").length, 250);
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
  $("#dk-vision-url").value = "http://localhost:4000/w/a/p/b/v1/data/groq/production?query=*";
  click($("[data-vision-copy]"));
  await settle();
  assert.equal(copied, "http://localhost:4000/w/a/p/b/v1/data/groq/production?query=*");
  assert.equal($("[data-vision-copied]").textContent, "The URL is copied to the clipboard");
}

console.log("__desk_vision: ok");
process.exit(0);

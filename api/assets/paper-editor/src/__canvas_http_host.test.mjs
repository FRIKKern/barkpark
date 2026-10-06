// task-9b0005a2f59d7690: <bp-paper-canvas> saved over HTTP by a fetch host.
// The host is the one EMBED-CONTRACT.md documents ("Recipe: an HTTP host"),
// extracted from the doc and run as written, so the recipe cannot drift from
// what this test proves. A scripted server stands in for the /ops route:
// it fences on ifRev (412 + details.actual) and applies patch-block ops.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const contract = readFileSync(new URL("../EMBED-CONTRACT.md", import.meta.url), "utf8");
const fenced = contract.split("<!-- http-host:begin -->")[1]?.split("<!-- http-host:end -->")[0];
assert.ok(fenced, "EMBED-CONTRACT.md carries the http-host block");
const recipe = fenced.replace(/^\s*```js\s*/, "").replace(/```\s*$/, "");

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
await import("./canvas/index.js");

const para = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const textOf = (block) => (block.content || []).map((n) => n.value).join("");

// The scripted server: one document, a rev counter, patch-block applied in place.
const server = { n: 1, blocks: [para("p-1", "Before"), para("p-2", "Other")] };
const rev = () => `r${server.n}`;
const posts = [];
const reads = [];
const json = (status, body) => ({ ok: status < 400, status, json: async () => body });
const fetch = async (url, init = {}) => {
  if (init.method === "POST") {
    const body = JSON.parse(init.body);
    posts.push(body);
    if (body.ifRev !== rev()) {
      return json(412, { error: { code: "precondition_failed", details: { expected: body.ifRev, actual: rev() } } });
    }
    for (const op of body.ops) {
      assert.equal(op.op, "patch-block", "the canvas emits server-shaped ops");
      server.blocks = server.blocks.map((b) => (b.id === op.id ? { ...b, ...op.patch } : b));
    }
    server.n += 1;
    return json(200, { result: { results: body.ops.map(() => ({})), rev: rev() } });
  }
  reads.push(url);
  return json(200, { result: { _id: "drafts.article-1", _rev: rev(), blocks: server.blocks } });
};
const connectCanvasOverHttp = new Function("fetch", `${recipe}\nreturn connectCanvasOverHttp;`)(fetch);

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = structuredClone(server.blocks);
document.body.appendChild(canvas);
const errors = [];
const disconnect = connectCanvasOverHttp(canvas, {
  opsUrl: "/w/acme/p/site/v1/data/doc/production/article/article-1/ops",
  readUrl: "/w/acme/p/site/v1/data/doc/production/article/article-1?perspective=raw",
  readBlocks: (doc) => doc.blocks,
  rev: "r1",
  headers: { authorization: "Bearer test" },
  onError: (e) => errors.push(e),
});
const settle = () => new Promise((resolve) => setTimeout(resolve, 30));
const typeInFirst = (text) => {
  const { state } = canvas._editor;
  // The end of p-1's text: the first node's content size + 1 (its opening).
  const end = state.doc.firstChild.content.size + 1;
  canvas._editor.commands.focus();
  canvas._editor.view.dispatch(state.tr.insertText(text, end));
};
const liveTexts = () => canvas._editor.getJSON().content.map((n) => (n.content || []).map((c) => c.text).join(""));

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.equal(canvas.acknowledgedSaves, true, "the host turns on acknowledged saves");

  // 1. A batch goes out as {ops, ifRev}, fenced on the rev the host was given.
  typeInFirst(" one");
  assert.equal(canvas.flushPendingChanges(), true);
  await settle();
  assert.equal(posts.length, 1);
  assert.deepEqual(Object.keys(posts[0]).sort(), ["ifRev", "ops"]);
  assert.equal(posts[0].ifRev, "r1");
  assert.equal(canvas.hasPendingChanges(), false, "the 200 acknowledged the batch");
  assert.equal(reads.length, 1, "the saved document is read back as the canvas's own echo");

  // 2. result.rev becomes the next ifRev.
  typeInFirst(" two");
  canvas.flushPendingChanges();
  await settle();
  assert.equal(posts[1].ifRev, "r2", "the answer's rev fences the next batch");
  assert.equal(textOf(server.blocks[0]), "Before one two");

  // 3. Another writer edits p-2. The next batch is stale: 412, resend on
  //    details.actual, re-read, and the foreign change arrives on screen
  //    without losing the author's edit.
  server.blocks = server.blocks.map((b) => (b.id === "p-2" ? para("p-2", "Other, edited elsewhere") : b));
  server.n += 1; // r4
  typeInFirst(" three");
  canvas._editor.commands.blur();
  canvas.flushPendingChanges();
  await settle();
  assert.equal(posts[2].ifRev, "r3", "the stale batch went out on the rev the host held");
  assert.equal(posts[3].ifRev, "r4", "and was resent on error.details.actual");
  assert.deepEqual(posts[3].ops, posts[2].ops, "the same batch, unchanged");
  assert.equal(reads.length, 3, "one read-back per saved batch");
  assert.deepEqual(server.blocks.map(textOf), ["Before one two three", "Other, edited elsewhere"]);
  assert.deepEqual(liveTexts(), ["Before one two three", "Other, edited elsewhere"], "both writers' changes are on screen");
  assert.equal(canvas.hasPendingChanges(), false);

  // 4. And the fence keeps up: the next batch rides the re-read rev.
  typeInFirst(" four");
  canvas.flushPendingChanges();
  await settle();
  assert.equal(posts[4].ifRev, "r5");
  assert.equal(textOf(server.blocks[0]), "Before one two three four");
  assert.deepEqual(errors, []);

  // 5. A later foreign write shows up through the host's own read-back: no
  //    acknowledged save is left waiting for an echo that never comes.
  server.blocks = server.blocks.map((b) => (b.id === "p-2" ? para("p-2", "Third writer") : b));
  server.n += 1; // r7
  typeInFirst(" five");
  canvas._editor.commands.blur();
  canvas.flushPendingChanges();
  await settle();
  assert.equal(posts.at(-1).ifRev, "r7", "a 412 on r6, resent on r7");
  assert.deepEqual(liveTexts(), ["Before one two three four five", "Third writer"]);

  console.log("ok canvas http host: {ops, ifRev}, rev hand-off, 412 resend + re-read keeps both writers");
} finally {
  disconnect();
  canvas.remove();
}

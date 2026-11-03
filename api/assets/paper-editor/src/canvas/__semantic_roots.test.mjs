import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const jsdom = new JSDOM("<!doctype html><body></body>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = jsdom;
for (const name of ["CustomEvent", "document", "Event", "HTMLElement", "KeyboardEvent", "Node"])
  globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });

const { Footnote, Toc, Video } = await import("./island-node.js");
const { embedConformanceRoot, sheetConformanceRoot } = await import("./embed-node.js");

function mount(extension, attrs) {
  const current = { type: { name: extension.name }, attrs };
  const editor = {
    isEditable: true,
    state: { doc: { nodeAt: () => current } },
    chain: () => ({ command() { return this; }, run: () => true }),
  };
  const view = extension.config.addNodeView()({ node: current, editor, getPos: () => 0 });
  document.body.appendChild(view.dom);
  return view;
}

const footnote = mount(Footnote, {
  notes: [{ id: "fn1", text: "The board updates live." }],
});
assert.equal(footnote.dom.querySelector("[data-bp-conformance-root]").outerHTML,
  '<ol class="bp-footnote" data-bp-conformance-root=""><li class="bp-footnote__note" id="fn-fn1">The board updates live.</li></ol>');
assert.ok(footnote.dom.querySelector("textarea"), "footnote edit controls remain mounted beside the semantic preview");

const toc = mount(Toc, {
  numbered: true,
  items: [
    { anchor: "start", level: 2, text: "Start" },
    { anchor: "detail", level: 3, text: "Detail" },
    { anchor: "finish", level: 2, text: "Finish" },
  ],
});
const tocRoot = toc.dom.querySelector("[data-bp-conformance-root]");
assert.deepEqual([...tocRoot.querySelectorAll("li")].map((li) => [li.dataset.level, li.firstChild.getAttribute("href"), li.textContent]), [
  ["1", "#start", "1. Start"],
  ["2", "#detail", "1.1. Detail"],
  ["1", "#finish", "2. Finish"],
]);
assert.ok(toc.dom.querySelector("textarea"), "toc edit controls remain mounted beside the semantic preview");

const video = mount(Video, {
  src: "https://ex.com/demo.mp4",
  poster: "https://ex.com/poster.jpg",
  bpRest: { captions: [{ lang: "en", src: "https://ex.com/en.vtt" }] },
});
const videoRoot = video.dom.querySelector("[data-bp-conformance-root]");
assert.equal(videoRoot.tagName, "FIGURE");
assert.equal(videoRoot.querySelector("video").getAttribute("src"), "https://ex.com/demo.mp4");
assert.equal(videoRoot.querySelector("track").getAttribute("src"), "https://ex.com/en.vtt");
assert.ok(video.dom.querySelector("input[aria-label='Video url']"),
  "video edit controls remain mounted beside the semantic preview");

const embed = embedConformanceRoot(document, { target: "Field notes" });
assert.equal(embed.outerHTML,
  '<section class="paper-embed paper-embed--unresolved bp-embed bp-embed--unresolved" data-embed="Field notes" data-bp-conformance-root="">↪ Field notes</section>');

const sheet = sheetConformanceRoot(document, {
  snapshot: {
    col_widths: [12, 8],
    head: ["Item", "Cost"],
    rows: [["Hosting", "42"], ["Domains", "18"]],
  },
});
assert.equal(sheet.outerHTML,
  '<table class="bp-table" role="presentation" data-bp-conformance-root=""><thead><tr><th class="bp-sheet__th" style="width: 12px;">Item</th><th class="bp-sheet__th" style="width: 8px;">Cost</th></tr></thead><tbody><tr><td class="bp-sheet__td" style="width: 12px;">Hosting</td><td class="bp-sheet__td sheet-al-right" style="width: 8px;">42</td></tr><tr><td class="bp-sheet__td" style="width: 12px;">Domains</td><td class="bp-sheet__td sheet-al-right" style="width: 8px;">18</td></tr></tbody></table>');

for (const view of [footnote, toc, video]) {
  view.destroy();
  view.dom.remove();
}
window.close();
console.log("canvas semantic roots preserve mounted edit islands: ok");

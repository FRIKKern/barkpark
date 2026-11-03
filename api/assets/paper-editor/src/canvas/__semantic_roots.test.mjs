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
const { Embed, Sheet } = await import("./embed-node.js");
const { Divider } = await import("./divider-node.js");

function mockNode(extension, attrs, type = null) {
  const nodeType = type || {
    name: extension.name,
    create(nextAttrs) { return mockNode(extension, nextAttrs, this); },
  };
  return {
    type: nodeType,
    attrs,
    eq(other) {
      return other?.type?.name === nodeType.name &&
        JSON.stringify(other.attrs) === JSON.stringify(attrs);
    },
  };
}

function mount(extension, attrs) {
  const current = mockNode(extension, attrs);
  const editor = {
    isEditable: true,
    options: { element: document.body },
    state: { doc: { nodeAt: () => current } },
    chain: () => ({ command() { return this; }, run: () => true }),
  };
  const view = extension.config.addNodeView()({ node: current, editor, getPos: () => 0 });
  view.makeNode = (nextAttrs) => mockNode(extension, nextAttrs, current.type);
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

const divider = mount(Divider, { bpId: "divider-1", bpType: "divider" });
assert.equal(
  divider.dom.outerHTML,
  '<div class="bp-section-divider" data-bp-conformance-root="" data-bp-type="divider" data-bp-id="divider-1" style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid"><span class="bp-section-divider__mark" style="position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;font-size:1.1rem">§</span></div>',
  "divider mounts the reader DOM directly without CSSOM rewriting its inline contract",
);

const atomViews = [];
for (const [extension, type, block, html] of [
  [Embed, "embed", { id: "embed-1", type: "embed", target: "Field notes" }, '<article class="paper-embed">Field notes</article>'],
  [Sheet, "sheet", { id: "sheet-1", type: "sheet", ref: "budget", snapshot: { rows: [["42"]] } }, '<div class="bp-sheet"><span>42</span></div>'],
]) {
  const view = mount(extension, { bpId: block.id, bpType: type, bpBlock: block });
  const root = view.dom.querySelector(":scope > [data-bp-conformance-root]");
  assert.equal(view.dom.getAttribute("data-bp-fleet-id"), block.id);
  assert.equal(root.tagName, "TEMPLATE", `${type} parity receipt is inert`);
  assert.equal(root.getAttribute("data-bp-fleet-body"), "",
    `${type} parity root is a server-paint hole`);
  assert.equal(root.getAttribute("data-bp-type"), type);
  assert.equal(root.content.childNodes.length, 0,
    `${type} has no client-side reader markup before host paint`);

  const matching = new CustomEvent("bp-fleet-paint", {
    detail: { html, sourceBlock: block }, cancelable: true,
  });
  assert.equal(root.dispatchEvent(matching), false, `${type} consumes its matching server paint`);
  assert.equal(matching.defaultPrevented, true);
  assert.equal(root.content.childElementCount, 1);

  const updatedBlock = type === "embed"
    ? { ...block, target: "Retargeted notes" }
    : { ...block, ref: "forecast", snapshot: { rows: [["84"]] } };
  assert.equal(view.update(view.makeNode({ bpId: block.id, bpType: type, bpBlock: updatedBlock })), true);
  assert.equal(root.content.childNodes.length, 0, `${type} clears old reader bytes after retarget`);

  const stale = new CustomEvent("bp-fleet-paint", {
    detail: { html: "<p>stale</p>", sourceBlock: block }, cancelable: true,
  });
  assert.equal(root.dispatchEvent(stale), false, `${type} cancels generic stale injection`);
  assert.equal(root.content.childNodes.length, 0, `${type} rejects old-source paint`);

  const freshHtml = `<section data-fresh="${type}">${type}</section>`;
  root.dispatchEvent(new CustomEvent("bp-fleet-paint", {
    detail: { html: freshHtml, sourceBlock: updatedBlock }, cancelable: true,
  }));
  assert.equal(root.innerHTML, freshHtml, `${type} accepts the current source paint`);

  // A hook may replay its id-keyed cache after a LiveView/PM remount. The new
  // receipt must reject bytes paired with the old carried source before it
  // accepts the current pair.
  view.destroy?.();
  view.dom.remove();
  const remount = mount(extension, { bpId: block.id, bpType: type, bpBlock: updatedBlock });
  const remountRoot = remount.dom.querySelector(":scope > template[data-bp-conformance-root]");
  remountRoot.dispatchEvent(new CustomEvent("bp-fleet-paint", {
    detail: { html: "<p>cached stale</p>", sourceBlock: block }, cancelable: true,
  }));
  assert.equal(remountRoot.content.childNodes.length, 0,
    `${type} remount rejects cached bytes for the old source`);
  remountRoot.dispatchEvent(new CustomEvent("bp-fleet-paint", {
    detail: { html: freshHtml, sourceBlock: updatedBlock }, cancelable: true,
  }));
  assert.equal(remountRoot.innerHTML, freshHtml,
    `${type} remount accepts cached bytes paired with its current source`);
  atomViews.push(remount);
}

assert.equal(atomViews[0].dom.querySelector("template").innerHTML.includes("data-fresh=\"embed\""), true);
assert.equal(atomViews[1].dom.querySelector("template").innerHTML.includes("data-fresh=\"sheet\""), true,
  "id-scoped paints remain isolated across mixed atom consumers");

for (const view of [footnote, toc, video, divider, ...atomViews]) {
  view.destroy?.();
  view.dom.remove();
}
window.close();
console.log("canvas semantic roots preserve mounted edit islands: ok");

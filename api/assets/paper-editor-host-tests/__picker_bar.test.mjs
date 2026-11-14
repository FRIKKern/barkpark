// __picker_bar.test.mjs — task-04d9b49b5d9b6237: the desk's empty image field
// is TanStack's bar (barkpark-studio ImageInput.tsx): one focusable box, the
// image icon and "Drag or paste image here", then Upload and Select.
//
// Mounts the TRACKED static asset api/priv/static/assets/bp-media-picker.js in
// jsdom with chrome="bar" and no image, and checks:
//   * the box, its words (from data-strings) and its two buttons;
//   * Upload opens the file dialog; Select opens the library, or the file
//     dialog when no library is wired;
//   * an image pasted on the box uploads; a text paste does not; a paste on a
//     filled field does nothing;
//   * the host says it is empty (data-bar-empty) and drops it with an image;
//   * without chrome the picker draws the old empty card, as before.
//
// Run: node ../paper-editor-host-tests/__picker_bar.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.fetch = window.fetch = async () => ({ ok: false, json: async () => ({}) });

await import("../../priv/static/assets/bp-media-picker.js");

let failures = 0;
const check = async (name, fn) => {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
};

const strings = { drag_paste: "Dra eller lim inn bilde her", upload_button: "Last opp", select: "Velg", bar_label: "Slipp, lim inn eller last opp et bilde" };

function mount(attrs = {}) {
  const el = document.createElement("bp-media-picker");
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  document.body.appendChild(el);
  return el;
}

// Count file-dialog opens without opening one.
function dialogClicks(el) {
  const n = { clicks: 0 };
  el.querySelector('input[type="file"]').addEventListener("click", (e) => {
    n.clicks++;
    e.preventDefault();
  });
  return n;
}

await check("chrome=bar, empty: one focusable box, the hint, Upload and Select, in the given words", () => {
  const el = mount({ chrome: "bar", "data-strings": JSON.stringify(strings) });
  const bar = el.querySelector(".bp-mp-preview > .bp-mp-bar");
  assert.ok(bar, "the bar is drawn");
  assert.equal(bar.tabIndex, 0, "the box takes focus, so a paste can land");
  assert.equal(bar.getAttribute("aria-label"), strings.bar_label);
  assert.equal(bar.querySelector(".bp-mp-bar-hint").textContent.trim(), strings.drag_paste);
  assert.ok(bar.querySelector(".bp-mp-bar-hint svg"), "the hint carries the image icon");
  const buttons = [...bar.querySelectorAll(".bp-mp-bar-actions > button")].map((b) => b.textContent.trim());
  assert.deepEqual(buttons, [strings.upload_button, strings.select]);
  assert.equal(bar.querySelectorAll(".bp-mp-bar-actions svg").length, 2, "each button has its icon");
  assert.ok(!el.querySelector(".bp-mp-empty"), "no old empty card");
  assert.ok(el.hasAttribute("data-bar-empty"), "the host says it is empty");
  el.remove();
});

await check("the English words stand when the server sends none", () => {
  const el = mount({ chrome: "bar" });
  assert.equal(el.querySelector(".bp-mp-bar-hint").textContent.trim(), "Drag or paste image here");
  assert.deepEqual([...el.querySelectorAll(".bp-mp-bar-actions > button")].map((b) => b.textContent.trim()), ["Upload", "Select"]);
  el.remove();
});

await check("Upload opens the file dialog", () => {
  const el = mount({ chrome: "bar" });
  const n = dialogClicks(el);
  el.querySelector(".bp-mp-bar-upload").click();
  assert.equal(n.clicks, 1);
  el.remove();
});

await check("Select opens the library; with none wired, the file dialog", () => {
  const el = mount({ chrome: "bar" });
  const n = dialogClicks(el);
  el.querySelector(".bp-mp-bar-select").click();
  assert.equal(n.clicks, 1, "no library: the file dialog");

  let opened = 0;
  window.BpAssetBrowser = { ensure: () => ({ open: () => opened++ }) };
  el.querySelector(".bp-mp-bar-select").click();
  assert.equal(opened, 1, "the library opens");
  assert.equal(n.clicks, 1, "and not the file dialog");
  delete window.BpAssetBrowser;
  el.remove();
});

await check("an image pasted on the box uploads it; a text paste does not", () => {
  const el = mount({ chrome: "bar" });
  const taken = [];
  el._takeFile = (f) => taken.push(f.name);
  const paste = (data) => {
    const ev = new window.Event("paste", { bubbles: true, cancelable: true });
    ev.clipboardData = data;
    el.querySelector(".bp-mp-bar").dispatchEvent(ev);
    return ev;
  };
  const text = paste({ files: [], items: [{ kind: "string", type: "text/plain" }] });
  assert.equal(taken.length, 0);
  assert.ok(!text.defaultPrevented, "a text paste passes through");
  const shot = { name: "shot.png", type: "image/png" };
  const ev = paste({ files: [], items: [{ kind: "file", type: "image/png", getAsFile: () => shot }] });
  assert.deepEqual(taken, ["shot.png"]);
  assert.ok(ev.defaultPrevented);
  paste({ files: [{ name: "file.jpg", type: "image/jpeg" }], items: [] });
  assert.deepEqual(taken, ["shot.png", "file.jpg"]);
  el.remove();
});

await check("a paste on a FILLED bar field sends no upload and keeps the image", () => {
  const el = mount({ chrome: "bar", value: JSON.stringify({ url: "/media/cover.png", assetId: "a1" }) });
  const taken = [];
  el._takeFile = (f) => taken.push(f.name);
  const btn = el.querySelector(".bp-mp-actions button");
  assert.ok(btn, "the filled field has its action buttons");
  btn.focus();
  const ev = new window.Event("paste", { bubbles: true, cancelable: true });
  ev.clipboardData = { files: [{ name: "shot.png", type: "image/png" }], items: [] };
  btn.dispatchEvent(ev);
  assert.deepEqual(taken, [], "no upload");
  assert.ok(!ev.defaultPrevented, "the paste is not taken");
  assert.equal(el.querySelector(".bp-mp-preview-img").getAttribute("src"), "/media/cover.png", "the image stays");
  el.remove();
});

await check("with an image set, the bar picker draws the image and is not empty", () => {
  const el = mount({ chrome: "bar", value: JSON.stringify({ url: "/media/cover.png", assetId: "a1" }) });
  assert.ok(el.querySelector(".bp-mp-preview-img"));
  assert.ok(!el.querySelector(".bp-mp-bar"));
  assert.ok(!el.hasAttribute("data-bar-empty"));
  el.remove();
});

await check("without chrome the empty picker is the old card, and a paste does nothing", () => {
  const el = mount();
  assert.ok(el.querySelector(".bp-mp-preview > .bp-mp-empty[role=button]"));
  assert.ok(!el.querySelector(".bp-mp-bar"));
  assert.ok(!el.hasAttribute("data-bar-empty"));
  const taken = [];
  el._takeFile = (f) => taken.push(f);
  const ev = new window.Event("paste", { bubbles: true, cancelable: true });
  ev.clipboardData = { files: [{ name: "x.png", type: "image/png" }], items: [] };
  el.querySelector(".bp-mp-empty").dispatchEvent(ev);
  assert.equal(taken.length, 0);
  el.remove();
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\nall pass");

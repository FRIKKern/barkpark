// __picker_bar_filled.test.mjs — task-19de214155da3f2a: in the desk, a set
// image is TanStack's frame (barkpark-studio ImageInput.tsx .image-preview):
// the image named "Preview of uploaded image", and a "…" button whose menu
// holds Upload, Select, Download, Copy URL and Remove.
//
// Mounts the TRACKED static asset api/priv/static/assets/bp-media-picker.js in
// jsdom with chrome="bar" and an image set, and checks the frame, the menu (its
// items, toggle, aria-expanded, focus back on Escape), each item's action, the
// host flag, where a paste lands, the broken-image fallback, and that without chrome nothing moved.
//
// Run: node ../paper-editor-host-tests/__picker_bar_filled.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/w/a/studio/_desk" });
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

const VALUE = JSON.stringify({ url: "/media/cover.png", assetId: "a1", alt: "A sun over a field" });
const nb = { preview_alt: "Forhåndsvisning av opplastet bilde", options_menu: "Åpne bildeinnstillingsmeny", upload_button: "Last opp", select: "Velg", download: "Last ned", copy_url: "Kopier URL", remove_short: "Fjern", replace_label: "Slipp eller lim inn et bilde for å erstatte det" };

function mount(attrs = {}) {
  const el = document.createElement("bp-media-picker");
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  document.body.appendChild(el);
  return el;
}
const menu = () => document.querySelector(".bp-mp-menu[role=menu]");
const items = () => [...document.querySelectorAll(".bp-mp-menu .bp-mp-menu-item")].map((b) => b.textContent.trim());
const press = (key) => document.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));

await check("set: the frame, the image named as TanStack's, the … button; the old row flagged away", () => {
  const el = mount({ chrome: "bar", value: VALUE });
  const frame = el.querySelector(".bp-mp-preview > .bp-mp-frame");
  assert.ok(frame, "the frame is drawn");
  assert.equal(frame.tabIndex, 0, "the frame takes focus, so a paste can replace the image");
  assert.equal(frame.getAttribute("aria-label"), "Drop or paste an image to replace it");
  assert.equal(frame.querySelector("img.bp-mp-preview-img").getAttribute("alt"), "Preview of uploaded image");
  const opts = frame.querySelector(".bp-mp-frame-actions > button.bp-mp-options");
  assert.ok(opts, "the … button");
  assert.equal(opts.getAttribute("aria-label"), "Open image options menu");
  assert.equal(opts.getAttribute("aria-haspopup"), "menu");
  assert.equal(opts.getAttribute("aria-expanded"), "false");
  assert.ok(opts.querySelector("svg"), "the ellipsis icon");
  assert.ok(el.hasAttribute("data-bar-filled") && !el.hasAttribute("data-bar-empty"));
  el.remove();
});

await check("the … opens TanStack's menu in the given words; a second press closes it", () => {
  const el = mount({ chrome: "bar", value: VALUE, "data-strings": JSON.stringify(nb) });
  const opts = el.querySelector(".bp-mp-options");
  assert.equal(el.querySelector("img").getAttribute("alt"), nb.preview_alt);
  opts.click();
  assert.ok(menu(), "the menu opens");
  assert.deepEqual(items(), [nb.upload_button, nb.select, nb.download, nb.copy_url, nb.remove_short]);
  assert.equal(opts.getAttribute("aria-expanded"), "true");
  assert.equal(document.activeElement, document.querySelector(".bp-mp-menu-item"), "focus on the first item");
  opts.click();
  assert.equal(menu(), null, "the second press closes it");
  assert.equal(opts.getAttribute("aria-expanded"), "false");
  el.remove();
});

await check("Escape closes the menu and puts focus back on the …", () => {
  const el = mount({ chrome: "bar", value: VALUE });
  const opts = el.querySelector(".bp-mp-options");
  opts.click();
  press("Escape");
  assert.equal(menu(), null);
  assert.equal(document.activeElement, opts);
  el.remove();
});

await check("each item does its job", async () => {
  const el = mount({ chrome: "bar", value: VALUE });
  let dialog = 0;
  el.querySelector('input[type="file"]').addEventListener("click", (e) => (dialog++, e.preventDefault()));
  const choose = (label) => {
    el.querySelector(".bp-mp-options").click();
    [...document.querySelectorAll(".bp-mp-menu-item")].find((b) => b.textContent.trim() === label).click();
  };
  choose("Upload");
  assert.equal(dialog, 1, "Upload: the file dialog");
  choose("Select");
  assert.equal(dialog, 2, "Select with no library: the file dialog");
  let opened = 0;
  window.BpAssetBrowser = { ensure: () => ({ open: () => opened++ }) };
  choose("Select");
  assert.equal(opened, 1, "Select: the library");
  delete window.BpAssetBrowser;

  const clicked = [];
  const orig = window.HTMLAnchorElement.prototype.click;
  window.HTMLAnchorElement.prototype.click = function () { clicked.push([this.href, this.hasAttribute("download")]); };
  choose("Download");
  window.HTMLAnchorElement.prototype.click = orig;
  assert.deepEqual(clicked, [["http://localhost/media/cover.png", true]], "Download: the image, absolute, as a download");

  const copied = [];
  // The picker reads the global `navigator`. Node 21+ has one (read-only as a
  // binding), so the stub goes on its `clipboard`; Node 20 (CI) has none, so
  // one is made first.
  if (typeof globalThis.navigator === "undefined") Object.defineProperty(globalThis, "navigator", { configurable: true, value: {} });
  Object.defineProperty(globalThis.navigator, "clipboard", { configurable: true, value: { writeText: async (t) => copied.push(t) } });
  choose("Copy URL");
  assert.deepEqual(copied, ["http://localhost/media/cover.png"], "Copy URL: the absolute address");

  choose("Remove");
  assert.ok(el.querySelector(".bp-mp-bar"), "Remove: back to the empty bar");
  assert.ok(el.hasAttribute("data-bar-empty") && !el.hasAttribute("data-bar-filled"));
  assert.equal(document.activeElement, el.querySelector(".bp-mp-bar"), "focus lands on the bar");
  el.remove();
});

await check("a paste replaces the image only on the frame, never on the … button", () => {
  const el = mount({ chrome: "bar", value: VALUE });
  const taken = [];
  el._takeFile = (f) => taken.push(f.name);
  const paste = (target) => {
    const ev = new window.Event("paste", { bubbles: true, cancelable: true });
    ev.clipboardData = { files: [{ name: "shot.png", type: "image/png" }], items: [] };
    target.dispatchEvent(ev);
    return ev;
  };
  const onOpts = paste(el.querySelector(".bp-mp-options"));
  assert.deepEqual(taken, [], "a paste on the … does nothing");
  assert.ok(!onOpts.defaultPrevented);
  const onFrame = paste(el.querySelector(".bp-mp-frame"));
  assert.deepEqual(taken, ["shot.png"], "a paste on the frame replaces the image");
  assert.ok(onFrame.defaultPrevented);
  el.remove();
});

await check("Download of an image on ANOTHER origin never navigates this tab: a blob download, or a new tab when CORS refuses", async () => {
  const XO = "http://127.0.0.1:9/media/cdn%20cover.png";
  const el = mount({ chrome: "bar", value: JSON.stringify({ url: XO, assetId: "a2" }) });
  const clicked = [];
  const orig = window.HTMLAnchorElement.prototype.click;
  window.HTMLAnchorElement.prototype.click = function () {
    clicked.push({ href: this.href, download: this.getAttribute("download"), target: this.target, rel: this.rel });
  };
  const made = [];
  const origCreate = URL.createObjectURL, origRevoke = URL.revokeObjectURL;
  URL.createObjectURL = (b) => (made.push(b), "blob:http://localhost/1");
  URL.revokeObjectURL = () => {};
  const origFetch = globalThis.fetch;
  const download = async () => {
    el.querySelector(".bp-mp-options").click();
    [...document.querySelectorAll(".bp-mp-menu-item")].find((b) => b.textContent.trim() === "Download").click();
    for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0));
  };
  try {
    const fetched = [];
    globalThis.fetch = async (u, o) => (fetched.push([u, o && o.mode]), { ok: true, blob: async () => ({ size: 3 }) });
    await download();
    assert.deepEqual(fetched, [[XO, "cors"]], "the image is fetched, not navigated to");
    assert.deepEqual(clicked, [{ href: "blob:http://localhost/1", download: "cdn cover.png", target: "", rel: "noopener" }], "saved from a blob, under its own name");

    clicked.length = 0;
    globalThis.fetch = async () => { throw new TypeError("Failed to fetch"); };
    await download();
    assert.equal(clicked.length, 1);
    assert.equal(clicked[0].href, XO);
    assert.equal(clicked[0].target, "_blank", "CORS refused: a NEW tab, never this one");
    assert.equal(clicked[0].rel, "noopener");
  } finally {
    window.HTMLAnchorElement.prototype.click = orig;
    URL.createObjectURL = origCreate;
    URL.revokeObjectURL = origRevoke;
    globalThis.fetch = origFetch;
    el.remove();
  }
});

await check("Tab out of the open menu moves on from the …, not from the top of the page", () => {
  const el = mount({ chrome: "bar", value: VALUE });
  const opts = el.querySelector(".bp-mp-options");
  opts.click();
  assert.equal(document.activeElement, document.querySelector(".bp-mp-menu-item"));
  press("Tab");
  assert.equal(menu(), null, "Tab closes the menu");
  assert.equal(document.activeElement, opts, "focus is back on the … for the browser's Tab to move on from");
  el.remove();
});

await check("the image swaps under an open menu (a remote save): focus lands on the new …, not <body>", async () => {
  const OTHER = JSON.stringify({ url: "/media/other.png", assetId: "a3" });
  // The same element gets the new value.
  const el = mount({ chrome: "bar", value: VALUE, id: "cover" });
  el.querySelector(".bp-mp-options").click();
  el.value = OTHER;
  assert.equal(menu(), null, "the menu is closed");
  assert.equal(el.querySelector("img").getAttribute("src"), "/media/other.png");
  assert.equal(document.activeElement, el.querySelector(".bp-mp-options"), "focus on the new …");

  // LiveView re-mounts the field (its phx-update=ignore wrapper's id moves).
  el.querySelector(".bp-mp-options").click();
  const fresh = document.createElement("bp-media-picker");
  fresh.setAttribute("chrome", "bar");
  fresh.setAttribute("id", "cover");
  fresh.setAttribute("value", VALUE);
  el.replaceWith(fresh);
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(menu(), null);
  assert.equal(document.activeElement, fresh.querySelector(".bp-mp-options"), "focus on the re-mounted picker's …");
  fresh.remove();
});

await check("a broken image drops the flag, so the row with Remove comes back", () => {
  const el = mount({ chrome: "bar", value: VALUE });
  el.querySelector("img").dispatchEvent(new window.Event("error"));
  assert.ok(el.querySelector(".bp-mp-broken"));
  assert.ok(!el.hasAttribute("data-bar-filled"));
  el.remove();
});

await check("without chrome a set image is as before: its own alt, no frame, the old menu words", () => {
  const el = mount({ value: VALUE });
  assert.ok(!el.querySelector(".bp-mp-frame, .bp-mp-options"));
  assert.equal(el.querySelector("img.bp-mp-preview-img").getAttribute("alt"), "A sun over a field");
  assert.ok(!el.hasAttribute("data-bar-filled"));
  el._openContextMenu(10, 10);
  assert.deepEqual(items(), ["Upload file", "Browse library", "Remove image"]);
  el._closeContextMenu();
  el.remove();
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\nall pass");

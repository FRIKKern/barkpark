// __desk_image_field.test.mjs: the desk's image field in the browser
// (bp-media-picker.js chrome="bar", bp-desk-image.js), as the TanStack
// Studio's ImageInput (J12).
//
// THE STORED SHAPE. Sanity's hotspot {x, y, width, height} and crop {top,
// bottom, left, right} sit on the image object, in the reference shape and
// in the legacy one; keys the picker does not edit stay; a new image drops
// both. The image's own fields (alt) are written by `setPart`.
//
// THE FIELD. A set image shows "Open image edit dialog" beside its "…" when
// the schema asks for `hotspot`. A move in the page that connects the picker
// again keeps the image picked since (it used to go back to the empty value
// it was drawn with).
//
// THE DIALOG. "Edit hotspot and crop": the hotspot and the crop are sliders;
// arrows move them by 0.5% of the image, Shift+arrows by 2.5%, and every key
// press is written. Escape or a press on the backdrop closes it and the focus
// goes back to its button.
// An input marked `data-desk-image-part` writes its picker's field.
//
// Runs the TRACKED static assets under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_image_field.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/w/acme/p/web/d/production/studio/_desk/post;post-05",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node", "Image"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.fetch = async () => ({ ok: false, json: async () => ({}) });

await import("../../priv/static/assets/bp-media-picker.js");
await import("../../priv/static/assets/bp-desk-image.js");
const hook = window.__bpMediaPickerTestHook;
const desk = window.BarkparkDeskImage;
assert.ok(hook && desk, "both scripts define their globals");

// ── The stored shape ────────────────────────────────────────────────────────
const REF = "image-a88ad4d7210c7ff5716cd5e9fc4ec61f2f3bb1e3-640x400-png";
const stored = {
  _type: "image",
  asset: { _type: "reference", _ref: REF },
  alt: "A sun",
  caption: "kept",
  hotspot: { _type: "sanity.imageHotspot", x: 0.5, y: 0.5, width: 1, height: 1 },
  crop: { _type: "sanity.imageCrop", top: 0, bottom: 0, left: 0, right: 0 },
};
const parsed = hook.parseValue(JSON.stringify(stored));
assert.equal(parsed.hotspot, undefined, "the reference shape's hotspot stays on the stored object (a focal click moves its centre)");
assert.deepEqual(parsed.crop, stored.crop, "its crop is read");
assert.equal(hook.parseValue(JSON.stringify({ assetId: "a" })).crop, undefined, "a value without them reads as it always did");

const hotspot = { x: 0.4, y: 0.45, width: 0.3, height: 0.35 };
const crop = { top: 0.1, bottom: 0, left: 0.02, right: 0.18 };
const out = JSON.parse(hook.serializeAssetRefValue({ assetRef: REF, source: stored, alt: "A sun", focalX: 0.4, focalY: 0.45, hotspot, crop }));
assert.deepEqual(out.hotspot, { _type: "sanity.imageHotspot", ...hotspot }, "the hotspot is written as Sanity stores it, its _type kept");
assert.deepEqual(out.crop, { _type: "sanity.imageCrop", ...crop }, "and the crop");
assert.equal(out.caption, "kept", "a key the picker does not edit stays");
assert.equal(out.alt, "A sun");

const swapped = JSON.parse(hook.serializeAssetRefValue({ assetRef: "asset-new", source: stored, alt: "A sun", hotspot, crop }));
assert.equal(swapped.hotspot, undefined, "a new image drops the old hotspot");
assert.equal(swapped.crop, undefined, "and the old crop");
assert.equal(swapped.alt, "A sun", "its alt text stays");

const legacy = JSON.parse(hook.serializeValue("/media/a.png", "a", { alt: "x", hotspot, crop }));
assert.deepEqual([legacy.url, legacy.assetId, legacy.alt], ["/media/a.png", "a", "x"], "the legacy shape stays legacy");
assert.deepEqual([legacy.hotspot, legacy.crop], [hotspot, crop], "with the hotspot and crop on it");
assert.equal(hook.serializeValue("/media/a.png", "", {}), "/media/a.png", "a bare URL still round-trips as a bare URL");
assert.equal(hook.parseValue(JSON.stringify({ assetId: "a", hotspot: { x: "no" } })).hotspot, undefined, "a malformed hotspot reads as unset");

// ── The field ───────────────────────────────────────────────────────────────
const fieldset = document.createElement("fieldset");
fieldset.className = "field";
fieldset.innerHTML = "<legend>Main image</legend>";
document.body.appendChild(fieldset);
const picker = document.createElement("bp-media-picker");
picker.id = "mainImage";
picker.setAttribute("chrome", "bar");
picker.setAttribute("hotspot", "");
picker.setAttribute("value-shape", "asset-ref");
picker.setAttribute("value", JSON.stringify({ _type: "image", asset: { _type: "reference", _ref: REF } }));
fieldset.appendChild(picker);
const changes = [];
picker.addEventListener("bp-change", (e) => changes.push(JSON.parse(e.detail.value)));
const last = () => changes[changes.length - 1];

const img = picker.querySelector("img.bp-mp-preview-img");
assert.equal(img && img.getAttribute("alt"), "Preview of uploaded image", "the set image is named as TanStack's");
assert.match(img.getAttribute("src"), /^\/images\/barkpark\/production\/a88ad4d7210c7ff5716cd5e9fc4ec61f2f3bb1e3-640x400\.png\?w=800/, "its preview is the dataset's own image route");
const opener = picker.querySelector('button[aria-label="Open image edit dialog"]');
assert.ok(opener, "a set image with `hotspot` offers the dialog");
assert.equal(opener.getAttribute("title"), "Edit hotspot and crop");

picker.setPart("alt", "A sun over a field");
assert.equal(last().alt, "A sun over a field", "the image's alt is written on the image object");
picker.setPart("caption", "Morning");
assert.equal(last().caption, "Morning", "and any other field of the image");

const part = document.createElement("input");
part.setAttribute("data-desk-image-part", "alt");
part.setAttribute("data-desk-image-for", "mainImage");
document.body.appendChild(part);
part.value = "Typed";
part.dispatchEvent(new window.Event("input", { bubbles: true }));
assert.equal(last().alt, "Typed", "an input marked as the image's field writes it through its picker");

// A patch moves the field: it is connected again and keeps what was written.
fieldset.removeChild(picker);
fieldset.appendChild(picker);
assert.equal(JSON.parse(picker.value).alt, "Typed", "a reconnect keeps the value written since");
assert.ok(picker.querySelector("img.bp-mp-preview-img"), "and still shows the image");

// ── The dialog ──────────────────────────────────────────────────────────────
const btn = picker.querySelector(".bp-mp-crop");
btn.focus();
btn.click();
const dialog = document.querySelector('[role="dialog"]');
assert.ok(dialog, "the button opens the dialog");
assert.equal(document.getElementById(dialog.getAttribute("aria-labelledby")).textContent, "Edit hotspot and crop", "named by its title");
const spot = dialog.querySelector('[data-handle="hotspot"][tabindex="0"]');
const rect = dialog.querySelector('[data-handle="crop"][tabindex="0"]');
assert.ok(spot && rect, "the hotspot and the crop are focusable");
assert.ok(spot.compareDocumentPosition(rect) & window.Node.DOCUMENT_POSITION_FOLLOWING, "the hotspot comes before the crop in Tab order");
assert.ok(dialog.querySelector('[data-handle="hotspotHandle"]') && dialog.querySelector('[data-handle="crop-right"]'), "with the hotspot's handle and the crop's sides");

const key = (el, k, shift = false) => el.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, shiftKey: shift, bubbles: true }));
// The default hotspot covers the whole image: shrink it first, as the mouse does.
const small = { x: 0.43, y: 0.56, width: 0.36, height: 0.37 };
picker.setHotspotCrop(small, { top: 0, bottom: 0, left: 0, right: 0.18 });
desk.close();
btn.click();
const spot2 = document.querySelector('[data-handle="hotspot"]');
for (let i = 0; i < 5; i++) key(spot2, "ArrowLeft");
for (let i = 0; i < 3; i++) key(spot2, "ArrowUp", true);
const rect2 = document.querySelector('[data-handle="crop"]');
for (let i = 0; i < 4; i++) key(rect2, "ArrowRight");
const keyed = last();
assert.ok(Math.abs(keyed.hotspot.x - (small.x - 0.025)) < 1e-6, `left ×5 moves 2.5% (${keyed.hotspot.x})`);
assert.ok(Math.abs(keyed.hotspot.y - (small.y - 0.075)) < 1e-6, `Shift+up ×3 moves 7.5% (${keyed.hotspot.y})`);
assert.ok(Math.abs(keyed.crop.left - 0.02) < 1e-6 && Math.abs(keyed.crop.right - 0.16) < 1e-6, "right ×4 moves the crop 2%");
assert.equal(keyed.hotspot.width, small.width, "the keys move, never resize");

document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
assert.equal(document.querySelector('[role="dialog"]'), null, "Escape closes it");
assert.equal(document.activeElement, picker.querySelector(".bp-mp-crop"), "and the focus is back on its button, not <body>");

// A press on the backdrop closes it too, and the focus is back on its button:
// the press's default action (focus to <body>) is prevented.
btn.click();
const layer = document.querySelector(".dk-crop-layer");
const press = new window.MouseEvent("mousedown", { bubbles: true, cancelable: true });
layer.dispatchEvent(press);
assert.equal(document.querySelector('[role="dialog"]'), null, "a press on the backdrop closes it");
assert.equal(press.defaultPrevented, true, "and its default action, which would focus <body>, is prevented");
assert.equal(document.activeElement, picker.querySelector(".bp-mp-crop"), "the focus is back on its button");

// A press inside the dialog does not close it.
btn.click();
document.querySelector(".dk-crop-dialog").dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
assert.ok(document.querySelector('[role="dialog"]'), "a press inside the dialog keeps it open");
desk.close();

// The geometry keeps the hotspot inside the crop.
const g = desk.geometry;
assert.deepEqual(g.fitHotspot({ x: 0.9, y: 0.5, width: 0.4, height: 0.4 }, { top: 0, bottom: 0, left: 0, right: 0.5 }), { x: 0.3, y: 0.5, width: 0.4, height: 0.4 });
assert.deepEqual(g.moveCrop({ top: 0, bottom: 0, left: 0, right: 0.01 }, 0.05, 0), { top: 0, bottom: 0, left: 0.01, right: 0 }, "the crop stays on the image");

console.log("desk image field: ok");

// __desk_slice_keep_header_focus.test.mjs — a focused header button survives
// the patch that re-draws its pane.
//
// When the URL makes a pane the last one, the page first draws it as the read
// view and, one round trip later, as the editor (desk_live.ex: the editor's
// section has an id of its own). A button in the read view's header row (focus
// mode, close) goes with it and the focus falls to <body>. The button of the
// same name (`aria-label`) in the same pane's header takes the focus back; with
// none of that name, the focus is left alone. A reference link does the same by
// its href (__desk_slice_keep_link.test.mjs).
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_keep_header_focus.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: `http://localhost${BASE}/post;post-a`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const focusBtn = `<button type="button" class="dk-focus icon-btn" aria-label="Focus mode">F</button>`;
const close = `<a href="${BASE}/post" class="dk-close icon-btn" aria-label="Close Post A">×</a>`;
const split = `<a href="${BASE}/post;post-a|post-a" class="dk-split icon-btn" aria-label="Split pane right">S</a>`;
const pane = (id, index, kind, header) =>
  `<section class="pane-column dk-pane" id="${id}" data-pane-index="${index}" data-pane-kind="${kind}"><div class="pane-header"><h2 class="pane-header-title">T</h2>${header}</div><div class="pane-body"></div></section>`;

function mount(readHeader = focusBtn + close) {
  window.document.body.innerHTML =
    `<div id="desk-panes">` +
    pane("p0", 0, "types", "") +
    pane("p1", 1, "list", focusBtn) +
    pane("desk-pane-2-doc:post-a", 2, "doc", readHeader) +
    `</div><button id="outside">Outside</button>`;
  const el = window.document.getElementById("desk-panes");
  const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent: () => {} });
  hook.mounted();
  return { el, hook };
}

// The patch: the read view's section goes, the editor's comes in its place.
const swap = (el, header) => {
  const old = el.querySelector('[data-pane-index="2"]');
  old.insertAdjacentHTML("afterend", pane("desk-pane-2-doc:post-a-editor", 2, "doc", header));
  old.remove();
};
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const active = () => window.document.activeElement;
const editor = (el, sel) => el.querySelector(`#desk-pane-2-doc\\:post-a-editor ${sel}`);

// ── The close link in the read view's header keeps the focus ────────────────
{
  const { el, hook } = mount();
  el.querySelector('[data-pane-index="2"] .dk-close').focus();
  swap(el, split + focusBtn + close);
  await settle();
  assert.equal(active(), editor(el, ".dk-close"), "the editor's close link has the focus");
  hook.destroyed();
}

// ── The focus mode button keeps the focus ───────────────────────────────────
{
  const { el, hook } = mount();
  el.querySelector('[data-pane-index="2"] .dk-focus').focus();
  swap(el, split + focusBtn + close);
  await settle();
  assert.equal(active(), editor(el, ".dk-focus"), "the editor's focus mode button has the focus");
  hook.destroyed();
}

// ── No button of that name in the new header: the focus is left alone ───────
{
  const { el, hook } = mount();
  el.querySelector('[data-pane-index="2"] .dk-focus').focus();
  swap(el, split + close);
  await settle();
  assert.equal(active(), window.document.body, "no other button, and no field, is given the focus");
  hook.destroyed();
}

// ── Another pane's button of the same name does not take it ─────────────────
{
  const { el, hook } = mount();
  el.querySelector('[data-pane-index="2"] .dk-focus').focus();
  el.querySelector('[data-pane-index="2"]').remove();
  await settle();
  // Any later patch: pane 1's "Focus mode" stays unfocused.
  el.querySelector("#p0 .pane-body").innerHTML = "<span>x</span>";
  await settle();
  assert.equal(active(), window.document.body, "only the same pane's header");
  hook.destroyed();
}

// ── The focus had moved on: a later patch does not pull it back ─────────────
{
  const { el, hook } = mount();
  el.querySelector('[data-pane-index="2"] .dk-close').focus();
  window.document.getElementById("outside").focus();
  swap(el, split + focusBtn + close);
  await settle();
  assert.equal(active().id, "outside", "the focus stays where the editor put it");
  hook.destroyed();
}

// ── A reference link still goes by its href ─────────────────────────────────
{
  const ref = `<a href="${BASE}/post;post-a;author-x" class="dk-ref" data-desk-ref aria-label="Alan">Alan</a>`;
  const { el, hook } = mount(focusBtn + close);
  el.querySelector('[data-pane-index="2"] .pane-body').innerHTML = ref;
  el.querySelector("a[data-desk-ref]").focus();
  const old = el.querySelector('[data-pane-index="2"]');
  old.insertAdjacentHTML("afterend", pane("desk-pane-2-doc:post-a-editor", 2, "doc", focusBtn + close));
  old.remove();
  editor(el, ".pane-body").innerHTML = ref;
  await settle();
  assert.equal(active(), editor(el, "a[data-desk-ref]"), "the link keeps the focus by its href");
  hook.destroyed();
}

console.log("desk slice keep header focus: ok");

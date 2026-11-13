// __desk_slice_keep_link.test.mjs — a focused link survives the patch that
// re-draws its pane (rig panes spec, J21 F5).
//
// When the URL makes a pane the last one, the page first draws it as the read
// view and, one round trip later, as the editor (desk_live.ex: the editor's
// section has an id of its own). A reference link focused in the read view
// goes with it, the focus falls to <body>, and the Enter pressed next opens
// nothing. The same link in the same pane takes the focus back.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_keep_link.test.mjs
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

const AUTHOR = `${BASE}/post;post-a;author-x,type=author,parentRefPath=author`;
const ref = (href) => `<a href="${href}" class="dk-ref" data-desk-ref>Alan</a>`;
const pane = (id, index, kind, body) =>
  `<section class="pane-column dk-pane" id="${id}" data-pane-index="${index}" data-pane-kind="${kind}"><div class="pane-header"></div><div class="pane-body">${body}</div></section>`;

function mount() {
  window.document.body.innerHTML =
    `<div id="desk-panes">` +
    pane("p0", 0, "types", "") +
    pane("p1", 1, "list", "") +
    pane("desk-pane-2-doc:post-a", 2, "doc", ref(AUTHOR)) +
    `</div><button id="outside">Outside</button>`;
  const el = window.document.getElementById("desk-panes");
  const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent: () => {} });
  hook.mounted();
  return { el, hook };
}

// The patch: the read view's section goes, the editor's comes in its place.
const swap = (el, body) => {
  const old = el.querySelector('[data-pane-index="2"]');
  old.insertAdjacentHTML("afterend", pane("desk-pane-2-doc:post-a-editor", 2, "doc", body));
  old.remove();
};
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const active = () => window.document.activeElement;

// ── The read view turns into the editor: the same link keeps the focus ──────
{
  const { el, hook } = mount();
  el.querySelector("a[data-desk-ref]").focus();
  swap(el, ref(AUTHOR));
  await settle();

  const again = el.querySelector("#desk-pane-2-doc\\:post-a-editor a[data-desk-ref]");
  assert.equal(active(), again, "the same link in the re-drawn pane has the focus");
  hook.destroyed();
}

// ── The link is not there after the patch: the focus is not put anywhere ────
{
  const { el, hook } = mount();
  el.querySelector("a[data-desk-ref]").focus();
  swap(el, ref(`${BASE}/post;post-a;author-y,type=author,parentRefPath=author`));
  await settle();
  assert.equal(active(), window.document.body, "another link is not given the focus");
  hook.destroyed();
}

// ── The focus had moved on: a later patch does not pull it back ─────────────
{
  const { el, hook } = mount();
  el.querySelector("a[data-desk-ref]").focus();
  window.document.getElementById("outside").focus();
  swap(el, ref(AUTHOR));
  await settle();
  assert.equal(active().id, "outside", "the focus stays where the editor put it");
  hook.destroyed();
}

// ── Another pane's link with the same href does not take it ─────────────────
{
  const { el, hook } = mount();
  el.querySelector("a[data-desk-ref]").focus();
  const old = el.querySelector('[data-pane-index="2"]');
  old.remove();
  el.querySelector("#p1 .pane-body").innerHTML = ref(AUTHOR);
  await settle();
  assert.equal(active(), window.document.body, "only the same pane's link");
  hook.destroyed();
}

console.log("desk slice keep link: ok");

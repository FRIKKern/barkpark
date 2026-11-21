// __desk_revision_focus.test.mjs — task-74c8db8d9303dc84: opening a revision
// while a field has the focus leaves the focus on a named control in the
// pane, never on the page.
//
// Browser Forward onto a revision with Excerpt focused left the focus on
// BODY, at 1440 and 390 (review of #27908, real Chrome). The revision's form
// keeps the live form's ids, so morphdom moves the focused Excerpt into the
// read-only fields' disabled fieldset; a disabled field cannot hold the
// focus, and LiveView's restore after the patch cannot focus it again.
//
// This test patches a desk pane with the morphdom LiveView ships, then does
// what LiveView's DOMPatch does after it: focus the input that had the focus
// again (`restoreFocus`) and send `phx:update` on the document. The field
// code is the REAL priv/static/assets/bp-desk-revision-focus.js, with the
// REAL bp-tab-keys.js the page loads (`formStart`). jsdom draws
// no layout, so what is seen is stubbed: an element is seen unless it or an
// ancestor is `hidden` or `visibility: hidden`.
//
// Run: node ../paper-editor-host-tests/__desk_revision_focus.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "./jsdom.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const API = path.join(__dirname, "../..");
const ASSETS = path.join(API, "priv/static/assets");
const read = (...p) => fs.readFileSync(path.join(...p), "utf8");
const LIVE_VIEW_SRC = read(ASSETS, "phoenix_live_view.js");
const PHOENIX_SRC = read(ASSETS, "phoenix.js");
const SCRIPT = "bp-desk-revision-focus.js";

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// One document pane, as EditorHost draws it: the title bar's Editor tab, the
// shell's header controls (kept in the form, hidden), the group tabs, the
// form holder, the History panel and the footer.
// `doc` names another document: its pane and field ids are its own, as the
// desk's (`desk-pane-<index>-<key>`), so a patch to it removes the fields.
// `published` draws the published view: read-only, with Unpublish.
function pane({ revision, published, history = true, tabs = true, footer = true, doc = "" }) {
  revision = revision || published;
  const fields =
    `<form id="editor-form" phx-change="validate">` +
    `<textarea id="excerpt${doc && "-" + doc}" name="doc[excerpt]">${revision ? "Old" : "Draft"}</textarea></form>`;
  const box = revision
    ? `<div id="p-form-box-revision" data-desk-form-box><fieldset class="dk-readonly-fields" disabled data-desk-readonly-fields>${fields}</fieldset></div>`
    : `<div id="p-form-box" data-desk-form-box><fieldset class="dk-readonly-fields">${fields}</fieldset></div>`;
  const row = (id, current) =>
    `<li><button type="button" id="row-${id}" data-desk-revision="${id}"${current ? ' aria-current="true"' : ""}>Edited</button></li>`;
  return (
    `<section id="p${doc && "-" + doc}" data-pane-kind="doc" data-pane="doc:${doc || "d"}" data-pane-index="1">` +
    `<div id="p-title-bar" class="doc-title-bar dk-title-bar"><div role="tablist"><button type="button" id="editor-tab" role="tab" tabindex="0">Editor</button></div></div>` +
    `<div id="p-body" class="pane-body doc-form">` +
    `<div id="p-shell-header" style="visibility: hidden"><button type="button" id="classic">Classic</button></div>` +
    (tabs
      ? `<div class="bp-tab-bar" role="tablist"><button type="button" id="bp-group-tab-all-fields" role="tab" tabindex="0">All fields</button>` +
        `<button type="button" id="bp-group-tab-seo" role="tab" tabindex="-1">SEO</button></div>`
      : "") +
    `<fieldset id="p-form-holder" class="dk-revision-form">${box}</fieldset>` +
    (history ? `<aside id="p-history"><ol>${row("r2", !revision)}${row("r1", revision)}</ol></aside>` : "") +
    `</div>` +
    (footer
      ? published
        ? `<footer id="p-published-footer" class="dk-edit-footer published-footer"><button type="button" id="unpublish">Unpublish</button></footer>`
        : revision
        ? `<footer id="p-revision-footer" class="dk-edit-footer revision-footer"><button type="button" id="revert">Revert to revision</button></footer>`
        : `<footer id="p-footer" class="dk-edit-footer doc-footer"><button type="button" id="publish">Publish</button></footer>`
      : "") +
    `</section>`
  );
}

function page(opts = {}, { script = true } = {}) {
  const dom = new JSDOM(`<!doctype html><html><body><div id="desk-panes" class="dk">${pane({ ...opts, revision: false })}</div></body></html>`, {
    runScripts: "outside-only",
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const { document } = window;
  window.eval(PHOENIX_SRC);
  const instrumented = LIVE_VIEW_SRC.replace(",ot=dn;", ",ot=dn;window.__bpShippedMorphdom=ot;");
  assert.notEqual(instrumented, LIVE_VIEW_SRC, "the shipped LiveView bundle exposes its vendored morphdom in this test");
  window.eval(instrumented);
  const morphdom = window.__bpShippedMorphdom;
  assert.equal(typeof morphdom, "function");
  window.Element.prototype.checkVisibility = function () {
    for (let el = this; el && el.nodeType === 1; el = el.parentElement) {
      if (el.hidden || el.style.visibility === "hidden") return false;
    }
    return true;
  };
  // Where opening a document puts the focus (formStart), as root.html.heex loads it.
  window.eval(read(ASSETS, "bp-tab-keys.js"));
  if (script) window.eval(read(ASSETS, SCRIPT));

  const excerpt = () => document.getElementById("excerpt");
  // LiveView's patch: morph the pane, focus the input that had the focus
  // again (a disabled one cannot take it), then `phx:update`.
  const patch = (next) => {
    const focused = document.activeElement;
    const to = document.createElement("div");
    to.innerHTML = pane({ ...opts, ...next });
    morphdom(document.querySelector('[data-pane-kind="doc"]'), to.firstChild, { getNodeKey: (node) => node.id });
    if (focused && focused !== document.body && focused.isConnected && document.activeElement !== focused) focused.focus();
    document.dispatchEvent(new window.CustomEvent("phx:update", { bubbles: true, cancelable: true }));
  };
  const tick = () => new Promise((r) => window.setTimeout(r, 30));
  const active = () => (document.activeElement === document.body ? "BODY" : document.activeElement.id);
  return { window, document, excerpt, patch, tick, active };
}

await check("the instrument: with no rescue, Excerpt moved into the disabled fieldset leaves the focus on BODY", async () => {
  const { excerpt, patch, active } = page({}, { script: false });
  excerpt().focus();
  assert.equal(active(), "excerpt");
  patch({ revision: true });
  assert.equal(excerpt().matches(":disabled"), true, "Excerpt is the revision's, disabled");
  assert.equal(active(), "BODY", "the defect");
});

await check("Excerpt focused, a revision opens: the focus goes to the History panel's current entry", async () => {
  const { excerpt, patch, active } = page();
  excerpt().focus();
  patch({ revision: true });
  assert.equal(excerpt().matches(":disabled"), true);
  assert.equal(active(), "row-r1", "the entry for the revision shown, as a click on it leaves the focus");
});

await check("the History panel closed: where opening a document puts it, All fields", async () => {
  const { excerpt, patch, active } = page({ history: false });
  excerpt().focus();
  patch({ revision: true });
  assert.equal(active(), "bp-group-tab-all-fields", "not Classic, which the shell keeps hidden");
});

await check("no field groups either: the footer's Revert to revision", async () => {
  const { excerpt, patch, active } = page({ history: false, tabs: false });
  excerpt().focus();
  patch({ revision: true });
  assert.equal(active(), "revert");
});

await check("no footer: the pane's Editor tab", async () => {
  const { excerpt, patch, active } = page({ history: false, tabs: false, footer: false });
  excerpt().focus();
  patch({ revision: true });
  assert.equal(active(), "editor-tab");
});

await check("the patch's own move blurs Excerpt while it is enabled: still rescued", async () => {
  const { window, document, excerpt, patch, active } = page();
  excerpt().focus();
  // morphdom moving the field fires a blur before the field is disabled
  // (real Chrome on Forward); LiveView's leave flush sends one too.
  excerpt().dispatchEvent(new window.FocusEvent("focusout", { bubbles: true }));
  patch({ revision: true });
  assert.equal(active(), "row-r1");
  assert.notEqual(document.activeElement, document.body);
});

await check("focus moved away by the person (nothing focused): it stays where the person left it", async () => {
  const { excerpt, patch, tick, active } = page();
  excerpt().focus();
  excerpt().blur();
  await tick();
  patch({ revision: true });
  await tick();
  assert.equal(active(), "BODY", "nothing takes back a focus the person moved away");
});

await check("the draft redrawn while typing: Excerpt keeps the focus", async () => {
  const { excerpt, patch, tick, active } = page();
  excerpt().focus();
  patch({ revision: false });
  await tick();
  assert.equal(active(), "excerpt");
});

await check("the fieldset disabled in place, the field still holding the focus: handed on too", () => {
  const { window, excerpt, active } = page();
  excerpt().focus();
  // jsdom keeps the focus on the disabled field, as Chrome does until it
  // next renders.
  window.document.querySelector("fieldset.dk-readonly-fields").disabled = true;
  assert.equal(active(), "excerpt");
  window.document.dispatchEvent(new window.CustomEvent("phx:update", { bubbles: true }));
  assert.equal(active(), "row-r2", "the pane's current entry, the focus off the disabled field");
});

// task-8fe9bc3aa4437be6: Back from a revision or the published view, and
// Back onto another document's revision, remove the focused control.
await check("the instrument: with no rescue, Back from a revision with Revert focused leaves the focus on BODY", async () => {
  const { document, patch, active } = page({ history: false, tabs: false }, { script: false });
  patch({ revision: true });
  document.getElementById("revert").focus();
  patch({ revision: false });
  assert.equal(document.getElementById("revert"), null, "Back to the live document removes Revert");
  assert.equal(active(), "BODY", "the defect");
});

await check("History closed, a revision opens on Revert, Back: the live form's start, as focusIntoForm", async () => {
  const { excerpt, patch, active } = page({ history: false, tabs: false });
  excerpt().focus();
  patch({ revision: true });
  assert.equal(active(), "revert", "#28058's hand-off");
  patch({ revision: false });
  assert.equal(active(), "excerpt", "the form's first control, not BODY");
});

await check("with field groups, Back from a revision on Revert: All fields", async () => {
  const { document, patch, active } = page({ history: false });
  patch({ revision: true });
  document.getElementById("revert").focus();
  patch({ revision: false });
  assert.equal(active(), "bp-group-tab-all-fields");
});

await check("Back from the published view on Unpublish: the live form's start", async () => {
  const { document, patch, active } = page({ history: false, tabs: false });
  patch({ published: true });
  document.getElementById("unpublish").focus();
  patch({ revision: false });
  assert.equal(active(), "excerpt");
});

await check("Back onto another document's revision, its field focused: that pane takes the focus, never BODY", async () => {
  const { document, patch, active } = page({ history: false, tabs: false });
  patch({ revision: false, doc: "rv2" });
  document.getElementById("excerpt-rv2").focus();
  patch({ revision: true, doc: "rv1" });
  assert.equal(document.getElementById("excerpt-rv2"), null, "the other document's field is removed, not moved");
  assert.equal(active(), "revert", "its form is read-only: the footer's first control");
});

await check("the same, with field groups: All fields", async () => {
  const { document, patch, active } = page({ history: false });
  patch({ revision: false, doc: "rv2" });
  document.getElementById("excerpt-rv2").focus();
  patch({ revision: true, doc: "rv1" });
  assert.equal(active(), "bp-group-tab-all-fields");
});

await check("a removed control whose focus was moved on (a dialog, a row): left where it is", async () => {
  const { document, patch, active } = page({ history: false, tabs: false });
  patch({ revision: true });
  document.getElementById("revert").focus();
  const other = document.createElement("button");
  other.id = "elsewhere";
  document.body.appendChild(other);
  patch({ revision: false });
  other.focus();
  document.dispatchEvent(new document.defaultView.CustomEvent("phx:update", { bubbles: true }));
  assert.equal(active(), "elsewhere");
});

await check("Revert blurred by the person, then Back: nothing takes the focus back", async () => {
  const { document, patch, tick, active } = page({ history: false, tabs: false });
  patch({ revision: true });
  document.getElementById("revert").focus();
  document.getElementById("revert").blur();
  await tick();
  patch({ revision: false });
  await tick();
  assert.equal(active(), "BODY");
});

await check("the desk loads it, as it loads its other scripts", () => {
  const desk = read(API, "lib/barkpark_web/live/studio/desk_live.ex");
  const deskJs = read(ASSETS, "bp-desk.js");
  assert.match(desk, /data-desk-revision-focus=\{BarkparkWeb\.StaticAssets\.path\("bp-desk-revision-focus\.js"\)\}/);
  assert.match(deskJs, /deskScript\("data-desk-revision-focus", window\.BarkparkDeskRevisionFocus\)/);
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("ok desk revision focus: a field moved into a revision's disabled fields hands the focus on");

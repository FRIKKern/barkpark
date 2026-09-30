import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

// task-bbfdcf4c80b8300d long tail: a footnote's painted notes edit where they
// read. The server paints the reader's <ol class="bp-footnote"> unchanged inside
// the contextual preview; BarkparkPaperPaintedCopy turns each painted row into a
// native host that writes its panel field, so the form's autosave runs.
const hooksSource = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");

const readerRows = (a, c) => `<ol class="bp-footnote"><li id="fn-a" class="bp-footnote__note">${a}</li><li id="fn-c" class="bp-footnote__note">${c}</li></ol>`;
const dom = new JSDOM(`<!doctype html><body>
  <div class="bp-paper-contextual-editor">
    <div class="bp-paper-contextual-preview" id="technical-preview-fn" phx-hook="BarkparkPaperPaintedCopy"
         data-painted-copy="li" data-painted-copy-names="note-0-text,note-3-text"
         data-painted-copy-form="technical-block-form-fn" data-painted-copy-label="Footnote">${readerRows("First.", "Third.")}</div>
    <details><summary>Configure footnotes</summary>
      <form id="technical-block-form-fn" phx-change="paper-block-autosave">
        <textarea name="note-0-text">First.</textarea>
        <textarea name="note-3-text">Third.</textarea>
      </form>
    </details>
  </div>
</body>`, { url: "http://localhost/" });
const { window } = dom;
vm.runInContext(hooksSource, vm.createContext({
  window, document: window.document, CustomEvent: window.CustomEvent, Event: window.Event, FormData: window.FormData,
  Date, setTimeout, clearTimeout, customElements: { whenDefined: () => Promise.resolve() },
}));
const document = window.document;
const el = document.getElementById("technical-preview-fn");
const hook = { ...window.BarkparkPaperEditorHooks.BarkparkPaperPaintedCopy, el };
hook.mounted();

let hosts = [...el.querySelectorAll("li")];
assert.deepEqual(hosts.map(h => h.contentEditable), ["plaintext-only", "plaintext-only"], "every painted note edits where it reads");
assert.deepEqual(hosts.map(h => h.getAttribute("aria-label")), ["Footnote 1", "Footnote 2"]);
assert.deepEqual(hosts.map(h => h.className), ["bp-footnote__note", "bp-footnote__note"], "the reader's row markup is kept");

const field = document.querySelector('[name="note-3-text"]');
const changes = [];
document.getElementById("technical-block-form-fn").addEventListener("input", e => changes.push(e.target.name));
hosts[1].textContent = "Third, edited.";
hosts[1].dispatchEvent(new window.Event("input", { bubbles: true }));
assert.equal(field.value, "Third, edited.", "a painted row writes the stored note it shows (index 3, not its row index)");
assert.deepEqual(changes, ["note-3-text"], "the form's own autosave fires for exactly that field");
assert.equal(document.querySelector('[name="note-0-text"]').value, "First.", "other notes are untouched");

const enter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
hosts[1].dispatchEvent(enter);
assert.equal(enter.defaultPrevented, true, "Enter never splits a footnote");

// A server patch while a row has focus keeps the typed text and focus.
hosts[1].focus();
hook.beforeUpdate();
el.innerHTML = readerRows("First.", "Third.");
hook.updated();
hosts = [...el.querySelectorAll("li")];
assert.equal(hosts[1].textContent, "Third, edited.", "a stale server echo never overwrites the focused row");
assert.equal(document.activeElement, hosts[1]);
assert.equal(hosts[1].contentEditable, "plaintext-only", "a patched preview is decorated again");

// A paint that does not match the named notes is never mapped onto them.
el.innerHTML = `<ol class="bp-footnote"><li class="bp-footnote__note">Only one.</li></ol>`;
hook._held = null;
hook.updated();
assert.equal(el.querySelector("li").getAttribute("contenteditable"), null);
hook.destroyed();

// An empty name leaves its painted row read-only; the others still edit.
el.innerHTML = readerRows("First.", "Third.");
el.dataset.paintedCopyNames = ",note-3-text";
const partial = { ...window.BarkparkPaperEditorHooks.BarkparkPaperPaintedCopy, el };
partial.mounted();
hosts = [...el.querySelectorAll("li")];
assert.equal(hosts[0].getAttribute("contenteditable"), null, "an unnamed row stays read-only");
assert.equal(hosts[1].contentEditable, "plaintext-only");
partial.destroyed();

// A multiline host (a code-tabs panel) takes Enter as a newline; a one-line host
// in the same preview still commits on Enter.
el.innerHTML = `<div class="bp-code-tabs"><div class="bp-code-tabs__strip"><button class="bp-code-tabs__tab">JS</button></div>` +
  `<div class="bp-code-tabs__panels"><div class="bp-code-tabs__panel"><pre>console.log(1)</pre></div></div></div>`;
el.dataset.paintedCopy = ".bp-code-tabs__tab, .bp-code-tabs__panel > pre";
el.dataset.paintedCopyNames = "note-0-text,note-3-text";
el.dataset.paintedCopyMultiline = ".bp-code-tabs__panel > pre";
const inserted = [];
document.execCommand = (cmd, _ui, value) => { inserted.push([cmd, value]); return true; };
const code = { ...window.BarkparkPaperEditorHooks.BarkparkPaperPaintedCopy, el };
code.mounted();
const [tab, pre] = [el.querySelector("button"), el.querySelector("pre")];
assert.equal(tab.getAttribute("aria-multiline"), "false");
assert.equal(pre.getAttribute("aria-multiline"), "true", "a code panel is a multiline host");
const codeEnter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
pre.dispatchEvent(codeEnter);
assert.equal(codeEnter.defaultPrevented, true);
assert.deepEqual(inserted, [["insertText", "\n"]], "Enter in a code panel inserts a newline");
const tabEnter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
tab.dispatchEvent(tabEnter);
assert.equal(inserted.length, 1, "Enter in a one-line host never inserts text");
code.destroyed();
window.close();
console.log("footnote painted copy: rows edit in place, write their own note field, survive a focused patch; mismatches refused");

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-hooks.js",
  import.meta.url,
), "utf8");
const shell = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-shell.css",
  import.meta.url,
), "utf8");
const component = readFileSync(new URL(
  "../../../lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex",
  import.meta.url,
), "utf8");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function liveViewMorph(window, from, to) {
  if (!window.__bpPaperLinksMorphdom) {
    window.eval(readFileSync(new URL(
      "../../../priv/static/assets/phoenix.js",
      import.meta.url,
    ), "utf8"));
    const liveViewSource = readFileSync(new URL(
      "../../../priv/static/assets/phoenix_live_view.js",
      import.meta.url,
    ), "utf8");
    const instrumented = liveViewSource.replace(
      ",rt=hn;",
      ",rt=hn;window.__bpPaperLinksMorphdom=rt;",
    );
    assert.notEqual(instrumented, liveViewSource,
      "the shipped LiveView bundle exposes its vendored morphdom in this test");
    window.eval(instrumented);
  }
  return window.__bpPaperLinksMorphdom(from, to, {
    getNodeKey: (node) => node?.getAttribute?.("id") || node?.id,
    onBeforeElUpdated: (fromEl, toEl) => {
      window.BarkparkPaperEditorBeforeElUpdated(fromEl, toEl);
    },
  });
}

assert.match(component, /bp-paper-links-header-editor/,
  "paper-links renders one direct heading editor in its reader header");
assert.match(component, /paper-links-title-editor/,
  "paper-links renders a dedicated scalar title form");
assert.match(component, /paper-links-description-editor/,
  "paper-links renders a dedicated scalar description form");
assert.match(component, /paper-links-title-panel-trigger/,
  "the Configure panel reaches the canonical title field");
assert.match(component, /paper-links-description-panel-trigger/,
  "the Configure panel reaches the canonical description field");
assert.ok((component.match(/:if=\{!@empty/g) || []).length >= 2,
  "a no-reference header omits both reader paint wrappers");
assert.ok((component.match(/tabindex=\{@empty && "-1"\}/g) || []).length >= 2,
  "no-reference canonical fields stay out of the keyboard tab order");

assert.match(shell, /\.bp-paper-links-title-form:not\(:focus-within\)\s*\{[^}]*position:\s*absolute[^}]*clip-path:\s*inset\(50%\)/s,
  "the canonical title form adds no resting header geometry");
assert.match(shell, /\.bp-paper-links-description-form:not\(:focus-within\)\s*\{[^}]*position:\s*absolute[^}]*clip-path:\s*inset\(50%\)/s,
  "the canonical description form adds no resting header geometry");
assert.match(shell, /\.bp-paper-links-header-editor label\.sr-only\s*\{[^}]*position:\s*absolute[^}]*width:\s*1px[^}]*height:\s*1px[^}]*clip-path:\s*inset\(50%\)/s,
  "the scalar labels stay visually hidden while their forms are focused");
assert.match(shell, /\.bp-paper-links-title-owner:has\(\.bp-paper-links-title-form:focus-within\)[^{]*> \.bp-paper-links-title-heading\s*\{[^}]*display:\s*none/s,
  "the title paint wrapper yields only while its canonical field is focused");
assert.match(shell, /\.bp-paper-links-description-owner:has\(\.bp-paper-links-description-form:focus-within\)[^{]*> \.bp-paper-links-description-paragraph\s*\{[^}]*display:\s*none/s,
  "the description paint wrapper yields only while its canonical field is focused");
assert.match(shell, /textarea\.bp-paper-inline-text\.bp-paper-links-title-input[^{]*\{[^}]*width:\s*100%[^}]*font:\s*inherit[^}]*resize:\s*none[^}]*overflow:\s*hidden[^}]*overflow-wrap:\s*anywhere/s,
  "the autosized title keeps reader typography and wrapping");
assert.match(shell, /textarea\.bp-paper-inline-text\.bp-paper-links-description-input[^{]*\{[^}]*width:\s*100%[^}]*font:\s*inherit[^}]*resize:\s*none[^}]*overflow:\s*hidden[^}]*overflow-wrap:\s*anywhere/s,
  "the autosized description keeps reader typography and wrapping");
assert.match(shell, /\[data-paper-links-description-empty="true"\]:not\(:focus-within\)\s*\{[^}]*height:\s*0[^}]*margin-block:\s*0/s,
  "an absent description reserves no reader space");
assert.match(shell, /\[data-paper-links-header-empty="true"\]:not\(:focus-within\)\s*\{[^}]*height:\s*0[^}]*margin-block:\s*0/s,
  "an empty no-reference header stays zero-flow until its fallback field is focused");

const blockId = "related: foo/[header]#?";
const encodedId = Buffer.from(blockId).toString("base64url");
const titleId = `paper-links-title-${encodedId}`;
const descriptionId = `paper-links-description-${encodedId}`;
const rawWhitespaceTitle = "   ";

const emptyDom = new JSDOM(`<!doctype html><body>
  <header class="bp-paper-links-header-editor" data-paper-links-header-empty="true">
    <div class="bp-paper-links-title-owner" data-paper-links-title-default="true">
      <form class="bp-paper-edit-form bp-paper-links-title-form"
            data-test-id="paper-links-title-editor">
        <input type="hidden" name="block_id" value="${blockId}">
        <textarea id="empty-${titleId}" name="title" tabindex="-1"
                  placeholder="Explore the work">${rawWhitespaceTitle}</textarea>
      </form>
    </div>
    <div class="bp-paper-links-description-owner" data-paper-links-description-empty="true">
      <form class="bp-paper-edit-form bp-paper-links-description-form"
            data-test-id="paper-links-description-editor">
        <input type="hidden" name="block_id" value="${blockId}">
        <textarea id="empty-${descriptionId}" name="description" tabindex="-1"></textarea>
      </form>
    </div>
  </header>
  <button type="button" data-paper-links-title-panel-trigger
          aria-controls="empty-${titleId}">Edit title</button>
  <button type="button" data-paper-links-description-panel-trigger
          aria-controls="empty-${descriptionId}">Edit description</button>
</body>`);
assert.equal(emptyDom.window.document.querySelector(".bp-paper-links-title-heading"), null);
assert.equal(emptyDom.window.document.querySelector(".bp-paper-links-description-paragraph"), null);
assert.equal(emptyDom.window.document.querySelector("[data-paper-links-title-paint]"), null);
assert.equal(emptyDom.window.document.querySelector("[data-paper-links-description-paint]"), null);
for (const field of emptyDom.window.document.querySelectorAll("textarea")) {
  assert.equal(field.tabIndex, -1, "a visually hidden no-reference field is not a tab stop");
  const fallback = emptyDom.window.document.querySelector(`[aria-controls="${field.id}"]`);
  fallback.addEventListener("click", () => field.focus());
  fallback.click();
  assert.equal(emptyDom.window.document.activeElement, field,
    "the Configure fallback can still focus a no-reference field programmatically");
}
assert.equal(emptyDom.window.document.querySelector("[name='title']").value, rawWhitespaceTitle,
  "a whitespace-only source stays exact and separate from the displayed default");
emptyDom.window.close();

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:related-header" data-paper-rev="7">
    <button id="view" data-editing="true">View</button>
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:related-header" data-paper-rev="7">
      <div class="bp-paper-contextual-editor" data-test-id="paper-links-contextual-editor">
        <div class="bp-paper-contextual-preview" data-test-id="paper-links-preview">
          <section data-paper-links>
          <header class="bp-paper-links-header-editor" data-paper-links-header-editor>
            <div class="bp-paper-links-title-owner" data-paper-links-title-default="true">
                <h2 class="bp-paper-links-title-heading">
                <button type="button" data-paper-links-title-paint
                        aria-controls="${titleId}">Explore the work</button>
              </h2>
              <form class="bp-paper-edit-form bp-paper-links-title-form"
                    id="paper-links-title-form-${blockId}"
                    phx-submit="paper-edit-block" phx-change="paper-block-autosave"
                    phx-debounce="500" data-test-id="paper-links-title-editor">
                <input type="hidden" name="block_id" value="${blockId}">
                <label class="sr-only" for="${titleId}">Related papers title</label>
                <textarea id="${titleId}" name="title" rows="1"
                          class="bp-paper-inline-text bp-paper-links-title-input"
                          placeholder="Explore the work" phx-hook="BarkparkPaperAutoSize"></textarea>
              </form>
            </div>
            <div class="bp-paper-links-description-owner" data-paper-links-description-empty="false">
              <p class="bp-paper-links-description-paragraph">
                <button type="button" data-paper-links-description-paint
                        aria-controls="${descriptionId}">Live description</button>
              </p>
              <form class="bp-paper-edit-form bp-paper-links-description-form"
                    id="paper-links-description-form-${blockId}"
                    phx-submit="paper-edit-block" phx-change="paper-block-autosave"
                    phx-debounce="500" data-test-id="paper-links-description-editor">
                <input type="hidden" name="block_id" value="${blockId}">
                <label class="sr-only" for="${descriptionId}">Related papers description</label>
                <textarea id="${descriptionId}" name="description" rows="1"
                          class="bp-paper-inline-text bp-paper-links-description-input"
                          phx-hook="BarkparkPaperAutoSize">Live description</textarea>
              </form>
            </div>
          </header>
          <article data-paper-link-card>
            <h3>Resolved title from another Paper</h3>
            <p>Resolved description from another Paper</p>
          </article>
          </section>
        </div>
        <details>
          <summary>Configure related papers</summary>
          <button type="button" data-paper-links-title-panel-trigger
                  aria-controls="${titleId}">Edit title</button>
          <button type="button" data-paper-links-description-panel-trigger
                  aria-controls="${descriptionId}">Edit description</button>
          <form class="bp-paper-edit-form" phx-submit="paper-edit-block"
                phx-change="paper-block-autosave" phx-debounce="500"
                data-test-id="paper-links-editor">
            <input type="hidden" name="block_id" value="${blockId}">
            <input type="hidden" name="ref-count" value="1">
            <input name="layout" value="chapters">
            <input name="ref-0-slug" value="source-paper">
            <input name="ref-0-title" value="Authored label">
            <textarea name="ref-0-description">Authored summary</textarea>
            <button type="submit" name="ref-action" value="add">Add reference</button>
          </form>
        </details>
      </div>
      <footer>
        <button type="button" data-paper-history-action="undo" disabled>Undo</button>
        <button type="button" data-paper-history-action="redo" disabled>Redo</button>
        <span data-paper-history-status role="status" aria-live="polite"></span>
        <span role="status" data-test-id="bp-paper-footer-save"></span>
      </footer>
    </div>
  </main>
</body>`, { url: "http://localhost/", runScripts: "outside-only" });
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
vm.runInContext(hooksSource, vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
}));

const title = window.document.getElementById(titleId);
const description = window.document.getElementById(descriptionId);
const titleForm = window.document.querySelector("[data-test-id='paper-links-title-editor']");
const descriptionForm = window.document.querySelector("[data-test-id='paper-links-description-editor']");
const referenceForm = window.document.querySelector("[data-test-id='paper-links-editor']");
assert.match(titleId, /^paper-links-title-[A-Za-z0-9_-]+$/);
assert.equal(window.document.querySelector(`#${titleId}`), title,
  "the URL-safe field ID remains a valid JS.focus selector for hostile authored IDs");
assert.equal(window.document.querySelector(`#${descriptionId}`), description);
assert.equal(title.value, "",
  "the displayed default title is not materialized into absent authored source");
assert.equal(title.placeholder, "Explore the work");
assert.equal(titleForm.elements.namedItem("block_id").value, blockId);
assert.equal(descriptionForm.elements.namedItem("block_id").value, blockId);
assert.equal(window.document.querySelectorAll(".bp-paper-links-title-owner").length, 1);
assert.equal(window.document.querySelectorAll(".bp-paper-links-description-owner").length, 1);
assert.equal(window.document.querySelector(".bp-paper-links-title-heading form"), null,
  "the title form is a sibling of its semantic heading");
assert.equal(window.document.querySelector(".bp-paper-links-description-paragraph form"), null,
  "the description form is a sibling of its semantic paragraph");

for (const { trigger, field } of [
  { trigger: "[data-paper-links-title-paint]", field: title },
  { trigger: "[data-paper-links-title-panel-trigger]", field: title },
  { trigger: "[data-paper-links-description-paint]", field: description },
  { trigger: "[data-paper-links-description-panel-trigger]", field: description },
]) {
  const button = window.document.querySelector(trigger);
  assert.equal(button.getAttribute("aria-controls"), field.id);
  button.addEventListener("click", () => window.document
    .getElementById(button.getAttribute("aria-controls"))?.focus());
  button.click();
  assert.equal(window.document.activeElement, field,
    "reader paint and Configure fallback focus the same canonical field");
}
for (const field of [title, description]) {
  assert.equal(field.tagName, "TEXTAREA");
  assert.equal(field.rows, 1);
  assert.equal(field.getAttribute("phx-hook"), "BarkparkPaperAutoSize");
}

const calls = [];
const replies = [];
const toggles = [];
const hook = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
  el: window.document.getElementById("view"),
  pushEvent(event, payload) {
    if (event === "paper-toggle-edit") {
      toggles.push(event);
      return Promise.resolve({});
    }
    calls.push({ event, payload: structuredClone(payload) });
    return new Promise((resolve) => replies.push({ resolve, toTarget: false }));
  },
  pushEventTo(_target, event, payload) {
    calls.push({ event, payload: structuredClone(payload) });
    return new Promise((resolve) => replies.push({ resolve, toTarget: true }));
  },
};
hook.mounted();
const settle = (reply) => {
  const pending = replies.shift();
  pending.resolve(pending.toTarget
    ? [{ status: "fulfilled", value: { reply } }]
    : reply);
};

// These correlated history receipts are synthetic client-protocol fixtures.
// Server tests own the separate claim that paper-links title and description
// saves issue authorized history receipts on real Public and Studio hosts.

title.focus();
title.blur();
hook.el.click();
await tick();
assert.equal(calls.length, 0,
  "viewing a displayed default title sends no patch and keeps its source absent");
assert.deepEqual(toggles, ["paper-toggle-edit"]);
toggles.length = 0;

title.focus();
title.value = "  Chosen heading  ";
title.setSelectionRange(3, 9);
title.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Chosen",
}));
await new Promise((resolve) => setTimeout(resolve, 510));
assert.equal(calls.length, 1);
assert.deepEqual(Object.keys(calls[0].payload).sort(),
  ["block_id", "if_rev", "request_id", "title"].sort());
assert.equal(calls[0].payload.block_id, blockId);
assert.equal(calls[0].payload.title, "  Chosen heading  ");
assert.equal(calls[0].payload.if_rev, 7);

description.focus();
description.value = "  Revised description  ";
description.setSelectionRange(2, 10);
description.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Revised",
}));
referenceForm.elements.namedItem("layout").dispatchEvent(
  new window.InputEvent("input", { bubbles: true, inputType: "insertText", data: null }),
);
hook.el.click();
await tick();
assert.equal(calls.length, 1, "description and reference forms wait behind the title save");
assert.deepEqual(toggles, [], "View remains fenced through all three forms");

const titleCall = calls[0];
settle({
  saved: true,
  changed: true,
  request_id: titleCall.payload.request_id,
  rev: 8,
  history_step: { version: 1, ref: titleCall.payload.request_id, action: "undo" },
});
await tick();
assert.equal(calls.length, 2);
assert.deepEqual(Object.keys(calls[1].payload).sort(),
  ["block_id", "description", "if_rev", "request_id"].sort());
assert.equal(calls[1].payload.description, "  Revised description  ");
assert.equal(calls[1].payload.if_rev, 8);
assert.equal(window.document.activeElement, description);
assert.deepEqual([description.selectionStart, description.selectionEnd], [2, 10]);

const descriptionCall = calls[1];
settle({
  saved: true,
  changed: true,
  request_id: descriptionCall.payload.request_id,
  rev: 9,
  history_step: { version: 1, ref: descriptionCall.payload.request_id, action: "undo" },
});
await tick();
assert.equal(calls.length, 3);
const referencePayload = calls[2].payload;
assert.equal(referencePayload.if_rev, 9);
assert.equal(referencePayload.block_id, blockId);
assert.equal(referencePayload.layout, "chapters");
assert.equal(referencePayload["ref-0-title"], "Authored label");
assert.equal(referencePayload.title, undefined,
  "the reference form cannot overwrite the separately authored heading");
assert.equal(referencePayload.description, undefined,
  "the reference form cannot overwrite the separately authored description");
assert.doesNotMatch(JSON.stringify(referencePayload), /Resolved title|Resolved description/,
  "live copy rendered from another Paper never becomes authored reference payload");
settle({
  saved: true,
  changed: false,
  request_id: referencePayload.request_id,
  rev: 9,
  history_step: null,
});
await tick();
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "View proceeds only after title, description, and reference forms settle");
await tick();

toggles.length = 0;
description.focus();
description.value = "  Draft survives reference transitions  ";
description.setSelectionRange(2, 16);
description.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Draft",
}));
hook.el.click();
await tick();
assert.equal(calls.length, 4);
const transitionCall = calls[3];
assert.equal(transitionCall.payload.if_rev, 9);
assert.equal(transitionCall.payload.description, "  Draft survives reference transitions  ");
settle({
  saved: true,
  changed: true,
  request_id: transitionCall.payload.request_id,
  rev: 10,
  history_step: { version: 1, ref: transitionCall.payload.request_id, action: "undo" },
});
await tick();
await tick();
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "the description draft drains before a reference transition can repaint its header");

const preview = window.document.querySelector("[data-test-id='paper-links-preview']");
const originalSection = preview.querySelector("[data-paper-links]");
const header = preview.querySelector("[data-paper-links-header-editor]");
const renderedCard = preview.querySelector("[data-paper-link-card]");
const authoritativeHeader = header.cloneNode(true);
authoritativeHeader.querySelector(`[id="${titleId}"]`).textContent = "  Chosen heading  ";
authoritativeHeader.querySelector(`[id="${descriptionId}"]`).textContent =
  "  Draft survives reference transitions  ";
const authoritativeHeaderHtml = authoritativeHeader.outerHTML;
const emptyPreview = window.document.createElement("div");
emptyPreview.className = preview.className;
emptyPreview.dataset.testId = "paper-links-preview";
emptyPreview.innerHTML = authoritativeHeaderHtml;
liveViewMorph(window, preview, emptyPreview);
const populatedPreview = window.document.createElement("div");
populatedPreview.className = preview.className;
populatedPreview.dataset.testId = "paper-links-preview";
populatedPreview.innerHTML = `<section data-paper-links>${authoritativeHeaderHtml}${renderedCard.outerHTML}</section>`;
liveViewMorph(window, preview, populatedPreview);
const emptyAgainPreview = window.document.createElement("div");
emptyAgainPreview.className = preview.className;
emptyAgainPreview.dataset.testId = "paper-links-preview";
emptyAgainPreview.innerHTML = authoritativeHeaderHtml;
liveViewMorph(window, preview, emptyAgainPreview);
assert.equal(window.document.getElementById(titleId), title,
  "the 0→1→0 reference transition preserves the canonical title textarea instance");
assert.equal(window.document.getElementById(descriptionId), description,
  "the 0→1→0 reference transition preserves the canonical description textarea instance");
assert.equal(description.value, "  Draft survives reference transitions  ");
assert.deepEqual([description.selectionStart, description.selectionEnd], [2, 16],
  "the stable textarea carries its saved selection through both reparents");

const undo = window.document.querySelector('[data-paper-history-action="undo"]');
const redo = window.document.querySelector('[data-paper-history-action="redo"]');
assert.equal(undo.disabled, false);
undo.click();
await tick();
const undoCall = calls.at(-1);
assert.equal(undoCall.event, "paper-history-step");
assert.deepEqual(undoCall.payload, {
  history_ref: transitionCall.payload.request_id,
  action: "undo",
  request_id: undoCall.payload.request_id,
  if_rev: 10,
});
settle({
  saved: true,
  request_id: undoCall.payload.request_id,
  rev: 11,
  history_step: { version: 1, ref: undoCall.payload.request_id, action: "redo" },
});
await tick();
assert.equal(redo.disabled, false,
  "a correlated description Undo receipt exposes only its opaque Redo token");
redo.click();
await tick();
const redoCall = calls.at(-1);
assert.equal(redoCall.payload.history_ref, undoCall.payload.request_id);
assert.equal(redoCall.payload.if_rev, 11);
settle({
  saved: true,
  request_id: redoCall.payload.request_id,
  rev: 12,
  history_step: { version: 1, ref: redoCall.payload.request_id, action: "undo" },
});
await tick();

title.focus();
title.value = "";
title.setSelectionRange(0, 0);
title.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "historyUndo", data: null,
}));
hook.el.click();
await tick();
const nativeUndoCall = calls.at(-1);
assert.equal(nativeUndoCall.event, "paper-block-autosave");
assert.equal(nativeUndoCall.payload.if_rev, 12);
assert.equal(nativeUndoCall.payload.title, "",
  "native text Undo after an acknowledgement remains a normal scalar save");
settle({
  saved: true,
  changed: true,
  request_id: nativeUndoCall.payload.request_id,
  rev: 13,
  history_step: { version: 1, ref: nativeUndoCall.payload.request_id, action: "undo" },
});
await tick();

toggles.length = 0;
description.focus();
hook._bpPaperExitCoordinator.observeRevision({ rev: 14, apply: () => {
  window.document.querySelector("main").dataset.paperRev = "14";
} });
description.value = "  Exact local description  ";
description.setSelectionRange(2, 13);
description.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Exact",
}));
hook.el.click();
await tick();
const rejected = calls.at(-1).payload;
assert.equal(rejected.if_rev, 13);
assert.equal(rejected.description, "  Exact local description  ");
settle({
  saved: false,
  conflict: true,
  request_id: rejected.request_id,
  current_rev: 14,
});
await tick();
assert.equal(description.value, "  Exact local description  ");
assert.equal(window.document.activeElement, description);
assert.deepEqual([description.selectionStart, description.selectionEnd], [2, 13]);
assert.deepEqual(toggles, [], "conflict keeps View fenced and the exact draft visible");
const keep = window.document.querySelector('[data-bp-paper-conflict] [data-action="keep"]');
assert.ok(keep && !keep.disabled);
keep.click();
await tick();
const retried = calls.at(-1).payload;
assert.notEqual(retried.request_id, rejected.request_id);
assert.equal(retried.if_rev, 14);
assert.equal(retried.description, "  Exact local description  ");
settle({
  saved: true,
  changed: true,
  request_id: retried.request_id,
  rev: 15,
  history_step: { version: 1, ref: retried.request_id, action: "undo" },
});
await tick();
assert.equal(hook._bpPaperExitCoordinator.hasUnsaved(), false);

hook.destroyed();
dom.window.close();
console.log("PASS paper-links header: isolated scalars, FIFO, receipt protocol, live-copy guard, and conflict recovery");

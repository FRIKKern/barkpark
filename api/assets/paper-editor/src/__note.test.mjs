// __note.test.mjs — the standalone runner for the notes-grid split `note` WIDGET
// smoke suite. Imports the shared harness-registered checks in ./smoke/note.mjs
// (projection + round-trip zero-ops + non-vacuous per-field mutation ops + lead-removal
// lands + insert + echo), then report()s the aggregate pass/fail + exit code. Also
// folded into the ./__smoke.mjs index so `npm test` runs it in the aggregate.
// Run: node src/__note.test.mjs
import "./smoke/note.mjs";
import { report } from "./smoke/harness.mjs";

// Mounted jsdom coverage proves the real schema retains the source carrier and
// the existing opaque NodeView exposes no stale-save controls. Not browser proof.
const { JSDOM } = await import("jsdom");
const { window } = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
globalThis.window = window;
globalThis.document = window.document;
for (const name of ["customElements", "CustomEvent", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
const { Editor } = await import("@tiptap/core");
const { AllSelection, TextSelection } = await import("@tiptap/pm/state");
const { default: StarterKit } = await import("@tiptap/starter-kit");
const { Note } = await import("./canvas/note-node.js");
const { Opaque } = await import("./canvas/opaque-node.js");
const { runToTiptap, runToOps, docToBlocks } = await import("./canvas/run-convert.js");
const { default: assert } = await import("node:assert/strict");
const { readFileSync } = await import("node:fs");
const { applyOps, check } = await import("./smoke/harness.mjs");
await import("./canvas/index.js");
const tick = () => new Promise(resolve => setTimeout(resolve, 20));
const fieldValue = (field, value) => {
  if ("value" in field) field.value = value;
  else field.textContent = value;
};
const readField = field => "value" in field ? field.value : field.textContent;
const mountCanvas = blocks => {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = blocks;
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail));
  document.body.appendChild(canvas);
  return { canvas, batches };
};
async function mountedCheck(name, fn) {
  try { await fn(); check(name, () => {}); }
  catch (error) { check(name, () => { throw error; }); }
}
const original = {
  id: "mounted-note", type: "note", label: "divergent", custom: { keep: [null, 7] },
  slots: {
    label: [{ id: "label-p", type: "paragraph", meta: true, content: [
      { type: "strong", extra: "wrapper", children: [{ type: "text", value: "Shown", extra: "leaf" }] },
    ] }],
    body: [{ type: "paragraph", content: [{ type: "text", value: "Body", custom: true }] }],
    unknown: [{ extra: "keep" }],
  },
};
function mount(block) {
  const element = document.createElement("div");
  document.body.appendChild(element);
  return new Editor({ element, extensions: [StarterKit, Note, Opaque], content: runToTiptap([block]) });
}
try {
  check("note mounted: schema retains full carrier and label input emits lossless folded edit", () => {
    const editor = mount(original);
    try {
      assert.deepEqual(docToBlocks(editor.getJSON()), [original]);
      assert.deepEqual(runToOps([original], editor.getJSON()), []);
      const input = editor.view.dom.querySelector('[data-test-id="paper-note-label"]');
      assert.equal(readField(input), "Shown");
      fieldValue(input, "Changed in input");
      input.dispatchEvent(new window.Event("input", { bubbles: true }));
      editor.view.dom.querySelector(".bp-canvas-note").dispatchEvent(new window.Event("bp-flush-node"));
      const expected = structuredClone(original);
      expected.slots.label[0].content[0].children[0].value = "Changed in input";
      const ops = runToOps([original], editor.getJSON());
      assert.equal(ops.length, 1);
      assert.deepEqual(Object.keys(ops[0].patch), ["slots"]);
      assert.deepEqual(applyOps([original], ops), [expected]);
      editor.commands.setContent(runToTiptap([expected]));
      assert.deepEqual(docToBlocks(editor.getJSON()), [expected]);
      assert.deepEqual(runToOps([expected], editor.getJSON()), []);
    } finally { editor.destroy(); }
  });
  check("note mounted: body contentDOM edit preserves leaf metadata", () => {
    const editor = mount(original);
    try {
      assert.ok(editor.view.dom.querySelector(".bp-canvas-note__body"));
      const node = editor.state.doc.firstChild;
      editor.commands.insertContentAt({ from: 1, to: node.nodeSize - 1 }, "Changed body");
      const expected = structuredClone(original);
      expected.slots.body[0].content[0].value = "Changed body";
      assert.deepEqual(applyOps([original], runToOps([original], editor.getJSON())), [expected]);
    } finally { editor.destroy(); }
  });
  check("note mounted: unsupported rich input is an exact read-only carry without note controls", () => {
    const unsupported = structuredClone(original);
    unsupported.slots.body[0].content.push({ type: "code", value: "Second run", extra: 9 });
    const editor = mount(unsupported);
    try {
      const guard = editor.view.dom.querySelector('[data-test-id="paper-opaque-note"]');
      assert.ok(guard);
      assert.equal(guard.getAttribute("contenteditable"), "false");
      assert.equal(editor.view.dom.querySelector("input, .bp-canvas-note__body"), null);
      assert.deepEqual(docToBlocks(editor.getJSON()), [unsupported]);
      assert.deepEqual(runToOps([unsupported], editor.getJSON()), []);
    } finally { editor.destroy(); }
  });
  for (const lead of [undefined, "", "  ", "Short lead", "A long lead that wraps across several lines alongside the body at narrow widths"]) {
    check(`note resting DOM uses reader-shaped inline lead and body ${JSON.stringify(lead)}`, () => {
      const before = { id: "layout", type: "note", label: "label", text: "Body text that continues on the same line and wraps naturally at the available width." };
      if (lead !== undefined) before.lead = lead;
      const editor = mount(before);
      try {
        const label = editor.view.dom.querySelector('[data-test-id="paper-note-label"]');
        const leadEl = editor.view.dom.querySelector('[data-test-id="paper-note-lead"]');
        const body = editor.view.dom.querySelector('.bp-canvas-note__body');
        assert.equal(label.tagName, "SPAN");
        assert.equal(leadEl.tagName, "B", "wrapping bold inline lead, not a fixed-width input");
        assert.equal(body.tagName, "SPAN", "same inline formatting context");
        assert.equal(leadEl.textContent, (lead || "").trim());
        assert.equal(leadEl.parentElement.nextSibling.textContent, (lead || "").trim() ? " " : "", "exact reader separator; absent lead adds no space");
        assert.deepEqual(docToBlocks(editor.getJSON()), [before], "visual trimming never normalizes source");
      } finally { editor.destroy(); }
    });
  }
  check("note CSS mirrors the reader contract and current root-linked shell without claiming geometry", () => {
    const css = path => readFileSync(new URL(path, import.meta.url), "utf8");
    const styles = css("./styles.css");
    const shell = css("../../../priv/static/assets/bp-paper-editor-shell.css");
    const root = css("../../../lib/barkpark_web/layouts/root.html.heex");
    assert.ok(root.includes('/assets/bp-paper-editor-shell.css'));
    const noteRules = text => text.split("\n").map(line => line.trim()).filter(line => line.startsWith(".bp-canvas-note") || line.startsWith("@media (max-width: 520px) { .bp-canvas-note"));
    assert.deepEqual(noteRules(styles), noteRules(shell));
    assert.match(styles, /\.bp-canvas-note \{[^}]*margin: 0;/);
    assert.match(styles, /\.bp-canvas-note__k \{[^}]*font-size: 0\.75rem;/);
    assert.doesNotMatch(styles.match(/\.bp-canvas-note__d \{[^}]*\}/)[0], /flex|gap:/);
  });
  check("note preview nested surface neutralizes only page geometry in both CSS copies", () => {
    const selector = ".bp-paper-surface .bp-canvas-note-preview > .bp-paper-surface";
    const expected = {
      "max-width": "none", "max-inline-size": "none", "min-inline-size": "0",
      "min-height": "0", margin: "0", padding: "0",
    };
    // This rule starts with .bp-paper-surface, outside the noteRules filter above.
    for (const path of ["./styles.css", "../../../priv/static/assets/bp-paper-editor-shell.css"]) {
      const css = readFileSync(new URL(path, import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
      const rule = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].find(([, head]) => head.trim() === selector);
      assert.ok(rule, `${path}: missing Note-only nested-surface neutralizer`);
      const declarations = Object.fromEntries(rule[2].split(";").filter(part => part.trim()).map(part => part.split(":").map(value => value.trim())));
      assert.deepEqual(declarations, expected, `${path}: geometry only; preserve tokens, font, color and background`);
    }
    const fixture = document.createElement("div");
    fixture.innerHTML = `<div class="bp-paper-surface"><div class="bp-canvas-note-preview"><div class="bp-paper-surface" id="note-sink"></div></div><div class="bp-canvas-stats-inline"><div class="bp-paper-surface"></div></div></div><div class="bp-canvas-note-preview"><div class="bp-paper-surface"></div></div>`;
    assert.deepEqual([...fixture.querySelectorAll(selector)].map(node => node.id), ["note-sink"], "leave page surfaces, other sinks and unhosted previews untouched");
  });
  for (const field of ["label", "lead"]) {
    await mountedCheck(`note canvas: focused ${field} draft survives foreign echo before private debounce and intentional exit`, async () => {
      const before = { ...structuredClone(original), lead: "Existing lead" };
      const { canvas, batches } = mountCanvas([before]);
      const elsewhere = document.createElement("button");
      document.body.appendChild(elsewhere);
      try {
        const input = canvas.querySelector(`[data-test-id="paper-note-${field}"]`);
        input.focus();
        fieldValue(input, `Typed ${field}`);
        input.dispatchEvent(new window.Event("input", { bubbles: true }));
        assert.equal(canvas._editor.isFocused, false, "island focus is not PM focus");
        assert.equal(canvas.hasPendingChanges(), true, "exit protection sees input before any timer");
        const foreign = [{ id: "remote", type: "paragraph", content: [{ type: "text", value: "Remote sibling" }] }, before];
        canvas.applyServerBlocks(foreign, { mode: "external" });
        assert.deepEqual(canvas._pendingServerBlocks, foreign, "foreign structure queues");
        assert.equal(document.activeElement, input);
        assert.equal(readField(input), `Typed ${field}`);
        elsewhere.focus();
        await tick();
        assert.equal(document.activeElement, elsewhere, "intentional external focus is not stolen");
        assert.equal(readField(input), `Typed ${field}`);
        assert.equal(canvas.flushPendingChanges(), true, "View/exit flush emits the island draft");
        assert.equal(batches.length, 1);
        const accepted = applyOps(foreign, batches[0].ops);
        canvas.identifyOpsRequest(batches[0].seq, "note-save");
        canvas.applyServerBlocks(accepted, { mode: "own", requestId: "note-save" });
        canvas.acknowledgeOps(batches[0].seq, true);
        await tick();
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), accepted, "saved draft and foreign sibling reconcile");
        assert.equal(canvas.hasPendingChanges(), false);
        assert.equal(document.activeElement, elsewhere);
      } finally { canvas.remove(); elsewhere.remove(); await tick(); }
    });
  }
  await mountedCheck("note canvas: IME draft is pending before PM transaction and cannot be replaced on exit", async () => {
    const { canvas, batches } = mountCanvas([original]);
    try {
      const lead = canvas.querySelector('[data-test-id="paper-note-lead"]');
      lead.focus();
      lead.dispatchEvent(new window.Event("compositionstart"));
      lead.textContent = "Composed lead";
      lead.dispatchEvent(new window.Event("input", { bubbles: true }));
      assert.equal(canvas.hasPendingChanges(), true);
      assert.equal(canvas.flushPendingChanges(), false, "unfinished composition stays pending, not a false saved exit");
      assert.equal(batches.length, 0);
      const foreign = [{ ...original, custom: { duringComposition: true } }];
      canvas.applyServerBlocks(foreign);
      assert.deepEqual(canvas._pendingServerBlocks, foreign);
      assert.equal(lead.textContent, "Composed lead");
      lead.dispatchEvent(new window.Event("compositionend"));
      assert.equal(canvas.flushPendingChanges(), true);
      assert.equal(batches.length, 1);
      assert.deepEqual(applyOps(foreign, batches[0].ops), [{ ...foreign[0], lead: "Composed lead" }]);
    } finally { canvas.remove(); await tick(); }
  });
  await mountedCheck("note canvas: lead visual trim/focus is a no-op and native history updates the island", async () => {
    const before = { ...original, lead: "  Original lead  " };
    const { canvas, batches } = mountCanvas([before]);
    try {
      const lead = canvas.querySelector('[data-test-id="paper-note-lead"]');
      assert.equal(lead.textContent, "Original lead");
      lead.focus();
      assert.equal(lead.textContent, "  Original lead  ");
      lead.blur();
      await tick();
      assert.equal(lead.textContent, "Original lead");
      assert.equal(canvas.flushPendingChanges(), false);
      assert.equal(batches.length, 0);
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [before]);
      lead.focus();
      lead.textContent = "History edit";
      lead.dispatchEvent(new window.Event("input", { bubbles: true }));
      lead.dispatchEvent(new window.KeyboardEvent("keydown", { key: "z", ctrlKey: true, bubbles: true, cancelable: true }));
      assert.equal(lead.textContent, "  Original lead  ");
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [before]);
    } finally { canvas.remove(); await tick(); }
  });
  await mountedCheck("note canvas: focused clean island queues foreign echo until actual focus release", async () => {
    const { canvas } = mountCanvas([original]);
    try {
      const label = canvas.querySelector('[data-test-id="paper-note-label"]');
      label.focus();
      const foreign = [{ ...original, custom: { latest: true } }];
      canvas.applyServerBlocks(foreign);
      assert.deepEqual(canvas._pendingServerBlocks, foreign);
      label.blur();
      await tick();
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), foreign);
    } finally { canvas.remove(); await tick(); }
  });
  await mountedCheck("note canvas: same-visible flat-to-slots echo replaces the source carrier before the next edit", async () => {
    const flat = { id: "reencoded", type: "note", label: "Label", lead: "Lead", text: "Body", custom: "old" };
    const { canvas, batches } = mountCanvas([flat]);
    try {
      const foreign = { id: flat.id, type: "note", custom: "new", slots: {
        label: [{ type: "paragraph", extra: 1, content: [{ type: "text", value: "Label", meta: true }] }],
        lead: [{ type: "paragraph", content: [{ type: "text", value: "Lead" }] }],
        body: [{ type: "paragraph", content: [{ type: "text", value: "Body" }] }],
      } };
      canvas.applyServerBlocks([foreign]);
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [foreign]);
      assert.equal(canvas.flushPendingChanges(), false);
      const label = canvas.querySelector('[data-test-id="paper-note-label"]');
      label.textContent = "After encoding change";
      label.dispatchEvent(new window.Event("input", { bubbles: true }));
      canvas.flushPendingChanges();
      const expected = structuredClone(foreign);
      expected.slots.label[0].content[0].value = "After encoding change";
      assert.deepEqual(applyOps([foreign], batches[0].ops), [expected]);
    } finally { canvas.remove(); await tick(); }
  });
  await mountedCheck("note canvas: same-visible carrier metadata refresh survives later edit and coarse section replacement", async () => {
    const { canvas, batches } = mountCanvas([original]);
    try {
      const foreign = structuredClone(original);
      foreign.custom = { latest: ["metadata", null] };
      foreign.slots.label[0].content[0].children[0].extra = "new leaf metadata";
      canvas.applyServerBlocks([foreign]);
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [foreign], "no same-visible stale source");
      const input = canvas.querySelector('[data-test-id="paper-note-label"]');
      fieldValue(input, "After echo");
      input.dispatchEvent(new window.Event("input", { bubbles: true }));
      canvas.flushPendingChanges();
      const expected = structuredClone(foreign);
      expected.slots.label[0].content[0].children[0].value = "After echo";
      assert.deepEqual(applyOps([foreign], batches[0].ops), [expected]);
      const section = [{ id: "section", type: "section", blocks: docToBlocks(canvas._editor.getJSON()) }];
      const doc = runToTiptap(section);
      doc.content[0].content.push({ type: "paragraph", attrs: { bpId: null, bpType: "paragraph" }, content: [{ type: "text", text: "New child" }] });
      const ops = runToOps(section, doc);
      assert.ok(ops.some(op => op.op === "replace-block"));
      assert.deepEqual(applyOps(section, ops)[0].blocks[0], expected);
    } finally { canvas.remove(); await tick(); }
  });
  for (const field of ["label", "lead"]) {
    await mountedCheck(`note history: ${field} undo/redo retains refreshed carrier`, async () => {
      const note = structuredClone(original);
      note.slots.lead = [{ type: "paragraph", extra: "lead paragraph", content: [
        { type: "text", value: "Original lead", extra: "lead leaf" },
      ] }];
      const noteAt = blocks => blocks[0];
      const liveNote = canvas => canvas._editor.state.doc.firstChild;
      const before = [note];
      const { canvas, batches } = mountCanvas(before);
      try {
        const editedSteps = [];
        const record = ({ transaction }) => editedSteps.push(...transaction.steps);
        canvas._editor.on("transaction", record);
        const input = canvas.querySelector(`[data-test-id="paper-note-${field}"]`);
        input.textContent = `Saved ${field}`;
        input.dispatchEvent(new window.Event("input", { bubbles: true }));
        canvas._editor.off("transaction", record);
        assert.equal(canvas.flushPendingChanges(), true, "history edit emits a batch");
        assert.equal(batches.length, 1);
        const saved = applyOps(before, batches[0].ops);
        canvas.identifyOpsRequest(batches[0].seq, "history-save");
        canvas.applyServerBlocks(saved, { mode: "own", requestId: "history-save" });
        canvas.acknowledgeOps(batches[0].seq, true);
        await tick();
        assert.equal(canvas.hasPendingChanges(), false, "initial history edit settles before refresh");

        const refreshed = structuredClone(saved);
        const refreshedNote = noteAt(refreshed);
        refreshedNote.custom = { authority: "latest", keep: [null, 42] };
        refreshedNote.slots.unknown.push({ authoritative: true });
        refreshedNote.slots[field][0].extra = "latest paragraph metadata";
        // Re-encode the edited field without changing its visible value.
        refreshedNote.slots[field][0].content = [{ type: "em", extra: "latest wrapper", children: [
          { type: "code", value: `Saved ${field}`, extra: "latest terminal" },
        ] }];
        const authoritativeCarrier = structuredClone(refreshedNote);
        canvas.applyServerBlocks(refreshed, { mode: "external" });
        assert.deepEqual(liveNote(canvas).attrs.bpBlock, authoritativeCarrier);
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), refreshed);

        for (const action of ["undo", "redo"]) {
          assert.equal(canvas._editor.commands[action](), true, `${action} remains available after the non-history refresh`);
          assert.deepEqual(liveNote(canvas).attrs.bpBlock, authoritativeCarrier, `${action} must not restore historical bpBlock`);
          assert.equal(liveNote(canvas).attrs.bpId, authoritativeCarrier.id);
          const expected = structuredClone(refreshed);
          const value = action === "undo" ? (field === "label" ? "Shown" : "Original lead") : `Saved ${field}`;
          noteAt(expected).slots[field][0].content[0].children[0].value = value;
          const live = canvas._editor.getJSON();
          assert.deepEqual(docToBlocks(live), expected, "complete live reconstruction retains authoritative metadata");
          assert.deepEqual(applyOps(refreshed, runToOps(refreshed, live)), expected, "complete folded field patch is lossless");

          // Exercise the coarse path with the actual installed-PM history
          // result, not a fresh projection that could hide a stale bpBlock.
          const sectionBaseline = [{ id: "coarse-history", type: "section", blocks: refreshed }];
          const sectionDoc = runToTiptap(sectionBaseline);
          sectionDoc.content[0].content = structuredClone(live.content);
          sectionDoc.content[0].content.push({ type: "paragraph", attrs: { bpId: null, bpType: "paragraph" },
            content: [{ type: "text", text: "New sibling after history" }] });
          const coarseOps = runToOps(sectionBaseline, sectionDoc);
          assert.ok(coarseOps.some(op => op.op === "replace-block"), "coarse reconstruction emits replacement");
          const coarse = applyOps(sectionBaseline, coarseOps);
          assert.deepEqual(coarse[0].blocks[0], noteAt(expected), "coarse replacement keeps all authoritative note keys");
          assert.equal(coarse[0].blocks.length, 2);
        }
        const { AttrStep } = await import("@tiptap/pm/transform");
        assert.equal(editedSteps.length, 1);
        assert.ok(editedSteps[0] instanceof AttrStep, "installed PM records only the intended attribute in history");
        assert.equal(editedSteps[0].attr, field);
      } finally { canvas.remove(); await tick(); }
    });
  }
  for (const field of ["label", "lead"]) {
    await mountedCheck(`note history: remote visible ${field} replaces conflicting local history`, async () => {
      const before = [{ ...original, lead: "Lead A" }];
      const { canvas, batches } = mountCanvas(before);
      try {
        const input = canvas.querySelector(`[data-test-id="paper-note-${field}"]`);
        input.textContent = "Local B";
        input.dispatchEvent(new window.Event("input", { bubbles: true }));
        canvas.flushPendingChanges();
        const saved = applyOps(before, batches[0].ops);
        canvas.identifyOpsRequest(batches[0].seq, "remote-conflict-save");
        canvas.applyServerBlocks(saved, { mode: "own", requestId: "remote-conflict-save" });
        canvas.acknowledgeOps(batches[0].seq, true);
        await tick();
        const remote = structuredClone(saved);
        if (field === "label") remote[0].slots.label[0].content[0].children[0].value = "Remote C";
        else remote[0].lead = "Remote C";
        remote[0].custom = { latest: true };
        canvas.applyServerBlocks(remote, { mode: "external" });
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), remote);
        canvas._editor.commands.undo();
        assert.equal(canvas._editor.state.doc.firstChild.attrs[field], "Remote C");
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), remote);
        assert.deepEqual(runToOps(remote, canvas._editor.getJSON()), []);
        assert.equal(canvas.flushPendingChanges(), false);
        assert.equal(batches.length, 1);
      } finally { canvas.remove(); await tick(); }
    });
  }
  for (const field of ["label", "lead"]) {
    for (const stamp of ["own echo", "materialization"]) {
      await mountedCheck(`note history: pre-ACK new note ${field} retains stable ID through ${stamp} and undo/redo`, async () => {
        const { slashTypeToNode } = await import("./canvas/slash-insert.js");
        const { closeHistory } = await import("@tiptap/pm/history");
        const { canvas, batches } = mountCanvas([]);
        try {
          const newNote = slashTypeToNode("note");
          canvas._editor.commands.insertContentAt({ from: 0, to: canvas._editor.state.doc.content.size }, newNote);
          canvas._editor.view.dispatch(closeHistory(canvas._editor.state.tr));
          assert.equal(canvas._editor.state.doc.firstChild.attrs.bpId, null);
          const originalValue = canvas._editor.state.doc.firstChild.attrs[field];
          const input = canvas.querySelector(`[data-test-id="paper-note-${field}"]`);
          input.textContent = `New ${field}`;
          input.dispatchEvent(new window.Event("input", { bubbles: true }));
          assert.equal(batches.length, 0, "edit precedes any save acknowledgement");

          let saved;
          if (stamp === "own echo") {
            saved = docToBlocks(canvas._editor.getJSON());
            saved[0].id = "server-confirmed-note";
            canvas.applyServerBlocks(saved, { mode: "own" });
          } else {
            assert.equal(canvas.flushPendingChanges(), true);
            assert.equal(batches.length, 1);
            saved = applyOps([], batches[0].ops);
          }
          const stableId = saved[0].id;
          assert.ok(stableId);
          assert.equal(canvas._editor.state.doc.firstChild.attrs.bpId, stableId);
          if (stamp === "materialization") {
            canvas.identifyOpsRequest(batches[0].seq, "new-note-save");
            canvas.applyServerBlocks(saved, { mode: "own", requestId: "new-note-save" });
            canvas.acknowledgeOps(batches[0].seq, true);
          }
          const latestCarrier = structuredClone(canvas._editor.state.doc.firstChild.attrs.bpBlock);
          for (const action of ["undo", "redo"]) {
            assert.equal(canvas._editor.commands[action](), true);
            const live = canvas._editor.state.doc.firstChild;
            assert.equal(live.attrs.bpId, stableId, `${action} cannot restore pre-ACK null identity`);
            assert.deepEqual(live.attrs.bpBlock, latestCarrier);
            assert.equal(live.attrs[field], action === "undo" ? originalValue : `New ${field}`,
              `${action} must change the field, not merely return true`);
            const expected = structuredClone(saved);
            if (action === "undo") {
              if (field === "lead") delete expected[0].lead;
              else expected[0].label = originalValue;
            }
            const doc = canvas._editor.getJSON();
            assert.deepEqual(docToBlocks(doc), expected);
            // The original slash carrier lacks lead. Clearing a now-saved flat
            // lead uses null on the shallow patch wire, not a key deletion.
            const folded = structuredClone(expected);
            if (action === "undo" && field === "lead") folded[0].lead = null;
            assert.deepEqual(applyOps(saved, runToOps(saved, doc)), folded);
            assert.equal(Object.hasOwn(expected[0], "slots"), false, "slash note remains flat");
          }
        } finally { canvas.remove(); await tick(); }
      });
    }
  }

  await mountedCheck("note readonly paint: canonical server HTML is display-only and stale or empty paint is guarded", async () => {
    const unsafe = structuredClone(original);
    unsafe.slots.body[0].content = [
      { type: "text", value: "Unsafe <text>", meta: { keep: true } },
      { type: "code", value: "& code", id: "code-leaf", custom: [null, 3] },
    ];
    const { canvas, batches } = mountCanvas([unsafe]);
    try {
      const atom = canvas.querySelector('[data-test-id="paper-opaque-note"]');
      assert.equal(canvas._editor.state.doc.firstChild.type.name, "bpOpaque");
      const hole = atom.querySelector("[data-bp-fleet-body]");
      assert.ok(hole, "unsafe note participates in existing server paint channel");
      assert.equal(atom.getAttribute("data-bp-fleet-id"), unsafe.id);
      const paint = (html, sourceBlock) => {
        const event = new window.CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock }, cancelable: true });
        assert.equal(hole.dispatchEvent(event), false, "node view owns injection and blocks generic hook fallback");
      };
      // Server output is a test payload, not a client renderer. Elixir tests pin
      // these escaped bytes to Components.note_item_html and the actual producer.
      const html = '<div class="bp-note"><span class="bp-note__k">Shown</span><div class="bp-note__d">Unsafe &lt;text&gt;&amp; code</div></div>';
      paint(html, unsafe);
      assert.equal(hole.innerHTML, html);
      assert.equal(atom.classList.contains("bp-canvas-readonly"), false, "successful paint has no chip-frame margin");
      assert.equal(hole.querySelector('[contenteditable], [role="textbox"], input, textarea'), null);
      assert.equal(atom.contentEditable === "false" || atom.getAttribute("contenteditable") === "false", true);
      assert.deepEqual(canvas._editor.state.doc.firstChild.attrs.bpBlock, unsafe);
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [unsafe]);
      assert.deepEqual(runToOps([unsafe], canvas._editor.getJSON()), []);
      assert.equal(canvas.flushPendingChanges(), false);
      assert.equal(batches.length, 0);

      paint("stale body", { ...unsafe, custom: "older metadata" });
      paint("unbound body", undefined);
      assert.equal(hole.innerHTML, html, "stale/unbound paint cannot replace current reader preview");
      paint("", unsafe);
      assert.match(hole.textContent, /preview unavailable/i);
      assert.equal(hole.querySelector(".bp-note"), null);
      paint(null, unsafe);
      assert.match(hole.textContent, /preview unavailable/i);
      const reordered = Object.fromEntries(Object.entries(unsafe).reverse());
      paint(html, reordered);
      assert.equal(hole.innerHTML, html, "source equality does not depend on JSON object key order");

      const refreshed = structuredClone(unsafe);
      refreshed.slots.body[0].content[0].value = "Latest body";
      refreshed.custom = { authoritative: [null, 9] };
      canvas.applyServerBlocks([refreshed], { mode: "external" });
      assert.match(hole.textContent, /loading.*preview/i, "changed carrier invalidates displayed old paint");
      paint(html, unsafe);
      assert.equal(hole.querySelector(".bp-note"), null);
      const latestHtml = html.replace("Unsafe &lt;text&gt;", "Latest body");
      paint(latestHtml, refreshed);
      assert.equal(hole.innerHTML, latestHtml);
      hole.dispatchEvent(new window.Event("input", { bubbles: true }));
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [refreshed]);
      assert.equal(canvas.flushPendingChanges(), false);
      assert.equal(batches.length, 0);
    } finally { canvas.remove(); await tick(); }
  });

  await mountedCheck("note readonly paint: installed LiveView hook routes and replays source-bound HTML without saving", async () => {
    const vm = await import("node:vm");
    const hooksSource = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");
    vm.runInContext(hooksSource, vm.createContext({
      window, document, customElements, CustomEvent, CSS: globalThis.CSS,
      FormData: window.FormData, setTimeout, clearTimeout,
    }));
    const unsafe = { ...original, content: [{ type: "text", value: "Dormant fallback" }] };
    const main = document.createElement("main");
    main.className = "bp-paper-editor";
    const wrapper = document.createElement("div");
    wrapper.id = "note-preview-run-0";
    wrapper.dataset.canvasBlocks = JSON.stringify([unsafe]);
    wrapper.dataset.canvasDataset = "production";
    const canvas = document.createElement("bp-paper-canvas");
    wrapper.appendChild(canvas);
    main.appendChild(wrapper);
    document.body.appendChild(main);
    const handlers = new Map();
    const requests = [];
    const hook = {
      ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas, el: wrapper,
      handleEvent: (name, handler) => handlers.set(name, handler),
      pushEvent: (name, payload) => { requests.push({ name, payload }); return Promise.resolve({}); },
    };
    try {
      hook.mounted();
      const html = '<div class="bp-note"><span class="bp-note__k">Shown</span><div class="bp-note__d">Body</div></div>';
      handlers.get("bp:block-html")({ renders: [{ block_id: unsafe.id, source_block: unsafe, html }] });
      const hole = canvas.querySelector("[data-bp-fleet-body]");
      assert.equal(hole.innerHTML, html);
      handlers.get("bp:block-html")({ renders: [{ block_id: "another-note", source_block: unsafe, html: "wrong note" }] });
      assert.equal(hole.innerHTML, html);
      hole.replaceChildren();
      hook.updated();
      assert.equal(hole.innerHTML, html, "existing hook replays cached canonical paint");
      handlers.get("bp:block-html")({ renders: [{ block_id: unsafe.id, source_block: { ...unsafe, custom: "stale" }, html: "stale" }] });
      assert.equal(hole.innerHTML, html, "generic hook cannot bypass node-view source guard");
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [unsafe]);
      assert.equal(canvas.flushPendingChanges(), false);
      assert.equal(requests.some(request => request.name === "paper-ops"), false);
    } finally { hook.destroyed(); main.remove(); await tick(); }
  });

  for (const initiallySafe of [false, true]) {
    await mountedCheck(`note conflict recovery: cached latest paint survives ${initiallySafe ? "safe-to-opaque mount" : "opaque source update"}`, async () => {
      const vm = await import("node:vm");
      vm.runInContext(readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
        vm.createContext({ window, document, customElements, CustomEvent, CSS: globalThis.CSS,
          FormData: window.FormData, setTimeout, clearTimeout }));
      const latest = structuredClone(original);
      latest.custom = { latest: [null, { id: "preserved-metadata" }] };
      latest.slots.body[0].content = [
        { type: "text", value: "Latest ", metadata: true },
        { type: "code", value: "unsafe body", id: "latest-leaf" },
      ];
      const old = initiallySafe
        ? { id: latest.id, type: "note", label: "Old", text: "Old safe body" }
        : { ...structuredClone(latest), custom: { old: true }, label: "old shadow" };
      const main = document.createElement("main");
      main.className = "bp-paper-editor";
      const wrapper = document.createElement("div");
      wrapper.id = "note-conflict-run-0";
      wrapper.dataset.canvasBlocks = JSON.stringify([old]);
      wrapper.dataset.canvasDataset = "production";
      const canvas = document.createElement("bp-paper-canvas");
      wrapper.appendChild(canvas);
      main.appendChild(wrapper);
      document.body.appendChild(main);
      const handlers = new Map();
      const requests = [];
      const hook = {
        ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas, el: wrapper,
        handleEvent: (name, handler) => handlers.set(name, handler),
        pushEvent: (name, payload) => { requests.push({ name, payload }); return Promise.resolve({}); },
      };
      try {
        hook.mounted();
        await tick();
        assert.equal(canvas._editor.state.doc.firstChild.type.name, initiallySafe ? "note" : "bpOpaque");
        const html = '<div class="bp-note"><span class="bp-note__k">Shown</span><div class="bp-note__d">Latest unsafe body</div></div>';
        handlers.get("bp:block-html")({ renders: [{ block_id: latest.id, source_block: latest, html }] });
        assert.equal(canvas.querySelector("[data-bp-fleet-body]")?.innerHTML === html, false,
          "future-source paint stays cached while the old source is installed");
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [old]);

        canvas.resolveConflictWithServerBlocks([latest]);
        await tick();
        const atom = canvas.querySelector('[data-test-id="paper-opaque-note"]');
        assert.equal(atom.getAttribute("data-bp-fleet-id"), latest.id);
        assert.equal(atom.querySelector("[data-bp-fleet-body]").innerHTML, html,
          "mounted/updated node signals readiness only after latest source and identity are installed");
        assert.deepEqual(canvas._editor.state.doc.firstChild.attrs.bpBlock, latest);
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [latest]);
        assert.deepEqual(runToOps([latest], canvas._editor.getJSON()), []);
        assert.equal(canvas.flushPendingChanges(), false);
        assert.equal(requests.some(request => request.name === "paper-ops"), false);

        handlers.get("bp:block-html")({ renders: [{ block_id: latest.id, source_block: old, html: "stale" }] });
        hook.updated();
        assert.equal(atom.querySelector("[data-bp-fleet-body]").innerHTML, html);
      } finally { hook.destroyed(); main.remove(); await tick(); }
    });
  }


  for (const composingLead of [false, true]) {
    await mountedCheck(`note empty-body click: ${composingLead ? "live composed absent lead" : "committed lead"} collapses AllSelection without replacing siblings`, async () => {
      const before = [
        { id: "prior-paragraph", type: "paragraph", custom: { keep: [null, 3] },
          content: [{ type: "text", value: "Prior paragraph", extra: true }] },
        { id: "empty-note", type: "note", label: "Target", ...(composingLead ? {} : { lead: "Nonempty lead" }), text: "", custom: { keep: 7 } },
        { id: "sibling-note", type: "note", label: "Sibling", lead: "Sibling lead", text: "Sibling body", custom: { keep: [false] } },
      ];
      const { canvas, batches } = mountCanvas(before);
      try {
        await tick();
        const editor = canvas._editor;
        const projectedBefore = docToBlocks(editor.getJSON());
        const paragraph = editor.state.doc.child(0).toJSON();
        const sibling = editor.state.doc.child(2).toJSON();
        const pos = editor.state.doc.child(0).nodeSize;
        assert.equal(editor.state.doc.childCount, 3);
        assert.equal(editor.state.doc.nodeAt(pos).type.name, "note");
        if (composingLead) {
          const lead = canvas.querySelector(".bp-canvas-note__lead");
          lead.focus();
          lead.dispatchEvent(new window.Event("compositionstart", { bubbles: true }));
          fieldValue(lead, "Live composed lead");
          lead.dispatchEvent(new window.Event("input", { bubbles: true }));
          assert.equal(editor.state.doc.nodeAt(pos).attrs.lead, null, "IME draft has not committed to the model");
          assert.equal(readField(lead), "Live composed lead");
          assert.equal(canvas.querySelector(".bp-canvas-note").hasAttribute("data-note-pending"), true);
        }
        editor.view.dispatch(editor.state.tr.setSelection(new AllSelection(editor.state.doc)));
        const desc = canvas.querySelector(".bp-canvas-note__d");
        const event = new window.MouseEvent("mousedown", { button: 0, bubbles: true, cancelable: true });
        desc.dispatchEvent(event);
        assert.equal(event.defaultPrevented, true);
        assert.ok(editor.state.selection instanceof TextSelection);
        assert.equal(editor.state.selection.empty, true);
        assert.equal(editor.state.selection.from, pos + 1);
        await tick();
        assert.equal(editor.view.hasFocus(), true);
        assert.equal(window.getSelection().isCollapsed, true);
        assert.equal(editor.state.selection.from, pos + 1);
        if (composingLead) {
          assert.equal(editor.state.doc.nodeAt(pos).attrs.lead, "Live composed lead", "focus transfer blurs and commits the composition");
          assert.equal(canvas.querySelector(".bp-canvas-note").hasAttribute("data-note-pending"), false);
        }
        editor.view.dispatch(editor.state.tr.insertText("Only target body"));
        assert.deepEqual(editor.state.doc.child(0).toJSON(), paragraph);
        assert.deepEqual(editor.state.doc.child(2).toJSON(), sibling);
        const expected = structuredClone(before);
        expected[1].text = "Only target body";
        if (composingLead) expected[1].lead = "Live composed lead";
        const projectedAfter = structuredClone(projectedBefore);
        projectedAfter[1] = expected[1];
        assert.deepEqual(docToBlocks(editor.getJSON()), projectedAfter);
        assert.equal(canvas.flushPendingChanges(), true);
        assert.equal(batches.length, 1);
        assert.deepEqual(applyOps(before, batches[0].ops), expected);
      } finally { canvas.remove(); await tick(); }
    });

  }

  for (const control of [
    { name: "no lead", lead: null },
    { name: "blank lead", lead: "   " },
    { name: "nonempty body", text: "Body" },
    { name: "noneditable", editable: false },
    { name: "middle button", mouse: { button: 1 } },
    { name: "secondary button", mouse: { button: 2 } },
    ...["shiftKey", "ctrlKey", "metaKey", "altKey"].map(key => ({ name: key, mouse: { [key]: true } })),
    { name: "body child target", child: true },
  ]) {
    await mountedCheck(`note empty-body click: leaves ${control.name} gesture native`, async () => {
      const before = [{ id: "gesture-note", type: "note", label: "Label", lead: "Lead", text: "",
        ...(Object.hasOwn(control, "lead") ? { lead: control.lead } : {}),
        ...(Object.hasOwn(control, "text") ? { text: control.text } : {}) }];
      const { canvas, batches } = mountCanvas(before);
      try {
        await tick();
        const editor = canvas._editor;
        if (control.editable === false) editor.setEditable(false);
        editor.view.dispatch(editor.state.tr.setSelection(new AllSelection(editor.state.doc)));
        const selection = editor.state.selection;
        // Observe the NodeView boundary without jsdom attempting native hit-testing.
        canvas.querySelector(".bp-canvas-note__d").addEventListener("mousedown", event => event.stopPropagation());
        const event = new window.MouseEvent("mousedown", { button: 0, bubbles: true, cancelable: true, ...control.mouse });
        canvas.querySelector(control.child ? ".bp-canvas-note__body" : ".bp-canvas-note__d").dispatchEvent(event);
        assert.equal(event.defaultPrevented, false);
        assert.ok(editor.state.selection.eq(selection));
        assert.deepEqual(docToBlocks(editor.getJSON()), before);
        assert.equal(canvas.flushPendingChanges(), false);
        assert.deepEqual(batches, []);
      } finally { canvas.remove(); await tick(); }
    });
  }

} finally { window.close(); }
report();

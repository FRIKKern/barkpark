// Exercise the rendered controls, then inspect their emitted persistence patches.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true, url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element",
  "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Range", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
const resizeObservers = [];
globalThis.ResizeObserver = class ResizeObserver {
  constructor(callback) {
    this.callback = callback;
    this.targets = new Set();
    this.disconnected = false;
    resizeObservers.push(this);
  }
  observe(target) { this.targets.add(target); }
  disconnect() {
    this.disconnected = true;
    this.targets.clear();
  }
};
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({
  top: 0, left: 0, right: 0, bottom: 0,
});
globalThis.CSS ||= { escape: value => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const text = value => [{ type: "text", value }];
const table = { id: "table", type: "table", head: [text("Name"), text("Age")],
  rows: [[text("Ada"), text("36")], [text("Bob"), text("40")]] };
const mixedTable = { id: "table-mixed", type: "table", caption: "Keep me",
  head: ["Name", "Age"], rows: [["Ada", "36"], [
    { content: [{ type: "link", href: "/bob", tracking: { keep: true },
      children: text("Bob") }], sourceId: "opaque-cell" }, "40",
  ]] };
const linkedBob = { content: [{ type: "link", href: "/bob", tracking: { keep: true },
  children: text("Bob") }], sourceId: "opaque-cell" };
const section = { id: "section", type: "section", title: "Group",
  layout: { mode: "grid", tracks: 2, cells: { child: { span: 2 } } },
  blocks: [{ id: "child", type: "paragraph", content: text("Keep this") }] };
let cases = 0;
async function exercise(block, action, verify) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = structuredClone([block]);
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
  document.body.appendChild(canvas);
  try {
    await new Promise(resolve => setTimeout(resolve, 350));
    assert.equal(batches.length, 0, "mount must not author an edit");
    action(canvas);
    canvas.flushPendingChanges();
    assert.equal(batches.length, 1, "control emits exactly one batch");
    assert.equal(batches[0].length, 1, "control changes exactly one block");
    const [op] = batches[0];
    assert.equal(op.op, "patch-block");
    assert.equal(op.id, block.id);
    verify(op.patch, canvas);
    assert.equal(canvas.flushPendingChanges(), false, "flush does not duplicate the change");
    cases++;
  } finally { canvas.remove(); }
}
const click = selector => canvas => {
  const control = canvas.querySelector(selector);
  assert.ok(control, `rendered control ${selector}`);
  assert.equal(control.disabled, false);
  control.click();
};
const change = (canvas, id, value, event = "change") => {
  const control = canvas.querySelector(`[data-test-id="${id}"]`);
  assert.ok(control, `rendered control ${id}`);
  control.value = value;
  control.dispatchEvent(new window.Event(event, { bubbles: true }));
};

try {
  for (const [type, before, after, extra] of [
    ["field-boolean", false, true, {}],
    ["field-boolean", true, false, {}],
    ["field-select", "a", "b", { options: [{ value: "a", label: "Alpha" }, { value: "b", label: "Beta" }] }],
    ["field-datetime", "2026-09-05T09:00", "2026-09-06T14:30", {}],
    ["field-color", "#000000", "#12abef", {}],
  ]) {
    await exercise({ id: "field", type, value: before, label: "Keep label", ...extra }, canvas => {
      const control = canvas.querySelector(`[data-test-id="paper-field-${type}"]`);
      assert.ok(control, `native ${type} control mounts`);
      if (type === "field-boolean") control.checked = after;
      else control.value = after;
      control.dispatchEvent(new window.Event("change", { bubbles: true }));
    }, patch => assert.deepEqual(patch, { value: after }, `${type} preserves the exact value type`));
  }
  for (const [title, expected] of [
    ["Add row", { head: table.head, rows: [...table.rows, [[], []]] }],
    ["Remove row", { head: table.head, rows: table.rows.slice(0, 1) }],
    ["Add column", { head: [...table.head, []], rows: table.rows.map(row => [...row, []]) }],
    ["Remove column", { head: table.head.slice(0, 1), rows: table.rows.map(row => row.slice(0, 1)) }],
    ["Toggle header row", { head: [], rows: [table.head, ...table.rows] }],
  ]) {
    await exercise(table, click(`button[title="${title}"]`), patch => {
      assert.deepEqual(patch.rows, expected.rows, title);
      assert.deepEqual(patch.head ?? null, expected.head, title);
    });
  }
  await exercise(mixedTable, click('button[title="Add column"]'), (patch, canvas) => {
    assert.deepEqual(patch.head, ["Name", "Age", []]);
    assert.deepEqual(patch.rows, [
      ["Ada", "36", []],
      [linkedBob, "40", []],
    ]);
    assert.doesNotMatch(canvas.innerHTML, /sourceId|bpTableSource|bpTableCellSource|Keep me/,
      "private source carriers never render into DOM");
  });
  for (const [title, expected] of [
    ["Add row", {
      head: mixedTable.head,
      rows: [...mixedTable.rows, [[], []]],
    }],
    ["Remove row", {
      head: mixedTable.head,
      rows: mixedTable.rows.slice(0, 1),
    }],
    ["Remove column", {
      head: ["Name"],
      rows: [["Ada"], [linkedBob]],
    }],
    ["Toggle header row", {
      head: [],
      rows: [mixedTable.head, ...mixedTable.rows],
    }],
  ]) {
    await exercise(mixedTable, click(`button[title="${title}"]`), patch => {
      assert.deepEqual(patch.head, expected.head, `${title} preserves header carriers`);
      assert.deepEqual(patch.rows, expected.rows, `${title} preserves body carriers`);
    });
  }
  {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = structuredClone([mixedTable]);
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      canvas.querySelector('button[title="Add row"]').click();
      assert.equal(canvas._editor.commands.undo(), true, "native table structure is undoable");
      assert.equal(canvas.flushPendingChanges(), false, "undo restores exact source-backed table");
      assert.deepEqual(batches, []);
    } finally { canvas.remove(); }
  }
  {
    const sourceTable = {
      id: "table-normalized-echo",
      type: "table",
      caption: "old table metadata",
      head: ["Name", "Owner"],
      rows: [["Ada", { content: text("Bob"), sourceId: "old-cell-metadata" }]],
    };
    const normalizedEcho = {
      ...sourceTable,
      caption: "fresh table metadata",
      head: [text("Name"), text("Owner")],
      rows: [[text("Ada"), {
        content: text("Bob"),
        sourceId: "fresh-cell-metadata",
        serverMetadata: { revision: 2 },
      }]],
    };
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = structuredClone([sourceTable]);
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      canvas.applyServerBlocks(structuredClone([normalizedEcho]));

      const liveTable = canvas._editor.getJSON().content[0];
      assert.deepEqual(liveTable.attrs.bpTableSource.block, normalizedEcho,
        "a normalized echo refreshes the private table source");
      assert.deepEqual(
        liveTable.content[1].content[1].attrs.bpTableCellSource.cell,
        normalizedEcho.rows[0][1],
        "a normalized echo refreshes the private cell source",
      );
      assert.equal(canvas._editor.commands.undo(), false,
        "the attribute-only authoritative refresh does not enter history");
      assert.deepEqual(batches, [], "the authoritative refresh does not author an edit");

      let bobEnd = null;
      canvas._editor.state.doc.descendants((node, pos) => {
        if (node.isText && node.text === "Bob") bobEnd = pos + node.nodeSize;
      });
      assert.notEqual(bobEnd, null, "the refreshed content-map cell remains editable");
      canvas._editor.view.dispatch(canvas._editor.state.tr.insertText("!", bobEnd));
      canvas.flushPendingChanges();

      assert.equal(batches.length, 1, "the next cell edit emits one batch");
      assert.deepEqual(batches[0][0].patch, {
        head: normalizedEcho.head,
        rows: [[normalizedEcho.rows[0][0], {
          ...normalizedEcho.rows[0][1],
          content: text("Bob!"),
        }]],
      }, "the next edit preserves freshly echoed carriers and cell metadata");
      cases++;
    } finally { canvas.remove(); }
  }
  {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [table];
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      canvas._editor.commands.setContent(
        '<table data-bp-type="table" data-bp-table-source="forged"><tbody>' +
        '<tr><td data-bp-table-cell-source="forged">pasted</td></tr></tbody></table>',
      );
      const pasted = canvas._editor.getJSON().content[0];
      assert.equal(pasted.attrs.bpTableSource, null,
        "pasted HTML cannot import a table source carrier");
      assert.equal(pasted.content[0].content[0].attrs.bpTableCellSource, null,
        "pasted HTML cannot import a cell source carrier");
    } finally { canvas.remove(); }
  }
  for (const [id, mode, tracks] of [
    ["paper-section-mode", "stack", 2],
    ["paper-section-tracks-inc", "grid", 3],
    ["paper-section-tracks-dec", "grid", 1],
  ]) {
    await exercise(section, click(`[data-test-id="${id}"]`), patch => {
      assert.equal(patch.layout.mode, mode);
      assert.equal(patch.layout.tracks, tracks);
      assert.deepEqual(patch.layout.cells, section.layout.cells);
      if (patch.blocks) assert.deepEqual(patch.blocks, section.blocks);
    });
  }
  await exercise({ id: "action", type: "action", label: "Read", href: "/before" }, canvas => {
    change(canvas, "paper-action-href", "/after", "input");
    change(canvas, "paper-action-priority", "primary");
  }, patch => {
    assert.equal(patch.href, "/after");
    assert.equal(patch.priority, "primary");
    assert.equal(patch.label, "Read");
  });
  await exercise({ id: "card", type: "card", slots: {
    title: [{ type: "heading", text: "Keep title" }],
    body: [{ type: "paragraph", content: text("Keep body") }],
  } }, canvas => {
    change(canvas, "paper-card-action-label-create", "Visit");
    change(canvas, "paper-card-action-href", "/visit");
    change(canvas, "paper-card-action-priority", "primary");
    canvas.querySelector('[data-test-id="paper-card-media-src"]').dispatchEvent(
      new window.CustomEvent("bp-change", { bubbles: true, detail: { value: "/chosen.png" } }));
  }, patch => {
    assert.equal(patch.slots.title[0].text, "Keep title");
    assert.deepEqual(patch.slots.body, [{ type: "paragraph", content: text("Keep body") }]);
    assert.equal(patch.slots.media[0].src, "/chosen.png");
    assert.deepEqual(patch.slots.action[0], {
      type: "action", label: "Visit", href: "/visit", priority: "primary",
    });
  });
  for (const [name, media] of [
    ["absent-type", { src: "/before.png", alt: "Keep alt", width: 320,
      height: 180, metadata: { keep: true } }],
    ["null-type", { type: null, src: "/before.png", alt: "Keep alt",
      width: 320, height: 180, metadata: { keep: true } }],
  ]) {
    await exercise({ id: `card-media-${name}`, type: "card", slots: {
      title: [{ type: "heading", text: "Keep title" }],
      body: [{ type: "paragraph", content: text("Keep body") }],
      media: [media],
      opaque: [{ type: "future", value: { keep: true } }],
    } }, canvas => {
      canvas.querySelector('[data-test-id="paper-card-media-src"]').dispatchEvent(
        new window.CustomEvent("bp-change", {
          bubbles: true,
          detail: { value: JSON.stringify({ url: "/after.png", assetId: "asset-2" }) },
        }),
      );
    }, patch => {
      assert.deepEqual(patch.slots.media, [{ ...media, src: "/after.png" }],
        `${name} replacement changes only src without normalizing the carrier`);
      assert.deepEqual(patch.slots.title, [{ type: "heading", text: "Keep title" }]);
      assert.deepEqual(patch.slots.body, [{ type: "paragraph", content: text("Keep body") }]);
      assert.deepEqual(patch.slots.opaque, [{ type: "future", value: { keep: true } }]);
    });
  }
  {
    const source = { id: "card-media-direct", type: "card", slots: {
      body: [{ type: "paragraph", content: text("Keep body") }],
      media: [{ src: "/before.png", alt: "Authored alt", width: 640,
        metadata: { keep: [1, 2] } }],
      opaque: [{ type: "future", value: { keep: true } }],
    } };
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = structuredClone([source]);
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      const picker = canvas.querySelector("bp-media-picker");
      const paint = canvas.querySelector('[data-test-id="paper-card-media-control"]');
      const image = canvas.querySelector("img");
      const controls = canvas.querySelector(".bp-canvas-card__controls");
      assert.equal(canvas.querySelectorAll("bp-media-picker").length, 1,
        "an admitted image has one picker instance");
      assert.equal(picker.previousElementSibling, paint,
        "the existing picker is anchored beside the visible image control");
      assert.equal(controls.contains(picker), false,
        "the admitted image does not retain a duplicate Configure picker");
      assert.equal(picker.hidden, true, "the picker implementation adds no duplicate image paint");
      assert.equal(paint.hidden, false);
      assert.equal(paint.getAttribute("aria-haspopup"), "dialog");
      assert.equal(paint.getAttribute("aria-label"), "Replace Card image: Authored alt");
      for (const [property, value] of [
        ["offsetLeft", 14], ["offsetTop", 23], ["offsetWidth", 280], ["offsetHeight", 160],
      ]) Object.defineProperty(image, property, { configurable: true, value });
      const imageObserver = resizeObservers.find(observer => observer.targets.has(image));
      assert.ok(imageObserver, "the direct control observes the bare image geometry");
      imageObserver.callback();
      assert.deepEqual({
        left: paint.style.left,
        top: paint.style.top,
        width: paint.style.width,
        height: paint.style.height,
      }, { left: "14px", top: "23px", width: "280px", height: "160px" },
      "the pointer target covers the image and no Card body content");
      Object.defineProperty(image, "offsetHeight", { configurable: true, value: 190 });
      image.dispatchEvent(new window.Event("load"));
      assert.equal(paint.style.height, "190px", "image load refreshes the overlay geometry");

      let browserOpens = 0;
      let fileOpens = 0;
      picker.openBrowser = () => { browserOpens += 1; return true; };
      picker.openFileDialog = () => { fileOpens += 1; };
      paint.click();
      for (const key of ["Enter", " "]) {
        const event = new window.KeyboardEvent("keydown", {
          key, bubbles: true, cancelable: true,
        });
        paint.dispatchEvent(event);
        assert.equal(event.defaultPrevented, true, `${JSON.stringify(key)} activates the picker`);
      }
      assert.equal(browserOpens, 3, "pointer, Enter and Space open the same picker");
      assert.equal(fileOpens, 0);
      picker.openBrowser = () => { browserOpens += 1; return false; };
      paint.click();
      assert.equal(fileOpens, 1, "a missing asset browser falls back to the same picker's file dialog");

      picker.dispatchEvent(new window.CustomEvent("bp-change", {
        bubbles: true, detail: { value: "/after.png" },
      }));
      assert.deepEqual(canvas._editor.getJSON().content[0].attrs.media, {
        src: "/after.png", alt: "Authored alt", width: 640,
        metadata: { keep: [1, 2] },
      }, "direct replacement preserves the exact type-absent media carrier");
      assert.equal(canvas._editor.commands.undo(), true);
      assert.deepEqual(canvas._editor.getJSON().content[0].attrs.media, source.slots.media[0],
        "native Undo restores the exact source carrier");
      assert.equal(canvas._editor.commands.redo(), true);
      assert.equal(canvas.flushPendingChanges(), true);
      assert.deepEqual(batches, [[{ op: "patch-block", id: source.id, patch: { slots: {
        ...source.slots,
        media: [{ ...source.slots.media[0], src: "/after.png" }],
      } } }]], "native Redo flushes only the direct media replacement");
      const opensBeforeDestroy = browserOpens;
      canvas._editor.commands.setContent("<p>Replacement</p>");
      paint.click();
      assert.equal(browserOpens, opensBeforeDestroy,
        "destroyed Card media controls cannot reopen their detached picker");
      assert.equal(imageObserver.disconnected, true,
        "destroying the Card releases its image resize observer");
      cases++;
    } finally { canvas.remove(); }

    const readerCanvas = document.createElement("bp-paper-canvas");
    readerCanvas.setAttribute("editable", "false");
    readerCanvas.blocks = structuredClone([source]);
    document.body.appendChild(readerCanvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      assert.equal(readerCanvas.querySelector('[data-test-id="paper-card-media-control"]').hidden,
        true, "View exposes the bare reader image without an editing overlay");
      assert.equal(readerCanvas.querySelector("img").style.display, "");
    } finally { readerCanvas.remove(); }
  }

  for (const [name, media, admitted] of [
    ["type-absent", { src: "/image.png" }, true],
    ["image-type", { type: "image", src: "/image.png" }, true],
    ["null-type", { type: null, src: "/image.png" }, false],
    ["empty-src", { type: "image", src: "" }, false],
    ["missing", null, false],
  ]) {
    const slots = { body: [{ type: "paragraph", content: [] }] };
    if (media) slots.media = [media];
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [{ id: `card-media-admission-${name}`, type: "card", slots }];
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      const picker = canvas.querySelector("bp-media-picker");
      const paint = canvas.querySelector('[data-test-id="paper-card-media-control"]');
      const controls = canvas.querySelector(".bp-canvas-card__controls");
      assert.equal(canvas.querySelectorAll("bp-media-picker").length, 1,
        `${name} keeps exactly one picker`);
      assert.equal(!paint.hidden, admitted, `${name} direct admission`);
      assert.equal(controls.contains(picker), !admitted,
        `${name} uses exactly ${admitted ? "the image" : "Configure"} picker location`);
      cases++;
    } finally { canvas.remove(); }
  }
  await exercise({ id: "card-clear-action-label", type: "card", slots: {
    body: [{ type: "paragraph", content: text("Keep body") }],
    action: [{ id: "keep-id", type: "action", label: "Clear me", href: "/keep",
      priority: "secondary", metadata: { keep: true } }],
  } }, canvas => {
    const label = canvas.querySelector('[data-test-id="paper-card-action-label"]');
    label.textContent = "";
    label.dispatchEvent(new window.InputEvent("input", { bubbles: true }));
  }, patch => {
    assert.deepEqual(patch.slots.action[0], {
      id: "keep-id", type: "action", label: "", href: "/keep",
      priority: "secondary", metadata: { keep: true },
    }, "clearing only the label retains the action, href, priority and metadata");
  });
  await exercise({ id: "card-action-latest-attrs", type: "card", slots: {
    body: [{ type: "paragraph", content: text("Keep body") }],
    action: [{ id: "keep-id", type: "action", label: "Before", href: null,
      priority: "future-priority", metadata: { keep: true } }],
  } }, canvas => {
    const label = canvas.querySelector('[data-test-id="paper-card-action-label"]');
    label.textContent = "After";
    label.dispatchEvent(new window.InputEvent("input", { bubbles: true }));
    change(canvas, "paper-card-action-href", "/after");
    change(canvas, "paper-card-action-priority", "primary");
  }, patch => {
    assert.deepEqual(patch.slots.action[0], {
      id: "keep-id", type: "action", label: "After", href: "/after",
      priority: "primary", metadata: { keep: true },
    }, "sequential label, href and priority writes each start from the latest action attrs");
  });

  {
    const source = { id: "card-action-direct", type: "card", extra: { keep: true }, slots: {
      body: [{ type: "paragraph", content: text("Keep body") }],
      action: [{ id: "cta", type: "action", label: "Go", href: null,
        priority: "future-priority", metadata: { keep: [1, 2] } }],
    } };
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = structuredClone([source]);
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      const label = canvas.querySelector('[data-test-id="paper-card-action-label"]');
      const labelControl = canvas.querySelector(
        '[data-test-id="paper-card-action-label-control"]',
      );
      const readerLink = canvas.querySelector("a.bp-button");
      assert.equal(label.tagName, "SPAN");
      assert.equal(label.getAttribute("role"), "textbox");
      assert.equal(label.getAttribute("aria-label"), "Card action label");
      assert.equal(label.contentEditable, "plaintext-only");
      assert.equal(label.closest("a"), null, "the editing host is not nested in a link");
      assert.equal(label.parentElement.contentEditable, "false",
        "the editing host has the same ProseMirror ownership boundary as the Card title");
      assert.equal(readerLink.style.display, "none", "Edit exposes no navigation target");
      assert.equal(canvas.querySelector('[data-test-id="paper-card-action-label-create"]').hidden,
        true, "a present action has no duplicate label input");
      labelControl.click();
      assert.equal(document.activeElement, label,
        "the panel control focuses the same canonical visible label host");

      label.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
      label.textContent = "Open directly";
      label.dispatchEvent(new window.InputEvent("input", { bubbles: true }));
      assert.equal(canvas.flushPendingChanges(), false,
        "an active composition is not serialized by an early canvas flush");
      label.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true }));
      assert.equal(canvas.flushPendingChanges(), true,
        "composition completion reaches the ordinary canvas flush boundary");
      assert.equal(batches.length, 1);
      assert.deepEqual(batches[0], [{ op: "patch-block", id: source.id, patch: {
        slots: {
          ...source.slots,
          action: [{ id: "cta", type: "action", label: "Open directly", href: null,
            priority: "future-priority", metadata: { keep: [1, 2] } }],
        },
      } }], "label-only editing preserves href representation, unknown priority and metadata");
      assert.equal(canvas.querySelector("p").textContent, "Keep body",
        "typing the action label cannot enter the Card body");
      const undo = new window.KeyboardEvent("keydown", {
        key: "z", metaKey: true, bubbles: true, cancelable: true,
      });
      label.dispatchEvent(undo);
      assert.equal(undo.defaultPrevented, true, "the label routes native Undo to the canvas");
      assert.equal(canvas._editor.getJSON().content[0].attrs.action.label, "Go");
      const redo = new window.KeyboardEvent("keydown", {
        key: "z", metaKey: true, shiftKey: true, bubbles: true, cancelable: true,
      });
      label.dispatchEvent(redo);
      assert.equal(redo.defaultPrevented, true, "the label routes native Redo to the canvas");
      assert.equal(canvas._editor.getJSON().content[0].attrs.action.label, "Open directly");

      cases++;
    } finally { canvas.remove(); }

    const readerCanvas = document.createElement("bp-paper-canvas");
    readerCanvas.setAttribute("editable", "false");
    readerCanvas.blocks = structuredClone([source]);
    document.body.appendChild(readerCanvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      const readerLink = readerCanvas.querySelector("a.bp-button");
      assert.equal(readerLink.style.display, "", "View keeps the ordinary reader anchor");
      assert.equal(readerLink.getAttribute("href"), "");
      assert.equal(readerCanvas.querySelector('[data-test-id="paper-card-action-label"]').style.display,
        "none", "View hides the non-navigational editing host");
    } finally { readerCanvas.remove(); }
  }

  for (const [name, action] of [["absent", undefined], ["nil", null], ["empty", []]]) {
    const slots = { body: [{ type: "paragraph", content: [] }] };
    if (action !== undefined) slots.action = action;
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [{ id: `card-action-${name}`, type: "card", slots }];
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      const label = canvas.querySelector('[data-test-id="paper-card-action-label"]');
      const labelControl = canvas.querySelector(
        '[data-test-id="paper-card-action-label-control"]',
      );
      assert.equal(label.style.display, "none", `${name} action has no direct label island`);
      assert.equal(labelControl.hidden, true, `${name} action has no misleading focus control`);
      assert.equal(canvas.querySelector('[data-test-id="paper-card-action-label-create"]').hidden,
        false, `${name} action retains explicit Configure creation`);
      assert.equal(canvas.flushPendingChanges(), false,
        `${name} action mount/focus state does not materialize a slot`);
      assert.deepEqual(batches, []);
      cases++;
    } finally { canvas.remove(); }
  }
  for (const [name, action] of [
    ["absent-label", { id: "keep", type: "action", href: "/keep", meta: { exact: true } }],
    ["null-label", { id: "keep", type: "action", label: null, href: null,
      meta: { exact: true } }],
  ]) {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [{ id: `card-action-${name}`, type: "card", slots: {
      body: [{ type: "paragraph", content: [] }], action: [action],
    } }];
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await new Promise(resolve => setTimeout(resolve, 350));
      const label = canvas.querySelector('[data-test-id="paper-card-action-label"]');
      assert.equal(label.textContent, "");
      label.focus();
      label.dispatchEvent(new window.InputEvent("input", { bubbles: true }));
      assert.equal(canvas.flushPendingChanges(), false,
        `${name} remains an exact no-op when its empty label is untouched`);
      assert.deepEqual(batches, []);
      cases++;
    } finally { canvas.remove(); }
  }
  console.log(`mounted control matrix: ${cases} interaction/payload cases passed`);
} finally { window.close(); }

// __sheet_embed_retarget_audit.test.mjs — pd-ee-sheet-embed-audit: the MOUNTED
// record of what a sheet ref and an embed target can and cannot do in the canvas.
//
// WHY THIS FILE EXISTS. Three suites already touch these two blocks, and none of
// them measures the reference VALUE:
//
//   * src/smoke/node-views.mjs (S3.6) proves the PURE projection + fold — verbatim
//     carry, zero ops — with `assert.deepEqual`, which is key-order blind and never
//     mounts a node-view.
//   * src/__keyboard_reach.test.mjs mounts both atoms, but its fixture seeds
//     `{ type:"sheet", sheet:{title:"Q3"} }` and `{ type:"embed", url:"…" }` —
//     NEITHER carries the `ref` / `target` the chip actually reads
//     (embed-node.js sheetChipLabel/embedChipLabel). Both chips render their
//     empty fallback there, so that suite is structurally unable to notice a
//     regression in how a reference is displayed or preserved.
//   * api/test/barkpark/portable_doc/render/canvas_reader_parity_gate_test.exs §4
//     asserts the READER render of a sheet/embed block is deterministic and
//     non-empty. That is a statement about Render.render_block, on the server,
//     with no canvas in the picture at all.
//
// So: preservation is well proven, DISPLAY and EDITABILITY of the reference value
// are not. This file mounts the real <bp-paper-canvas> and drives real events.
//
// §1  PRECONDITION — both atoms mount and their chips CARRY the reference value.
//     (Without this every assertion below could pass on an empty chip.)
// §2  NO RETARGET AFFORDANCE — the sheet/embed node-views expose zero editable
//     control and zero mutable attr. PROVEN NON-VACUOUS by a positive control:
//     the SAME query finds the figure atom's caption control in the SAME document.
// §3  SELECT → DELETE → UNDO restores the block with its reference VERBATIM.
// §3b POINTER parity — a real click on the chip mutates nothing and opens nothing.
// §4  ROUND TRIP IS NOT EDITABILITY — the mounted doc's carried block is
//     BYTE-identical (JSON.stringify, key order included) to the seed, and the
//     canvas emits no path that could have changed it.
//
// Run: node src/canvas/__sheet_embed_retarget_audit.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements",
  "CustomEvent",
  "document",
  "DOMParser",
  "Element",
  "Event",
  "EventTarget",
  "HTMLElement",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "Node",
  "NodeFilter",
  "Selection",
  "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.Element.prototype.scrollIntoView ||= function () {};
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");
const { NodeSelection } = await import("@tiptap/pm/state");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const keydown = (el, key, opts = {}) => {
  const event = new window.KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...opts,
  });
  el.dispatchEvent(event);
  return event;
};

// The reference values this whole file is about. A sheet's `ref` and an embed's
// `target` are the two values `pd-ee-sheet-embed-audit` asks whether an author can
// change from the canvas.
const SHEET_REF = "production/budget";
const EMBED_TARGET = "Linked Note";

const SHEET_SEED = {
  id: "sh-1",
  type: "sheet",
  ref: SHEET_REF,
  snapshot: { rows: [["Item", "Cost"], ["Server", "100"], ["Domain", "12"]] },
};
const EMBED_SEED = { id: "em-1", type: "embed", target: EMBED_TARGET };

const blocks = [
  { id: "b-title", type: "heading", level: 1, role: "title", text: "References" },
  { id: "b-prose", type: "paragraph", content: [{ type: "text", value: "Body." }] },
  SHEET_SEED,
  EMBED_SEED,
  // POSITIVE CONTROL for §2: a node-view in the SAME document that DOES mount an
  // editable control. If the §2 query cannot find THIS one, an empty result on the
  // sheet/embed atoms proves nothing about them — it proves the query is broken.
  { id: "b-figure", type: "figure", src: "/hero.png", caption: "Cap" },
];

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = blocks;
document.body.appendChild(canvas);
await new Promise((resolve) => setTimeout(resolve, 400));

// Anything an author could type into, toggle, or pick with. Deliberately broad:
// a retarget affordance built as a button, an input, a select, a contenteditable
// span, or one of the picker Web Components would all be caught here.
const CONTROL_SELECTOR =
  "input, textarea, select, button, [contenteditable='true'], [role='button'], " +
  "[role='textbox'], [role='combobox'], bp-reference-picker, bp-media-picker";

try {
  const editor = canvas._editor;
  assert.ok(editor, "mount creates the real TipTap editor");
  assert.ok(editor.isEditable, "the canvas mounts EDITABLE (one surface, no view mode)");
  const proseMirror = canvas.querySelector(".ProseMirror");
  assert.ok(proseMirror, "mount creates the real ProseMirror DOM");

  const byTestId = (id) => canvas.querySelector(`[data-test-id="${id}"]`);
  const nodeOfType = (name) => {
    let found = null;
    editor.state.doc.descendants((n) => {
      if (!found && n.type.name === name) found = n;
      return !found;
    });
    return found;
  };

  // ── §1 PRECONDITION: the atoms mounted AND the chip carries the reference ───

  check("§1 the sheet atom mounts and its chip CARRIES the ref (not the empty fallback)", () => {
    const el = byTestId("paper-readonly-sheet");
    assert.ok(el, "the sheet node-view did not mount — every assertion below is vacuous");
    const text = el.textContent.trim();
    assert.equal(
      text,
      `Sheet · ${SHEET_REF} · 3×2`,
      `the sheet chip does not show its ref — an author cannot even READ which sheet this is (chip: ${JSON.stringify(text)})`,
    );
  });

  check("§1 the embed atom mounts and its chip CARRIES the target (not '(untitled)')", () => {
    const el = byTestId("paper-readonly-embed");
    assert.ok(el, "the embed node-view did not mount — every assertion below is vacuous");
    const text = el.textContent.trim();
    assert.equal(
      text,
      `↪ ${EMBED_TARGET}`,
      `the embed chip does not show its target — an author cannot even READ what is transcluded (chip: ${JSON.stringify(text)})`,
    );
    assert.notEqual(text, "↪ (untitled)", "the chip fell back to the untitled marker");
  });

  // ── §2 NO RETARGET AFFORDANCE, proven against a positive control ────────────
  //
  // THE AUDIT FINDING THIS FILE RECORDS. An absence is never caught by reading an
  // empty result: the control below proves the query CAN find a control in this
  // very document, so an empty result on the two atoms is a measurement.

  check("§2 POSITIVE CONTROL: the query finds a real editable control in this document", () => {
    const figure = byTestId("paper-figure");
    assert.ok(figure, "precondition: the figure node-view mounted");
    const controls = figure.querySelectorAll(CONTROL_SELECTOR);
    assert.ok(
      controls.length > 0,
      "CONTROL_SELECTOR found nothing in the figure atom — the selector is broken, " +
        "so the empty results in the next two checks would measure nothing",
    );
  });

  for (const [label, testId] of [
    ["sheet", "paper-readonly-sheet"],
    ["embed", "paper-readonly-embed"],
  ]) {
    check(`§2 the ${label} atom exposes NO editable control (no retarget affordance)`, () => {
      const el = byTestId(testId);
      const controls = Array.from(el.querySelectorAll(CONTROL_SELECTOR));
      assert.equal(
        controls.length,
        0,
        `AUDIT STATE CHANGED: the ${label} atom now mounts ${controls.length} control(s) ` +
          `(${controls.map((c) => c.tagName.toLowerCase()).join(", ")}). ` +
          `pd-ee-sheet-embed-audit recorded ZERO. If a retarget picker was deliberately ` +
          `added, update this check and close pd-ee-sheet-embed-retarget.`,
      );
      assert.equal(
        el.getAttribute("contenteditable"),
        "false",
        `the ${label} atom is no longer contenteditable=false`,
      );
    });
  }

  check("§2 neither atom's NODE carries a mutable ref/target attr for an editor to write", () => {
    for (const [label, nodeName, key] of [
      ["sheet", "bpSheet", "ref"],
      ["embed", "bpEmbed", "target"],
    ]) {
      const node = nodeOfType(nodeName);
      assert.ok(node, `precondition: ${nodeName} is in the document`);
      const attrKeys = Object.keys(node.attrs).sort();
      assert.deepEqual(
        attrKeys,
        ["bpBlock", "bpId", "bpType"],
        `the ${label} atom's attr set changed from the audited {bpBlock,bpId,bpType}`,
      );
      assert.ok(
        !(key in node.attrs),
        `the ${label} atom now carries a top-level \`${key}\` attr — the reference became mutable`,
      );
      // The value is reachable ONLY inside the verbatim-carried block.
      assert.ok(
        node.attrs.bpBlock && node.attrs.bpBlock[key],
        `the ${label} reference is not even carried on bpBlock — preservation is broken`,
      );
    }
  });

  // ── §3 SELECT → DELETE → UNDO preserves the reference VERBATIM ──────────────
  //
  // Deletion is proven elsewhere; UNDO of a deleted reference atom is not. A
  // structural undo that restored the atom WITHOUT its ref/target would lose the
  // only copy of the value, silently.

  for (const [label, testId, nodeName, key, expected] of [
    ["sheet", "paper-readonly-sheet", "bpSheet", "ref", SHEET_REF],
    ["embed", "paper-readonly-embed", "bpEmbed", "target", EMBED_TARGET],
  ]) {
    check(`§3 ${label}: keyboard select → Backspace deletes → undo restores the ${key} VERBATIM`, () => {
      const before = JSON.stringify(nodeOfType(nodeName).attrs.bpBlock);
      assert.ok(before.includes(expected), `precondition: the carried block holds the ${key}`);

      const el = byTestId(testId);
      el.focus();
      keydown(el, "Enter");
      assert.ok(
        editor.state.selection instanceof NodeSelection &&
          editor.state.selection.node.type.name === nodeName,
        `precondition: Enter selected the ${label} atom`,
      );

      keydown(proseMirror, "Backspace", { code: "Backspace", keyCode: 8 });
      assert.equal(
        nodeOfType(nodeName),
        null,
        `Backspace did not remove the selected ${label} atom`,
      );

      assert.equal(editor.commands.undo(), true, `undo reported no step for the ${label} delete`);
      const restored = nodeOfType(nodeName);
      assert.ok(restored, `undo did not bring the ${label} atom back`);
      assert.equal(
        JSON.stringify(restored.attrs.bpBlock),
        before,
        `undo restored the ${label} atom but NOT byte-identically — the ${key} was altered or dropped`,
      );
    });
  }

  // ── §3b POINTER: a click reaches no affordance either ───────────────────────
  //
  // The row asks for pointer checks alongside the keyboard ones. A mouse cannot
  // reach an affordance the keyboard cannot, because there is none to reach: the
  // node-view's `stopEvent: () => true` means PM never turns a click inside the
  // chip into a transaction. Driven with real MouseEvents, asserted on the live
  // document — the pointer twin of §2/§3.

  for (const [label, testId] of [
    ["sheet", "paper-readonly-sheet"],
    ["embed", "paper-readonly-embed"],
  ]) {
    check(`§3b ${label}: a real click on the chip mutates nothing and opens no control`, () => {
      const el = byTestId(testId);
      const chip = el.querySelector(".bp-canvas-readonly-chip");
      assert.ok(chip, `precondition: the ${label} chip is in the DOM to be clicked`);
      const before = JSON.stringify(editor.getJSON());

      for (const type of ["mousedown", "mouseup", "click", "dblclick"]) {
        chip.dispatchEvent(new window.MouseEvent(type, { bubbles: true, cancelable: true }));
      }

      assert.equal(
        JSON.stringify(editor.getJSON()),
        before,
        `clicking the ${label} chip changed the document — the read-only atom is not inert to a pointer`,
      );
      assert.equal(
        el.querySelectorAll(CONTROL_SELECTOR).length,
        0,
        `clicking the ${label} chip revealed a control — a click-to-reveal retarget affordance exists and §2 missed it`,
      );
    });
  }

  // ── §4 ROUND TRIP IS NOT EDITABILITY ────────────────────────────────────────
  //
  // C3 of the audit row: record both properties without letting one stand in for
  // the other. Byte-parity of the carried block is asserted here with
  // JSON.stringify (key order included), which deepEqual in the smoke suite does
  // not see. It says nothing about whether an author can CHANGE the value — §2 is
  // the half that answers that, and it answers no.

  check("§4 the mounted block is BYTE-identical to the seed (stringify, key order included)", () => {
    for (const [label, nodeName, seed] of [
      ["sheet", "bpSheet", SHEET_SEED],
      ["embed", "bpEmbed", EMBED_SEED],
    ]) {
      const carried = nodeOfType(nodeName).attrs.bpBlock;
      assert.equal(
        JSON.stringify(carried),
        JSON.stringify(seed),
        `${label}: the carried block is not byte-identical to the seed after mount + select + delete + undo`,
      );
      assert.notEqual(carried, seed, `${label}: bpBlock is a SHARED REF to the seed, not a clone`);
    }
  });

  check("§4 byte-parity is not editability: the reference is unchanged AND unchangeable", () => {
    // Both halves, in one assertion, so neither can be quoted as the other.
    const sheet = nodeOfType("bpSheet");
    const embed = nodeOfType("bpEmbed");
    assert.equal(sheet.attrs.bpBlock.ref, SHEET_REF, "preserved");
    assert.equal(embed.attrs.bpBlock.target, EMBED_TARGET, "preserved");
    assert.equal(
      byTestId("paper-readonly-sheet").querySelectorAll(CONTROL_SELECTOR).length +
        byTestId("paper-readonly-embed").querySelectorAll(CONTROL_SELECTOR).length,
      0,
      "a retarget control appeared — preservation and editability are no longer the same verdict",
    );
  });
} finally {
  canvas.remove();
  window.close();
}

if (failures > 0) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nsheet/embed retarget audit passed");

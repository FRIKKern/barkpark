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
// WHAT CHANGED, 2026-09-17 (pd-ee-sheet-embed-retarget). §2 used to assert ZERO
// controls and no mutable reference on BOTH atoms, and its own failure message said
// to update it when a retarget picker was deliberately added. It has been: the sheet
// atom now mounts the EXISTING <bp-reference-picker> (ref-type="sheet") and a
// selection emits patch-block{ref, snapshot:null}. Asserting zero controls on the
// sheet would now assert the ABSENCE of the shipped feature — a green on that would
// mean the feature is gone. So the sheet half of §2 became an EXACT-SHAPE assertion
// (exactly one control, and it is the reference picker; zero controls outside it, so
// no cell editor crept in) and the embed half is UNCHANGED at zero. §5 is new: it
// DRIVES the picker and measures the op.
//
// §1  PRECONDITION — both atoms mount and their chips CARRY the reference value.
//     (Without this every assertion below could pass on an empty chip.)
// §2  THE AFFORDANCE IS EXACTLY ONE PICKER — the sheet node-view exposes the
//     reference picker and NOTHING else; the embed node-view still exposes zero.
//     PROVEN NON-VACUOUS by a positive control: the SAME query finds the figure
//     atom's caption control in the SAME document.
// §3  SELECT → DELETE → UNDO restores the block with its reference VERBATIM.
// §3b POINTER parity — a real click on the CHIP mutates nothing and reveals nothing.
// §4  ROUND TRIP — the mounted doc's carried block is BYTE-identical
//     (JSON.stringify, key order included) to the seed until something drives the
//     picker, and the sheet's cells are still not editable here.
// §5  THE RETARGET, DRIVEN — a real picker selection emits exactly
//     patch-block{ref:<new>, snapshot:null}; re-picking the SAME ref and clearing to
//     "" each emit ZERO ops; and the picker is ABSENT under data-picker-browse=false,
//     under a read-only editor, and on a template-locked block.
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
globalThis.sessionStorage = window.sessionStorage;
window.BP_PAPER_EDITOR_NO_INJECT = true;

// The retarget affordance IS the existing <bp-reference-picker>, so this suite has to
// upgrade the real Web Component and answer its real search fetch — otherwise the
// element would sit inert and §5 would drive nothing. Same mock shape as
// __reference_picker_mounted.test.mjs.
const fetches = [];
const fetchMock = async (url, options = {}) => {
  fetches.push({ url: String(url), options });
  if (options.method === "POST") return { ok: true, json: async () => ({}) };
  return {
    ok: true,
    json: async () => ({
      searchEventId: "search-event-1",
      documents: [{ _id: "drafts.q4-forecast", title: "Q4 forecast", type: "sheet" }],
    }),
  };
};
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

await import("../../../../priv/static/assets/bp-search-intel.js");
globalThis.BpSearchIntel = window.BpSearchIntel;
await import("../../../../priv/static/assets/bp-reference-picker.js");
await import("./index.js");
const { sheetRetargetAllowed } = await import("./embed-node.js");
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
canvas.setAttribute("data-dataset", "production");
canvas.setAttribute("data-scope-prefix", "/w/default/p/default");
canvas.blocks = blocks;
// §5 measures the OP a retarget emits, so the batches have to be captured from the
// moment the canvas exists — a listener added later could miss a mount-time batch and
// read its own blindness as "zero ops".
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
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
    // The CHIP, not the whole atom: since pd-ee-sheet-embed-retarget the atom also
    // holds the reference picker, whose own pill/buttons carry text. This check is
    // about what the chip SAYS the block resolves to, so it reads the chip.
    const chipEl = el.querySelector(".bp-canvas-readonly-chip");
    assert.ok(chipEl, "the sheet chip is missing — the block no longer says what it is");
    const text = chipEl.textContent.trim();
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

  // The SHEET atom's affordance is exact, not merely present: one reference picker,
  // and nothing else. "Nothing else" is the half that still guards the audit finding —
  // a cell editor, a rename input, or a second picker smuggled in beside it would all
  // fail here, and so would the picker DISAPPEARING.
  check("§2 the sheet atom exposes EXACTLY ONE control and it is the reference picker", () => {
    const el = byTestId("paper-readonly-sheet");
    const picker = byTestId("paper-sheet-retarget");
    assert.ok(
      picker,
      "the sheet retarget picker did not mount — pd-ee-sheet-embed-retarget shipped it; " +
        "its absence is the feature being gone, not the audit state being restored",
    );
    assert.equal(
      picker.tagName.toLowerCase(),
      "bp-reference-picker",
      `the retarget control is a <${picker.tagName.toLowerCase()}>, not the EXISTING ` +
        "<bp-reference-picker> the row required be reused",
    );
    assert.equal(
      picker.getAttribute("ref-type"),
      "sheet",
      "the retarget picker is not scoped to sheet documents",
    );
    assert.ok(el.contains(picker), "the picker is not inside the sheet atom");

    // Controls OUTSIDE the picker: the sheet's own chrome must contribute none. The
    // picker's internal buttons/input are its own business and are excluded by the
    // contains() filter, not by narrowing the selector.
    const outside = Array.from(el.querySelectorAll(CONTROL_SELECTOR)).filter(
      (c) => c !== picker && !picker.contains(c),
    );
    assert.equal(
      outside.length,
      0,
      `the sheet atom mounts ${outside.length} control(s) outside the reference picker ` +
        `(${outside.map((c) => c.tagName.toLowerCase()).join(", ")}) — only the REFERENCE ` +
        "is authored here; the sheet's cells stay read-only",
    );
    assert.equal(
      el.getAttribute("contenteditable"),
      "false",
      "the sheet atom is no longer contenteditable=false",
    );
  });

  check("§2 the embed atom exposes NO editable control (no retarget affordance)", () => {
    const el = byTestId("paper-readonly-embed");
    const controls = Array.from(el.querySelectorAll(CONTROL_SELECTOR));
    assert.equal(
      controls.length,
      0,
      `AUDIT STATE CHANGED: the embed atom now mounts ${controls.length} control(s) ` +
        `(${controls.map((c) => c.tagName.toLowerCase()).join(", ")}). ` +
        `pd-ee-sheet-embed-audit recorded ZERO and pd-ee-sheet-embed-retarget scoped ` +
        `itself to the SHEET only. If an embed retarget was deliberately added, update ` +
        `this check and say which row shipped it.`,
    );
    assert.equal(
      el.getAttribute("contenteditable"),
      "false",
      "the embed atom is no longer contenteditable=false",
    );
  });

  // The attr SET is unchanged by the retarget work and is still worth pinning: the new
  // ref is written INSIDE the verbatim-carried block (bpBlock), not as a new top-level
  // attr, so the verbatim-carry contract and the id stamp are untouched. A `ref` attr
  // appearing here would mean the block stopped riding verbatim.
  check("§2 neither atom's NODE grew a top-level ref/target attr — the value still rides bpBlock", () => {
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
        `the ${label} atom now carries a top-level \`${key}\` attr — the value left the ` +
          `verbatim-carried block, so bpBlock is no longer the whole block`,
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
    check(`§3b ${label}: a real click on the chip mutates nothing and reveals nothing new`, () => {
      const el = byTestId(testId);
      const chip = el.querySelector(".bp-canvas-readonly-chip");
      assert.ok(chip, `precondition: the ${label} chip is in the DOM to be clicked`);
      const before = JSON.stringify(editor.getJSON());
      const controlsBefore = el.querySelectorAll(CONTROL_SELECTOR).length;

      for (const type of ["mousedown", "mouseup", "click", "dblclick"]) {
        chip.dispatchEvent(new window.MouseEvent(type, { bubbles: true, cancelable: true }));
      }

      assert.equal(
        JSON.stringify(editor.getJSON()),
        before,
        `clicking the ${label} chip changed the document — the read-only atom is not inert to a pointer`,
      );
      // The CHIP is still inert. The count is asserted against what was there BEFORE
      // the click (0 for embed, the picker's own chrome for sheet), so a hidden
      // click-to-reveal surface is still caught, without this check having to
      // re-hardcode the shipped affordance §2 already pins exactly.
      assert.equal(
        el.querySelectorAll(CONTROL_SELECTOR).length,
        controlsBefore,
        `clicking the ${label} chip revealed a control — a click-to-reveal affordance exists and §2 missed it`,
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

  check("§4 preserved-until-touched: nothing has moved the reference, and only ONE thing can", () => {
    // Both halves, in one assertion, so neither can be quoted as the other. Mount +
    // select + delete + undo + a chip click have gone by and NOTHING moved the
    // reference: the ONLY path that can is the picker, and §5 drives it.
    const sheet = nodeOfType("bpSheet");
    const embed = nodeOfType("bpEmbed");
    assert.equal(sheet.attrs.bpBlock.ref, SHEET_REF, "preserved");
    assert.equal(embed.attrs.bpBlock.target, EMBED_TARGET, "preserved");
    assert.equal(
      byTestId("paper-readonly-embed").querySelectorAll(CONTROL_SELECTOR).length,
      0,
      "the embed atom grew a control — an embed target is still not authored in the canvas",
    );
    const picker = byTestId("paper-sheet-retarget");
    const sheetControls = Array.from(
      byTestId("paper-readonly-sheet").querySelectorAll(CONTROL_SELECTOR),
    ).filter((c) => c !== picker && !picker.contains(c));
    assert.equal(
      sheetControls.length,
      0,
      "a second edit surface appeared on the sheet atom beside the reference picker",
    );
  });
  // ── §5 THE RETARGET, DRIVEN ─────────────────────────────────────────────────
  //
  // §2 says the affordance EXISTS. That is not the same claim as "it works": a picker
  // that mounts and emits nothing would pass §2 and ship a dead control. So this
  // section drives the REAL Web Component — Change → type → the mocked search result →
  // mousedown — and measures the op batch the canvas actually emits.

  const NEW_REF = "q4-forecast";

  // Drive one full selection through the mounted picker. Returns the batches emitted
  // between the call and the flush, so each drive is measured in isolation.
  const drivePick = async () => {
    batches.length = 0;
    const picker = byTestId("paper-sheet-retarget");
    // No picker → no drive. Returning [] lets the §5 checks below report the MISSING
    // op as a failed assertion with a readable diff, instead of this helper throwing
    // and taking every remaining section down with it (an uncaught TypeError here
    // would hide §5b entirely).
    if (!picker) return [];
    const change = Array.from(picker.querySelectorAll("button")).find(
      (b) => b.textContent === "Change",
    );
    if (change) change.click();
    const input = picker.querySelector(".bp-ref-search-input");
    assert.ok(input, "the picker offers its real typeahead input");
    input.value = "q4";
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 400));
    const result = picker.querySelector(".bp-ref-dropdown-item");
    assert.ok(result, "the mocked scoped search result renders as a picker option");
    result.dispatchEvent(
      new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }),
    );
    canvas.flushPendingChanges();
    return batches.slice();
  };

  const firstPick = await drivePick();
  const sheetSearch = fetches.find(({ url }) => url.includes("q=q4"));

  check("§5 a real picker selection emits EXACTLY patch-block{ref, snapshot:null}", () => {
    assert.deepEqual(firstPick, [
      [
        {
          op: "patch-block",
          id: "sh-1",
          patch: { ref: NEW_REF, snapshot: null },
        },
      ],
    ]);
    // The snapshot key is PRESENT and null — not merely absent. patch.ex shallow-merges
    // the patch, so an absent key would LEAVE the old sheet's cached cells under the
    // new sheet's name; the explicit null is what clears them.
    const patch = firstPick[0][0].patch;
    assert.deepEqual(Object.keys(patch).sort(), ["ref", "snapshot"]);
    assert.equal(patch.snapshot, null, "the stale snapshot is not explicitly cleared");
  });

  check("§5 the patch names the PAPER's block, never the sheet document", () => {
    // The permission boundary, as an op-shape assertion: retargeting writes one key on
    // one block of THIS paper. Nothing in the batch addresses the referenced sheet, so
    // no read grant is being turned into a write anywhere.
    const ops = firstPick[0];
    assert.equal(ops.length, 1, "a retarget emitted more than one op");
    assert.equal(ops[0].id, "sh-1", "the op is keyed by something other than the paper block");
    assert.ok(
      !JSON.stringify(ops[0]).includes("sheet-doc"),
      "the op references a sheet document id",
    );
  });

  check("§5 the browse fetch is the scoped, sheet-typed read the picker already does", () => {
    assert.ok(sheetSearch, "the picker issued no search fetch");
    assert.equal(
      sheetSearch.url,
      "/w/default/p/default/v1/data/search/production?q=q4&perspective=raw&limit=50&type=sheet",
    );
    assert.equal(
      sheetSearch.options.credentials,
      "same-origin",
      "the browse does not ride the caller's own session — the server cannot scope it",
    );
  });

  check("§5 the chip and the carried block both moved to the new ref", () => {
    const node = nodeOfType("bpSheet");
    assert.equal(node.attrs.bpBlock.ref, NEW_REF, "the carried block still names the old sheet");
    assert.ok(
      !("snapshot" in node.attrs.bpBlock),
      "the OLD sheet's cached grid is still carried under the NEW ref — the stale-snapshot hazard",
    );
    assert.equal(
      byTestId("paper-readonly-sheet")
        .querySelector(".bp-canvas-readonly-chip")
        .textContent.includes(NEW_REF),
      true,
      "the summary chip still names the OLD sheet after a retarget",
    );
  });

  const secondPick = await drivePick();
  check("§5 re-picking the SAME sheet emits ZERO ops", () => {
    assert.deepEqual(secondPick, [], `a no-change re-pick emitted ${JSON.stringify(secondPick)}`);
  });

  batches.length = 0;
  const pickerEl = byTestId("paper-sheet-retarget");
  const removeBtn = pickerEl
    ? Array.from(pickerEl.querySelectorAll("button")).find((b) => b.textContent === "Remove")
    : null;
  if (removeBtn) removeBtn.click();
  canvas.flushPendingChanges();
  const clearBatches = batches.slice();

  check("§5 CLEARING the picker is a no-op — a retarget cannot blank a reference", () => {
    // The picker's Remove emits bp-change with "". Blanking the ref would leave a chip
    // with no identity and no route back to the sheet it named; deleting the block is
    // the affordance for "I do not want this". So the commit refuses an empty value.
    assert.deepEqual(clearBatches, [], `a clear emitted ${JSON.stringify(clearBatches)}`);
    assert.equal(
      nodeOfType("bpSheet").attrs.bpBlock.ref,
      NEW_REF,
      "a clear blanked the carried reference",
    );
  });

  // ── §5b WHERE THE AFFORDANCE IS NOT OFFERED ─────────────────────────────────
  //
  // Four independent nos, asserted on the exported predicate the node-view calls, so
  // each one is measured separately instead of being inferred from one mounted case.
  // The mounted negative below proves the predicate is the one that actually decides.

  check("§5b the predicate refuses embed, a read-only editor, a locked block, and a no-browse host", () => {
    const yes = { bpType: "sheet", editor: { isEditable: true }, block: { ref: "a" }, scope: { pickerBrowse: true } };
    assert.equal(sheetRetargetAllowed(yes), true, "precondition: the allowed case IS allowed");
    assert.equal(sheetRetargetAllowed({ ...yes, bpType: "embed" }), false, "embed");
    assert.equal(sheetRetargetAllowed({ ...yes, editor: { isEditable: false } }), false, "read-only editor");
    assert.equal(sheetRetargetAllowed({ ...yes, block: { ref: "a", locked: true } }), false, "template-locked block");
    assert.equal(sheetRetargetAllowed({ ...yes, scope: { pickerBrowse: false } }), false, "no browse grant");
  });
  // §5b MOUNTED: an item-share edit grant (data-picker-browse="false") authorizes THIS
  // paper, not dataset discovery — so no browse UI is mounted at all. A second canvas,
  // because the attribute is read once at node-view construction.
  {
    const locked = document.createElement("bp-paper-canvas");
    locked.setAttribute("data-dataset", "production");
    locked.setAttribute("data-picker-browse", "false");
    locked.blocks = [
      { id: "b-title", type: "heading", level: 1, role: "title", text: "Shared" },
      { id: "sh-2", type: "sheet", ref: SHEET_REF, snapshot: { rows: [["a"]] } },
    ];
    document.body.appendChild(locked);
    await new Promise((resolve) => setTimeout(resolve, 400));
    try {
      check("§5b MOUNTED: data-picker-browse=false mounts no retarget picker at all", () => {
        const atom = locked.querySelector('[data-test-id="paper-readonly-sheet"]');
        assert.ok(atom, "precondition: the sheet atom mounted on the share-scoped canvas");
        assert.ok(
          atom.textContent.includes(SHEET_REF),
          "precondition: the chip still shows the ref (the value stays READABLE)",
        );
        assert.equal(
          locked.querySelectorAll('[data-test-id="paper-sheet-retarget"]').length,
          0,
          "a browse UI mounted under an item-share edit grant",
        );
      });
    } finally {
      locked.remove();
    }
  }
} finally {
  canvas.remove();
  window.close();
}

if (failures > 0) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nsheet/embed retarget audit passed");

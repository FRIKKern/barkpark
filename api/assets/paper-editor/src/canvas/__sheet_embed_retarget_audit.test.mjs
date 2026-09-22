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
// no cell editor crept in). §5 is new: it DRIVES the picker and measures the op.
//
// WHAT CHANGED AGAIN, 2026-09-17 (pd-ee-embed-retarget, the sibling row). The EMBED
// half has now shipped the same affordance, so the four assertions that recorded the
// embed atom's ZERO controls are retired the same way and for the same reason — a
// green on "the embed atom mounts no control" would now be a green on the feature
// being gone. Retired, and what replaced each:
//   * §2 "the embed atom exposes NO editable control" → EXACT-SHAPE: exactly one
//     control, it is <bp-reference-picker>, and its ref-type is "paper".
//   * §4 "preserved-until-touched" asserted the embed control count is 0 → it now
//     asserts the embed atom holds the picker and NOTHING beside it, the same shape
//     the sheet half of that check already used.
//   * §5b's predicate check asserted `bpType:"embed"` is REFUSED → embed is now an
//     ALLOWED case, and the refusal is asserted on a read-only atom kind that has no
//     retargetable reference at all.
//   * §5b MOUNTED (data-picker-browse=false) measured only the sheet picker → it now
//     measures BOTH, on a canvas seeded with both atoms.
// UNCHANGED, deliberately: §2's "neither atom's NODE grew a top-level ref/target
// attr" still holds — an embed's target still rides INSIDE the verbatim-carried
// bpBlock, exactly as before, so that assertion is still true and still load-bearing.
// §5c is new: it drives the embed picker and measures the op, which is NOT the sheet's
// op (see the key-set assertion there).
//
// §1  PRECONDITION — both atoms mount and their chips CARRY the reference value.
//     (Without this every assertion below could pass on an empty chip.)
// §2  THE AFFORDANCE IS EXACTLY ONE PICKER — EACH node-view exposes its reference
//     picker (sheet: ref-type="sheet"; embed: ref-type="paper", since
//     pd-ee-embed-retarget) and NOTHING else. The older "the embed exposes zero"
//     reading of this section is SUPERSEDED, not regressed — see WHAT CHANGED AGAIN.
//     PROVEN NON-VACUOUS by a positive control: the SAME query finds the figure
//     atom's caption control in the SAME document.
// §3  SELECT → DELETE → UNDO restores the block with its reference VERBATIM.
// §3b POINTER parity — a real click on the CHIP mutates nothing and reveals nothing.
// §4  ROUND TRIP — the mounted doc's carried block is BYTE-identical
//     (JSON.stringify, key order included) to the seed until something drives the
//     picker, and the sheet's cells are still not editable here.
// §5  THE SHEET RETARGET, DRIVEN — a real picker selection emits exactly
//     patch-block{ref:<new>, snapshot:null}; re-picking the SAME ref and clearing to
//     "" each emit ZERO ops.
// §5c THE EMBED RETARGET, DRIVEN — its own op, patch-block{target} with NO snapshot
//     key, committing the paper's TITLE (never the doc id the picker emits), and a
//     bare typed title commits verbatim where the sheet's picker has no free-text door.
// §5d THE RETARGET IS UNDOABLE — a SECOND, DIFFERENT reference on each atom, then
//     undo: block AND chip go back. §3's undo is a DELETE; this one is an attr step.
// §5b WHERE IT IS NOT OFFERED — the picker is ABSENT under data-picker-browse=false,
//     under a read-only editor, and on a template-locked block, asserted on the
//     exported predicate and mounted once to prove the predicate is what decides.
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
  // The two atoms browse DIFFERENT types (a sheet ref names a sheet document; an
  // embed target names a paper), so the mock answers by the `type=` the picker asked
  // for. One shared answer would let the embed drive pass on a sheet-shaped hit and
  // hide the whole value-space divergence this file now pins.
  const paperSearch = String(url).includes("type=paper");
  // §5d needs a SECOND, DIFFERENT sheet to retarget to: an undo that "restores" a
  // value it never left would pass on a no-op re-pick and measure nothing. The
  // alternate document answers only the `q=alt` term, so every earlier drive still
  // sees exactly the single hit it was written against.
  const altSheet = String(url).includes("q=alt");
  return {
    ok: true,
    json: async () => ({
      searchEventId: "search-event-1",
      documents: paperSearch
        ? [{ _id: "drafts.paper-7f2", title: "Q4 Retro", type: "paper" }]
        : altSheet
          ? [{ _id: "drafts.alt-forecast", title: "Alt forecast", type: "sheet" }]
          : [{ _id: "drafts.q4-forecast", title: "Q4 forecast", type: "sheet" }],
    }),
  };
};
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

await import("../../../../priv/static/assets/bp-search-intel.js");
globalThis.BpSearchIntel = window.BpSearchIntel;
await import("../../../../priv/static/assets/bp-reference-picker.js");
await import("./index.js");
const { atomRetargetAllowed } = await import("./embed-node.js");
const { NodeSelection } = await import("@tiptap/pm/state");
const { closeHistory } = await import("@tiptap/pm/history");

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
    // The CHIP, not the whole atom: since pd-ee-embed-retarget the atom also holds the
    // reference picker, whose own input/buttons sit beside the chip. This check is
    // about what the chip SAYS is transcluded, so it reads the chip — the same read
    // the sheet half already does.
    const chipEl = el.querySelector(".bp-canvas-readonly-chip");
    assert.ok(chipEl, "the embed chip is missing — the block no longer says what it is");
    const text = chipEl.textContent.trim();
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

  // The EMBED atom, same exact-shape rule (pd-ee-embed-retarget). The ref-type is the
  // half that cannot be copied from the sheet: an embed's target resolves against
  // PAPERS by title-or-alias (Content.Papers render_embed_target →
  // resolve_doc_by_title_or_alias), so a picker scoped to any other type would browse
  // documents whose titles can never resolve.
  check("§2 the embed atom exposes EXACTLY ONE control and it is the PAPER-scoped picker", () => {
    const el = byTestId("paper-readonly-embed");
    const picker = byTestId("paper-retarget-embed");
    assert.ok(
      picker,
      "the embed retarget picker did not mount — pd-ee-embed-retarget shipped it; " +
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
      "paper",
      "the embed retarget picker is not scoped to PAPERS — an embed target resolves " +
        "by paper title-or-alias, so any other scope browses unresolvable documents",
    );
    assert.ok(el.contains(picker), "the picker is not inside the embed atom");

    const outside = Array.from(el.querySelectorAll(CONTROL_SELECTOR)).filter(
      (c) => c !== picker && !picker.contains(c),
    );
    assert.equal(
      outside.length,
      0,
      `the embed atom mounts ${outside.length} control(s) outside the reference picker ` +
        `(${outside.map((c) => c.tagName.toLowerCase()).join(", ")}) — only the POINTER ` +
        "is authored here; the transcluded note is edited in the target note",
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
    // Both atoms now hold a picker, so "nothing moved it" is asserted the same way on
    // each: exactly the picker, nothing beside it. A second edit surface on either atom
    // fails here.
    for (const [label, atomTestId, pickerTestId] of [
      ["sheet", "paper-readonly-sheet", "paper-sheet-retarget"],
      ["embed", "paper-readonly-embed", "paper-retarget-embed"],
    ]) {
      const picker = byTestId(pickerTestId);
      assert.ok(picker, `precondition: the ${label} retarget picker is mounted`);
      const beside = Array.from(byTestId(atomTestId).querySelectorAll(CONTROL_SELECTOR)).filter(
        (c) => c !== picker && !picker.contains(c),
      );
      assert.equal(
        beside.length,
        0,
        `a second edit surface appeared on the ${label} atom beside the reference picker`,
      );
    }
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
  const drivePick = async (pickerTestId = "paper-sheet-retarget", term = "q4") => {
    batches.length = 0;
    const picker = byTestId(pickerTestId);
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
    input.value = term;
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

  // ── §5c THE EMBED RETARGET, DRIVEN (pd-ee-embed-retarget) ───────────────────
  //
  // The embed half, driven the same way — and deliberately NOT asserted by copying §5
  // with the names swapped. Three things differ, and each one is a place a mirrored
  // expectation would be FALSE:
  //
  //   * the committed value is the picked paper's TITLE, not the doc id the picker
  //     emits. walk.ex embed/2 looks the target up in a map keyed by the raw target
  //     string, built by Papers.resolve_embeds_in_blocks via resolve_doc_by_title_or_
  //     alias — so an id written to `target` resolves to nothing, forever.
  //   * the patch key set is exactly ["target"] — no `snapshot`. An embed caches no
  //     projection, so there is nothing stale to clear and a null snapshot would write
  //     a key the block does not own.
  //   * a bare TYPED title commits verbatim, resolved or not. `![[Some Note]]` is the
  //     shorthand authors already have; a picker that refuses a title the search does
  //     not know would be a worse door than markdown.

  const NEW_EMBED_TARGET = "Q4 Retro";
  const NEW_EMBED_DOC_ID = "paper-7f2";

  const embedPick = await drivePick("paper-retarget-embed", "retro");
  const paperSearch = fetches.find(({ url }) => url.includes("q=retro"));

  // §5 retargeted the SHEET and nothing acked it, so this harness's `prevBlocks`
  // baseline still holds the sheet's ORIGINAL ref — every batch after §5 therefore
  // re-carries the sheet's patch alongside whatever else changed. That is the canvas
  // behaving correctly (an unacked op is re-sent), not the embed emitting two ops. So
  // the embed's op is measured by picking the ops keyed to the EMBED block out of the
  // batch — and the count of those is asserted, so a second embed op could not hide.
  const embedOps = (batchList) =>
    batchList.flat().filter((op) => op && op.id === "em-1");

  check("§5c a real embed picker selection emits EXACTLY patch-block{target}", () => {
    assert.equal(embedPick.length, 1, "a retarget emitted more than one batch");
    assert.deepEqual(embedOps(embedPick), [
      { op: "patch-block", id: "em-1", patch: { target: NEW_EMBED_TARGET } },
    ]);
    const patch = embedOps(embedPick)[0].patch;
    assert.deepEqual(
      Object.keys(patch).sort(),
      ["target"],
      "the embed patch carries a key beside `target` — most likely the sheet twin's " +
        "`snapshot: null`, which an embed block does not own",
    );
    assert.ok(!("snapshot" in patch), "the embed patch mirrored the sheet's snapshot clear");
  });

  check("§5c the committed target is the paper's TITLE, not the doc id the picker emits", () => {
    // THE DIVERGENCE, asserted in both directions: the title is present AND the id is
    // absent. Asserting only the first would pass on a value that happened to contain
    // both.
    const node = nodeOfType("bpEmbed");
    assert.equal(
      node.attrs.bpBlock.target,
      NEW_EMBED_TARGET,
      "the carried target is not the picked paper's title",
    );
    assert.ok(
      !JSON.stringify(embedPick).includes(NEW_EMBED_DOC_ID),
      `the op carries the doc id ${NEW_EMBED_DOC_ID} — an embed target resolves by ` +
        "TITLE, so an id there never resolves",
    );
  });

  check("§5c the browse fetch is the scoped, PAPER-typed read the picker already does", () => {
    assert.ok(paperSearch, "the embed picker issued no search fetch");
    assert.equal(
      paperSearch.url,
      "/w/default/p/default/v1/data/search/production?q=retro&perspective=raw&limit=50&type=paper",
    );
    assert.equal(
      paperSearch.options.credentials,
      "same-origin",
      "the browse does not ride the caller's own session — the server cannot scope it",
    );
  });

  check("§5c the chip moved to the new target and the node grew no top-level attr", () => {
    const node = nodeOfType("bpEmbed");
    assert.deepEqual(
      Object.keys(node.attrs).sort(),
      ["bpBlock", "bpId", "bpType"],
      "the retarget moved the target OUT of the verbatim-carried block",
    );
    assert.equal(
      byTestId("paper-readonly-embed")
        .querySelector(".bp-canvas-readonly-chip")
        .textContent.trim(),
      `↪ ${NEW_EMBED_TARGET}`,
      "the summary chip still names the OLD target after a retarget",
    );
  });

  check("§5c the canvas never RESOLVES the transclusion — it reads no paper's content", () => {
    // RESOLVED CONTENT STAYS OUT OF REACH: the editor buys the ability to change the
    // POINTER and nothing else. A document READ of a paper would be the first step of
    // resolving one in-canvas. (The SHEET picker does issue a doc read — it seeds from
    // a doc id and resolves its title — so this is scoped to paper reads, not to "no
    // doc read at all", which would pass for the wrong reason.)
    const paperDocReads = fetches
      .map(({ url }) => url)
      .filter((url) => url.includes("/v1/data/doc/") && url.includes("/paper/"));
    assert.deepEqual(
      paperDocReads,
      [],
      "the canvas read a paper document — it is starting to resolve transclusions",
    );
  });

  const embedRepick = await drivePick("paper-retarget-embed", "retro");
  check("§5c re-picking the SAME paper emits ZERO ops", () => {
    assert.deepEqual(embedRepick, [], `a no-change re-pick emitted ${JSON.stringify(embedRepick)}`);
  });

  batches.length = 0;
  const embedPickerEl = byTestId("paper-retarget-embed");
  const embedRemove = embedPickerEl
    ? Array.from(embedPickerEl.querySelectorAll("button")).find((b) => b.textContent === "Remove")
    : null;
  if (embedRemove) embedRemove.click();
  canvas.flushPendingChanges();
  const embedClear = batches.slice();

  check("§5c CLEARING the embed picker is a no-op — a retarget cannot blank a target", () => {
    assert.deepEqual(embedClear, [], `a clear emitted ${JSON.stringify(embedClear)}`);
    assert.equal(
      nodeOfType("bpEmbed").attrs.bpBlock.target,
      NEW_EMBED_TARGET,
      "a clear blanked the carried target",
    );
  });

  // FREE TEXT. Type a title the mocked search does NOT return and press Enter. The
  // commit must land anyway: an UNRESOLVED target is a supported state (notes get
  // renamed; a cross-dataset draft points at something not created yet), and the
  // reader already paints its unresolved-transclusion fallback for it. A validate-on-save would
  // make those workflows impossible — so this check is the one that would red if a
  // resolution check were ever added on the way out.
  const TYPED_TARGET = "A Note Nobody Has Written Yet";
  batches.length = 0;
  const typeTarget = (pickerTestId, typed) => {
    const picker = byTestId(pickerTestId);
    if (!picker) return;
    const change = Array.from(picker.querySelectorAll("button")).find(
      (b) => b.textContent === "Change",
    );
    if (change) change.click();
    const input = picker.querySelector(".bp-ref-search-input");
    assert.ok(input, "the picker offers its real typeahead input for free text");
    input.value = typed;
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
    input.dispatchEvent(
      new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }),
    );
    canvas.flushPendingChanges();
  };
  typeTarget("paper-retarget-embed", TYPED_TARGET);
  const typedBatches = batches.slice();

  check("§5c a BARE TYPED title commits verbatim — an unresolved target still SAVES", () => {
    assert.equal(typedBatches.length, 1, "a typed commit emitted more than one batch");
    assert.deepEqual(embedOps(typedBatches), [
      { op: "patch-block", id: "em-1", patch: { target: TYPED_TARGET } },
    ]);
    assert.equal(
      nodeOfType("bpEmbed").attrs.bpBlock.target,
      TYPED_TARGET,
      "the typed title did not reach the carried block",
    );
  });

  check("§5c the SHEET picker has no free-text door — ids are not typed by hand", () => {
    // The negative twin of the check above, and the reason free text is a per-atom
    // spec rather than a shared behaviour: a sheet `ref` is a doc id, and a hand-typed
    // id is a dangling reference with no reader fallback that names it.
    batches.length = 0;
    typeTarget("paper-sheet-retarget", "not-a-real-sheet-id");
    assert.deepEqual(
      batches.slice(),
      [],
      "typing into the SHEET picker and pressing Enter committed a hand-typed ref",
    );
  });

  // ── §5d THE RETARGET IS UNDOABLE ────────────────────────────────────────────
  //
  // The row asks for selection, deletion, undo AND the retarget action. §3 proves
  // undo of a DELETE; nothing above proves undo of a RETARGET, and they are not the
  // same step: a delete removes a node (a structural step ProseMirror has always
  // undone), while a retarget rewrites `bpBlock` on a node that stays put. A
  // node-view that committed its value OUTSIDE a ProseMirror transaction — straight
  // onto the attrs object, or through a step marked `addToHistory: false` — would
  // pass every check above and still leave the author with no way back to the
  // reference they just replaced. That is the failure this section measures, and it
  // measures it on BOTH atoms because the two adapters commit different values.
  //
  // Driven against a SECOND, DIFFERENT reference on each atom, never a re-pick: a
  // re-pick emits zero ops (§5/§5c), so an undo across one would "restore" a value
  // that never moved and pass on an editor with no history at all.

  // ProseMirror's history groups steps that land close together in TIME into one undo
  // event (`newGroupDelay`, 500ms). That is right for typing and wrong for measuring
  // here: without a deliberate break, the sheet's commit joins §5c's embed commit and a
  // single undo reverses BOTH — which is how the first run of this section read a
  // "restored" embed target it had never set. So each arm closes the history first, and
  // then measures ONE retarget. (The grouping itself is default editor behaviour, not a
  // defect of the picker; the closing is how the measurement stays about the picker.)
  const startNewUndoStep = () => editor.view.dispatch(closeHistory(editor.state.tr));

  const ALT_REF = "alt-forecast";
  const refBeforeUndo = nodeOfType("bpSheet").attrs.bpBlock.ref;
  startNewUndoStep();
  const altPick = await drivePick("paper-sheet-retarget", "alt");

  check("§5d sheet: the retarget MOVED the ref (precondition — an undo needs something to undo)", () => {
    assert.equal(
      refBeforeUndo,
      NEW_REF,
      "precondition: the sheet did not carry the §5 ref going in, so this section is not measuring what it says",
    );
    assert.deepEqual(
      altPick.flat().filter((op) => op && op.id === "sh-1"),
      [{ op: "patch-block", id: "sh-1", patch: { ref: ALT_REF, snapshot: null } }],
      "the alternate sheet did not commit — §5d's undo would have nothing to reverse",
    );
    assert.equal(nodeOfType("bpSheet").attrs.bpBlock.ref, ALT_REF);
  });

  check("§5d sheet: undo restores the PREVIOUS ref, on the block and on the chip", () => {
    assert.equal(editor.commands.undo(), true, "undo reported no step for the sheet retarget — the commit is outside the history");
    assert.equal(
      nodeOfType("bpSheet").attrs.bpBlock.ref,
      refBeforeUndo,
      "undo did not put the sheet back on the ref it was retargeted away from",
    );
    assert.ok(
      byTestId("paper-readonly-sheet")
        .querySelector(".bp-canvas-readonly-chip")
        .textContent.includes(refBeforeUndo),
      "the block went back but the CHIP still names the undone ref — the author reads a lie",
    );
  });

  const UNDO_TARGET = "A Note Typed Then Taken Back";
  const targetBeforeUndo = nodeOfType("bpEmbed").attrs.bpBlock.target;
  batches.length = 0;
  startNewUndoStep();
  typeTarget("paper-retarget-embed", UNDO_TARGET);
  const undoTargetBatches = batches.slice();

  check("§5d embed: the retarget MOVED the target (precondition)", () => {
    assert.equal(
      targetBeforeUndo,
      TYPED_TARGET,
      "precondition: the embed did not carry the §5c target going in",
    );
    assert.deepEqual(embedOps(undoTargetBatches), [
      { op: "patch-block", id: "em-1", patch: { target: UNDO_TARGET } },
    ]);
    assert.equal(nodeOfType("bpEmbed").attrs.bpBlock.target, UNDO_TARGET);
  });

  check("§5d embed: undo restores the PREVIOUS target, on the block and on the chip", () => {
    assert.equal(editor.commands.undo(), true, "undo reported no step for the embed retarget — the commit is outside the history");
    assert.equal(
      nodeOfType("bpEmbed").attrs.bpBlock.target,
      targetBeforeUndo,
      "undo did not put the embed back on the target it was retargeted away from",
    );
    assert.ok(
      byTestId("paper-readonly-embed")
        .querySelector(".bp-canvas-readonly-chip")
        .textContent.includes(targetBeforeUndo),
      "the block went back but the CHIP still names the undone target",
    );
  });

  check("§5d neither undo touched the OTHER atom's reference", () => {
    // Two undos ran back to back. If a retarget commit rewrote more of the document
    // than its own node, the second undo would walk the first atom back further than
    // the section asked — and the whole section would still read green without this.
    assert.equal(nodeOfType("bpSheet").attrs.bpBlock.ref, NEW_REF);
    assert.equal(nodeOfType("bpEmbed").attrs.bpBlock.target, TYPED_TARGET);
  });

  // ── §5b WHERE THE AFFORDANCE IS NOT OFFERED ─────────────────────────────────
  //
  // Four independent nos, asserted on the exported predicate the node-view calls, so
  // each one is measured separately instead of being inferred from one mounted case.
  // The mounted negative below proves the predicate is the one that actually decides.

  check("§5b the predicate allows BOTH atoms and refuses a read-only editor, a locked block, a no-browse host, and an atom with no reference", () => {
    const yes = { bpType: "sheet", editor: { isEditable: true }, block: { ref: "a" }, scope: { pickerBrowse: true } };
    assert.equal(atomRetargetAllowed(yes), true, "precondition: the allowed sheet case IS allowed");
    // pd-ee-embed-retarget: `embed` USED to be a refusal here. It is now an allowed
    // case — asserting the refusal would assert the absence of the shipped feature.
    assert.equal(
      atomRetargetAllowed({ ...yes, bpType: "embed", block: { target: "A Note" } }),
      true,
      "embed is now an ALLOWED case (pd-ee-embed-retarget)",
    );
    // The refusal that replaces it: an atom kind with no retargetable reference. This
    // is what keeps the predicate from becoming vacuously true for everything.
    assert.equal(atomRetargetAllowed({ ...yes, bpType: "figure" }), false, "no retargetable reference");
    for (const bpType of ["sheet", "embed"]) {
      const base = { ...yes, bpType, block: bpType === "sheet" ? { ref: "a" } : { target: "A Note" } };
      assert.equal(atomRetargetAllowed({ ...base, editor: { isEditable: false } }), false, `${bpType}: read-only editor`);
      assert.equal(
        atomRetargetAllowed({ ...base, block: { ...base.block, locked: true } }),
        false,
        `${bpType}: template-locked block`,
      );
      assert.equal(atomRetargetAllowed({ ...base, scope: { pickerBrowse: false } }), false, `${bpType}: no browse grant`);
    }
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
      // pd-ee-embed-retarget: the embed atom is seeded here too. Measuring only the
      // sheet would leave the embed picker's browse grant unmeasured — the two mount
      // through the same predicate, but a check that never looks cannot say so.
      { id: "em-2", type: "embed", target: EMBED_TARGET },
    ];
    document.body.appendChild(locked);
    await new Promise((resolve) => setTimeout(resolve, 400));
    try {
      check("§5b MOUNTED: data-picker-browse=false mounts no retarget picker on EITHER atom", () => {
        for (const [label, atomTestId, pickerTestId, value] of [
          ["sheet", "paper-readonly-sheet", "paper-sheet-retarget", SHEET_REF],
          ["embed", "paper-readonly-embed", "paper-retarget-embed", EMBED_TARGET],
        ]) {
          const atom = locked.querySelector(`[data-test-id="${atomTestId}"]`);
          assert.ok(atom, `precondition: the ${label} atom mounted on the share-scoped canvas`);
          assert.ok(
            atom.textContent.includes(value),
            `precondition: the ${label} chip still shows its reference (the value stays READABLE)`,
          );
          assert.equal(
            locked.querySelectorAll(`[data-test-id="${pickerTestId}"]`).length,
            0,
            `a ${label} browse UI mounted under an item-share edit grant`,
          );
        }
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

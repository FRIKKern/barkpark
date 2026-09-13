// Mounted canvas regression for the SECTION-PRESET caret contract:
//
//   insert a preset → the declared placeholder is SELECTED (or the atom is
//   NodeSelection-ed) → the very next keystroke OVERTYPES it.
//
// This is the live half of the preset gate. smoke/autocomplete-slash.mjs proves the
// registry/assembly/op-shape purely; it CANNOT prove a selection, because a selection
// needs a real ProseMirror view. So this file mounts the actual <bp-paper-canvas>,
// runs the real palette command for ALL FOUR presets, and asserts the post-insert
// selection AND the result of typing one character into it.
//
// ANTI-VACUOUS BY CONSTRUCTION: every preset must reach the "typed" assertion, and
// the run fails if any preset's placeholder survives a keystroke — so weakening the
// caret placement in command-palette.js (dropping the setSelection, pointing at the
// wrong block, or collapsing the selection to a caret) reds this file. Verified by
// mutation: collapsing the TextSelection to a caret fails 3 of 4 presets; removing
// the NodeSelection branch fails the annotated-figure.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
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
// jsdom ships no scrollIntoView; the SlashMenu calls it to keep the active row in view.
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");

const { buildCommandRegistry } = await import("./command-palette.js");
const {
  CANVAS_SECTION_PRESETS,
  sectionPresetBlocks,
  sectionPresetCaretTarget,
} = await import("./section-presets.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

// A fresh mounted canvas holding ONE empty top-level paragraph — the resting state a
// palette insert fires from (caret in a top-level prose block).
async function freshCanvas() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [{ id: "body", type: "paragraph", content: [{ type: "text", value: "" }] }];
  document.body.appendChild(canvas);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  return canvas;
}

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${error.message}`);
  }
}

try {
  assert.equal(CANVAS_SECTION_PRESETS.length, 4, "four presets to prove");

  for (const preset of CANVAS_SECTION_PRESETS) {
    const canvas = await freshCanvas();
    const editor = canvas._editor;
    const registry = buildCommandRegistry(editor);
    const cmd = registry.find((c) => c.id === `preset-${preset.kind}`);

    check(`${preset.kind}: the palette carries an "Insert ${preset.label}" command`, () => {
      assert.ok(cmd, `preset-${preset.kind} is in the live editor's registry`);
      assert.equal(cmd.group, "Presets", "in the Presets group");
      assert.equal(cmd.label, `Insert ${preset.label}`, "distinctly named");
    });
    if (!cmd) continue;

    // Caret into the resting paragraph, then run the REAL palette command.
    editor.commands.setTextSelection(1);
    const ran = cmd.run(editor);

    const blocks = sectionPresetBlocks(preset.kind);
    const target = sectionPresetCaretTarget(preset.kind);
    const targetType = blocks[target.block].type;

    check(`${preset.kind}: the command inserts the whole ${blocks.length}-block assembly`, () => {
      assert.equal(ran, true, "run() reports the insert landed");
      assert.equal(
        editor.state.doc.content.childCount,
        blocks.length,
        `the resting paragraph was REPLACED by ${blocks.length} top-level blocks`,
      );
      assert.deepEqual(
        editor.state.doc.content.content.map((n) => n.attrs.bpType),
        blocks.map((b) => b.type),
        "in the documented order",
      );
    });

    // ── CRITERION 2: selected / focused for immediate overtype ────────────────
    const sel = editor.state.selection;
    const selNode = sel.node; // present ONLY on a NodeSelection

    check(`${preset.kind}: the caret lands on block ${target.block} (${targetType})`, () => {
      const landed = selNode || sel.$from.parent;
      assert.equal(
        landed.attrs.bpType,
        targetType,
        `the selection sits on the declared caret block (${targetType})`,
      );
    });

    if (target.placeholder === null) {
      check(`${preset.kind}: the data-viz atom is SELECTED (NodeSelection, no text hole)`, () => {
        assert.ok(selNode, "a NodeSelection, not a collapsed caret");
        assert.equal(selNode.attrs.bpType, targetType, `the ${targetType} atom is the selection`);
      });
    } else {
      check(`${preset.kind}: the placeholder text is SELECTED, not merely caret-adjacent`, () => {
        assert.ok(!selNode, "a TextSelection (the block has an inline text hole)");
        assert.ok(!sel.empty, "the selection is a RANGE, not a collapsed caret");
        assert.equal(
          editor.state.doc.textBetween(sel.from, sel.to),
          target.placeholder,
          "the selected text IS the declared placeholder",
        );
      });
    }

    // THE PROOF THAT MATTERS: one keystroke replaces what was selected.
    const before = editor.state.doc.textContent;
    if (target.placeholder !== null) {
      assert.ok(
        before.includes(target.placeholder),
        `${preset.kind}: precondition — the placeholder is in the doc before typing`,
      );
    }
    editor.commands.insertContent("Z");
    const after = editor.state.doc.textContent;

    check(`${preset.kind}: the NEXT keystroke overtypes the selection`, () => {
      if (target.placeholder === null) {
        // The atom had no text hole: typing REPLACES the selected node outright.
        assert.ok(
          !editor.state.doc.content.content.some((n) => n.attrs.bpType === targetType),
          `typing replaced the selected ${targetType} atom`,
        );
        assert.ok(after.includes("Z"), "the typed character landed");
      } else {
        assert.ok(
          !after.includes(target.placeholder),
          `the placeholder "${target.placeholder}" is GONE after one keystroke`,
        );
        assert.ok(after.includes("Z"), "the typed character landed in its place");
        assert.notEqual(after, before, "the doc text really changed");
      }
    });

    canvas.remove();
  }

  // ── PHASE 2: the DEGRADE seam (caret inside a callout body) ────────────────
  //
  // A preset fired from somewhere a replace would corrupt (a callout body, a list
  // item) inserts AFTER the enclosing top-level block instead. ProseMirror's own
  // selection mapping then leaves the caret in the ORIGINAL block — so here the
  // explicit caret placement is the ONLY thing that moves it onto the preset, for
  // both the text-hole and the atom arms. (In phase 1 the mapping already lands on a
  // replaced first block, which is why phase 2 exists: it is the arm that falsifies
  // the NodeSelection branch.)
  for (const preset of CANVAS_SECTION_PRESETS) {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [
      { id: "c1", type: "callout", tone: "info", content: [{ type: "text", value: "inside" }] },
    ];
    document.body.appendChild(canvas);
    await tick(350);
    const editor = canvas._editor;
    const registry = buildCommandRegistry(editor);
    const cmd = registry.find((c) => c.id === `preset-${preset.kind}`);

    // Caret INSIDE the callout body (depth 1, parent type "callout" → the guard
    // refuses the replace and degrades to an insert-after).
    editor.commands.setTextSelection(2);
    const parentBefore = editor.state.selection.$from.parent.type.name;
    const blocks = sectionPresetBlocks(preset.kind);
    const target = sectionPresetCaretTarget(preset.kind);
    const targetType = blocks[target.block].type;
    const ran = cmd.run(editor);

    check(`${preset.kind}: from inside a callout body the preset is inserted AFTER it`, () => {
      assert.equal(parentBefore, "callout", "precondition — the caret really was in the callout body");
      assert.equal(ran, true, "run() reports the insert landed");
      assert.equal(
        editor.state.doc.content.childCount,
        1 + blocks.length,
        "the callout SURVIVES and the assembly lands after it",
      );
      assert.equal(
        editor.state.doc.content.child(0).attrs.bpType,
        "callout",
        "the enclosing callout was not replaced",
      );
    });

    const sel = editor.state.selection;
    const selNode = sel.node;

    check(`${preset.kind}: the degraded insert still moves the caret onto the preset`, () => {
      const landed = selNode || sel.$from.parent;
      assert.notEqual(landed.attrs.bpId, "c1", "the caret LEFT the origin callout");
      assert.equal(landed.attrs.bpType, targetType, `it sits on the declared ${targetType} block`);
      if (target.placeholder === null) {
        assert.ok(selNode, "the atom is NodeSelection-ed (not a caret left behind)");
      } else {
        assert.ok(!sel.empty, "the placeholder is a RANGE selection");
        assert.equal(
          editor.state.doc.textBetween(sel.from, sel.to),
          target.placeholder,
          "the selected text IS the declared placeholder",
        );
      }
    });

    editor.commands.insertContent("Z");
    check(`${preset.kind}: the degraded insert is overtypeable too`, () => {
      const after = editor.state.doc.textContent;
      assert.ok(after.startsWith("inside"), "the origin callout text is untouched");
      if (target.placeholder === null) {
        assert.ok(
          !editor.state.doc.content.content.some((n) => n.attrs.bpType === targetType),
          `typing replaced the selected ${targetType} atom`,
        );
      } else {
        assert.ok(!after.includes(target.placeholder), "the placeholder is GONE after one keystroke");
      }
      assert.ok(after.includes("Z"), "the typed character landed");
    });

    canvas.remove();
  }
  // ── PHASE 3: the canvas "/" SLASH MENU offers the same four presets ────────
  //
  // The palette (Mod-p) and the slash menu are two doors onto one registry. This phase
  // opens the REAL SlashMenu and picks the row IT built — no synthesized item — so a
  // preset that reaches the palette but never the slash menu is caught here.
  {
    const canvas = await freshCanvas();
    const editor = canvas._editor;
    canvas._openSlash("");
    await tick(0);
    const rows = (canvas._slash?._items || []).filter((it) => it.group === "Presets");

    check("slash menu: the four presets are offered as Presets rows", () => {
      assert.equal(rows.length, 4, "four Presets rows in the live slash menu");
      assert.deepEqual(
        rows.map((r) => r.preset),
        CANVAS_SECTION_PRESETS.map((p) => p.kind),
        "one row per preset kind, in registry order",
      );
      assert.deepEqual(
        rows.map((r) => r.label),
        CANVAS_SECTION_PRESETS.map((p) => p.label),
        "each row carries the preset's distinct name",
      );
    });

    // Pick the masthead row THE MENU BUILT, through the real _chooseSlash.
    editor.commands.setTextSelection(1);
    canvas._chooseSlash(rows[0]);
    check("slash menu: picking the Masthead row inserts the 7-block assembly, placeholder selected", () => {
      assert.equal(editor.state.doc.content.childCount, 7, "seven top-level blocks landed");
      const sel = editor.state.selection;
      assert.equal(
        editor.state.doc.textBetween(sel.from, sel.to),
        sectionPresetCaretTarget("masthead").placeholder,
        "the kicker placeholder is selected for overtype",
      );
    });
    canvas.remove();
  }
} catch (error) {
  failures += 1;
  console.log(`FAIL  section-presets mounted harness: ${error.message}`);
}

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nsection presets: caret + overtype PASS for all four presets");
process.exit(0);

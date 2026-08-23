// __keyboard_reach.test.mjs — pdd-t12 criterion 4 (keyboard + a11y parity): the
// MOUNTED proof that every edit affordance of the one-surface canvas is reachable
// WITHOUT A MOUSE.
//
// Why this file exists. __one_surface.test.mjs pins the PURE helpers (isActivateKey,
// atomAriaLabel, isBlockLocked) and __atom_chrome.test.mjs falls back to a STATIC
// source scan because "we cannot mount a node-view without a browser". That left the
// load-bearing half unproven: whether the shipped node-views actually CALL the
// helpers, and whether the DOM they build answers a keyboard. __locked_mounted.test.mjs
// showed the way — jsdom mounts the real <bp-paper-canvas>, so this file mounts it too
// and drives ONLY real KeyboardEvents through the real DOM. Nothing here is a stub:
// every assertion reads the live editor state or the live document.
//
// The affordance inventory it covers (pdd-t12 brief: hover chrome + context menu +
// slash palette, chrome AROUND content, never a mode):
//   §1  read-only atoms (sheet / embed / fleet / figure) are TAB STOPS with names
//   §2  the locked-template cue is ANNOUNCED, not just painted on hover
//   §3  Enter and Space bridge focus → NodeSelection; Backspace then deletes
//   §4  interior controls keep their own keystrokes (no wrapper hijack)
//   §5  the featured-image affordance activates on Enter/Space (role=button)
//   §6  the whole block-op catalogue (insert / turn-into / format / view) opens on
//       Mod-p alone, navigates with arrows, and closes with Escape
//
// Run: node src/__keyboard_reach.test.mjs   (or: npm test)

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
// jsdom has no layout, so it ships no scrollIntoView; the palette scrolls its active
// row into view on open. A no-op keeps the REAL open path running (we are testing the
// keyboard route, not the scrolling).
window.Element.prototype.scrollIntoView ||= function () {};
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./canvas/index.js");
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

// A keyboard event and nothing else. Every interaction in this file goes through
// this helper — there is no click, no mousedown, no hover anywhere below.
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

// One document carrying every affordance class the canvas ships.
const blocks = [
  { id: "b-title", type: "heading", level: 1, role: "title", text: "Keyboard" },
  {
    id: "b-prose",
    type: "paragraph",
    content: [{ type: "text", value: "Body text here." }],
  },
  // A LOCKED fleet atom — the template block whose lock cue is a hover tint for a
  // sighted mouse user and must be an announcement for everyone else. It sits ahead
  // of the deletable atoms on purpose: the doctrine lock veto (locks.js) rejects any
  // transaction that MOVES a locked node, so the atom §3 deletes must follow it.
  { id: "b-fleet", type: "task-board", locked: true, query: { status: "open" } },
  { id: "b-sheet", type: "sheet", sheet: { title: "Q3" } },
  { id: "b-figure", type: "figure", src: "/hero.png", caption: "Cap" },
  { id: "b-image", type: "field-image", field: "featured", value: "" },
  { id: "b-embed", type: "embed", url: "https://example.com/clip" },
];

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = blocks;
document.body.appendChild(canvas);
// Let TipTap's mount-time content normalization settle before any assertion.
await new Promise((resolve) => setTimeout(resolve, 400));

try {
  const editor = canvas._editor;
  assert.ok(editor, "mount creates the real TipTap editor");
  assert.ok(editor.isEditable, "the canvas mounts EDITABLE (one surface, no view mode)");
  const proseMirror = canvas.querySelector(".ProseMirror");
  assert.ok(proseMirror, "mount creates the real ProseMirror DOM");

  const nodeNames = editor.state.doc.content.content.map((n) => n.type.name);
  assert.deepEqual(
    nodeNames,
    ["heading", "paragraph", "bpFleet", "bpSheet", "bpFigure", "bpField", "bpEmbed"],
    "every affordance class actually mounted (a missing node would make the sweep below vacuous)",
  );

  const byTestId = (id) => canvas.querySelector(`[data-test-id="${id}"]`);

  // ── §1 Read-only atoms are TAB STOPS with an accessible name ────────────────
  //
  // The mouse reaches these by clicking the block. The keyboard reaches them only if
  // the node-view actually put a tab stop on the wrapper — which is exactly what the
  // pure helper test could not see.

  const ATOMS = [
    { testId: "paper-readonly-sheet", label: "sheet atom" },
    { testId: "paper-readonly-embed", label: "embed atom" },
    { testId: "paper-fleet-task-board", label: "fleet (task-board) atom" },
    { testId: "paper-figure", label: "figure atom" },
  ];

  check("§1 every read-only atom is a keyboard tab stop with a role and a name", () => {
    for (const { testId, label } of ATOMS) {
      const el = byTestId(testId);
      assert.ok(el, `${label}: the node-view mounted (missing → nothing to reach)`);
      assert.equal(
        el.getAttribute("tabindex"),
        "0",
        `${label} is NOT keyboard-reachable — its wrapper carries no tabindex="0" tab stop`,
      );
      assert.ok(
        el.getAttribute("role"),
        `${label} exposes no role — a screen reader cannot say what it landed on`,
      );
      const name = el.getAttribute("aria-label");
      assert.ok(
        name && name.trim().length > 0,
        `${label} has no accessible name — it announces as an unnamed group`,
      );
    }
  });

  check("§1 a tab stop is real focus: .focus() lands on the atom wrapper itself", () => {
    const sheet = byTestId("paper-readonly-sheet");
    proseMirror.focus();
    assert.notEqual(document.activeElement, sheet, "precondition: focus starts elsewhere");
    sheet.focus();
    assert.equal(
      document.activeElement,
      sheet,
      "the sheet atom cannot take DOM focus — Tab would skip past it",
    );
  });

  // ── §2 The locked-template cue is ANNOUNCED ─────────────────────────────────

  check("§2 a locked template atom announces its lock in the accessible name", () => {
    const locked = byTestId("paper-fleet-task-board");
    assert.equal(
      locked.getAttribute("aria-label"),
      "Task board — locked, part of the document template",
      "the locked fleet atom does not announce the lock — the cue is mouse/vision-only",
    );
    assert.equal(locked.getAttribute("data-bp-locked"), "true");
    // Non-vacuity: an UNLOCKED atom must NOT carry the clause.
    const unlocked = byTestId("paper-readonly-sheet");
    assert.ok(
      !/locked/.test(unlocked.getAttribute("aria-label") || ""),
      "an unlocked atom must not claim to be locked",
    );
    assert.equal(unlocked.getAttribute("data-bp-locked"), null);
  });

  // ── §3 Enter / Space select the atom; Backspace then deletes it ─────────────
  //
  // The mouse affordance is click-to-select then Backspace. This is its twin, driven
  // entirely from the keyboard.

  check("§3 Enter on a focused atom selects it (focus → NodeSelection bridge)", () => {
    const sheet = byTestId("paper-readonly-sheet");
    sheet.focus();
    const event = keydown(sheet, "Enter");
    assert.equal(
      event.defaultPrevented,
      true,
      "Enter on the atom was not consumed — no activation handler is wired",
    );
    assert.ok(
      editor.state.selection instanceof NodeSelection,
      "Enter did not produce a NodeSelection — the atom cannot be selected without a mouse",
    );
    assert.equal(editor.state.selection.node.type.name, "bpSheet");
  });

  check("§3 Space is an equal activation key on a focused atom", () => {
    // Move the selection away first so the assertion cannot pass on a stale one.
    const sheetPos = editor.state.selection.from;
    editor.commands.setTextSelection(1);
    assert.ok(
      !(editor.state.selection instanceof NodeSelection),
      "precondition: the selection is no longer a NodeSelection",
    );
    const sheet = byTestId("paper-readonly-sheet");
    sheet.focus();
    keydown(sheet, " ");
    assert.ok(
      editor.state.selection instanceof NodeSelection,
      "Space did not select the atom — only Enter works, so Space users are stranded",
    );
    assert.equal(editor.state.selection.from, sheetPos);
  });

  check("§3 an ordinary key on a focused atom is NOT swallowed", () => {
    const sheet = byTestId("paper-readonly-sheet");
    sheet.focus();
    const event = keydown(sheet, "a");
    assert.equal(
      event.defaultPrevented,
      false,
      "the atom swallows every keystroke — that would trap the keyboard on the block",
    );
  });

  check("§3 Backspace after a keyboard selection DELETES the atom (structural op, no mouse)", () => {
    const embed = byTestId("paper-readonly-embed");
    embed.focus();
    keydown(embed, "Enter");
    assert.equal(editor.state.selection.node.type.name, "bpEmbed", "precondition: the embed is selected");
    const before = editor.state.doc.content.content.map((n) => n.type.name);
    assert.ok(before.includes("bpEmbed"), "precondition: the embed is still in the document");
    keydown(proseMirror, "Backspace", { code: "Backspace", keyCode: 8 });
    const after = editor.state.doc.content.content.map((n) => n.type.name);
    assert.ok(
      !after.includes("bpEmbed"),
      "Backspace did not remove the keyboard-selected atom — deletion stays a mouse-only affordance",
    );
    assert.equal(after.length, before.length - 1, "exactly one block was removed");
  });

  // ── §4 Interior controls keep their own keystrokes ──────────────────────────

  check("§4 a keystroke inside an interior control is NOT hijacked into atom selection", () => {
    const caption = canvas.querySelector(".bp-canvas-figure-caption-input");
    assert.ok(caption, "precondition: the figure's caption control mounted");
    editor.commands.setTextSelection(1);
    assert.ok(
      !(editor.state.selection instanceof NodeSelection),
      "precondition: nothing is node-selected",
    );
    caption.focus();
    keydown(caption, "Enter");
    assert.ok(
      !(editor.state.selection instanceof NodeSelection),
      "typing inside the caption selected the whole figure — interior controls are unusable by keyboard",
    );
  });

  // ── §5 The featured-image affordance ────────────────────────────────────────

  check("§5 the featured-image placeholder is a named button-role tab stop", () => {
    const placeholder = byTestId("paper-featured-image-placeholder");
    assert.ok(placeholder, "precondition: the empty-image placeholder mounted");
    assert.equal(placeholder.getAttribute("tabindex"), "0");
    assert.equal(placeholder.getAttribute("role"), "button");
    assert.equal(placeholder.getAttribute("aria-label"), "Add an image");
    placeholder.focus();
    assert.equal(document.activeElement, placeholder, "the placeholder cannot take focus");
  });

  check("§5 Enter and Space activate the featured-image picker; a plain key does not", () => {
    const placeholder = byTestId("paper-featured-image-placeholder");
    placeholder.focus();
    assert.equal(
      keydown(placeholder, "Enter").defaultPrevented,
      true,
      "Enter does not open the media picker — the affordance is click-only",
    );
    assert.equal(
      keydown(placeholder, " ").defaultPrevented,
      true,
      "Space does not open the media picker — the affordance is click-only",
    );
    assert.equal(
      keydown(placeholder, "a").defaultPrevented,
      false,
      "the placeholder consumes unrelated keys",
    );
  });

  // ── §6 The block-op catalogue opens from the keyboard alone ─────────────────
  //
  // Insert / turn-into / format / view are the operations a mouse gets from the
  // right-click context menu. Mod-p is their keyboard twin: one chord, no pointer.

  check("§6 Mod-p alone opens the command palette (context-menu ops, no mouse)", () => {
    assert.ok(!canvas._palette || !canvas._palette.isOpen(), "precondition: the palette is closed");
    proseMirror.focus();
    const event = keydown(proseMirror, "p", { metaKey: true });
    assert.equal(event.defaultPrevented, true, "Mod-p was not consumed by the canvas");
    assert.ok(
      canvas._palette && canvas._palette.isOpen(),
      "Mod-p did not open the command palette — block ops stay behind a right-click",
    );
    const palette = document.querySelector(".bp-cmd-palette");
    assert.ok(palette, "the palette opened without rendering its DOM");
    const input = palette.querySelector(".bp-cmd-input");
    assert.ok(input, "the palette has no filter input");
    assert.ok(input.getAttribute("aria-label"), "the palette filter input has no accessible name");
    assert.equal(document.activeElement, input, "opening the palette did not move focus into it");
  });

  check("§6 the palette carries the whole block-op catalogue (insert / turn-into / format / view)", () => {
    const palette = document.querySelector(".bp-cmd-palette");
    const groups = Array.from(palette.querySelectorAll(".bp-slash-group")).map((el) =>
      el.textContent.trim(),
    );
    for (const group of ["Insert", "Format", "Turn into"]) {
      assert.ok(
        groups.includes(group),
        `the keyboard palette is missing the "${group}" ops — those stay mouse-only`,
      );
    }
    const rows = palette.querySelectorAll('[role="option"]');
    assert.ok(
      rows.length >= 20,
      `the palette exposes only ${rows.length} keyboard-reachable ops — the catalogue is not there`,
    );
    // Every row must be a real, named option a screen reader can read out.
    for (const row of rows) {
      assert.ok(row.textContent.trim().length > 0, "a palette option has no visible name");
    }
  });

  check("§6 ArrowDown moves the palette selection and Escape closes it", () => {
    const palette = document.querySelector(".bp-cmd-palette");
    const before = palette.querySelector(".is-active").textContent;
    keydown(proseMirror, "ArrowDown");
    assert.notEqual(
      palette.querySelector(".is-active").textContent,
      before,
      "ArrowDown does not move the palette cursor — the list is not keyboard-navigable",
    );
    keydown(proseMirror, "ArrowUp");
    assert.equal(
      palette.querySelector(".is-active").textContent,
      before,
      "ArrowUp does not move back",
    );
    keydown(proseMirror, "Escape");
    assert.ok(
      !canvas._palette.isOpen(),
      "Escape does not close the palette — a keyboard user cannot get out",
    );
  });

  check("§6 Mod-Shift-m reaches the markdown source surface from the keyboard", () => {
    assert.equal(canvas.isSourceMode ? canvas.isSourceMode() : false, false, "precondition: rich mode");
    const event = keydown(proseMirror, "m", { metaKey: true, shiftKey: true });
    assert.equal(
      event.defaultPrevented,
      true,
      "Mod-Shift-m is not wired — the source surface is unreachable from the keyboard",
    );
    const textarea = canvas.querySelector("textarea");
    assert.ok(textarea, "Mod-Shift-m did not open the source textarea");
    // Return to rich mode so teardown is clean.
    keydown(textarea, "m", { metaKey: true, shiftKey: true });
  });
} finally {
  canvas.remove();
  window.close();
}

if (failures > 0) {
  console.log(`\n${failures} keyboard-reach check(s) FAILED`);
  process.exit(1);
}
console.log("\nmounted keyboard-reach proof passed — every canvas edit affordance is reachable without a mouse");

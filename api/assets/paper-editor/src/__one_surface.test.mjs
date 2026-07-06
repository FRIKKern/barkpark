// __one_surface.test.mjs — pure-Node unit test for pdd-t12c (one-surface parity
// polish): the keyboard + screen-reader helpers that make the canvas read-only
// atoms (sheet / embed / fleet) reachable and announceable without a mouse.
//
// Pure by construction: imports ONLY the DOM-free helpers from embed-node.js (the
// Node.create schema + its chip-label helpers load in plain Node; the NodeView
// factory — the only `document`/`editor` toucher — never runs here). The node-view
// WIRING that consumes these (tabindex/role/aria on the wrapper, the Enter/Space →
// NodeSelection bridge, interior link/form interactivity) is browser-only and is on
// the PR's manual-verify list. Run: node src/__one_surface.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import {
  isBlockLocked,
  atomAriaLabel,
  isActivateKey,
  sheetChipLabel,
  embedChipLabel,
  fleetChipLabel,
} from "./canvas/embed-node.js";

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

// ── isBlockLocked: locks are a STRICT `locked === true` flag ─────────────────────

check("isBlockLocked: only literal true is locked; everything else is not", () => {
  assert.equal(isBlockLocked({ locked: true }), true);
  assert.equal(isBlockLocked({ locked: false }), false);
  assert.equal(isBlockLocked({}), false);
  assert.equal(isBlockLocked(null), false);
  assert.equal(isBlockLocked(undefined), false);
  // Truthy-but-not-true never counts (mirrors the server's strict contract).
  assert.equal(isBlockLocked({ locked: "true" }), false);
  assert.equal(isBlockLocked({ locked: 1 }), false);
});

// ── atomAriaLabel: the accessible name = the visible chip + a locked clause ──────

check("atomAriaLabel: an unlocked atom's name IS its chip text (no decoration)", () => {
  assert.equal(atomAriaLabel("Task board", { type: "task-board" }), "Task board");
  assert.equal(atomAriaLabel("Sheet · Q3 · 4×3", {}), "Sheet · Q3 · 4×3");
});

check("atomAriaLabel: a locked atom appends the immovable-template clause", () => {
  assert.equal(
    atomAriaLabel("Task board", { type: "task-board", locked: true }),
    "Task board — locked, part of the document template",
  );
});

check("atomAriaLabel: a missing/blank chip degrades to a legible name, never empty", () => {
  assert.equal(atomAriaLabel("", {}), "Block");
  assert.equal(atomAriaLabel(undefined, {}), "Block");
  assert.equal(atomAriaLabel(null, { locked: true }), "Block — locked, part of the document template");
});

// The accessible name is DERIVED from the same chip-label helper the sighted user
// sees — never hand-mirrored — so the two can never drift (rule 3 in miniature).
check("atomAriaLabel: stays in lockstep with each atom's own chip-label helper", () => {
  const fleet = { type: "cards" };
  assert.equal(atomAriaLabel(fleetChipLabel(fleet), fleet), fleetChipLabel(fleet));

  const sheet = { ref: "Ledger", snapshot: { rows: [[1, 2], [3, 4]] } };
  assert.equal(atomAriaLabel(sheetChipLabel(sheet), sheet), sheetChipLabel(sheet));

  const embed = { target: "design-notes" };
  assert.equal(atomAriaLabel(embedChipLabel(embed), embed), embedChipLabel(embed));

  // …and a locked sheet carries BOTH the live chip text and the lock clause.
  const lockedSheet = { ref: "Ledger", snapshot: { rows: [[1]] }, locked: true };
  assert.equal(
    atomAriaLabel(sheetChipLabel(lockedSheet), lockedSheet),
    `${sheetChipLabel(lockedSheet)} — locked, part of the document template`,
  );
});

// ── isActivateKey: Enter / Space select the focused atom (→ Backspace deletes) ───

check("isActivateKey: Enter and both Space spellings activate; nothing else does", () => {
  assert.equal(isActivateKey({ key: "Enter" }), true);
  assert.equal(isActivateKey({ key: " " }), true);
  assert.equal(isActivateKey({ key: "Spacebar" }), true); // legacy Edge/IE spelling
  assert.equal(isActivateKey({ key: "a" }), false);
  assert.equal(isActivateKey({ key: "Tab" }), false);
  assert.equal(isActivateKey({ key: "Backspace" }), false);
  assert.equal(isActivateKey(null), false);
  assert.equal(isActivateKey(undefined), false);
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall one-surface parity-polish checks passed");

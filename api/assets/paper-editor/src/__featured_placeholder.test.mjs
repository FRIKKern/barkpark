// __featured_placeholder.test.mjs — pure-Node unit test for the t13 featured-image
// PLACEHOLDER decision + copy (pd-doctrine rule 1 + 5). Imports ONLY the DOM-free
// pure helpers from field-node.js — never touches `document` / TipTap / HTMLElement,
// so it runs in plain Node exactly like __wikilink.test.mjs / __callout_shorthand.test.mjs.
//
// CARVE-OUT: the ghost-frame DOM, the reveal-on-activate swap, and the actual
// media-picker `bp-change` → patch wiring are BROWSER-ONLY (they live in
// buildPickerNodeView's node-view) and are exercised in the live editor. What is pure
// and pinned here: WHEN the placeholder shows (isEmptyPickerValue / imagePlaceholderModel),
// its copy, and that a chosen asset's value flows through coercePickerValue as the patch
// value (the identity the node-view commits on selection).
//
// Run: node src/__featured_placeholder.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import {
  isEmptyPickerValue,
  imagePlaceholderModel,
  coercePickerValue,
  canvasScope,
  IMAGE_PLACEHOLDER_LABEL,
  IMAGE_PLACEHOLDER_HINT,
} from "./canvas/field-node.js";

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

// ── isEmptyPickerValue: "no asset yet" — the SAME emptiness the reader skips on ──

check("isEmptyPickerValue: null / undefined / '' / whitespace are all empty", () => {
  assert.equal(isEmptyPickerValue(null), true);
  assert.equal(isEmptyPickerValue(undefined), true);
  assert.equal(isEmptyPickerValue(""), true);
  assert.equal(isEmptyPickerValue("   "), true);
  assert.equal(isEmptyPickerValue("\t\n "), true);
});

check("isEmptyPickerValue: any real value is NOT empty", () => {
  assert.equal(isEmptyPickerValue("/media/files/hero.jpg"), false);
  assert.equal(isEmptyPickerValue("drafts.asset-abc"), false);
  assert.equal(isEmptyPickerValue("https://cdn.example/hero.png"), false);
});

check("canvasScope carries scoped picker confinement from the canvas host", () => {
  const attrs = new Map([
    ["data-dataset", "production"],
    ["data-scope-prefix", "/w/acme/p/books"],
    ["data-token", ""],
    ["data-picker-browse", "false"],
  ]);
  const editor = {
    options: {
      element: {
        closest: () => ({ getAttribute: (name) => attrs.get(name) ?? null }),
      },
    },
  };

  assert.deepEqual(canvasScope(editor), {
    dataset: "production",
    scopePrefix: "/w/acme/p/books",
    token: "",
    pickerBrowse: false,
  });
});

// ── imagePlaceholderModel: the ghost frame shows ONLY for an asset-less image ───

check("imagePlaceholderModel: field-image with NO asset → show the frame", () => {
  const m = imagePlaceholderModel("field-image", "");
  assert.equal(m.show, true, "an empty image picker shows the placeholder");
  assert.equal(m.label, IMAGE_PLACEHOLDER_LABEL);
  assert.equal(m.hint, IMAGE_PLACEHOLDER_HINT);
  assert.equal(m.ariaLabel, IMAGE_PLACEHOLDER_LABEL, "keyboard-reachable: the aria-label carries the action");
});

check("imagePlaceholderModel: field-image with an asset → NO frame (WC preview shows)", () => {
  assert.equal(imagePlaceholderModel("field-image", "/media/files/hero.jpg").show, false);
  assert.equal(imagePlaceholderModel("field-image", "drafts.asset-abc").show, false);
});

check("imagePlaceholderModel: a whitespace-only value still shows the frame", () => {
  assert.equal(imagePlaceholderModel("field-image", "   ").show, true);
});

check("imagePlaceholderModel: field-reference NEVER shows the image frame", () => {
  // A reference's empty state is its own typeahead pill — unchanged by t13.
  assert.equal(imagePlaceholderModel("field-reference", "").show, false);
  assert.equal(imagePlaceholderModel("field-reference", "doc-123").show, false);
});

check("imagePlaceholderModel copy is the calm doctrine chrome (not a raw/empty look)", () => {
  // GENERIC copy by design: a field-image node is a schema image FIELD (cover,
  // portrait, …) — its own label renders above the frame. The "featured" copy
  // lives where role is known: the per-block path's
  // [data-block-role="featured"] CSS (root.html.heex).
  assert.equal(IMAGE_PLACEHOLDER_LABEL, "Add an image");
  assert.ok(/media library/i.test(IMAGE_PLACEHOLDER_HINT), "the hint points at the picker");
});

check("imagePlaceholderModel: the aria-label carries the FIELD label when present", () => {
  // The visible copy stays generic, but a screen reader hears WHICH image
  // field the button fills.
  assert.equal(
    imagePlaceholderModel("field-image", "", "Cover").ariaLabel,
    IMAGE_PLACEHOLDER_LABEL + " — Cover"
  );
  // Absent / blank labels degrade to the bare action.
  assert.equal(imagePlaceholderModel("field-image", "", null).ariaLabel, IMAGE_PLACEHOLDER_LABEL);
  assert.equal(imagePlaceholderModel("field-image", "", "   ").ariaLabel, IMAGE_PLACEHOLDER_LABEL);
});

// ── picker-open → selection value flows as the committed patch value (identity) ──

check("coercePickerValue: a chosen asset's bp-change value IS the committed value", () => {
  // The media picker fires bp-change{detail:{value}}; the node-view commits exactly
  // that value (setNodeMarkup → patch-block). A selection replaces the empty state.
  assert.equal(coercePickerValue({ value: "/media/files/2026/07/hero.jpg" }), "/media/files/2026/07/hero.jpg");
});

check("coercePickerValue: a CLEAR (missing/empty detail) coerces to '' → frame returns", () => {
  assert.equal(coercePickerValue({}), "");
  assert.equal(coercePickerValue(null), "");
  assert.equal(coercePickerValue({ value: null }), "");
  // …and an empty committed value re-triggers the placeholder decision.
  assert.equal(imagePlaceholderModel("field-image", coercePickerValue({})).show, true);
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall featured-placeholder checks passed");

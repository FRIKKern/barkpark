// __picker_reference_hit_type_apart.test.mjs — task-522073bdad4a7ad2: in a
// reference picker over several types, a hit whose type has no list preview
// ran its title into its type word ("RettsdataVirksomhet" on gyl, 2026-10-19).
// The bare title was a text node in a block button, and the type span came
// right after it. Now every hit puts its title in the .bp-ref-hit-main column,
// the row is a flex row, and a space separates each trailing word.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom, and reads the row's CSS from the root layout.
//
// Run: node src/__picker_reference_hit_type_apart.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "KeyboardEvent", "MouseEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;

globalThis.fetch = window.fetch = async () => ({
  ok: true,
  json: async () => ({
    documents: [
      { _id: "dept-1", _type: "department", title: "Avdeling Nord" },
      { _id: "person-1", _type: "person", title: "Kari Nord", _preview: { subtitle: "Redaktør" } },
      { _id: "drafts.org-1", _type: "organization", title: "Nordlag" },
    ],
  }),
});

await import("../../../priv/static/assets/bp-reference-picker.js");

try {
  const shell = document.createElement("div");
  shell.setAttribute("data-type-labels", JSON.stringify({ department: "Virksomhet", person: "Person", organization: "Ekstern organisasjon" }));
  const picker = document.createElement("bp-reference-picker");
  picker.setAttribute("ref-type", "department,person,organization");
  shell.appendChild(picker);
  document.body.appendChild(shell);
  await new Promise((r) => setTimeout(r, 10));

  picker.querySelector(".bp-ref-search-input").focus();
  await picker._search("Nord");

  const items = [...picker.querySelectorAll(".bp-ref-dropdown-item")];
  assert.equal(items.length, 3);
  const [bare, withPreview, draft] = items;

  // The bare hit reads as two words (main read "Avdeling NordVirksomhet").
  assert.equal(bare.textContent, "Avdeling Nord Virksomhet");
  assert.equal(bare.querySelector(".bp-ref-hit-main .bp-ref-hit-title").textContent, "Avdeling Nord", "the title sits in the title column");
  const type = bare.querySelector(".bp-ref-hit-type");
  assert.equal(type.textContent, "Virksomhet");
  assert.equal(type.parentElement, bare, "the type word is its own item in the row, after the title column");
  assert.equal(bare.lastElementChild, type);
  assert.equal(bare.querySelector(".bp-ref-hit-main .bp-ref-hit-type"), null, "the type word is not inside the title column");

  // A hit with a preview has the same structure: title column, then type.
  assert.equal(withPreview.querySelector(".bp-ref-hit-main .bp-ref-hit-title").textContent, "Kari Nord");
  assert.equal(withPreview.lastElementChild.className, "bp-ref-suggest-meta bp-ref-hit-type");
  assert.equal(withPreview.textContent, "Kari NordRedaktør Person");

  // A draft badge after the type word is a separate word too.
  assert.equal(draft.textContent, "Nordlag Ekstern organisasjon draft");

  // The row lays its children out side by side with a gap, for every hit.
  const css = readFileSync(new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url), "utf8");
  const rule = css.match(/bp-reference-picker \.bp-ref-dropdown-item \{([^}]*)\}/);
  assert.ok(rule, "the root layout styles .bp-ref-dropdown-item");
  assert.match(rule[1], /display:\s*flex/, "every hit row is a flex row");
  assert.match(rule[1], /gap:\s*\d+px/, "with a gap between title column and type word");
  const main = css.match(/bp-reference-picker \.bp-ref-hit-main \{([^}]*)\}/);
  assert.match(main[1], /flex:\s*1/, "the title column takes the free width, so the type word sits at the end");

  console.log("reference picker hit type apart: all checks passed");
} finally {
  window.close();
}

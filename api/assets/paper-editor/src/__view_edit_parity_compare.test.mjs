// The comparison half of the View/Edit parity matrix, proven without a browser.
//
// __view_edit_parity_matrix.mjs needs Chromium and a compiled api tree, so it
// cannot run inside `npm test`. What CAN run here is the part that decides
// pass/fail: given owner maps, does a planted style change surface as an
// UNEXPECTED divergence, does the known ledger tolerate exactly what it lists,
// and does a ledger entry that stopped firing come back as STALE?

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { AXES, MISSING, classify, diffSurface, keyOf, staleEntries } from "./view-edit-parity-compare.js";

const base = Object.fromEntries(AXES.map((axis) => [axis, `v-${axis}`]));
const style = (over = {}) => ({ ...base, tag: "p", ...over });

const view = {
  caption: { owners: { "A caption": style({ letterSpacing: "0.09px", textRendering: "optimizelegibility" }) } },
  body: { owners: { "Body copy": style() } },
};
const identical = {
  caption: { owners: { "A caption": [style({ letterSpacing: "0.09px", textRendering: "optimizelegibility", role: "text" }), style({ letterSpacing: "0.09px", textRendering: "optimizelegibility", role: "control" })] } },
  body: { owners: { "Body copy": [style()] } },
};

// 1. Identical owners: zero divergences, and every owner pair was compared.
{
  const r = diffSurface({ surface: "liveview", fixtures: ["caption", "body"], view, edit: identical });
  assert.equal(r.differences.length, 0);
  assert.equal(r.compared, 3, "both caption owners (paint + control) and the body owner are compared");
}

// 2. A planted change on ONE of two owners of the same text is caught — the
//    resting paint can match while the textarea behind it does not.
{
  const planted = structuredClone(identical);
  planted.caption.owners["A caption"][1].letterSpacing = "normal";
  const r = diffSurface({ surface: "liveview", fixtures: ["caption", "body"], view, edit: planted });
  assert.deepEqual(r.differences.map((d) => [d.fixture, d.axis, d.view, d.edit, d.editRole]), [
    ["caption", "letterSpacing", "0.09px", "normal", "control"],
  ]);
  const { known, unexpected } = classify(r.differences, []);
  assert.equal(known.length, 0);
  assert.equal(unexpected.length, 1, "an unlisted divergence is unexpected, so the matrix exits 1");
}

// 3. Missing owners and unmounted blocks are divergences, not silent passes.
{
  const r = diffSurface({ surface: "canvas", fixtures: ["caption", "body"], view, edit: { caption: { missing: true }, body: { owners: {} } } });
  assert.deepEqual(r.differences.map((d) => d.axis), ["mounted", MISSING]);
  assert.equal(r.compared, 0);
}

// 4. The ledger tolerates exactly its keys; an entry that no longer fires is stale.
{
  const planted = structuredClone(identical);
  planted.body.owners["Body copy"][0].textRendering = "auto";
  const r = diffSurface({ surface: "liveview", fixtures: ["caption", "body"], view, edit: planted });
  const listed = { surface: "liveview", fixture: "body", text: "Body copy", axis: "textRendering", reason: "test" };
  const gone = { surface: "liveview", fixture: "caption", text: "A caption", axis: "letterSpacing", reason: "test" };
  const seen = new Set();
  const { known, unexpected } = classify(r.differences, [listed, gone], seen);
  assert.equal(known.length, 1);
  assert.equal(unexpected.length, 0);
  assert.deepEqual(staleEntries([listed, gone], seen).map(keyOf), [keyOf(gone)]);
}

// 5. The committed ledger is well formed: every entry has a reason and a unique key.
{
  const ledger = JSON.parse(readFileSync(new URL("./view-edit-parity.known.json", import.meta.url), "utf8"));
  assert.ok(Array.isArray(ledger.entries));
  const keys = new Set();
  for (const entry of ledger.entries) {
    assert.ok(entry.reason && entry.reason.length > 20, `ledger entry needs a checkable reason: ${keyOf(entry)}`);
    assert.ok(!keys.has(keyOf(entry)), `duplicate ledger key ${keyOf(entry)}`);
    keys.add(keyOf(entry));
  }
}

// 6. A text that repeats the same number of times on both sides is paired by
//    POSITION (task-6306bdab9b1cb699). The task-list's ○ is first the momentum
//    header's glyph (0.78rem row), then a row's glyph: the header meets the
//    header and the row meets the row, so two matching surfaces show no
//    divergence. Under the old pairing the reader kept only its FIRST owner and
//    met every Edit owner, so the header glyph was compared with the row glyph.
const header = style({ fontSize: "12.48px", lineHeight: "18px", tag: "span.bp-g" });
const row = style({ fontSize: "14.08px", lineHeight: "22px", tag: "span.bp-g" });
const glyphView = { tasks: { owners: { "○": [header, row] } } };
{
  const edit = { tasks: { owners: { "○": [structuredClone(header), structuredClone(row)] } } };
  const r = diffSurface({ surface: "canvas", fixtures: ["tasks"], view: glyphView, edit });
  assert.deepEqual(r.differences, [], "header↔header and row↔row match");
  assert.equal(r.compared, 2, "both positions are compared, not skipped");

  const legacy = diffSurface({ surface: "canvas", fixtures: ["tasks"], view: { tasks: { owners: { "○": header } } }, edit });
  assert.deepEqual(
    legacy.differences.map((d) => [d.axis, d.view, d.edit]),
    [["fontSize", "12.48px", "14.08px"], ["lineHeight", "18px", "22px"]],
    "a single View owner still meets every Edit owner (the old pairing, kept for unequal counts)",
  );
}

// 7. Control: a planted style difference on a ROW glyph still surfaces — the
//    pairing compares rows, it does not excuse them.
{
  const planted = { tasks: { owners: { "○": [structuredClone(header), { ...structuredClone(row), fontSize: "15px" }] } } };
  const r = diffSurface({ surface: "canvas", fixtures: ["tasks"], view: glyphView, edit: planted });
  assert.deepEqual(r.differences.map((d) => [d.text, d.axis, d.view, d.edit]), [["○", "fontSize", "14.08px", "15px"]]);
  const { unexpected } = classify(r.differences, []);
  assert.equal(unexpected.length, 1);

  const plantedHeader = { tasks: { owners: { "○": [{ ...structuredClone(header), lineHeight: "30px" }, structuredClone(row)] } } };
  const h = diffSurface({ surface: "canvas", fixtures: ["tasks"], view: glyphView, edit: plantedHeader });
  assert.deepEqual(h.differences.map((d) => [d.axis, d.view, d.edit]), [["lineHeight", "18px", "30px"]]);
}

// 8. Unequal counts fall back to the first View owner against every Edit owner,
//    so an Edit side that lost (or gained) an occurrence is still compared.
{
  const r = diffSurface({ surface: "canvas", fixtures: ["tasks"], view: glyphView, edit: { tasks: { owners: { "○": [structuredClone(row)] } } } });
  assert.equal(r.compared, 1);
  assert.deepEqual(r.differences.map((d) => d.axis), ["fontSize", "lineHeight"], "the header-first View owner meets the lone row owner");
}

console.log("view-edit-parity compare: 8 checks passed");

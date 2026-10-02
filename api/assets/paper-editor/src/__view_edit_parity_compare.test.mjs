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

console.log("view-edit-parity compare: 5 checks passed");

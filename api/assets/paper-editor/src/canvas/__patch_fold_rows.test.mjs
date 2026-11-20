// The rows that tie this editor's patch.ex mirror (patch-fold.js, which the
// source-mode wall folds a save with) to patch.ex: each row's ops, folded onto
// `before`, give `after`. api/test/barkpark/portable_doc/patch_fold_rows_test.exs runs
// the same rows against Patch. A row without a result fails on both sides.
// Run: node src/canvas/__patch_fold_rows.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { applyOps } from "./patch-fold.js";

const { rows } = JSON.parse(readFileSync(
  new URL("../../../../test/support/fixtures/paper-editor/patch_fold_rows.json", import.meta.url), "utf8"));

assert.ok(rows.length > 0, "the shared rows are there");
for (const row of rows) {
  assert.ok(Array.isArray(row.before) && Array.isArray(row.ops) && Array.isArray(row.after), `${row.row}: has a result`);
  assert.deepEqual(applyOps(row.before, row.ops), row.after, row.row);
}
console.log(`patch fold rows: ${rows.length} rows passed`);

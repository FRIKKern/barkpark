// The source-wall walk's own checks (task-368b4fe38e75712d): sharedFixtureWalk run on a
// root built here, holding one good file of each kind and the bad shapes, each named.
// A file with a key its shape does not carry, at the top or inside an op's documents, is
// unread (onlyKeys, docOf), and a skipped file that holds a document at any depth is
// named (holdsDocument), while the good files are read.
// Run: node src/__source_wall_walk_shapes.test.mjs

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { sharedFixtureWalk } from "./__source_wall_goldens.mjs";

const paragraph = (value) => ({ type: "paragraph", content: [{ type: "text", value }] });
const doc = (value) => ({ version: 1, title: value, preview: value, blocks: [{ id: "p1", ...paragraph(value) }] });

const FILES = {
  // Read: one of each shape the bad files below are variants of.
  "blocks/good.golden.json": { name: "good", type: "paragraph", shape: "x", input: paragraph("good block"), expectedHtml: "" },
  "ops/good.json": { op: {}, before: doc("before"), after: doc("after") },
  "limit-docs.json": { _comment: "", docs: [{ name: "one", doc: paragraph("limit doc") }], edges: [] },
  "i18n/en.json": { Hello: "Hei" },
  // Not read: a key outside the shape's set.
  "blocks/extra.golden.json": { type: "paragraph", input: paragraph("extra"), surprise: true },
  "more/limit-docs.json": { _comment: "", docs: [{ name: "two", doc: paragraph("two") }], edges: [], huge: [{ name: "h", doc: paragraph("hidden") }] },
  "ops/middle.json": { op: {}, before: doc("before 2"), after: doc("after 2"), middle: doc("hidden") },
  "ops/inner.json": { op: {}, before: { ...doc("before 3"), surprise: true }, after: doc("after 3") },
  // Skipped, yet holding a document.
  "i18n/doc.json": { blocks: [paragraph("hidden")] },
  "i18n/nested.json": { wrap: { blocks: [paragraph("hidden deeper")] } },
};

const root = mkdtempSync(join(tmpdir(), "source-wall-walk-"));
try {
  for (const [path, value] of Object.entries(FILES)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), JSON.stringify(value));
  }
  const walked = sharedFixtureWalk(root);
  const names = walked.docs.map(([name]) => name).sort();

  assert.deepEqual(names, ["blocks/good", "limit-docs docs/one", "ops/good after", "ops/good before"],
    "the good files are read, each document by name");
  assert.deepEqual(walked.unread.sort(), ["blocks/extra.golden.json", "more/limit-docs.json", "ops/inner.json", "ops/middle.json"],
    "a file with a key its shape does not carry is unread");
  assert.deepEqual(walked.skippedDocuments.sort(), ["i18n/doc.json", "i18n/nested.json"],
    "a skipped file that holds a document, at any depth, is named; a clean one is not");
  assert.deepEqual(walked.skipped.map(([path]) => path).sort(), ["i18n/doc.json", "i18n/en.json", "i18n/nested.json"], "the i18n files are skipped");
  console.log("source wall walk shapes: passed");
} finally {
  rmSync(root, { recursive: true, force: true });
}

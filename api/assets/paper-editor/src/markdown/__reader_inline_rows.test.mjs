// The rows that tie reader-inline.js to the reader (task-368b4fe38e75712d):
// api/test/support/fixtures/paper-editor/reader_inline_rows.json. Each row is a block
// and the inline runs the reader shows for it; the reader's own test
// (api/test/barkpark/portable_doc/reader_inline_rows_test.exs) renders the same rows
// and derives which keys the reader takes words from, so neither side drifts alone.
// Here: every row's block gives exactly its runs through readerInline, and the
// fixture's line_types are the types serialize.js writes as a Markdown line of words,
// found by serializing every golden block type with words in `content` or `text`.
// Run: node src/markdown/__reader_inline_rows.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { blocksToMarkdown } from "../markdown.js";
import { readerInline } from "./reader-inline.js";
import { sharedFixtureWalk } from "../__source_wall_goldens.mjs";

const fixture = JSON.parse(readFileSync(fileURLToPath(new URL(
  "../../../../test/support/fixtures/paper-editor/reader_inline_rows.json", import.meta.url)), "utf8"));

assert.ok(fixture.rows.length > 0, "the fixture has rows");
for (const row of fixture.rows) {
  const read = readerInline(row.block);
  assert.notEqual(read, null, `${row.row}: reader-inline.js handles a ${row.block.type}`);
  assert.deepEqual(read, row.inline, `${row.row}: reader-inline.js shows what the reader shows`);
}

const WORD = "Wordmark";
const types = [...new Set(sharedFixtureWalk().docs.flatMap(([, blocks]) => blocks.map((block) => block.type)))].sort();
const lineTypes = types.filter((type) => [{ content: [{ type: "text", value: WORD }] }, { text: WORD }].some((words) => {
  const md = blocksToMarkdown([{ id: "x", type, ...words }]);
  return !md.startsWith("<!--bp:block") && md.includes(WORD);
}));
assert.deepEqual(lineTypes, [...fixture.line_types].sort(),
  "the fixture's line types are the types serialize.js writes as a line of words");

console.log(`reader inline rows: ${fixture.rows.length} rows, line types ${lineTypes.join(", ")} (of ${types.length} golden types): passed`);

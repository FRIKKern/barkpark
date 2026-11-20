// Every shared Portable Doc fixture through the source-mode wall (task-368b4fe38e75712d).
// sharedFixtureWalk (__source_wall_goldens.mjs) reads EVERY file under
// api/priv/portable_doc/goldens by its shape: each document a file holds is one Paper
// here. A file that holds none is on its named skip list with its reason, and a file
// neither read nor skipped fails this test, as does a skip entry that matches nothing.
// Each Paper goes through sourceLoss (src/markdown/carries.js), the one comparison source
// mode runs before it opens, with the save run as source mode runs it (sourceSaved: the
// ops a save sends folded onto what is stored; the projection here is runToTiptap
// without the editor's schema, which __source_inside_edit_sweep.test.mjs adds).
// The lists below are what source mode refuses today and why; REFUSED is the work queue
// for the tasks that make Markdown carry those shapes (marks on text:
// task-5f0ba8904b973a3a; deep lists and other source losses: task-dde1d993de85a6e3;
// a quote or callout whose words are only in `text`, which source mode shows read-only).
// A fixture that starts or stops being
// refused moves a list, so the change is seen.
// Run: node src/__source_wall_fixtures.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { firstLoss, sourceLoss } from "./markdown/carries.js";
import { sourceSaved } from "./canvas/source-save.js";
import { jsonDepth, MAX_VALUE_DEPTH, sharedFixtureWalk } from "./__source_wall_goldens.mjs";
import { runToOps, runToTiptap } from "./canvas/run-convert.js";

const view = { toDoc: runToTiptap, toOps: runToOps };

const REFUSED = [
  "blocks/paragraph paragraph content.marks",
  "from-markdown/nested-list-children list items[0]",
  "limit-docs docs/many marks paragraph content.marks",
  "limits/em-at-the-depth-limit paragraph content[0].children[0].children",
  "limits/em-one-level-above-the-depth-limit paragraph content[0].children[0].children",
  "limits/list-at-the-depth-limit list items[0]",
  "limits/list-one-level-above-the-depth-limit list items[0]",
  "limits/marks-at-the-depth-limit paragraph content.marks",
  "limits/marks-one-level-above-the-depth-limit paragraph content.marks",
  "limits/strong-at-the-depth-limit paragraph content[0].children[0].children",
  "limits/strong-one-level-above-the-depth-limit paragraph content[0].children[0].children",
  "locales/en.locale-golden callout text",
  "nested-list-carriers list items[0]",
];

// Documents nesting past Portable Doc's value-depth limit are named, not run: the
// validator refuses them, so no Paper holds one. The names are shared rows, and
// test/barkpark/portable_doc/source_wall_too_deep_test.exs fails unless Validate
// refuses each one as too_deep.
const TOO_DEEP = JSON.parse(readFileSync(new URL("../../../test/support/fixtures/paper-editor/source_wall_too_deep.json", import.meta.url), "utf8"))
  .rows.map((row) => row.name);

// The comparison itself: what is the same content, and what is a loss.
{
  const text = (value, marks) => (marks ? { type: "text", value, marks } : { type: "text", value });
  const para = (id, content) => ({ id, type: "paragraph", content });
  assert.equal(firstLoss([para("a", [text("x")])], [para("b", [text("x")])]), null, "a top-level id is not content");
  assert.equal(
    firstLoss([para("a", [text("a "), text("b"), text("", undefined)])], [para("a", [text("a b", [])])]),
    null,
    "split runs with the same marks, an empty run and an empty marks list are the same content",
  );
  assert.deepEqual(
    firstLoss([para("a", [text("a "), text("b", ["strong"])])], [para("a", [text("a b")])]),
    { index: 0, type: "paragraph", path: "content.marks", part: "marks" },
    "a lost mark is named as marks, not text",
  );
  assert.deepEqual(
    firstLoss([{ id: "c", type: "callout", slots: { body: [para("p", [text("w")])] } }], [{ id: "c", type: "callout" }]),
    { index: 0, type: "callout", path: "slots.body", part: "body" },
    "a lost slot is named by the slot",
  );
  assert.deepEqual(firstLoss([para("a", [text("x")])], []).index, 0, "a lost block is a loss");
  const section = (child) => ({ id: "s", type: "section", blocks: [child] });
  assert.equal(firstLoss([section({ type: "divider" })], [section({ id: "m1", type: "divider" })]), null,
    "an id the save gives a nested block that had none is not a loss");
  assert.deepEqual(firstLoss([section({ id: "d", type: "divider" })], [section({ type: "divider" })]).path, "blocks[0].id",
    "a nested id the save drops is a loss");
  assert.equal(firstLoss([{ id: "h", type: "heading", level: 2, text: "T" }], [{ type: "heading", text: "T", level: 2, id: "z" }]), null,
    "key order is not content");
  assert.equal(firstLoss([{ type: "list", items: [[text("a")]] }], [{ type: "list", ordered: false, lang: "", items: [[text("a")]] }]), null,
    "a key that carries nothing is the same as no key");
  assert.equal(firstLoss([{ type: "list", ordered: true, items: [[text("a")]] }], [{ type: "list", items: [[text("a")]] }]).path, "ordered",
    "a key that carries something is content");
}

const walked = sharedFixtureWalk();
assert.deepEqual(walked.unread, [], "every file under the goldens root is read as documents or named on the skip list");
assert.deepEqual(walked.unusedSkips, [], "every skip entry still names a file");
assert.deepEqual(walked.skippedDocuments, [], "no skipped file holds a document");
const refused = [];
const tooDeep = [];
for (const [name, blocks] of walked.docs) {
  // Past the value-depth limit the validator refuses the document: no Paper holds it.
  if (jsonDepth({ blocks }) > MAX_VALUE_DEPTH) {
    tooDeep.push(name);
    continue;
  }
  const loss = sourceLoss(blocks, (parsed) => sourceSaved(blocks, parsed, view));
  if (loss) refused.push(`${name} ${loss.type} ${loss.path}`);
}

const count = walked.docs.length;
console.log(`source wall over ${count} shared fixture documents (${walked.skipped.length} files skipped, ` +
  `${walked.duplicates.length} documents read under two names folded): ${count - refused.length - tooDeep.length} open, ` +
  `${refused.length} refused, ${tooDeep.length} past the value-depth limit\n${refused.join("\n")}`);
assert.ok(count >= 180, `the fixtures were found (${count})`);
assert.deepEqual(refused, REFUSED, "the fixtures source mode refuses today");
assert.deepEqual(tooDeep, TOO_DEEP, "the fixtures past the value-depth limit");
console.log("source wall fixtures: passed");

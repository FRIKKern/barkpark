// Every shared Portable Doc fixture through the source-mode wall (task-368b4fe38e75712d):
// the input of each block and limit golden in api/priv/portable_doc/goldens, as a one-block
// Paper, through sourceLoss (src/markdown/carries.js), the one comparison source mode runs
// before it opens, with the parse settled as the save would store it (settleSourceParse).
// The list below is what source mode refuses today and why; it is the work queue for the tasks that make Markdown carry those shapes (marks on text:
// task-5f0ba8904b973a3a; deep lists and other source losses: task-dde1d993de85a6e3). A
// fixture that starts or stops being refused moves this list, so the change is seen.
// Run: node src/__source_wall_fixtures.test.mjs

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { firstLoss, sourceLoss } from "./markdown/carries.js";
import { settleSourceParse } from "./canvas/source-realign.js";

const GOLDENS = fileURLToPath(new URL("../../../priv/portable_doc/goldens/", import.meta.url));

const REFUSED = [
  "blocks/paragraph paragraph content.marks",
  "limits/em-at-the-depth-limit paragraph content[0].children[0].children",
  "limits/em-one-level-above-the-depth-limit paragraph content[0].children[0].children",
  "limits/heatmap-number-past-what-a-float-holds heatmap cells[0][0]",
  "limits/list-at-the-depth-limit list items[0]",
  "limits/list-one-level-above-the-depth-limit list items[0]",
  "limits/marks-at-the-depth-limit paragraph content.marks",
  "limits/marks-one-level-above-the-depth-limit paragraph content.marks",
  "limits/strong-at-the-depth-limit paragraph content[0].children[0].children",
  "limits/strong-one-level-above-the-depth-limit paragraph content[0].children[0].children",
];

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
  assert.equal(firstLoss([{ id: "h", type: "heading", level: 2, text: "T" }], [{ type: "heading", text: "T", level: 2, id: "z" }]), null,
    "key order is not content");
  assert.equal(firstLoss([{ type: "list", items: [[text("a")]] }], [{ type: "list", ordered: false, lang: "", items: [[text("a")]] }]), null,
    "a key that carries nothing is the same as no key");
  assert.equal(firstLoss([{ type: "list", ordered: true, items: [[text("a")]] }], [{ type: "list", items: [[text("a")]] }]).path, "ordered",
    "a key that carries something is content");
}

const refused = [];
let count = 0;
for (const dir of ["blocks", "limits"]) {
  for (const file of readdirSync(join(GOLDENS, dir)).filter((name) => name.endsWith(".golden.json")).sort()) {
    count++;
    const { input } = JSON.parse(readFileSync(join(GOLDENS, dir, file), "utf8"));
    const block = { id: "fixture", ...input };
    const loss = sourceLoss([block], (parsed) => settleSourceParse([block], parsed));
    if (loss) refused.push(`${dir}/${file.replace(/\.golden\.json$/, "")} ${loss.type} ${loss.path}`);
  }
}

console.log(`source wall over ${count} shared fixtures: ${count - refused.length} open, ${refused.length} refused\n${refused.join("\n")}`);
assert.ok(count >= 130, `the goldens were found (${count})`);
assert.deepEqual(refused, REFUSED, "the fixtures source mode refuses today");
console.log("source wall fixtures: passed");

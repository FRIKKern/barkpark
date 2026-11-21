// Prints the documents of the paper editor's shared fixture walk (sharedFixtureWalk in
// assets/paper-editor/src/__source_wall_goldens.mjs), one JSON line per document:
// {"name": ..., "blocks": [...]}. The first line is the walk's own bookkeeping
// ({"unread": [...], "skippedDocuments": [...], "count": n}), so an ExUnit test reads the
// very documents the source wall is measured on instead of keeping its own list.
//
// The stringify is iterative: a worst-case limit document nests 20,000 levels, past what
// JSON.stringify's recursion survives.

import { sharedFixtureWalk } from "../../assets/paper-editor/src/__source_wall_goldens.mjs";

function stringify(root) {
  const out = [];
  const stack = [{ value: root }];
  while (stack.length) {
    const frame = stack.pop();
    if (frame.text !== undefined) {
      out.push(frame.text);
      continue;
    }
    const { value } = frame;
    if (Array.isArray(value)) {
      const parts = [{ text: "[" }];
      value.forEach((item, index) => {
        if (index) parts.push({ text: "," });
        parts.push({ value: item === undefined ? null : item });
      });
      parts.push({ text: "]" });
      for (let i = parts.length - 1; i >= 0; i--) stack.push(parts[i]);
    } else if (value && typeof value === "object") {
      const parts = [{ text: "{" }];
      Object.keys(value)
        .filter((key) => value[key] !== undefined)
        .forEach((key, index) => {
          parts.push({ text: `${index ? "," : ""}${JSON.stringify(key)}:` });
          parts.push({ value: value[key] });
        });
      parts.push({ text: "}" });
      for (let i = parts.length - 1; i >= 0; i--) stack.push(parts[i]);
    } else {
      out.push(JSON.stringify(value === undefined ? null : value));
    }
  }
  return out.join("");
}

const walk = sharedFixtureWalk();
process.stdout.write(
  `${JSON.stringify({ unread: walk.unread, skippedDocuments: walk.skippedDocuments, count: walk.docs.length })}\n`,
);
for (const [name, blocks] of walk.docs) process.stdout.write(`${stringify({ name, blocks })}\n`);

// __inline_object_vocabulary.test.mjs — task-85fee859cf3bfef6 (inline objects,
// slice 3): the pure decisions behind the field canvas's inline objects.
// Run: node src/canvas/__inline_object_vocabulary.test.mjs
import assert from "node:assert/strict";
import { parseVocabulary, allowedInlineTypes, docVocabularyViolation, inlineObjectFor, slashItemsForVocabulary } from "./vocabulary.js";
import { fieldRequired, controlKind, refusalField } from "./inline-object.js";

const vocab = parseVocabulary({
  styles: ["normal"],
  inline: [
    { name: "chip", title: "Status chip", fields: [{ name: "text", type: "string" }, { bad: 1 }] },
    "mention",
    "mention",
    { title: "no name" },
  ],
});

assert.deepEqual(vocab.inlineObjects.map((o) => [o.name, o.title, o.fields.length]), [
  ["chip", "Status chip", 1],
  ["mention", "mention", 0],
]);
assert.ok(allowedInlineTypes(vocab).has("chip") && allowedInlineTypes(vocab).has("mention"));
assert.equal(inlineObjectFor(vocab, "chip").title, "Status chip");
assert.equal(inlineObjectFor(vocab, "badge"), null);
assert.deepEqual(parseVocabulary({ styles: ["normal"] }).inlineObjects, [], "no inline key, no kinds");

const rows = slashItemsForVocabulary([], vocab).filter((r) => r.inline);
assert.deepEqual(rows.map((r) => r.type), ["inline:chip", "inline:mention"]);

// The calm veto names an undeclared inline atom, never a declared one.
const para = (atomType) => ({
  type: "doc",
  content: [{ type: "paragraph", content: [{ type: "bpInlineOpaque", attrs: { node: { type: atomType } } }] }],
});
assert.equal(docVocabularyViolation(para("chip"), vocab), null);
assert.equal(docVocabularyViolation(para("badge"), vocab), "inline badge");

assert.equal(fieldRequired({ validation: { required: true } }), true);
assert.equal(fieldRequired({ validation: [{ max: 3 }, { required: true }] }), true);
assert.equal(fieldRequired({ validation: { required: true, level: "warning" } }), false);
assert.equal(fieldRequired({}), false);

assert.equal(controlKind({ type: "string", options: { list: ["a"] } }), "select");
assert.equal(controlKind({ type: "text" }), "textarea");
assert.equal(controlKind({ type: "integer" }), "number");
assert.equal(controlKind({ type: "boolean" }), "checkbox");
assert.equal(controlKind({ type: "reference" }), "readonly");

const fields = [{ name: "text" }, { name: "tone" }];
assert.equal(refusalField("paragraph/content/1/tone: must be one of positive", fields), "tone");
assert.equal(refusalField("inline badge is not in this field's vocabulary", fields), null);
assert.equal(refusalField("paragraph/content/1/size: Required", fields), null);

console.log("PASS inline_object_vocabulary: parse, offer, veto, controls and refusal paths");

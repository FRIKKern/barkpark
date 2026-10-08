// __vocabulary.test.mjs — Gyldendal parity stage E1: the field-vocabulary
// decisions, pure-Node (no TipTap mount). Run: node src/canvas/__vocabulary.test.mjs

import assert from "node:assert/strict";
import {
  parseVocabulary,
  allowedBlockTypes,
  allowedHeadingLevels,
  allowedInlineTypes,
  docVocabularyViolation,
  transactionVetoesVocabulary,
  slashItemsForVocabulary,
  quoteTypeFor,
} from "./vocabulary.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// The agency Sanity blockContent registry, verbatim in shape.
const AGENCY = JSON.stringify({
  styles: ["normal", "h2", "h3", "blockquote"],
  lists: ["bullet", "number"],
  marks: ["strong", "em"],
  annotations: [{ name: "link", fields: [{ name: "href", type: "string" }] }],
  of: ["image"],
});

const text = (value, marks = []) => ({ type: "text", text: value, marks: marks.map((m) => ({ type: m })) });
const para = (...inl) => ({ type: "paragraph", content: inl });
const heading = (level, value) => ({ type: "heading", attrs: { level }, content: [text(value)] });
const doc = (...nodes) => ({ type: "doc", content: nodes });
const fakeTr = (after, changed = true) => ({ docChanged: changed, doc: { toJSON: () => after } });
const fakeState = (before) => ({ doc: { toJSON: () => before } });

check("absent / empty / malformed declaration → null (no restriction at all)", () => {
  assert.equal(parseVocabulary(null), null);
  assert.equal(parseVocabulary(""), null);
  assert.equal(parseVocabulary("{nope"), null);
  assert.equal(parseVocabulary("[]"), null);
  assert.equal(docVocabularyViolation(doc(heading(1, "x")), null), null);
  assert.equal(transactionVetoesVocabulary(fakeTr(doc(heading(1, "x"))), fakeState(doc()), null), false);
});

check("the agency vocabulary maps onto exactly the portable-doc types it names", () => {
  const v = parseVocabulary(AGENCY);
  assert.deepEqual([...allowedBlockTypes(v)].sort(), ["heading", "image", "list", "paragraph", "pullquote"]);
  assert.deepEqual([...allowedHeadingLevels(v)].sort(), [2, 3]);
  assert.deepEqual([...allowedInlineTypes(v)].sort(), ["em", "link", "strong", "text"]);
});

check("an in-vocabulary doc has no violation", () => {
  const v = parseVocabulary(AGENCY);
  const d = doc(
    heading(2, "Praise"),
    para(text("a "), text("b", ["bold"]), text("c", ["link"])),
    { type: "orderedList", content: [{ type: "listItem", content: [para(text("one"))] }] },
    { type: "pullquote", attrs: { bpType: "pullquote" }, content: [text("q")] },
    { type: "bpOpaque", attrs: { bpType: "image", bpBlock: { type: "image", src: "/x.png" } } },
  );
  assert.equal(docVocabularyViolation(d, v), null);
});

check("violations are named: h1, a wrong mark, an un-listed block, a wrong list kind", () => {
  const v = parseVocabulary(AGENCY);
  assert.equal(docVocabularyViolation(doc(heading(1, "no")), v), "heading level 1");
  assert.equal(docVocabularyViolation(doc(para(text("z", ["strike"]))), v), "inline strikethrough");
  assert.equal(docVocabularyViolation(doc({ type: "bpOpaque", attrs: { bpType: "code" } }), v), "block type code");
  const bulletOnly = parseVocabulary(JSON.stringify({ styles: ["normal"], lists: ["bullet"] }));
  assert.equal(
    docVocabularyViolation(doc({ type: "orderedList", content: [] }), bulletOnly),
    "numbered list",
  );
});

check("THE CALM VETO: a user edit that introduces an h1 is vetoed; a no-worse edit passes", () => {
  const v = parseVocabulary(AGENCY);
  const clean = doc(para(text("hi")));
  // paste an h1 into a clean doc → veto
  assert.equal(transactionVetoesVocabulary(fakeTr(doc(para(text("hi")), heading(1, "pasted"))), fakeState(clean), v), true);
  // an in-vocabulary edit → passes
  assert.equal(transactionVetoesVocabulary(fakeTr(doc(para(text("hi there")))), fakeState(clean), v), false);
  // a doc that was ALREADY out of vocabulary (server-held) is not frozen by a calm edit
  const dirty = doc(heading(1, "old"), para(text("a")));
  assert.equal(transactionVetoesVocabulary(fakeTr(doc(heading(1, "old"), para(text("ab")))), fakeState(dirty), v), false);
  // a transaction that did not change the doc never vetoes
  assert.equal(transactionVetoesVocabulary(fakeTr(doc(heading(1, "x")), false), fakeState(clean), v), false);
});

check("the slash menu offers only the vocabulary's block types and never a compound starter", () => {
  const v = parseVocabulary(AGENCY);
  const items = [
    { type: "paragraph", label: "Paragraph" },
    { type: "heading", label: "Heading" },
    { type: "list", label: "List" },
    { type: "code", label: "Code" },
    { type: "callout", label: "Callout" },
    { type: "masthead", label: "Masthead", compound: "masthead" },
  ];
  assert.deepEqual(slashItemsForVocabulary(items, v).map((i) => i.type), ["paragraph", "heading", "list"]);
  assert.equal(slashItemsForVocabulary(items, null), items);
});

// task-96fce87b7b71c288: `{name, fields}` entries in blocks.of are custom object
// blocks the server already admits; the canvas admits the same names.
const WITH_OBJECTS = JSON.stringify({
  styles: ["normal"],
  of: [
    "image",
    { name: "callout", fields: [{ name: "tone", type: "string" }] },
    { name: "factBox", title: "Faktaboks", fields: [{ name: "body", type: "text" }] },
    { fields: [] },
  ],
});

check("object entries in blocks.of are allowed block types", () => {
  const v = parseVocabulary(WITH_OBJECTS);
  assert.deepEqual(v.of, ["image", "callout", "factBox"]);
  assert.deepEqual(
    v.objects.map((o) => [o.name, o.title]),
    [
      ["callout", "callout"],
      ["factBox", "Faktaboks"],
    ],
  );
  assert.ok(allowedBlockTypes(v).has("factBox"));
  const opaque = (t) => ({ type: "bpOpaque", attrs: { bpType: t, bpBlock: { type: t } } });
  assert.equal(docVocabularyViolation(doc(para(text("a")), opaque("factBox")), v), null);
  assert.equal(docVocabularyViolation(doc(opaque("banner")), v), "block type banner");
  // inserting a declared object block into a clean doc is not vetoed
  assert.equal(
    transactionVetoesVocabulary(fakeTr(doc(para(text("a")), opaque("factBox"))), fakeState(doc(para(text("a")))), v),
    false,
  );
});

check("the slash menu offers a declared object block, once, as an object row", () => {
  const v = parseVocabulary(WITH_OBJECTS);
  const items = [
    { type: "paragraph", label: "Paragraph" },
    { type: "callout", label: "Callout" },
  ];
  const offered = slashItemsForVocabulary(items, v);
  // callout has a canvas item already, so it is kept as that item, not doubled
  assert.deepEqual(offered.map((i) => i.type), ["paragraph", "callout", "factBox"]);
  const row = offered.find((i) => i.type === "factBox");
  assert.equal(row.object, true);
  assert.equal(row.label, "Faktaboks");
  assert.equal(offered.find((i) => i.type === "callout").object, undefined);
});

// task-071f8c843336d12e: a field's blockquote STYLE is the pullquote block.
check("a quote gesture makes the block the field admits", () => {
  assert.equal(quoteTypeFor(null), "blockquote", "a paper canvas keeps the plain quote");
  assert.equal(quoteTypeFor(parseVocabulary({ styles: ["normal", "blockquote"] })), "pullquote");
  assert.equal(quoteTypeFor(parseVocabulary({ styles: ["normal"], of: ["blockquote"] })), "blockquote");
  assert.equal(quoteTypeFor(parseVocabulary({ styles: ["normal"] })), "blockquote", "no quote admitted: the veto decides");
});
check("the slash menu keeps its Quote row in a field with the blockquote style, as a pullquote pick", () => {
  const items = [{ type: "paragraph" }, { type: "blockquote", label: "Quote" }, { type: "callout" }];
  const offered = slashItemsForVocabulary(items, parseVocabulary({ styles: ["normal", "blockquote"] }));
  assert.deepEqual(offered.map((i) => i.type), ["paragraph", "blockquote"]);
  assert.equal(offered[1].quoteAs, "pullquote");
  assert.equal(offered[1].label, "Quote");
  assert.deepEqual(slashItemsForVocabulary(items, parseVocabulary({ styles: ["normal"] })).map((i) => i.type), ["paragraph"]);
});

if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\nvocabulary: all checks passed");

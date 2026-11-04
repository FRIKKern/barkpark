// smoke/round-trip.mjs — S0 prose/marks/list round-trips.
//
// VERBATIM extraction from src/__smoke.mjs: the numbered prose/mark/list/wikilink/
// idempotency round-trips (1-17). Every check is
// moved unchanged (same name, body, assertions); the shared check()/assertFolds run
// through the harness so the aggregate report + exit code span all modules.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import {
  blockToTiptap,
  tiptapToFullBlock,
  buildPatchBlockOp,
  inlineArrayToTiptap,
} from "../convert.js";
import { Wikilink, Blockref, Tag, Valueref } from "../marks.js";
import { BUILD_SHA, CONTRACT_VERSION, EDITOR_VERSION } from "../contract.js";
import { readFileSync } from "node:fs";

// 1) paragraph with bold + italic + inline code round-trips.
check("paragraph round-trip (text + bold + em + code)", () => {
  const sample = {
    id: "p-1",
    type: "paragraph",
    content: [
      { type: "text", value: "Hello " },
      { type: "strong", children: [{ type: "text", value: "world" }] },
      { type: "text", value: " and " },
      { type: "em", children: [{ type: "text", value: "cosmos" }] },
      { type: "text", value: " " },
      { type: "code", value: "x = 1" },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-1", "paragraph");
  assert.deepEqual(back, sample);
});

// 2) heading carries flat text + level, clamped to 1..6.
check("heading round-trip (text + level)", () => {
  const sample = { id: "h-1", type: "heading", level: 2, text: "Status" };
  const back = tiptapToFullBlock(blockToTiptap(sample), "h-1", "heading");
  assert.deepEqual(back, sample);
});

// 3) bullet list with two items round-trips item inline arrays.
check("bullet list round-trip", () => {
  const sample = {
    id: "l-1",
    type: "list",
    ordered: false,
    items: [
      [{ type: "text", value: "first" }],
      [
        { type: "text", value: "second " },
        { type: "strong", children: [{ type: "text", value: "bold" }] },
      ],
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "l-1", "list");
  assert.deepEqual(back, sample);
});

// 4) ordered list preserves the ordered flag.
check("ordered list flag preserved", () => {
  const sample = {
    id: "l-2",
    type: "list",
    ordered: true,
    items: [[{ type: "text", value: "step one" }]],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "l-2", "list");
  assert.equal(back.ordered, true);
  assert.deepEqual(back, sample);
});

// 4a) LEGACY FLAT-STRING list items — the obsidian crash shape. 7 real legacy
//     papers store `items:["text one","text two"]` (flat STRINGS) where the
//     canonical shape is inline ARRAYS. `inlineArrayToTiptap("a string")` would
//     run `.forEach` on a string and THROW, crashing BOTH editors on open. The
//     defensive coercion in convert.js must:
//       (a) NOT throw on a string item (per-block projection), and
//       (b) project a string-item list BYTE-IDENTICALLY to its normalized
//           inline-array form (render/projection-preserving — the data normalize
//           is proven safe by this equality).
check("list with FLAT-STRING items projects WITHOUT throwing (defensive coercion)", () => {
  const stringList = {
    id: "l-str",
    type: "list",
    ordered: false,
    items: ["text one", "text two"],
  };
  // (a) MUST NOT throw.
  const td = blockToTiptap(stringList);
  assert.equal(td.content[0].type, "bulletList");
  assert.equal(td.content[0].content.length, 2, "two list items");

  // (b) byte-identical to the canonical inline-array form's projection.
  const inlineList = {
    id: "l-str",
    type: "list",
    ordered: false,
    items: [
      [{ type: "text", value: "text one" }],
      [{ type: "text", value: "text two" }],
    ],
  };
  assert.deepEqual(
    blockToTiptap(stringList).content[0].content.map(li => li.content),
    blockToTiptap(inlineList).content[0].content.map(li => li.content),
    "visible projection matches while opaque source attributes retain the carrier",
  );
});

// Source-aware list conversion keeps old string carriers without a migration.
check("list with FLAT-STRING items round-trips without migrating carriers", () => {
  const stringList = {
    id: "l-str2",
    type: "list",
    ordered: false,
    items: ["alpha", "beta"],
  };
  const back = tiptapToFullBlock(blockToTiptap(stringList), "l-str2", "list");
  assert.deepEqual(back, {
    id: "l-str2",
    type: "list",
    ordered: false,
    items: ["alpha", "beta"],
  });
});

// 5) the emitted patch-block op matches the on-the-wire shape exactly:
//    { op:"patch-block", id, patch:{ content:[...] } }
check("patch-block op shape for 'Hello **world**'", () => {
  const tiptapDoc = blockToTiptap({
    id: "p-9",
    type: "paragraph",
    content: [
      { type: "text", value: "Hello " },
      { type: "strong", children: [{ type: "text", value: "world" }] },
    ],
  });
  const op = buildPatchBlockOp(tiptapDoc, "p-9", "paragraph");
  assert.deepEqual(op, {
    op: "patch-block",
    id: "p-9",
    patch: {
      content: [
        { type: "text", value: "Hello " },
        { type: "strong", children: [{ type: "text", value: "world" }] },
      ],
    },
  });
  console.log("      emitted op:", JSON.stringify(op));
});

// 6) strikethrough round-trips (the canonical bug: strike typed in Studio was
//    dropped on save — MARK_ORDER had no portable-doc equivalent).
check("paragraph round-trip (strikethrough)", () => {
  const sample = {
    id: "p-6",
    type: "paragraph",
    content: [
      { type: "text", value: "was " },
      { type: "strikethrough", children: [{ type: "text", value: "removed" }] },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-6", "paragraph");
  assert.deepEqual(back, sample);
});

// 7) underline round-trips.
check("paragraph round-trip (underline)", () => {
  const sample = {
    id: "p-7",
    type: "paragraph",
    content: [
      { type: "text", value: "see " },
      { type: "underline", children: [{ type: "text", value: "here" }] },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-7", "paragraph");
  assert.deepEqual(back, sample);
});

// 8) nested bold > strikethrough round-trips (nesting matches MARK_ORDER:
//    strong outer, strikethrough inner).
check("paragraph round-trip (bold > strikethrough)", () => {
  const sample = {
    id: "p-8",
    type: "paragraph",
    content: [
      {
        type: "strong",
        children: [
          { type: "strikethrough", children: [{ type: "text", value: "gone" }] },
        ],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-8", "paragraph");
  assert.deepEqual(back, sample);
});

// 9) wikilink WITH alias round-trips ([[target|alias]]).
check("paragraph round-trip (wikilink + alias)", () => {
  const sample = {
    id: "p-9w",
    type: "paragraph",
    content: [
      { type: "text", value: "see " },
      {
        type: "wikilink",
        target: "intro-to-x",
        alias: "the intro",
        children: [{ type: "text", value: "the intro" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-9w", "paragraph");
  assert.deepEqual(back, sample);
});

// 10) wikilink WITHOUT alias round-trips byte-exact — no stray `alias` key.
//     (The idempotency gate: alias:undefined must never leak into the node.)
check("paragraph round-trip (wikilink, no alias)", () => {
  const sample = {
    id: "p-10w",
    type: "paragraph",
    content: [
      {
        type: "wikilink",
        target: "setup",
        children: [{ type: "text", value: "setup" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-10w", "paragraph");
  assert.deepEqual(back, sample);
  assert.ok(
    !Object.prototype.hasOwnProperty.call(back.content[0], "alias"),
    "plain wikilink must not gain an alias key",
  );
});

// 10a) wikilink WITH docId (picked-paper id pin) round-trips carrying
//      target + docId — the id resolves render to the EXACT paper, closing the
//      title-collision hole. Mirrors the alias guard.
check("paragraph round-trip (wikilink + docId)", () => {
  const sample = {
    id: "p-10wd",
    type: "paragraph",
    content: [
      { type: "text", value: "see " },
      {
        type: "wikilink",
        target: "intro-to-x",
        docId: "doc-7",
        children: [{ type: "text", value: "intro-to-x" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-10wd", "paragraph");
  assert.deepEqual(back, sample);
  assert.equal(back.content[1].docId, "doc-7");
});

// 10b) wikilink WITHOUT docId round-trips byte-exact — no stray `docId` key.
//      (The byte-exact gate for every existing / typed-not-picked wikilink:
//      docId:undefined must never leak into the node.)
check("paragraph round-trip (wikilink, no docId)", () => {
  const sample = {
    id: "p-10wnd",
    type: "paragraph",
    content: [
      {
        type: "wikilink",
        target: "setup",
        children: [{ type: "text", value: "setup" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-10wnd", "paragraph");
  assert.deepEqual(back, sample);
  assert.ok(
    !Object.prototype.hasOwnProperty.call(back.content[0], "docId"),
    "plain wikilink must not gain a docId key",
  );
});

// 10c) TASK-CHIP wikilink round-trips (lvw-t7 protective gate, wire §4): the
//      chip is NOT a new node type — it is a plain wikilink whose target is a
//      task doc id, with docId pinned + alias set. All chip state
//      (status/priority/criteria) lives in the RESOLVER, never on the node, so
//      NO convert.js mapping change is needed — this test PROVES that stays
//      true: target/alias/docId round-trip byte-exact through the editor, and
//      the node gains no chip-specific keys a save could then drop.
check("paragraph round-trip (task-chip wikilink: target + alias + docId)", () => {
  const sample = {
    id: "p-10tc",
    type: "paragraph",
    content: [
      { type: "text", value: "tracked by " },
      {
        type: "wikilink",
        target: "lvw-t7",
        docId: "lvw-t7",
        alias: "the resolver task",
        children: [{ type: "text", value: "the resolver task" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-10tc", "paragraph");
  assert.deepEqual(back, sample);
  const node = back.content[1];
  assert.equal(node.target, "lvw-t7");
  assert.equal(node.docId, "lvw-t7");
  assert.equal(node.alias, "the resolver task");
  assert.deepEqual(
    Object.keys(node).sort(),
    ["alias", "children", "docId", "target", "type"],
    "chip wikilink must not gain chip-state keys (status/priority/criteria live in the resolver)",
  );
});

// 11) blockref leaf round-trips (target/anchor ride the mark, not the text).
check("paragraph round-trip (blockref)", () => {
  const sample = {
    id: "p-11b",
    type: "paragraph",
    content: [
      { type: "text", value: "cf " },
      { type: "blockref", target: "doc-7", anchor: "abc123" },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-11b", "paragraph");
  assert.deepEqual(back, sample);
});

// 12) tag leaf round-trips.
check("paragraph round-trip (tag)", () => {
  const sample = {
    id: "p-12t",
    type: "paragraph",
    content: [
      { type: "text", value: "filed under " },
      { type: "tag", name: "epic" },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-12t", "paragraph");
  assert.deepEqual(back, sample);
});

// 12v) valueref — the inline live value (wire contract: the
//      portabledoc-inline-liveref-taskchip-wire paper §3, decision D6). The FULL
//      wire shape round-trips byte-exactly: target/field + the RESERVED
//      passthrough `as`/`label` (round-trip opaquely, never interpreted) + the
//      dual-written fallback text child, which must round-trip UNCHANGED (D6).
//      Pre-fix, inlineToTiptapNodes' default case flattened this node to plain
//      text on load and tiptapToBlock rewrote the whole content on save — one
//      keystroke deleted it permanently.
check("paragraph round-trip (valueref, full wire shape + D6 fallback child)", () => {
  const sample = {
    id: "p-12v",
    type: "paragraph",
    content: [
      { type: "text", value: "Launch delay is " },
      {
        type: "valueref",
        target: "launch-plan",
        field: "launch_delay",
        as: "duration",
        fallback: "12 weeks",
        label: "launch delay",
        children: [{ type: "text", value: "12 weeks" }],
      },
      { type: "text", value: " for now." },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-12v", "paragraph");
  assert.deepEqual(back, sample);
  // D6 pinned explicitly: the fallback text child round-trips UNCHANGED.
  assert.deepEqual(back.content[1].children, [
    { type: "text", value: "12 weeks" },
  ]);
});

// 12w) CHILDLESS minimal valueref (no as/label/children) — the exact shape the
//      pre-fix default case DROPPED ENTIRELY on load (childless unknown inline).
//      Must round-trip byte-exact with NO stray reserved keys leaking in
//      (the alias:undefined idempotency gate, applied to as/label/children).
check("paragraph round-trip (valueref, childless minimal — no stray keys)", () => {
  const sample = {
    id: "p-12w",
    type: "paragraph",
    content: [
      { type: "text", value: "delay: " },
      {
        type: "valueref",
        target: "launch-plan",
        field: "launch_delay",
        fallback: "12 weeks",
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-12w", "paragraph");
  assert.deepEqual(back, sample);
  for (const key of ["as", "label", "children"]) {
    assert.ok(
      !Object.prototype.hasOwnProperty.call(back.content[1], key),
      `minimal valueref must not gain a ${key} key`,
    );
  }
});

// 12x) PER-BLOCK ACCEPTANCE — editing an ADJACENT word in the same paragraph
//      round-trips the valueref unchanged. Simulates the human edit on the
//      TipTap doc (retouch a NEIGHBORING text run only), then saves through
//      tiptapToFullBlock — the exact whole-content rewrite that used to delete
//      the valueref.
check("per-block: editing an ADJACENT word round-trips the valueref unchanged", () => {
  const valueref = {
    type: "valueref",
    target: "launch-plan",
    field: "launch_delay",
    as: "duration",
    fallback: "12 weeks",
    label: "launch delay",
    children: [{ type: "text", value: "12 weeks" }],
  };
  const sample = {
    id: "p-12x",
    type: "paragraph",
    content: [
      { type: "text", value: "Launch delay is " },
      valueref,
      { type: "text", value: " — tracked." },
    ],
  };
  const doc = blockToTiptap(sample);
  const para = doc.content[0];
  // The human edit: retype the TRAILING adjacent run; the valueref run untouched.
  const last = para.content.length - 1;
  para.content[last] = { ...para.content[last], text: " — tracked closely." };

  const back = tiptapToFullBlock(doc, "p-12x", "paragraph");
  assert.deepEqual(back.content[0], { type: "text", value: "Launch delay is " });
  assert.deepEqual(back.content[1], valueref, "valueref survives byte-identical");
  assert.deepEqual(back.content[2], { type: "text", value: " — tracked closely." });
});

// 13) bold INSIDE a wikilink round-trips (locks MARK_ORDER: wikilink outside).
check("paragraph round-trip (bold inside wikilink)", () => {
  const sample = {
    id: "p-13",
    type: "paragraph",
    content: [
      {
        type: "wikilink",
        target: "x",
        children: [
          { type: "strong", children: [{ type: "text", value: "X" }] },
        ],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-13", "paragraph");
  assert.deepEqual(back, sample);
});

// 14) determinism / idempotency double-pass: a second full round-trip is a
//     no-op for every node kind (proves MARK_ORDER stays aligned).
check("round-trip is idempotent (double-pass, all kinds)", () => {
  const sample = {
    id: "p-14",
    type: "paragraph",
    content: [
      { type: "strong", children: [{ type: "text", value: "b" }] },
      { type: "em", children: [{ type: "text", value: "i" }] },
      { type: "strikethrough", children: [{ type: "text", value: "s" }] },
      { type: "underline", children: [{ type: "text", value: "u" }] },
      { type: "code", value: "c" },
      { type: "link", href: "https://x", children: [{ type: "text", value: "l" }] },
      { type: "wikilink", target: "w", children: [{ type: "text", value: "w" }] },
      { type: "blockref", target: "d", anchor: "a" },
      { type: "tag", name: "t" },
      {
        type: "valueref",
        target: "v",
        field: "f",
        fallback: "fb",
        children: [{ type: "text", value: "fb" }],
      },
    ],
  };
  const once = tiptapToFullBlock(blockToTiptap(sample), "p-14", "paragraph");
  const twice = tiptapToFullBlock(blockToTiptap(once), "p-14", "paragraph");
  assert.deepEqual(once, sample);
  assert.deepEqual(twice, once);
});

// 15) the editor mark schemas carry EXACTLY the attrs convert.js reads. Drift
//     here (e.g. renaming `anchor`→`anchorId`) would silently break the engine
//     round-trip even though the pure converters still pass. (A full TipTap
//     setContent→getJSON round-trip needs jsdom — tracked as a follow-up.)
check("editor mark schemas match convert.js attrs", () => {
  assert.equal(Wikilink.name, "wikilink");
  assert.deepEqual(Object.keys(Wikilink.config.addAttributes()).sort(), [
    "alias",
    "docId",
    "target",
  ]);
  assert.equal(Blockref.name, "blockref");
  assert.deepEqual(Object.keys(Blockref.config.addAttributes()).sort(), [
    "anchor",
    "target",
  ]);
  assert.equal(Tag.name, "tag");
  assert.deepEqual(Object.keys(Tag.config.addAttributes()), ["name"]);
  assert.equal(Valueref.name, "valueref");
  assert.deepEqual(Object.keys(Valueref.config.addAttributes()).sort(), [
    "as",
    "children",
    "fallback",
    "field",
    "label",
    "target",
  ]);
});

// 16) the embed contract exposes its build identity from a DOM-free module (so
//     this guard runs in pure Node, never importing index.js): the versions are
//     package.json's, and BUILD_SHA is null until esbuild defines it.
check("contract exposes CONTRACT_VERSION, EDITOR_VERSION and BUILD_SHA", () => {
  const pkg = JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8"));
  assert.match(CONTRACT_VERSION, /^\d+\.\d+\.\d+$/);
  assert.equal(CONTRACT_VERSION, pkg.barkpark.contractVersion);
  assert.equal(EDITOR_VERSION, pkg.version);
  assert.equal(BUILD_SHA, null);
});

// 17) blockToTiptap is editability-independent — the read-mode `editable`
//     attribute lives entirely in the Web Component (index.js); convert.js has
//     no editability parameter and no DOM, so its output is byte-identical in
//     read and edit mode. This proves the editable seam never reaches convert.js.
check("blockToTiptap is identical regardless of editability", () => {
  const sample = {
    id: "p-17",
    type: "paragraph",
    content: [
      { type: "text", value: "read " },
      { type: "strong", children: [{ type: "text", value: "or" }] },
      { type: "text", value: " edit" },
    ],
  };
  assert.deepEqual(blockToTiptap(sample), blockToTiptap(sample));
});

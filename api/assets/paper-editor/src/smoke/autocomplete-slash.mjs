// smoke/autocomplete-slash.mjs — the canvas slash-menu DIRECT-INSERT round-trips
// (S-slash) + the P5 command-palette registry / Insert-command default-block parity /
// fuzzy filter.
//
// VERBATIM extraction from src/__smoke.mjs §S-slash + §P5-palette: each check moved
// unchanged (same name, body, assertions), carrying the section-local helpers
// (slashInsertOps, SLASH_INSERTABLE, reconstructDefault) and the PALETTE_REGISTRY
// fixture — the two sections share reconstructDefault, so they live in one module. The
// shared check()/assertFolds run through the harness so the aggregate report + exit
// code span all modules.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";
import {
  CANVAS_SLASH_TYPES,
  canvasDefaultBlock,
  slashTypeToNode,
  CANVAS_SLASH_TEXTABLE_NODES,
  slashTriggerAllowsParent,
} from "../canvas/slash-insert.js";
import { normalizeTone } from "../tone.js";
import {
  buildCommandRegistry,
  fuzzyFilterCommands,
  fuzzyMatch,
} from "../canvas/command-palette.js";

// ── P4 S-slash: canvas slash menu DIRECT-INSERT round-trips ─────────────────
//
// The canvas slash pick inserts slashTypeToNode(type) DIRECTLY into the doc — so
// runToOps must emit ONE insert-after (or append, on an empty run) carrying the
// SAME default block default_block/2 would have built. These tests prove that for
// every insertable type, plus the allowlist (excluded types absent) and the
// callout-shorthand replace.

// Helper: insert a slash node AFTER a single anchor block and return the ops.
function slashInsertOps(type) {
  const anchor = { id: "p-1", type: "paragraph", content: [{ type: "text", value: "anchor" }] };
  const prev = [anchor];
  const prevDoc = runToTiptap(prev);
  const node = slashTypeToNode(type);
  const nextDoc = { type: "doc", content: [...prevDoc.content, node] };
  const ops = runToOps(prev, nextDoc);
  return { prev, nextDoc, ops };
}

// (a) Per-type: slashTypeToNode → ONE insert-after carrying { type, …default } whose
//     reconstructed block matches default_block/2, AND the fold reproduces nextDoc.
const SLASH_INSERTABLE = [
  "paragraph",
  "heading",
  "list",
  "callout",
  "code",
  "divider",
  "diagram",
  "field-string",
  "field-boolean",
];
for (const type of SLASH_INSERTABLE) {
  check(`S-slash: /${type} → one insert-after carrying a ${type} block`, () => {
    const { prev, nextDoc, ops } = slashInsertOps(type);
    const inserts = ops.filter((o) => o.op === "insert-after" || o.op === "append-block");
    assert.equal(inserts.length, 1, `${type}: exactly one structural insert`);
    assert.equal(ops.length, 1, `${type}: ONLY the insert (no stray patch/move)`);
    const ins = inserts[0];
    assert.equal(ins.op, "insert-after", `${type}: insert-after (anchor survives)`);
    assert.equal(ins.afterId, "p-1", `${type}: anchored after the surviving block`);
    assert.equal(ins.block.type, type, `${type}: the carried block is of type ${type}`);
    assert.ok(ins.block.id != null, `${type}: the carried block has a minted id`);
    // The carried block is the CANONICAL reconstruction of the default node — the
    // exact shape runToOps+nextNodeToBlock produce, which is what the server persists.
    // It is the NORMALIZED form of default_block/2: the converter drops an empty
    // inline text run (paragraph/list/callout body → []) and omits empty optionals
    // (code.lang, diagram.caption). Both forms are SEMANTICALLY the same default; the
    // canonical form is the fixed point of project→reconstruct. We assert the carried
    // block equals canvasDefaultBlock(type) run through that SAME projection round-trip
    // (so the test pins the canonical shape without hard-coding each normalization).
    const canonical = reconstructDefault(type);
    const { id: _gotId, ...gotRest } = ins.block;
    assert.deepEqual(gotRest, canonical, `${type}: block matches the canonical default shape`);
    // The fold gate: runToOps's ops reproduce nextDoc.
    assertFolds(prev, nextDoc, ops, `S-slash /${type}`);
  });
}

// The CANONICAL reconstructed default for a type: project canvasDefaultBlock(type)
// to a node and reconstruct it through the SAME runToOps insert path, returning the
// carried block minus its (minted) id. This is the fixed point of the projection
// round-trip — the exact normalized shape the server receives — so the per-type
// assertion above pins it without hard-coding each normalization rule.
function reconstructDefault(type) {
  const node = slashTypeToNode(type);
  const ops = runToOps([], { type: "doc", content: [node] });
  const block = ops[0].block;
  const { id: _id, ...rest } = block;
  return rest;
}

// (a*) The NON-EMPTY defaults that MUST survive the round-trip (the load-bearing
//      datums of default_block/2): heading text+level, callout tone, field labels,
//      field-color/field-select values. These pin the fidelity that an empty-content
//      normalization could otherwise mask.
check("S-slash: non-empty defaults survive (heading/callout/field labels+values)", () => {
  const h = reconstructDefault("heading");
  assert.equal(h.text, "New heading", "heading text default");
  assert.equal(h.level, 2, "heading level default is 2");
  const c = reconstructDefault("callout");
  assert.equal(c.tone, "info", "callout default tone is info");
  assert.equal(reconstructDefault("field-slug").label, "Slug", "field-slug label");
  assert.equal(reconstructDefault("field-text").label, "Long text", "field-text label");
  const color = reconstructDefault("field-color");
  assert.equal(color.value, "#000000", "field-color default value");
  const select = reconstructDefault("field-select");
  assert.equal(select.value, "", "field-select default value is empty");
  assert.deepEqual(
    select.options,
    [
      { value: "option-1", label: "Option 1" },
      { value: "option-2", label: "Option 2" },
    ],
    "field-select default options",
  );
});

// (a') field-boolean's default value is the BOOLEAN false (not "" or "false") — the
//      per-type default that distinguishes it from the string fields.
check("S-slash: /field-boolean default value is boolean false", () => {
  const { ops } = slashInsertOps("field-boolean");
  const ins = ops.find((o) => o.op === "insert-after");
  assert.equal(ins.block.value, false, "the default boolean value is false");
  assert.equal(typeof ins.block.value, "boolean", "and it is a real boolean");
});

// (a'') field-string's default value is the empty STRING (the non-boolean default).
check("S-slash: /field-string default value is empty string", () => {
  const { ops } = slashInsertOps("field-string");
  const ins = ops.find((o) => o.op === "insert-after");
  assert.equal(ins.block.value, "", "the default string value is \"\"");
  assert.equal(ins.block.label, "Text", "and the default label is Text");
});

// (b) INSERT INTO AN EMPTY RUN — append-block (no surviving anchor). A divider into
//     an empty doc appends and reconstructs as a divider block.
check("S-slash: /divider into an EMPTY run → append-block of a divider", () => {
  const prev = [];
  const node = slashTypeToNode("divider");
  const nextDoc = { type: "doc", content: [node] };
  const ops = runToOps(prev, nextDoc);
  assert.equal(ops.length, 1, "one op");
  assert.equal(ops[0].op, "append-block", "appended (no anchor in an empty run)");
  assert.equal(ops[0].block.type, "divider", "the appended block is a divider");
  assertFolds(prev, nextDoc, ops, "S-slash /divider empty");
});

// (c) THE ALLOWLIST — every insertable type is IN, every excluded type is OUT.
check("S-slash: CANVAS_SLASH_TYPES holds exactly the insertable set", () => {
  for (const t of [
    "paragraph", "heading", "list", "callout", "code", "divider", "diagram",
    "field-string", "field-slug", "field-text", "field-boolean",
    "field-select", "field-datetime", "field-color",
  ]) {
    assert.ok(CANVAS_SLASH_TYPES.has(t), `${t} must be insertable`);
  }
  // EXCLUDED from SLASH-INSERT (NOT the same as canvas-eligibility): read-only refs
  // (sheet/embed) and the pickers (field-image/field-reference) DO ride the canvas now,
  // but a "/" pick can't DIRECT-insert them — sheet/embed are references with no empty
  // default, and the pickers need a fetch-scope (dataset/refType) the slash default
  // can't supply. Also excluded: the nested-structure run-splitting boundaries
  // (section/composite/arrayOf/codelist/localizedText) and the article-chrome blocks
  // (eyebrow/byline/ingress/pullquote).
  for (const t of [
    "sheet", "embed", "section", "composite", "arrayOf", "codelist", "localizedText",
    "field-image", "field-reference", "eyebrow", "byline", "ingress", "pullquote",
  ]) {
    assert.ok(!CANVAS_SLASH_TYPES.has(t), `${t} must NOT be insertable`);
  }
  assert.equal(CANVAS_SLASH_TYPES.size, 14, "exactly 14 insertable types");
});

// (d) THE CALLOUT SHORTHAND — `> [!warn]- ` replaces the para with a bpCallout node
//     of the matched tone (warning), collapsed. We build the node the WC builds and
//     assert runToOps reconstructs a callout block of that tone (collapsible/collapsed
//     carried). This mirrors _maybeCalloutShorthand's node construction.
check("S-slash: `> [!warn]- ` → a warning callout (collapsed) insert", () => {
  // The WC: canvasDefaultBlock("callout") + tone from normalizeTone(m[1]) + collapsible
  // + collapsed = (m[2] === "-").
  const tone = normalizeTone("warn"); // → "warning"
  const collapsed = "-" === "-"; // true
  const block = canvasDefaultBlock("callout");
  block.tone = tone;
  block.collapsible = true;
  block.collapsed = collapsed;
  const node = runToTiptap([block]).content[0];
  // Replace a "/"-typed origin paragraph (modelled as a removed prev block) with the
  // callout: prev has one paragraph, next has ONLY the callout node → remove + insert.
  const prev = [{ id: "o-1", type: "paragraph", content: [{ type: "text", value: "" }] }];
  const nextDoc = { type: "doc", content: [node] };
  const ops = runToOps(prev, nextDoc);
  const inserts = ops.filter((o) => o.op === "insert-after" || o.op === "append-block");
  assert.equal(inserts.length, 1, "one structural insert (the callout)");
  const ins = inserts[0];
  assert.equal(ins.block.type, "callout", "the inserted block is a callout");
  assert.equal(ins.block.tone, "warning", "tone is warning (warn → warning)");
  assert.equal(ins.block.collapsible, true, "collapsible carried");
  assert.equal(ins.block.collapsed, true, "collapsed (modifier was '-')");
  // The origin paragraph is removed (the shorthand consumed it).
  assert.ok(ops.some((o) => o.op === "remove-block" && o.id === "o-1"), "origin para removed");
  assertFolds(prev, nextDoc, ops, "S-slash callout-shorthand");
});

// (d') `> [!note] ` (no modifier) → an info callout (note → info), NOT collapsed.
check("S-slash: `> [!note] ` → an info callout (not collapsed)", () => {
  const block = canvasDefaultBlock("callout");
  block.tone = normalizeTone("note"); // → "info"
  block.collapsible = true;
  block.collapsed = false; // m[2] === "" → not collapsed
  const node = runToTiptap([block]).content[0];
  const prev = [{ id: "o-1", type: "paragraph", content: [{ type: "text", value: "" }] }];
  const nextDoc = { type: "doc", content: [node] };
  const ops = runToOps(prev, nextDoc);
  const ins = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.equal(ins.block.type, "callout", "a callout");
  assert.equal(ins.block.tone, "info", "tone is info (note → info)");
  // collapsed:false is NOT carried (calloutBlockToNode threads it only when === true),
  // so the reconstructed block has no `collapsed` key — byte-fidelity with default_block.
  assert.ok(!("collapsed" in ins.block), "no stray collapsed:false key");
});

// (e) TEXTABLE-NODE classification — prose/callout take an into-body caret; the atoms
//     (divider/code/diagram/field) do not. Asserts the node-type names the WC keys on.
check("S-slash: CANVAS_SLASH_TEXTABLE_NODES classifies body vs atom nodes", () => {
  // The projected node TYPE for each insertable type (runToTiptap naming).
  const projType = (t) => slashTypeToNode(t).type;
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("paragraph")), "paragraph is textable");
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("heading")), "heading is textable");
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("list")), "list (bulletList) is textable");
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("callout")), "callout is textable");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("divider")), "divider is an atom");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("code")), "code (bpCode) is an atom");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("diagram")), "diagram (bpDiagram) is an atom");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("field-string")), "field (bpField) is an atom");
});

// (f) BUG#2 GUARD — slashTriggerAllowsParent must REJECT a callout-body parent and
//     ACCEPT a top-level paragraph/heading. The `/` slash menu and the `> [!type]`
//     callout shorthand both REPLACE the whole enclosing textblock with a top-level
//     node (start=$pos.before(depth)/end=$pos.after(depth)). A callout body
//     (callout-node.js group:"block", content:"inline*") is ALSO a depth-1 node, so a
//     depth-only guard let "/head"+Enter / "> [!warning] " typed INSIDE a callout body
//     pass → replaceWith spanned + DESTROYED the enclosing callout. The guard must key
//     on the parent node TYPE, not depth alone.
check("S-slash: slashTriggerAllowsParent rejects a callout body, accepts prose", () => {
  // ACCEPT — a top-level paragraph/heading (depth 1, prose parent): the only safe
  // place to replace the block with a top-level node.
  assert.equal(slashTriggerAllowsParent(1, "paragraph"), true, "top-level paragraph accepted");
  assert.equal(slashTriggerAllowsParent(1, "heading"), true, "top-level heading accepted");

  // REJECT — a callout BODY. It is depth 1 (top-level node) but its parent TYPE is
  // "callout", so the swap would destroy the enclosing callout. This is the bug fix.
  assert.equal(slashTriggerAllowsParent(1, "callout"), false, "callout body rejected (Bug #2)");

  // REJECT — a paragraph nested inside a list item (depth 3): pre-existing nesting
  // guard, must keep rejecting (swapping the inner paragraph for a top-level node
  // would corrupt the doc).
  assert.equal(slashTriggerAllowsParent(3, "paragraph"), false, "list-item paragraph rejected");
  // Defensive: a future inline-content node-view (any non-prose parent type) is rejected
  // even at depth 1.
  assert.equal(slashTriggerAllowsParent(1, "tableCell"), false, "non-prose depth-1 parent rejected");
});

// ── P5 command palette: registry + Insert-command default_block PARITY + fuzzy ──
//
// The palette is the Obsidian Cmd-P analog — a keyboard-triggered launcher over the
// command registry. These pure tests prove (a) the registry is WELL-FORMED (every
// command has id/label/group/run); (b) the Insert commands produce the SAME default
// block as the slash pick — the registry Insert run() and the slash pick BOTH route
// through slashTypeToNode → so an Insert command is byte-equal to the slash-menu path,
// asserted by reconstructing each insertable type the SAME way the S-slash tests do;
// and (c) the fuzzy filter returns the expected matches. The live FORMAT/TURN-INTO
// toggle EFFECTS need a real editor (a DOM ProseMirror instance), so they are left to
// the orchestrator's browser check — here we assert the COMMANDS exist + are shaped.

// buildCommandRegistry() with no editor → the documented static contract (the full
// canvas StarterKit command set is assumed present).
const PALETTE_REGISTRY = buildCommandRegistry();

check("P5 palette: registry is well-formed (id/label/group/run on every command)", () => {
  assert.ok(Array.isArray(PALETTE_REGISTRY), "registry is an array");
  assert.ok(PALETTE_REGISTRY.length > 0, "registry is non-empty");
  const ids = new Set();
  for (const c of PALETTE_REGISTRY) {
    assert.equal(typeof c.id, "string", "id is a string");
    assert.ok(c.id.length > 0, `id non-empty (${c.label})`);
    assert.ok(!ids.has(c.id), `id ${c.id} is unique`);
    ids.add(c.id);
    assert.equal(typeof c.label, "string", `${c.id}: label is a string`);
    assert.ok(c.label.length > 0, `${c.id}: label non-empty`);
    assert.equal(typeof c.group, "string", `${c.id}: group is a string`);
    assert.ok(
      ["Insert", "Format", "Turn into"].includes(c.group),
      `${c.id}: group is one of Insert/Format/Turn into (got ${c.group})`,
    );
    assert.equal(typeof c.run, "function", `${c.id}: run is a function`);
  }
});

check("P5 palette: one Insert command per CANVAS_SLASH_TYPES entry", () => {
  const insertCmds = PALETTE_REGISTRY.filter((c) => c.group === "Insert");
  // Every insertable type has an Insert command, keyed insert-<type>.
  for (const t of CANVAS_SLASH_TYPES) {
    assert.ok(
      insertCmds.some((c) => c.id === `insert-${t}`),
      `Insert command for ${t} present`,
    );
  }
  assert.equal(
    insertCmds.length,
    CANVAS_SLASH_TYPES.size,
    "exactly one Insert command per insertable type (no extras)",
  );
});

check("P5 palette: Format + Turn-into commands present (canvas StarterKit set)", () => {
  const fmt = PALETTE_REGISTRY.filter((c) => c.group === "Format").map((c) => c.id);
  // bold / italic / strike / code marks ship in the canvas StarterKit; clear too.
  for (const id of ["format-bold", "format-italic", "format-strike", "format-code", "format-clear"]) {
    assert.ok(fmt.includes(id), `${id} present`);
  }
  const turn = PALETTE_REGISTRY.filter((c) => c.group === "Turn into").map((c) => c.id);
  for (const id of ["turn-paragraph", "turn-h1", "turn-h2", "turn-h3", "turn-bullet", "turn-ordered"]) {
    assert.ok(turn.includes(id), `${id} present`);
  }
});

// (PARITY) — each Insert command's slashTypeToNode → nextNodeToBlock is BYTE-EQUAL to
// the slash-menu path. We prove parity by reconstructing the default block the SAME
// way the S-slash test does (reconstructDefault, defined above) and asserting it
// matches what the Insert command would insert — both call slashTypeToNode(type), so
// the inserted block is identical. This is the default_block parity the task demands.
check("P5 palette: Insert command default block == slash-menu default block (parity)", () => {
  for (const type of [
    "paragraph", "heading", "list", "callout", "code", "divider", "diagram",
    "field-string", "field-slug", "field-text", "field-boolean",
    "field-select", "field-datetime", "field-color",
  ]) {
    // The slash-menu path: slashTypeToNode(type) → runToOps reconstructs the block.
    const slashBlock = reconstructDefault(type);
    // The palette Insert path inserts slashTypeToNode(type) at the selection (the
    // SAME node); reconstructing it the same way yields the SAME block. We assert the
    // canonical reconstruction is identical (the Insert command carries no extra
    // shape — it is exactly the slash node).
    const node = slashTypeToNode(type);
    const ops = runToOps([], { type: "doc", content: [node] });
    const { id: _id, ...paletteBlock } = ops[0].block;
    assert.deepEqual(
      paletteBlock,
      slashBlock,
      `Insert ${type}: palette block byte-equal to the slash-menu default block`,
    );
  }
});

check("P5 palette: fuzzy filter returns the expected matches", () => {
  // "cal" → Insert Callout (subsequence c-a-l in "Insert Callout").
  const cal = fuzzyFilterCommands(PALETTE_REGISTRY, "cal");
  assert.ok(cal.some((c) => c.id === "insert-callout"), "\"cal\" matches Insert Callout");

  // "bold" → Format Bold.
  const bold = fuzzyFilterCommands(PALETTE_REGISTRY, "bold");
  assert.ok(bold.some((c) => c.id === "format-bold"), "\"bold\" matches Format Bold");
  assert.ok(!bold.some((c) => c.id === "format-italic"), "\"bold\" does NOT match Italic");

  // "h2" → Turn into Heading 2 (subsequence over "Turn into Heading 2").
  const h2 = fuzzyFilterCommands(PALETTE_REGISTRY, "h2");
  assert.ok(h2.some((c) => c.id === "turn-h2"), "\"h2\" matches Turn into Heading 2");

  // Group is part of the haystack: "insert" returns ALL Insert commands.
  const ins = fuzzyFilterCommands(PALETTE_REGISTRY, "insert");
  assert.equal(
    ins.length,
    PALETTE_REGISTRY.filter((c) => c.group === "Insert").length,
    "\"insert\" matches every Insert command (group in the haystack)",
  );

  // Empty query passes EVERYTHING (the open-palette resting state).
  assert.equal(
    fuzzyFilterCommands(PALETTE_REGISTRY, "").length,
    PALETTE_REGISTRY.length,
    "empty query passes the whole registry",
  );

  // A no-match query returns []. "zzzq" is no subsequence of any label+group.
  assert.equal(fuzzyFilterCommands(PALETTE_REGISTRY, "zzzq").length, 0, "no-match → []");

  // Filter PRESERVES registry order (group-contiguity for grouped rendering).
  const all = fuzzyFilterCommands(PALETTE_REGISTRY, "");
  assert.deepEqual(all.map((c) => c.id), PALETTE_REGISTRY.map((c) => c.id), "order preserved");
});

check("P5 palette: fuzzyMatch is a subsequence match (order-sensitive, case-insensitive)", () => {
  assert.ok(fuzzyMatch("cal", "Insert Callout"), "c-a-l is a subsequence");
  assert.ok(fuzzyMatch("CAL", "insert callout"), "case-insensitive");
  assert.ok(fuzzyMatch("", "anything"), "empty query always matches");
  assert.ok(!fuzzyMatch("lac", "Insert Callout"), "wrong order does NOT match");
  assert.ok(!fuzzyMatch("xyz", "Insert Callout"), "absent chars do NOT match");
});

check("P5 palette: editor-filtered registry hides unregistered commands (underline)", () => {
  // A fake editor exposing ONLY bold among the toggles + the node commands; no
  // toggleUnderline → no underline command. Proves the editor-filtered build.
  const fakeEditor = {
    commands: {
      toggleBold: () => {},
      // italic/strike/code/underline intentionally ABSENT
      unsetAllMarks: () => {},
      setParagraph: () => {},
      toggleHeading: () => {},
      toggleBulletList: () => {},
      toggleOrderedList: () => {},
    },
  };
  const reg = buildCommandRegistry(fakeEditor);
  const ids = reg.map((c) => c.id);
  assert.ok(ids.includes("format-bold"), "bold present (registered)");
  assert.ok(!ids.includes("format-italic"), "italic absent (not registered)");
  assert.ok(!ids.includes("format-underline"), "underline absent (not registered)");
  // Insert + turn-into still present (their commands are registered).
  assert.ok(ids.includes("insert-callout"), "insert still present");
  assert.ok(ids.includes("turn-h2"), "turn-into still present");
});

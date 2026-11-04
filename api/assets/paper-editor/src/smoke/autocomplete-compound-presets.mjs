// smoke/autocomplete-compound-presets.mjs — compound and section-preset insert gates.
//
// Mechanical continuation of autocomplete-slash.mjs; check bodies and fixtures are
// preserved. This module builds its own registry from the pure registry factory.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";
import {
  CANVAS_SECTION_PRESETS,
  sectionPresetBlocks,
  sectionPresetNodes,
  sectionPresetCaretTarget,
} from "../canvas/section-presets.js";
import {
  CANVAS_SLASH_TYPES,
  canvasDefaultBlock,
  CANVAS_COMPOUND_INSERTS,
  compoundInsertBlock,
  compoundKindToNode,
} from "../canvas/slash-insert.js";
import { buildCommandRegistry } from "../canvas/command-palette.js";

const PALETTE_REGISTRY = buildCommandRegistry();

// ── COMPOUND INSERTS (the Starters group — grid-of-cards) ────────────────────
//
// A compound insert is ONE authoring action inserting a PRE-COMPOSED subtree (a
// container + seeded children) as a SINGLE node. It deliberately lives OUTSIDE
// CANVAS_SLASH_TYPES (typed single-node — the size-23 pin and the one-Insert-command-
// per-type parity above stay honest) in its own registry + palette group. These
// checks prove: the registry⇄palette lockstep, the built block's shape (the
// SECTION_OF_CARDS shape smoke/cards.mjs proves round-trips at zero ops), the insert
// path (ONE insert-after, every id minted, fold reproduces the doc), and that the
// INSERTED compound is the projection fixed point (zero ops on the next load).

check("compound: registry ⇄ palette Starters lockstep (one command per kind, none in Insert)", () => {
  assert.ok(CANVAS_COMPOUND_INSERTS.length > 0, "at least one compound starter");
  const starters = PALETTE_REGISTRY.filter((c) => c.group === "Starters");
  for (const c of CANVAS_COMPOUND_INSERTS) {
    assert.equal(typeof c.kind, "string", "kind is a string");
    assert.ok(!CANVAS_SLASH_TYPES.has(c.kind), `${c.kind} is NOT a fake CANVAS_SLASH_TYPES member`);
    assert.ok(
      starters.some((s) => s.id === `compound-${c.kind}`),
      `Starters command for ${c.kind} present`,
    );
  }
  assert.equal(
    starters.length,
    CANVAS_COMPOUND_INSERTS.length,
    "exactly one Starters command per compound kind (no extras)",
  );
  // And none of them leaked into the Insert group (the count-parity contract).
  assert.ok(
    !PALETTE_REGISTRY.some((c) => c.group === "Insert" && c.id.startsWith("compound-")),
    "no compound command rides the Insert group",
  );
});

check("compound: cards-grid block = section{grid,2 tracks} + 2 default cards (id-less)", () => {
  const block = compoundInsertBlock("cards-grid");
  assert.equal(block.type, "section", "the compound is ONE section block");
  assert.deepEqual(block.layout, { mode: "grid", tracks: 2 }, "2-track grid layout");
  assert.equal(block.blocks.length, 2, "two seeded children");
  for (const child of block.blocks) {
    assert.deepEqual(child, canvasDefaultBlock("card"), "each child IS the default card");
    assert.equal(child.id, null, "children are id-less (runToOps mints)");
  }
  assert.equal(block.id, null, "the section is id-less (runToOps mints)");
  // Defensive: an unknown kind builds nothing (callers no-op).
  assert.equal(compoundInsertBlock("nope"), null, "unknown kind → null");
  assert.equal(compoundKindToNode("nope"), null, "unknown kind → no node");
});

check("compound: inserting cards-grid → ONE insert-after, every id minted, fold reproduces", () => {
  const anchor = { id: "p-1", type: "paragraph", content: [{ type: "text", value: "anchor" }] };
  const prev = [anchor];
  const prevDoc = runToTiptap(prev);
  const node = compoundKindToNode("cards-grid");
  assert.equal(node.type, "bpSection", "the compound projects to ONE bpSection node");
  assert.equal(node.content.length, 2, "holding 2 children");
  assert.equal(node.content[0].type, "bpCard", "child 1 is a bpCard");
  assert.equal(node.content[1].type, "bpCard", "child 2 is a bpCard");
  const nextDoc = { type: "doc", content: [...prevDoc.content, node] };
  const ops = runToOps(prev, nextDoc);
  assert.equal(ops.length, 1, "ONE authoring action → ONE op");
  const ins = ops[0];
  assert.equal(ins.op, "insert-after", "an insert-after (the anchor survives)");
  assert.equal(ins.afterId, "p-1", "anchored after the surviving block");
  assert.equal(ins.block.type, "section", "carrying the section");
  assert.deepEqual(ins.block.layout, { mode: "grid", tracks: 2 }, "grid layout carried");
  assert.equal(ins.block.blocks.length, 2, "both cards carried");
  const ids = [ins.block.id, ins.block.blocks[0].id, ins.block.blocks[1].id];
  for (const id of ids) assert.ok(id != null, "every id minted (section + both cards)");
  assert.equal(new Set(ids).size, 3, "minted ids are distinct (no collision)");
  for (const child of ins.block.blocks) {
    assert.equal(child.type, "card", "child is a card");
    assert.deepEqual(
      child.slots.title,
      [{ type: "heading", text: "New card" }],
      "child title slot is the default",
    );
    assert.ok(!("tone" in child), "child gained no tone (present-only)");
  }
  assertFolds(prev, nextDoc, ops, "compound cards-grid insert");
});

check("compound: the INSERTED cards-grid round-trips at ZERO ops (+ real bpCard children)", () => {
  // Reconstruct the persisted block exactly as the insert path does (minted ids)…
  const node = compoundKindToNode("cards-grid");
  const insertOps = runToOps([], { type: "doc", content: [node] });
  const persisted = insertOps[0].block;
  // …then re-project it (the next editor load) and prove ZERO ops. Anti-vacuous:
  // the re-projected section really carries 2 bpCard children.
  const blocks = [persisted];
  const doc = runToTiptap(blocks);
  const sec = doc.content[0];
  assert.equal(sec.type, "bpSection");
  assert.equal(sec.content.length, 2, "two card children survive the round-trip");
  assert.equal(sec.content[0].type, "bpCard");
  assert.equal(sec.content[1].type, "bpCard");
  const ops = runToOps(blocks, doc);
  assert.deepEqual(ops, [], "the inserted compound is the projection fixed point (zero ops)");
  const folded = assertFolds(blocks, doc, ops, "inserted cards-grid re-load");
  assert.deepEqual(folded, blocks, "the persisted grid survives byte-identical");
});

// ── SECTION PRESETS (the Presets group — the /papers/section-presets assemblies) ──
//
// A section preset is ONE authoring action inserting an ORDERED SEQUENCE of N
// TOP-LEVEL blocks — the third insert shape, after the typed single node (Insert) and
// the single pre-composed subtree (Starters). It rides its OWN registry so BOTH
// existing count-parity contracts above stay honest. These checks prove: the
// registry⇄palette lockstep + four DISTINCT names, the documented assembly of each
// preset (block counts and ordered types, read off the served Paper), that every
// block is an EXISTING portable-doc type (no new block types → no render change),
// that each insert emits ONE insert-after PER block with every id minted and the fold
// reproducing the doc, and that the INSERTED preset is the projection fixed point.
//
// THE CARET CONTRACT lives here only as the DECLARATION check (the placeholder a
// preset claims is really the text of the block it points at). The LIVE proof — that
// the placeholder is SELECTED so the next keystroke overtypes it — needs a real
// ProseMirror view and lives in canvas/__section_presets_mounted.test.mjs.

// Every type any preset assembly uses, and the portable-doc block types the
// projection knows. A preset must never introduce a NEW type: the render path is
// untouched, so every block has to be one runToTiptap already projects.
const PRESET_KINDS = CANVAS_SECTION_PRESETS.map((p) => p.kind);

check("preset: registry ⇄ palette Presets lockstep (four DISTINCT presets, none in Insert/Starters)", () => {
  assert.equal(CANVAS_SECTION_PRESETS.length, 4, "exactly four section presets");
  assert.equal(new Set(PRESET_KINDS).size, 4, "four DISTINCT kinds");
  assert.deepEqual(
    PRESET_KINDS,
    ["masthead", "annotated-figure", "live-dashboard", "runbook-step"],
    "the four documented kinds, in the Paper's order",
  );
  const labels = CANVAS_SECTION_PRESETS.map((p) => p.label);
  assert.deepEqual(
    labels,
    ["Masthead", "Annotated figure", "Live dashboard section", "Runbook step"],
    "four DISTINCTLY NAMED palette entries",
  );
  assert.equal(new Set(labels).size, 4, "no two presets share a name");

  const presets = PALETTE_REGISTRY.filter((c) => c.group === "Presets");
  for (const p of CANVAS_SECTION_PRESETS) {
    assert.ok(!CANVAS_SLASH_TYPES.has(p.kind), `${p.kind} is NOT a fake CANVAS_SLASH_TYPES member`);
    const cmd = presets.find((c) => c.id === `preset-${p.kind}`);
    assert.ok(cmd, `Presets command for ${p.kind} present`);
    assert.equal(cmd.label, `Insert ${p.label}`, `${p.kind}: label carries the preset name`);
    assert.equal(typeof cmd.run, "function", `${p.kind}: run is a function`);
  }
  assert.equal(
    presets.length,
    CANVAS_SECTION_PRESETS.length,
    "exactly one Presets command per preset kind (no extras)",
  );
  // Neither existing count-parity contract absorbed a preset.
  assert.ok(
    !PALETTE_REGISTRY.some(
      (c) => (c.group === "Insert" || c.group === "Starters") && c.id.startsWith("preset-"),
    ),
    "no preset command rides the Insert or Starters group",
  );
});

check("preset: each assembly is the documented ordered block sequence (the Paper's recipes)", () => {
  // 01 MASTHEAD — SEVEN blocks, kicker → TOC.
  const masthead = sectionPresetBlocks("masthead");
  assert.equal(masthead.length, 7, "masthead has SEVEN blocks");
  assert.deepEqual(
    masthead.map((b) => b.type),
    ["eyebrow", "heading", "ingress", "byline", "stats", "divider", "toc"],
    "masthead order: eyebrow → h1 → ingress → byline → stats → divider → toc",
  );
  assert.equal(masthead[1].level, 1, "the masthead headline is a DISPLAY h1");
  assert.equal(masthead[4].items.length, 4, "a 4-tile stat wall");
  assert.equal(masthead[4].items[1].denom, "<of>", "the 2nd tile carries denom (the a/b read)");

  // 02 ANNOTATED FIGURE — a chart PLUS the annotation layer.
  const figure = sectionPresetBlocks("annotated-figure");
  assert.deepEqual(figure.map((b) => b.type), ["chart"], "the figure is one chart block");
  assert.equal(figure[0].kind, "line", "a line chart");
  assert.equal(figure[0].series.length, 1, "one seeded series");
  const ann = figure[0].annotations;
  assert.equal(ann.regions.length, 1, "a region wash");
  assert.equal(ann.refLines.length, 1, "a refLine target");
  assert.equal(ann.points.length, 1, "a point callout");
  assert.ok(figure[0].caption.startsWith("Figure <N>"), "a caption that states the claim");

  // 03 LIVE DASHBOARD — query stat/chart/task-board.
  const dash = sectionPresetBlocks("live-dashboard");
  assert.deepEqual(
    dash.map((b) => b.type),
    ["eyebrow", "columns", "chart", "task-board"],
    "dashboard order: eyebrow → columns of stats → chart → task board",
  );
  assert.equal(dash[1].columns.length, 3, "THREE stat columns");
  for (const col of dash[1].columns) {
    assert.equal(col.length, 1, "one block per column");
    assert.equal(col[0].type, "stat", "each column holds a stat");
    assert.ok(col[0].query?.filter, "each stat is QUERY-driven (not a literal number)");
  }
  assert.ok(dash[2].query?.over, "the chart is a query over a bucket");
  assert.equal(dash[2].query.over.on, "closed_at", "bucketed on closed_at");
  assert.ok(dash[3].query?.parent_id, "the task board is query-driven");

  // 04 RUNBOOK STEP — steps + terminal + rollback callout.
  const runbook = sectionPresetBlocks("runbook-step");
  assert.deepEqual(
    runbook.map((b) => b.type),
    ["steps", "callout"],
    "runbook order: steps → rollback callout",
  );
  assert.equal(runbook[0].steps.length, 2, "a do step and a VERIFY step");
  assert.deepEqual(
    runbook[0].steps[0].blocks.map((b) => b.type),
    ["paragraph", "terminal"],
    "the first step carries a terminal transcript",
  );
  assert.equal(runbook[1].tone, "warn", "the rollback callout is a warning");
  assert.equal(runbook[1].title, "Rollback", "…titled Rollback");

  // Defensive: an unknown kind builds nothing (callers no-op).
  assert.deepEqual(sectionPresetBlocks("nope"), [], "unknown kind → no blocks");
  assert.deepEqual(sectionPresetNodes("nope"), [], "unknown kind → no nodes");
  assert.equal(sectionPresetCaretTarget("nope"), null, "unknown kind → no caret target");
});

check("preset: every block is an EXISTING portable-doc type (no new block types) and id-less", () => {
  // The render path is untouched, so the ONLY proof that matters is that each block
  // projects through runToTiptap to a REAL node — a type the projection does not know
  // would fall through to nothing/opaque garbage rather than a typed node.
  for (const kind of PRESET_KINDS) {
    const blocks = sectionPresetBlocks(kind);
    const nodes = sectionPresetNodes(kind);
    assert.equal(nodes.length, blocks.length, `${kind}: one node per block`);
    for (const b of blocks) {
      assert.equal(b.id, null, `${kind}/${b.type}: id-less (runToOps mints on insert)`);
    }
    for (let i = 0; i < nodes.length; i += 1) {
      assert.equal(
        nodes[i].attrs.bpType,
        blocks[i].type,
        `${kind}: node ${i} projects as the SAME portable-doc type`,
      );
    }
  }
  // Anti-vacuous: the projection really does name the node types we expect, so the
  // loop above is comparing something real.
  assert.deepEqual(
    sectionPresetNodes("masthead").map((n) => n.type),
    ["eyebrow", "heading", "ingress", "byline", "bpFleet", "divider", "bpToc"],
    "the masthead projects to the article-chrome / fleet / divider / contents node set (toc is a canvas atom now)",
  );
});

check("preset: a fresh deep structure per call (two inserts never share a nested ref)", () => {
  const a = sectionPresetBlocks("masthead");
  const b = sectionPresetBlocks("masthead");
  assert.notEqual(a, b, "a new array per call");
  assert.notEqual(a[4].items[0], b[4].items[0], "nested objects are NOT shared");
  a[4].items[0].label = "MUTATED";
  assert.equal(
    sectionPresetBlocks("masthead")[4].items[0].label,
    "<what it counts>",
    "mutating one build does not poison the next",
  );
});

check("preset: inserting each preset → one insert PER block, ids minted, fold reproduces", () => {
  // THE WIRE SHAPE. A preset lands N NEW top-level blocks at once, so the diff emits
  // one insert op per block — every one anchored to the last block the SERVER already
  // knows (a brand-new sibling has no server id to anchor to yet) — followed by the
  // move-block run that orders the tail. That is the generic multi-insert shape, not a
  // preset special case; what this check pins is that NOTHING is lost or duplicated:
  // one insert per documented block, in order, every id minted and distinct, and the
  // fold of the whole batch reproduces the doc EXACTLY.
  for (const kind of PRESET_KINDS) {
    const anchor = { id: "p-1", type: "paragraph", content: [{ type: "text", value: "anchor" }] };
    const prev = [anchor];
    const prevDoc = runToTiptap(prev);
    const nodes = sectionPresetNodes(kind);
    const nextDoc = { type: "doc", content: [...prevDoc.content, ...nodes] };
    const ops = runToOps(prev, nextDoc);

    const inserts = ops.filter((o) => o.op === "insert-after" || o.op === "append-block");
    assert.equal(inserts.length, nodes.length, `${kind}: one insert op per inserted block`);
    assert.deepEqual(
      ops.filter((o) => o.op !== "insert-after" && o.op !== "append-block").map((o) => o.op),
      new Array(Math.max(nodes.length - 1, 0)).fill("move-block"),
      `${kind}: the only other ops are the ${nodes.length - 1} tail-ordering moves`,
    );
    assert.deepEqual(
      inserts.map((o) => o.block.type),
      sectionPresetBlocks(kind).map((b) => b.type),
      `${kind}: the inserts carry the documented block sequence, in order`,
    );
    const ids = inserts.map((o) => o.block.id);
    for (const id of ids) assert.ok(id != null, `${kind}: every inserted block got a minted id`);
    assert.equal(new Set(ids).size, ids.length, `${kind}: minted ids are distinct (no collision)`);
    assert.ok(
      ops.every((o) => o.op !== "remove-block"),
      `${kind}: the anchor paragraph survives (no removes)`,
    );

    const folded = assertFolds(prev, nextDoc, ops, `${kind} preset insert`);
    assert.equal(folded.length, 1 + nodes.length, `${kind}: the anchor plus every preset block`);
    assert.deepEqual(
      folded.slice(1).map((b) => b.type),
      sectionPresetBlocks(kind).map((b) => b.type),
      `${kind}: the folded run IS the documented assembly, in order`,
    );
  }
});

check("preset: the INSERTED preset round-trips at ZERO ops (projection fixed point)", () => {
  for (const kind of PRESET_KINDS) {
    // Reconstruct the persisted run exactly as the insert path does (minted ids,
    // ordered by the fold)…
    const nodes = sectionPresetNodes(kind);
    const nextDoc = { type: "doc", content: nodes };
    const insertOps = runToOps([], nextDoc);
    const persisted = assertFolds([], nextDoc, insertOps, `${kind} preset first insert`);
    assert.equal(
      persisted.length,
      sectionPresetBlocks(kind).length,
      `${kind}: every block persisted`,
    );

    // …then re-project it (the next editor load) and prove ZERO ops.
    const doc = runToTiptap(persisted);
    assert.equal(doc.content.length, persisted.length, `${kind}: re-projects block-for-block`);
    const ops = runToOps(persisted, doc);
    assert.deepEqual(ops, [], `${kind}: the inserted preset is the projection fixed point`);
    const folded = assertFolds(persisted, doc, ops, `inserted ${kind} re-load`);
    assert.deepEqual(folded, persisted, `${kind}: the persisted assembly survives byte-identical`);
  }
});

check("preset: every caret target names a real block, and its placeholder IS that block's text", () => {
  for (const p of CANVAS_SECTION_PRESETS) {
    const target = sectionPresetCaretTarget(p.kind);
    const blocks = sectionPresetBlocks(p.kind);
    assert.ok(target, `${p.kind}: declares a caret target`);
    assert.ok(
      Number.isInteger(target.block) && target.block >= 0 && target.block < blocks.length,
      `${p.kind}: caret block ${target.block} is inside the assembly (0..${blocks.length - 1})`,
    );
    const block = blocks[target.block];
    if (target.placeholder === null) {
      // A data-viz atom has no ProseMirror text hole — the block is NodeSelection-ed.
      assert.ok(
        ["chart", "stat", "stats", "task-board", "heatmap", "stat-grid"].includes(block.type),
        `${p.kind}: only a data-viz atom may decline a placeholder (got ${block.type})`,
      );
    } else {
      // The declared placeholder must be the EXACT text of the target block, because
      // the insert selects that block's whole inline hole. A drifted string here
      // would select text the author did not expect to lose.
      const text =
        block.text ??
        (block.content || []).map((n) => n.value ?? "").join("");
      assert.equal(
        text,
        target.placeholder,
        `${p.kind}: the declared placeholder IS block ${target.block}'s text`,
      );
      assert.ok(text.length > 0, `${p.kind}: the placeholder is non-empty (there is something to select)`);
    }
  }
});

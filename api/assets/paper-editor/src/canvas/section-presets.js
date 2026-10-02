// canvas/section-presets.js — PURE, DOM-free registry of the four SECTION PRESETS.
//
// A section preset is ONE authoring action that inserts a documented, ORDERED
// SEQUENCE of top-level blocks — the "assemblies, not atoms" recipes published at
// /papers/section-presets (masthead, annotated figure, live dashboard section,
// runbook step). Phase (b) of study recommendation #2 in /papers/portabledoc-
// potential-study §6: the recipes existed only as copy-paste JSON on that page;
// this module lands them at the editor's insertion seam.
//
// WHY ITS OWN REGISTRY (and not CANVAS_SLASH_TYPES / CANVAS_COMPOUND_INSERTS):
//   * CANVAS_SLASH_TYPES is typed SINGLE-NODE (one type → one default block → one
//     node) and its size is pin-tested against the palette's per-type Insert
//     commands (smoke/autocomplete-slash.mjs count parity).
//   * CANVAS_COMPOUND_INSERTS is ONE pre-composed top-level block (a container plus
//     seeded children) — still exactly one node, still one insert-after op.
//   * A preset is N TOP-LEVEL blocks. It is the third shape, so it rides its own
//     table to keep both existing contracts honest.
//
// NO NEW BLOCK TYPES and NO SCHEMA CHANGE: every block below is an existing
// portable-doc type, so the render path is untouched (no golden churn) — the blocks
// project through runToTiptap exactly as they would had the author pasted them.
//
// SOURCE OF TRUTH: the served Paper `section-presets` (bp doc get paper
// section-presets). The four `code` blocks on that page are the verbatim originals
// of PRESET_BLOCKS below; placeholders keep their <ANGLE BRACKET> form on purpose —
// they are what the author overtypes.

import { runToTiptap } from "./run-convert.js";

// ── the registry ────────────────────────────────────────────────────────────
//
// Each entry carries its own palette/slash presentation meta so the three surfaces
// (palette "Presets" group, canvas slash "Presets" group, this registry) stay in
// lockstep from ONE table — the CANVAS_COMPOUND_INSERTS precedent.
//
// `caret` declares WHERE the author starts typing after the insert:
//   block       — index into the preset's block sequence.
//   placeholder — the exact text the caret should SELECT so the next keystroke
//                 replaces it, or null when that block has no ProseMirror text hole
//                 (a data-viz atom: chart/stat/task-board configs are authored in the
//                 bpFleet JSON island, so the block is NodeSelection-ed instead).
export const CANVAS_SECTION_PRESETS = [
  {
    kind: "masthead",
    label: "Masthead",
    hint: "▛",
    desc: "7 blocks · kicker → TOC",
    caret: { block: 0, placeholder: "<KICKER> · <CONTEXT>" },
  },
  {
    kind: "annotated-figure",
    label: "Annotated figure",
    hint: "◣",
    desc: "chart · regions, refline, callout",
    caret: { block: 0, placeholder: null },
  },
  {
    kind: "live-dashboard",
    label: "Live dashboard section",
    hint: "◱",
    desc: "stat queries · chart · task board",
    caret: { block: 0, placeholder: "counts — live stat queries" },
  },
  {
    kind: "runbook-step",
    label: "Runbook step",
    hint: "⎇",
    desc: "steps · terminal · rollback callout",
    caret: {
      block: 1,
      placeholder: "<The undo path, spelled out before you need it.>",
    },
  },
];

// ── the assemblies ──────────────────────────────────────────────────────────
//
// Verbatim from the served Paper. A factory (not a frozen constant) so every insert
// gets its OWN deep structure — two inserts must never share a nested object ref.
// Every block is id-LESS: runToOps mints a fresh id per block on insert (the
// new-block signal), exactly like the single-node slash path.
const PRESET_BLOCKS = {
  // 01 · the masthead — eyebrow, display h1, ingress standfirst, byline topics,
  // a 4-tile stat wall (the 2nd tile uses `denom` for the compact a/b read), a
  // divider, and the TOC. SEVEN blocks.
  masthead: () => [
    { id: null, type: "eyebrow", text: "<KICKER> · <CONTEXT>" },
    {
      id: null,
      type: "heading",
      level: 1,
      content: [{ type: "text", value: "<Display headline.>" }],
    },
    {
      id: null,
      type: "ingress",
      content: [
        {
          type: "text",
          value:
            "<One-paragraph standfirst: the whole argument in four sentences.>",
        },
      ],
    },
    {
      id: null,
      type: "byline",
      items: ["<topic>", "<topic>", "<N> figures", "<N> sources"],
    },
    {
      id: null,
      type: "stats",
      items: [
        { value: "<big>", label: "<what it counts>" },
        { value: "<big>", denom: "<of>", label: "<what it counts>" },
        { value: "<big>", label: "<what it counts>" },
        { value: "<big>", label: "<what it counts>" },
      ],
    },
    { id: null, type: "divider" },
    {
      id: null,
      type: "toc",
      items: [{ text: "<section>", level: 1, anchor: "blocks-block-<idx>" }],
    },
  ],

  // 02 · the annotated figure — a chart block WITH the annotation layer: region
  // washes narrate zones, a refLine carries the target, a point callout names the
  // peak. The caption states the claim the figure earns.
  "annotated-figure": () => [
    {
      id: null,
      type: "chart",
      kind: "line",
      axes: { min: 0, max: 100, xLabels: ["<first>", "", "<mid>", "", "<last>"] },
      series: [{ label: "<series>", points: [10, 40, 25, 70, 55] }],
      annotations: {
        regions: [{ from: 0, to: 1.5, label: "<REGION>", tone: "warn" }],
        refLines: [{ y: 50, label: "<target>", tone: "ok" }],
        points: [{ index: 3, label: "<the peak>" }],
      },
      caption: "Figure <N> — <claim the figure earns, with source>.",
    },
  ],

  // 03 · the live dashboard section — three stat QUERIES in columns, a bars chart
  // over closed_at weeks, and a task board. Swap <epic-id> and publish; the reader
  // resolves every block live.
  "live-dashboard": () => [
    { id: null, type: "eyebrow", text: "counts — live stat queries" },
    {
      id: null,
      type: "columns",
      columns: [
        [
          {
            type: "stat",
            label: "tasks in the epic",
            query: { filter: { parent_id: "<epic-id>" } },
          },
        ],
        [
          {
            type: "stat",
            label: "still open",
            query: { filter: { parent_id: "<epic-id>", status: "open" } },
          },
        ],
        [
          {
            type: "stat",
            label: "done",
            query: { filter: { parent_id: "<epic-id>", status: "done" } },
          },
        ],
      ],
    },
    {
      id: null,
      type: "chart",
      kind: "bars",
      caption: "Tasks closed per week — resolved live on every render.",
      query: {
        filter: { parent_id: "<epic-id>", status: "done" },
        over: { bucket: "week", on: "closed_at", last: 10 },
      },
    },
    {
      id: null,
      type: "task-board",
      query: { parent_id: "<epic-id>", limit: 200 },
    },
  ],

  // 04 · the runbook step — numbered steps with terminal transcripts, a verification
  // step whose check can actually fail, and the rollback callout written BEFORE you
  // need it.
  "runbook-step": () => [
    {
      id: null,
      type: "steps",
      steps: [
        {
          title: "<Step title>",
          blocks: [
            {
              type: "paragraph",
              content: [
                { type: "text", value: "<What this step does and why.>" },
              ],
            },
            { type: "terminal", lines: ["$ <command>", "<expected output>"] },
          ],
        },
        {
          title: "<Verify>",
          blocks: [
            {
              type: "paragraph",
              content: [{ type: "text", value: "<The check that can fail.>" }],
            },
          ],
        },
      ],
    },
    {
      id: null,
      type: "callout",
      tone: "warn",
      title: "Rollback",
      content: [
        {
          type: "text",
          value: "<The undo path, spelled out before you need it.>",
        },
      ],
    },
  ],
};

// sectionPreset(kind) → the registry entry, or null for an unknown kind.
export function sectionPreset(kind) {
  return CANVAS_SECTION_PRESETS.find((p) => p.kind === kind) || null;
}

// sectionPresetBlocks(kind) → the ORDERED portable-doc block sequence for a preset.
// A fresh structure per call (no shared nested refs). Unknown kind → [].
export function sectionPresetBlocks(kind) {
  const build = PRESET_BLOCKS[kind];
  return build ? build() : [];
}

// sectionPresetNodes(kind) → the ORDERED TipTap nodes to insert, built via
// runToTiptap exactly like slashTypeToNode/compoundKindToNode — so every inserted
// node is byte-identical to the projection runToOps/nextNodeToBlock reverses, and
// the insert reconstructs the SAME blocks with zero drift. Unknown kind → [].
export function sectionPresetNodes(kind) {
  const blocks = sectionPresetBlocks(kind);
  if (!blocks.length) return [];
  return runToTiptap(blocks).content;
}

// sectionPresetCaretTarget(kind) → { block, placeholder } for the declared overtype
// target, or null for an unknown kind. See the `caret` doc on the registry.
export function sectionPresetCaretTarget(kind) {
  const p = sectionPreset(kind);
  return p ? p.caret : null;
}

/**
 * Web PROJECTIONS for the task-tracking / composition PortableDoc component
 * family — the web half of the cross-surface golden-parity spine (Unified
 * Aesthetic W5.c, S2).
 *
 * Each function maps an authored component block to the SAME structural
 * projection the Elixir generator emits into `<type>.golden.json` (a manifest-
 * derived element-tree of container_role / column·row roles / labels / glyph-
 * roles / nesting). `portable-doc.tsx` renders EACH of these types FROM the
 * matching projection here, and `__tests__/component-golden-parity.test.ts`
 * asserts the projection equals the committed golden fixture — so a web
 * divergence from the shared truth trips the freshness lock, never a hand-tuned
 * web-only assertion.
 *
 * DECISION-1: structure is the shared truth; each surface asserts its native
 * realization of THIS projection. Pure TS (no React / DOM) so it runs under
 * `node --test`, exactly like `task-board-columns.ts`.
 *
 * SUBSET-PARITY (projection ⊆ native), honest scope — the divergent bits are
 * FILED, not papered over, and are simply NOT projected:
 *   • card — only title + flattened body are shared; tone accent, media/action
 *     slots, and slot ORDER differ across Elixir/Go (au-w5-card-slot-parity). The
 *     Elixir View + this web reader now RENDER model B (slots recursed in the order
 *     media→title→body→action, image media fast-pathed to <img>, tone accent), but
 *     the projection stays the {title, body} FLOOR this wave because Go/pdrender still
 *     renders the old card shape. GRADUATION TARGET (activated in the follow-up PR once
 *     Go conforms — see `CardProjection` below): ordered slot kinds
 *     ["media","title","body","action"] + tone + a media-fastpath marker.
 *   • pipeline — the `source` accent is Elixir-class vs Go-provenance-line, so
 *     only kind/title/detail are shared.
 *   • roadmap — bar geometry (left/width) is surface-local; only the structural
 *     lane list (title · role · phase) + scale axis are shared.
 */

/** A loosely-typed authored block — only the keys a given projection reads matter. */
type Block = Record<string, unknown>;

function str(v: unknown): string {
  return typeof v === "string" ? v : typeof v === "number" ? String(v) : "";
}

/** Flatten a ProseMirror-style inline array to concatenated PLAIN text (marks
 * dropped) — the web twin of `Slots.flatten_inline_text/1`: a text/code leaf
 * contributes its `value`; a mark node contributes its children flattened. */
function flattenInline(v: unknown): string {
  if (typeof v === "string") return v;
  if (!Array.isArray(v)) return "";
  return v
    .map((node) => {
      if (typeof node === "string") return node;
      if (!node || typeof node !== "object") return "";
      const n = node as { type?: string; value?: unknown; children?: unknown };
      if (n.type === "text" || n.type === "code") return str(n.value);
      if (Array.isArray(n.children)) return flattenInline(n.children);
      return "";
    })
    .join("");
}

/** The lone element of a widget slot (`slots[name][0]`), or undefined. */
function slotElement(block: Block, name: string): Block | undefined {
  const slots = block.slots;
  if (!slots || typeof slots !== "object") return undefined;
  const list = (slots as Record<string, unknown>)[name];
  if (!Array.isArray(list) || list.length === 0) return undefined;
  const first = list[0];
  return first && typeof first === "object" ? (first as Block) : undefined;
}

/* ── the shared status vocabulary (mirrors design/status-manifest.json) ─────── */

interface LadderRow {
  role: string;
  glyph_role: string;
  glyph: string;
  spinner: boolean;
}

/** The white ladder, in manifest order — the status-legend projection. Mirrors
 * `StatusVocab.roles/0` + glyph/spinner; a manifest edit re-derives the Elixir
 * fixture, so this hard-coded twin must move in lockstep or the web leg reds. */
export const STATUS_LADDER: LadderRow[] = [
  { role: "open", glyph_role: "open", glyph: "○", spinner: false },
  { role: "ready", glyph_role: "ready", glyph: "○", spinner: false },
  { role: "progress", glyph_role: "progress", glyph: "", spinner: true },
  { role: "blocked", glyph_role: "blocked", glyph: "!", spinner: false },
  { role: "done", glyph_role: "done", glyph: "✓", spinner: false },
  { role: "cancel", glyph_role: "cancel", glyph: "✕", spinner: false },
];

/** Stored lifecycle status → ladder role (mirrors the manifest `statuses` map;
 * unknown/absent → the `open` default). */
const STATUS_TO_ROLE: Record<string, string> = {
  open: "open",
  ready: "ready",
  in_progress: "progress",
  blocked: "blocked",
  done: "done",
  closed: "done",
  cancelled: "cancel",
};

export function roleForStatus(status: string): string {
  return STATUS_TO_ROLE[status] ?? "open";
}

/* ── projection shapes (byte-mirror the golden `expected`) ──────────────────── */

export interface LegendProjection {
  container_role: "legend";
  rows: LadderRow[];
}
export interface NoteRow {
  label: string;
  lead: string;
  text: string;
}
export interface NotesProjection {
  container_role: "notes";
  rows: NoteRow[];
}
export interface NoteProjection extends NoteRow {
  container_role: "note";
}
export interface CardsProjection {
  container_role: "cards";
  cards: Array<{ title: string; text: string; tone: string }>;
}
export interface CardProjection {
  container_role: "card";
  title: string;
  body: string;
}
// GRADUATION TARGET (au-w5-card-slot-parity, documented — NOT activated this wave).
// After Go/pdrender's card leg conforms to model B, `CardProjection` graduates to the
// full shape below and `cardProjection` emits it (the card golden is regenerated across
// all three mirrors at that point). Kept as a doc-only type so the shape is committed
// but unreferenced — it does not touch the frozen {title, body} projection today.
//
//   interface CardProjectionGraduated {
//     container_role: "card";
//     slots: Array<"media" | "title" | "body" | "action">; // ordered kinds present
//     tone: "info" | "ok" | "warn" | "danger" | "";        // legacy card accent
//     media_fastpath: boolean;                              // image media child ⇒ <img>
//   }
export interface PipelineProjection {
  container_role: "pipeline";
  nodes: Array<{ kind: string; title: string; detail: string }>;
}
export interface StageProjection {
  container_role: "stage";
  kind: string;
  title: string;
  detail: string;
}
export interface TimelineEntry {
  role: string;
  glyph_role: string;
  label: string;
}
export interface TaskDetailProjection {
  container_role: "task-detail";
  title: string;
  sections: string[];
  timeline: TimelineEntry[];
  criteria: { met: number; total: number };
}
export interface RoadmapProjection {
  container_role: "roadmap";
  lanes: Array<{ title: string; role: string; phase: boolean }>;
  scale: string[];
}
export interface ColumnsProjection {
  container_role: "columns";
  columns: string[][];
}
export interface TerminalProjection {
  container_role: "terminal";
  title: string;
  live: boolean;
  footer: string;
  children: string[];
}

/* ── projectors ─────────────────────────────────────────────────────────────── */

const CARD_TONES = new Set(["info", "ok", "warn", "danger"]);
function cardTone(v: unknown): string {
  const t = str(v);
  return CARD_TONES.has(t) ? t : "";
}

/** A note row read through the slot-OR-flat contract (`Slots.note_*_text`): the
 * slot's flattened lone paragraph when materialized, else the flat field. */
function noteRow(item: Block): NoteRow {
  const slotText = (slot: string, flatKey: string): string => {
    const el = slotElement(item, slot);
    if (el) return flattenInline(el.content);
    return str(item[flatKey]);
  };
  return {
    label: slotText("label", "label"),
    lead: slotText("lead", "lead").trim(),
    text: slotText("body", "text"),
  };
}

export function statusLegendProjection(): LegendProjection {
  return { container_role: "legend", rows: STATUS_LADDER };
}

export function notesProjection(block: Block): NotesProjection {
  const items = Array.isArray(block.items) ? (block.items as Block[]) : [];
  return { container_role: "notes", rows: items.map(noteRow) };
}

export function noteProjection(block: Block): NoteProjection {
  return { container_role: "note", ...noteRow(block) };
}

export function cardsProjection(block: Block): CardsProjection {
  const items = Array.isArray(block.items) ? (block.items as Block[]) : [];
  return {
    container_role: "cards",
    cards: items.map((it) => ({
      title: str(it.title),
      text: str(it.text),
      tone: cardTone(it.tone),
    })),
  };
}

export function cardProjection(block: Block): CardProjection {
  const titleEl = slotElement(block, "title");
  const bodyEl = slotElement(block, "body");
  return {
    container_role: "card",
    title: titleEl ? str(titleEl.text) : "",
    body: bodyEl ? flattenInline(bodyEl.content) : "",
  };
}

export function pipelineProjection(block: Block): PipelineProjection {
  const nodes = Array.isArray(block.nodes) ? (block.nodes as Block[]) : [];
  return {
    container_role: "pipeline",
    nodes: nodes.map((n) => ({
      kind: str(n.kind),
      title: str(n.title),
      detail: str(n.detail),
    })),
  };
}

/** A stage text field read through the slot-OR-scalar contract
 * (`Slots.stage_field_text`): a scalar-only stage reads the flat scalar. */
function stageField(block: Block, name: string): string {
  const el = slotElement(block, name);
  if (el) return flattenInline(el.content);
  return str(block[name]);
}

export function stageProjection(block: Block): StageProjection {
  return {
    container_role: "stage",
    kind: stageField(block, "kind"),
    title: stageField(block, "title"),
    detail: stageField(block, "detail"),
  };
}

export function taskDetailProjection(block: Block): TaskDetailProjection {
  const task =
    block.task && typeof block.task === "object"
      ? (block.task as Block)
      : block;
  const criteria = Array.isArray(task.criteria) ? (task.criteria as Block[]) : [];
  const labels = Array.isArray(task.labels) ? (task.labels as unknown[]) : [];
  const timelineSegs = Array.isArray(task.timeline)
    ? (task.timeline as Block[])
    : [];

  // meta · timeline · criteria · labels — the emitter's ordered conditional slots
  // (timeline drawn after meta, before criteria in `task_detail_html/1`).
  const sections: string[] = ["meta"];
  if (timelineSegs.length > 0) sections.push("timeline");
  if (criteria.length > 0) sections.push("criteria");
  if (labels.length > 0) sections.push("labels");

  // Each cell's ladder role (derived, mirrors the emitter's `role_of`) doubles as
  // the glyph-role; the label is the shared plain text every surface prints.
  const timeline: TimelineEntry[] = timelineSegs.map((s) => {
    const role = roleForStatus(str(s.status));
    return { role, glyph_role: role, label: str(s.label) };
  });

  return {
    container_role: "task-detail",
    title: str(task.title),
    sections,
    timeline,
    criteria: {
      met: criteria.filter((c) => c && (c as Block).met === true).length,
      total: criteria.length,
    },
  };
}

export function roadmapProjection(block: Block): RoadmapProjection {
  const rows = Array.isArray(block.snapshot) ? (block.snapshot as Block[]) : [];
  const scale = Array.isArray(block.scale)
    ? (block.scale as unknown[]).map(str)
    : [];
  return {
    container_role: "roadmap",
    lanes: rows.map((r) => ({
      title: str(r.title),
      role: roleForStatus(str(r.status)),
      phase: r.phase_row === true,
    })),
    scale,
  };
}

function childTypes(list: unknown): string[] {
  if (!Array.isArray(list)) return [];
  return list.map((c) =>
    c && typeof c === "object" ? str((c as Block).type) : "",
  );
}

export function columnsProjection(block: Block): ColumnsProjection {
  const cols = Array.isArray(block.columns) ? (block.columns as unknown[]) : [];
  return { container_role: "columns", columns: cols.map(childTypes) };
}

export function terminalProjection(block: Block): TerminalProjection {
  const children = block.children ?? block.blocks ?? [];
  const live = block.live === true || block.live === "true" || block.live === "live";
  return {
    container_role: "terminal",
    title: str(block.title),
    live,
    footer: str(block.footer),
    children: childTypes(children),
  };
}

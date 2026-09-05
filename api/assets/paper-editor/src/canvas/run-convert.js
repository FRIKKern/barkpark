// run-convert.js — Phase-4 Stage S0: the headless system-of-record projector.
//
// This is the SEED of the continuous canvas. It projects a portable-doc block
// LIST into a SINGLE ProseMirror-style doc JSON (one top-level node per block,
// in order) and diffs an edited doc back into the EXACT op vocabulary the
// server already folds (patch-block / insert-after / remove-block / move-block).
//
// It SHIPS DARK. Nothing imports it — not index.js, not the bundle, not the
// LiveView, not the server. The working per-block <bp-paper-editor> and its
// committed bundle literally cannot regress because this module is unreachable
// at runtime. S0 is the system-of-record proof BEFORE any caret touches a
// screen: it lets us prove the blocks ⇄ one-doc ⇄ ops projection is lossless
// in pure Node, on harness fixtures, with zero UI risk.
//
// PURE, DOM-free, TipTap-free, ProseMirror-free, Node-API-free. It imports
// ONLY from ../convert.js — the same pure converter index.js uses today, so an
// interior edit emitted here is BYTE-IDENTICAL to what the per-block editor
// emits (convert.js:331 buildPatchBlockOp is the shared path).
//
// ── shapes (verified against the real code) ───────────────────────────────
//
//   convert.js:252 blockToTiptap(block) → { type:"doc", content:[ node ] }
//       for a PROSE block (paragraph | heading | list). We lift content[0].
//   convert.js:331 buildPatchBlockOp(editorJSON, id, type)
//       → { op:"patch-block", id, patch:{ ...mutable fields only } }
//
//   patch.ex op wire shapes (api/lib/barkpark/portable_doc/patch.ex):
//       patch-block   patch.ex:153  { "op":"patch-block",  "id":…, "patch":{…} }
//       insert-after  patch.ex:140  { "op":"insert-after",  "afterId":…, "block":{…} }
//       append-block  patch.ex:132  { "op":"append-block",  "block":{…} }
//       remove-block  patch.ex:191  { "op":"remove-block",  "id":… }
//       move-block    patch.ex:203  { "op":"move-block",    "id":…, "after":… | null }
//
// The block kinds convert.js treats as PROSE are exactly paragraph | heading |
// list (convert.js:257-288 — the switch in blockToTiptap). Everything else is
// non-prose and is carried as an OPAQUE placeholder node, verbatim.

import {
  blockToTiptap,
  buildPatchBlockOp,
  inlineArrayToTiptap,
  tiptapInlineToPd,
  tiptapToBlock,
} from "../convert.js";

// The doc-block kinds convert.js round-trips as prose (convert.js blockToTiptap
// switch). These project to a native ProseMirror textblock and diff via
// buildPatchBlockOp.
const PROSE_TYPES = new Set(["paragraph", "heading", "list"]);

// S3: non-prose block kinds the canvas handles as ATOM nodes — leaf nodes that
// live INSIDE the canvas document (not run boundaries, not opaque carry-through).
// The divider is the first: a leaf with no content, so it NEVER reports an
// interior change. As later increments land callout/code/field/sheet atoms they
// join this set. A node is "canvas-handled" if it is PROSE or a canvas ATOM;
// only a truly-unknown non-prose kind stays bpOpaque.
const CANVAS_ATOM_TYPES = new Set(["divider"]);

// S3.2: non-prose block kinds the canvas handles as CONTENT nodes — nodes with an
// EDITABLE interior (a contentDOM) living INSIDE the canvas document, NOT atoms
// and NOT opaque. The callout is the first: its body is an editable inline region
// (compose.ex:155 feeds callout `content` through compose_inline_children → ONE
// inline PdText), so unlike the divider ATOM it CAN report an interior change and
// emits a patch-block on a body/tone/title/collapsed edit. As later increments
// land sheet/field as content node-views they join this set.
//
// A node is "canvas-handled" if it is PROSE, a canvas ATOM, a canvas ATTR-ATOM, or
// a canvas CONTENT node; only a truly-unknown non-prose kind stays bpOpaque.
//
// The notes-grid split adds `note` (the singular annotated-item WIDGET) to this
// SAME set: like callout it is a CONTENT node whose BODY is an editable inline
// contentDOM, but a SUPERSET — it ALSO exposes label + lead as non-PM input islands
// (see note-node.js). node.type is "note" (no NODE_NAME indirection, the callout
// convention), so the isContent branches below sub-route note vs callout by node
// type. KEEP LOCKSTEP with paper_canvas.ex @canvas_content_types and index.js (Note).
const CANVAS_CONTENT_TYPES = new Set(["callout", "note"]);

// True when a CONTENT node/block is the `note` widget (sub-routing within the shared
// isContent kind: note.type === "note" vs callout.type === "callout").
function isNoteType(t) {
  return t === "note";
}

// Article-chrome ROLE prose: eyebrow / byline / ingress / pullquote. UNLIKE every
// other canvas node these need NO NODE_NAME map — node.type === bpType for all four
// (role-nodes.js names the node after the bpType). They mount as PLAIN styled prose
// (a `<p class="bp-role-*">` matching the reader), chrome-free, so they diff like a
// prose block would but with a per-role BODY MODEL:
//   eyebrow  → a PLAIN string in `text`  (compose.ex reads Map.get(b,"text"))
//   byline   → an `items` LIST joined/split on " · " (blocks.ex build_block_patch)
//   ingress  → an inline `content` array (the shared inline serializer)
//   pullquote→ an inline `content` array (the shared inline serializer)
// KEEP LOCKSTEP with paper_canvas.ex @canvas_role_types.
const CANVAS_ROLE_TYPES = new Set(["eyebrow", "byline", "ingress", "pullquote"]);
const ROLE_BODY_MODEL = {
  eyebrow: "text",
  byline: "items",
  ingress: "inline",
  pullquote: "inline",
};

// True when a portable-doc BLOCK type (and, since node.type === bpType, a NODE type)
// is an article-chrome role block.
function isCanvasRoleType(t) {
  return CANVAS_ROLE_TYPES.has(t);
}

// The `table` block as FOUR hand-rolled NESTED nodes (bpTable > bpTableRow >
// bpTableHeaderCell|bpTableCell; see table-node.js). UNLIKE every other canvas node,
// the TABLE is a container of PM structure, not a leaf/atom/inline body — its data
// lives in child nodes, not attrs. The bpTable NODE name differs from its bpType
// ("table"), like the code/diagram attr-atoms, so runToTiptap maps block.type →
// node.type and runToOps/classifyNode read the bpType back off node.attrs.bpType.
// A cell body is INLINE runs (compose.ex:406-425 feeds each cell through
// compose_inline_children → the shared serializer), so the cell↔portable-doc mapping
// REUSES inlineArrayToTiptap / tiptapInlineToPd verbatim (the callout precedent).
//
// KEEP LOCKSTEP with paper_canvas.ex @canvas_table_types and table-node.js.
const CANVAS_TABLE_TYPES = new Set(["table"]);
const CANVAS_TABLE_NODE_NAME = "bpTable";

// True when a portable-doc BLOCK type is the table (runToTiptap dispatch).
function isCanvasTableType(t) {
  return CANVAS_TABLE_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas table container. runToOps/classifyNode
// read node.type off a getJSON node (the NODE name, not the bpType).
function isCanvasTableNode(nodeType) {
  return nodeType === CANVAS_TABLE_NODE_NAME;
}

// STEP 4: the card WIDGET — a NEW slots-native block (media/title/body/action slots).
// It is a callout-shaped CONTENT node (an editable INLINE body contentDOM + chrome
// attrs) but SLOTS-NATIVE: its title/tone/media/action ride node.attrs, its body is
// the ONE contentDOM (the body slot's lone paragraph flattened to inline, the callout
// precedent). UNLIKE callout, node.type is the NODE name `bpCard` (not the bpType
// "card") — the section/code NODE_NAME indirection — and `tone` is PRESENT-ONLY (a
// tone-less card must NOT gain "info"; card_html treats absent tone as no modifier,
// matching the legacy cards item). KEEP LOCKSTEP with paper_canvas.ex
// @canvas_widget_types and card-node.js.
const CANVAS_CARD_TYPES = new Set(["card"]);
const CANVAS_CARD_NODE_NAME = "bpCard";

// True when a portable-doc BLOCK type is the card widget (runToTiptap dispatch).
function isCanvasCardType(t) {
  return CANVAS_CARD_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas card node. runToOps/classifyNode read
// node.type off a getJSON node (the NODE name `bpCard`, not the bpType "card").
function isCanvasCardNode(nodeType) {
  return nodeType === CANVAS_CARD_NODE_NAME;
}

// The `stage` WIDGET — the editable per-node twin of ONE legacy `pipeline` node. UNLIKE
// the card (a slots-native CONTENT node with an inline body), a stage is a CONTROL-ATOM:
// five PLAIN scalars (kind/title/detail text + files/source chrome) ride node.attrs,
// edited by native controls (stage-node.js) — no contentDOM. node.type is the NODE name
// `bpStage`; the bpType stays "stage". KEEP LOCKSTEP with paper_canvas.ex
// @canvas_widget_types and stage-node.js.
const CANVAS_STAGE_TYPES = new Set(["stage"]);
const CANVAS_STAGE_NODE_NAME = "bpStage";

// True when a portable-doc BLOCK type is the stage widget (runToTiptap dispatch).
function isCanvasStageType(t) {
  return CANVAS_STAGE_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas stage node. runToOps/classifyNode read
// node.type off a getJSON node (the NODE name `bpStage`, not the bpType "stage").
function isCanvasStageNode(nodeType) {
  return nodeType === CANVAS_STAGE_NODE_NAME;
}

// S3.3: non-prose block kinds the canvas handles as ATTR-ATOM nodes — ATOM nodes
// (no PM-managed interior, like the divider) whose body text rides in an ATTR and
// is edited by a NON-PM control (a <textarea> island; see code-node.js). The code
// block is the first: its `value` is a plain string (compose.ex:272 reads only
// Map.get(b,"value")) edited outside ProseMirror, with an optional `lang`. UNLIKE
// the divider ATOM (which has NOTHING to edit and emits zero ops forever), an
// attr-atom HAS a mutable value/lang, so it CAN emit a patch-block when those
// change — but UNLIKE the callout CONTENT node it has no contentDOM and no inline
// body (the text is an opaque string, not PM runs).
//
// S3.4 adds the `diagram` block to this SAME set: it reuses the code attr-atom shape
// ALMOST VERBATIM with two field differences — its body field is `source` (the
// Mermaid text, not `value`) plus an OPTIONAL `caption` (where code had `lang`).
// compose.ex:224 reads Map.get(b,"source") + Map.get(b,"caption"); the source rides
// the textarea island, edited outside ProseMirror. field-* / sheet STILL split until
// their own increments.
//
// A node is "canvas-handled" if it is PROSE, a canvas ATOM, a canvas ATTR-ATOM, or
// a canvas CONTENT node; only a truly-unknown non-prose kind stays bpOpaque.
const CANVAS_ATTR_ATOM_TYPES = new Set(["code", "diagram"]);

// The TipTap NODE name for an attr-atom block differs from its bpType. For code it is
// `bpCode`, NOT `code` — `code` is the StarterKit inline code MARK (a node + mark
// can't share a name). For diagram it is `bpDiagram` (the canvas naming convention;
// there is no StarterKit `diagram` node to collide with, but the canvas keeps the
// bp-prefix). runToTiptap maps a block.type → its node.type; runToOps maps it back
// via bpType. Keep aligned with code-node.js:BP_CODE_NODE_NAME and
// diagram-node.js:BP_DIAGRAM_NODE_NAME.
const CANVAS_ATTR_ATOM_NODE_NAMES = { code: "bpCode", diagram: "bpDiagram" };
// Reverse: node.type "bpCode" → bpType "code", "bpDiagram" → "diagram". Used by
// runToOps to detect an attr-atom by its NODE type (the type carried on a getJSON
// node).
const CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE = { bpCode: "code", bpDiagram: "diagram" };

// S3.5: the 7 NATIVE-CONTROL field-* block kinds the canvas handles as CONTROL-ATOM
// nodes — atom nodes (no PM-managed body, like the divider/code) whose VALUE rides
// in an attr and is edited by a NATIVE HTML control (input / textarea / checkbox /
// select / datetime-local / color; see field-node.js). UNLIKE the code/diagram
// attr-atoms (one bpType per TipTap node, body text in a free textarea), the field
// control-atom serves 7 bpTypes through ONE node (`bpField`), the edit surface is a
// TYPED control, and the value is COERCED BY FIELD TYPE exactly like the shipped
// BarkparkFieldBlockBridge (field-boolean → a BOOLEAN via control.checked; every
// other native type → a STRING via control.value).
//
// RUN-SPLITTER TAIL (part 1): field-image (bp-media-picker WC) and field-reference
// (bp-reference-picker WC) now ALSO ride the canvas through the SAME `bpField` atom —
// the PICKER variant. The pickers are CLIENT-SIDE (no LiveView dependency), so they
// mount inside the node-view exactly like a native control; the edit surface is the WC,
// and on its `bp-change` the node-view writes the new `value` back IDENTICALLY to the
// per-block bridge. From run-convert's POV the picker types are diffed/folded EXACTLY
// like the native types (value is the only mutable datum, patch is { value }), with two
// extra OPTIONAL config keys carried verbatim: refType (field-reference's target schema)
// and dataset (a per-block fetch-scope override). Keep CANVAS_FIELD_TYPES = native ∪
// picker aligned with field-node.js:(BP_NATIVE_FIELD_TYPES ∪ BP_PICKER_FIELD_TYPES) and
// paper_canvas.ex:(@canvas_field_types ∪ @canvas_picker_field_types).
//
// STILL OUT (separate nested-structure increment): composite / object / arrayOf /
// codelist / localizedText. Those are NOT in any canvas-field set and STILL split a
// run. (`section` is NO LONGER here — it rides its own bpSection CONTAINER node; see
// CANVAS_CONTAINER_TYPES below.)
const CANVAS_NATIVE_FIELD_TYPES = new Set([
  "field-string",
  "field-slug",
  "field-text",
  "field-boolean",
  "field-select",
  "field-datetime",
  "field-color",
]);
const CANVAS_PICKER_FIELD_TYPES = new Set(["field-image", "field-reference"]);
const CANVAS_FIELD_TYPES = new Set([
  ...CANVAS_NATIVE_FIELD_TYPES,
  ...CANVAS_PICKER_FIELD_TYPES,
]);

// The TipTap NODE name for ALL 7 native field types is the SAME single node
// `bpField` (UNLIKE code/diagram, which are one-node-per-type). The specific
// field-* kind rides the node's bpType attr; the node-view dispatches the control
// by it. Keep aligned with field-node.js:BP_FIELD_NODE_NAME.
const CANVAS_FIELD_NODE_NAME = "bpField";

// S3.6: the READ-ONLY ATOM block kinds the canvas handles as READ-ONLY atom nodes —
// atom nodes (no PM-managed body, like the divider/code/field) that are REFERENCES,
// NOT editable text. `sheet` (a cached value-grid embed, edited in its own surface)
// and `embed` (a note transclusion ![[note]], resolved at VIEW render) are both
// carried INTO the canvas as read-only atoms. This is the bpOpaque mechanism (carry
// the WHOLE block verbatim, deep-cloned) made CANVAS-ELIGIBLE (no split) + given a
// dedicated read-only node-view (embed-node.js) instead of the generic opaque
// placeholder.
//
// UNLIKE the field control-atom (whose `value` IS edited → a patch), a read-only atom
// NEVER emits a value/content patch — nothing is edited in the editor. It carries the
// WHOLE block on `bpBlock` (NOT just a value) so it round-trips VERBATIM with ZERO
// value ops, and it DOES participate in STRUCTURAL ops (insert/remove/move by bpId)
// like any block — so it no longer SPLITS a run.
//
// EXPLICITLY OUT (still boundaries): composite / object / arrayOf / codelist /
// localizedText (the nested-structure kinds). field-image / field-reference are
// NO LONGER out — they ride CANVAS_PICKER_FIELD_TYPES (∈ CANVAS_FIELD_TYPES), so
// blockToNode dispatches them to the editable fieldBlockToNode and field-node.js
// mounts bp-media-picker / bp-reference-picker as canvas-editable control-atoms.
// After S3.6 sheet/embed are canvas-eligible too, so the ONLY remaining run
// splitters are those nested-structure kinds. Keep aligned with
// embed-node.js:BP_SHEET_NODE_NAME / BP_EMBED_NODE_NAME and
// paper_canvas.ex:@canvas_readonly_atom_types.
const CANVAS_READONLY_ATOM_TYPES = new Set(["sheet", "embed"]);

// The TipTap NODE name for a read-only atom block differs from its bpType: for sheet
// it is `bpSheet`, for embed `bpEmbed` (the canvas bp-prefix convention; there is no
// StarterKit sheet/embed node to collide with). runToTiptap maps a block.type → its
// node.type; runToOps maps it back via bpType. Keep aligned with embed-node.js.
const CANVAS_READONLY_ATOM_NODE_NAMES = { sheet: "bpSheet", embed: "bpEmbed" };
// Reverse: node.type "bpSheet" → bpType "sheet", "bpEmbed" → "embed". Used by runToOps
// to detect a read-only atom by its NODE type (the type carried on a getJSON node).
const CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE = { bpSheet: "sheet", bpEmbed: "embed" };

// pdd-t8 (fleet-in-canvas): the COMPONENT-FLEET block kinds the canvas handles as
// SERVER-PAINTED READ-ONLY ATOM nodes. Like sheet/embed these are REFERENCES the
// editor never edits inline — but UNLIKE sheet/embed (whose read-only chip is
// computed client-side) a fleet block's TRUTH is the reader's own HTML (rule 3 /
// D8: ONE producer, byte for byte). So the canvas carries the WHOLE block verbatim
// on `bpBlock` (the bpOpaque verbatim-carry) AND paints the SERVER-pushed HTML
// (`bp:block-html`, keyed by bpId) into the node-view interior, falling back to a
// chip while that HTML is still loading. They emit ZERO value/content ops and
// participate ONLY in structural ops (insert/remove/move by bpId) — identical op
// posture to sheet/embed.
//
// ALL fleet kinds project to the SINGLE `bpFleet` node (like the 9 field-* kinds
// share `bpField`), discriminated by the bpType attr; the reverse mapping is the
// attr, so bpFleet is NOT in CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE. This is the
// canonical enumeration of the reader's non-prose component emitters
// (render/components.ex + render/figures.ex asciicast + render/forms.ex form);
// keep aligned with embed-node.js:BP_FLEET_NODE_NAME,
// shared/paper.ex:@fleet_render_types (the server-paint push),
// paper_editor.ex:@fleet_preview_types (the retained boundary-widget twin) and
// paper_canvas.ex:@canvas_fleet_types (the t12a partition flip). As of t12a the
// server partition folds these kinds INTO runs, so bpFleet actually MOUNTS — a
// top-level fleet block no longer falls through to a boundary widget.
// `diagram` is DELIBERATELY absent — it rides
// its own editable bpDiagram attr-atom (source textarea), not the read-only paint.
const CANVAS_FLEET_TYPES = new Set([
  "tasks",
  "task-list",
  "task-detail",
  "task-board",
  "roadmap",
  "notes",
  "cards",
  "pipeline",
  "status-legend",
  "asciicast",
  "form",
  "questionnaire",
]);
const CANVAS_FLEET_NODE_NAME = "bpFleet";

// pd-ee-dataviz-editors (charter D3): the 5 DATA-VIZ kinds (reader emitters in
// render/data_viz.ex; `stat-grid` is the accepted alias of `stats`). They ride the
// SAME bpFleet node + server-paint channel as CANVAS_FLEET_TYPES — the whole block
// verbatim on bpBlock, display HTML pushed on bp:block-html (ONE producer, D8) —
// with their authored config edited in the bpFleet JSON edit island (embed-node.js
// FLEET_CONFIG_EDITORS / FLEET_ITEM_EDITORS). A PARALLEL set, deliberately NOT
// folded into CANVAS_FLEET_TYPES: that set is 4-way-lockstepped with
// paper_editor.ex @fleet_preview_types (the classic-mode boundary widget), and
// DataViz stays OUT of the classic paint (charter D2 — classic keeps its read-only
// catch-all for these kinds). D4: deliberately ABSENT from slash-insert.js
// CANVAS_SLASH_TYPES (data-bearing, API-authored).
// KEEP LOCKSTEP with paper_canvas.ex @canvas_dataviz_types and
// shared/paper.ex @dataviz_render_types (7 kinds in every one).
const CANVAS_DATAVIZ_TYPES = new Set([
  "stat",
  "stats",
  "stat-grid",
  "heatmap",
  "chart",
  "duel",
  "lineage",
]);

// editable-figure: the `figure` block the canvas handles as a SERVER-PAINTED
// read-only-CHILD + editable-CAPTION ATOM (`bpFigure`; figure-node.js). A figure
// wraps ONE child block + a caption. Structurally it is a HYBRID of the fleet atom
// and the diagram attr-atom: the CHILD rides VERBATIM/immutable on `bpChild` and is
// PAINTED read-only via the SAME `bp:block-html` hook fleet uses (child-only HTML,
// keyed by the figure id), while the CAPTION is the SOLE editable datum (a non-PM
// input island, exactly like the diagram caption) that emits patch-block{caption}.
// Carrying ONLY the child (NOT the whole figure on a bpBlock) keeps the editable
// caption the single source of truth, so echo-equality compares child-only.
//
// KEEP LOCKSTEP with paper_canvas.ex @canvas_figure_types, figure-node.js
// BP_FIGURE_NODE_NAME, and shared/paper.ex @figure_render_types (the server
// child-paint push).
const CANVAS_FIGURE_TYPES = new Set(["figure"]);
const CANVAS_FIGURE_NODE_NAME = "bpFigure";

// True when a portable-doc BLOCK type is the figure (runToTiptap dispatch).
function isCanvasFigureType(t) {
  return CANVAS_FIGURE_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas figure atom ("bpFigure"). runToOps /
// classifyNode read node.type off a getJSON node (the NODE name, not the bpType).
function isCanvasFigureNode(nodeType) {
  return nodeType === CANVAS_FIGURE_NODE_NAME;
}

// live-data task-list: the `task-list` block the canvas handles as an EDITABLE-QUERY
// + server-painted-ROWS ATOM (`bpTaskList`; task-list-node.js). UNLIKE the fleet atom
// (whole block verbatim on bpBlock, ZERO ops) a LIVE task-list carries ONLY its
// editable data as typed attrs — `query` (the filter, JSON, like figure's bpChild),
// `title` (string, "" → absent) and `config` (JSON, verbatim) — NEVER a snapshot (the
// rows are a resolve-at-read PROJECTION the server paints, never persisted on the
// node). The QUERY is the sole authored datum: an edit emits patch-block{query} and
// the server RE-RESOLVES + repaints the rows (the LIVE binding through TaskResolver).
//
// The DISCRIMINANT (mirrors task_resolver.ex:139-159): presence-of-`query`. A
// task-list block WITH a `query` map is this LIVE widget (bpTaskList); a snapshot-only
// task-list (no `query`) is the legacy author-pinned form and falls through to the
// read-only bpFleet atom (CANVAS_FLEET_TYPES still holds "task-list" — additive, no
// alias fork). `tasks` stays fleet-read-only in v1.
//
// KEEP LOCKSTEP with paper_canvas.ex @canvas_task_list_types, task-list-node.js
// BP_TASK_LIST_NODE_NAME, and shared/paper.ex @fleet_render_types (task-list's query
// is resolved through the SAME task_previews/apply_preview server-paint channel).
const CANVAS_TASK_LIST_NODE_NAME = "bpTaskList";

// True when a portable-doc BLOCK is a LIVE task-list (a `task-list` type carrying a
// `query` MAP). A snapshot-only task-list returns false (→ the bpFleet fallback). This
// is the runToTiptap dispatch guard — the presence-of-query discriminant.
function isLiveTaskListBlock(block) {
  return (
    block && block.type === "task-list" && isPlainObject(block.query)
  );
}

// True when a TipTap NODE type is the canvas task-list widget ("bpTaskList").
// runToOps / classifyNode read node.type off a getJSON node (the NODE name).
function isCanvasTaskListNode(nodeType) {
  return nodeType === CANVAS_TASK_LIST_NODE_NAME;
}

// The CONTAINER block kinds the canvas handles as RECURSIVE nested-block nodes —
// canvas nodes whose interior is a NESTED BLOCK TREE (child blocks with their own
// type/content), not inline runs (callout) nor a verbatim opaque carry. THREE members:
//   * `columns` ⇄ `bpColumns` (content "bpColumn+"): columns become editable PM
//     regions (prose+divider); non-first-class children ride a read-only bpColumnAtom.
//   * `section` ⇄ `bpSection`: a nested block+ body wrapped by two rules + an editable
//     title; a TOP-LEVEL section is editable, a CHILD (depth>=1) section is carried
//     verbatim as bpOpaque (V1 forbid-nesting — sectionBlockToNode's depth-guard).
//   * `terminal` ⇄ `bpTerminal`: a nested block+ body wrapped in reader chrome (title
//     bar + optional live badge + optional footer); non-first-class body children ride
//     a read-only bpTerminalAtom. terminal-node.js.
// A container FOLDS INTO a run (it no longer SPLITS one). V1: FORBID container-in-
// container. Keep aligned with columns-node.js, section-node.js, terminal-node.js and
// paper_canvas.ex @canvas_container_types (partition-shape tests pin all four).
const CANVAS_CONTAINER_TYPES = new Set(["columns", "section", "terminal"]);

// block.type → its TipTap NODE name (they differ): columns→bpColumns, section→bpSection,
// terminal→bpTerminal. runToTiptap maps block.type → node.type; runToOps/classifyNode
// map back via bpType.
const CANVAS_CONTAINER_NODE_NAMES = {
  columns: "bpColumns",
  section: "bpSection",
  terminal: "bpTerminal",
};
// The section container's NODE name (singular alias used by sectionBlockToNode).
const CANVAS_CONTAINER_NODE_NAME = "bpSection";
// Reverse: node.type → bpType. Used by classifyNode/isCanvasContainerNode to resolve
// the bpType off a getJSON node (the NODE name, not the bpType).
const CANVAS_CONTAINER_BP_TYPE_BY_NODE = {
  bpColumns: "columns",
  bpSection: "section",
  bpTerminal: "terminal",
};

// The per-column node name + the verbatim child-carrier atom node name (columns-node.js).
const BP_COLUMN_NODE_NAME = "bpColumn";
const BP_COLUMN_ATOM_NODE_NAME = "bpColumnAtom";
// The terminal verbatim child-carrier atom node name (terminal-node.js). The terminal
// container has NO per-column wrapper — its body children mount directly.
const BP_TERMINAL_ATOM_NODE_NAME = "bpTerminalAtom";

// editable-action: the CTA `action` block the canvas handles as a CONTROL-ATOM node —
// a LEAF (href/label/priority; no children, no inline body) whose editable attrs ride
// NATIVE controls (like the field-* set, but ONE bpType and no BarkparkFieldBlockBridge
// coercion; see action-node.js). Its node-view renders the reader's own bp-button anchor
// byte-identically. UNLIKE code/diagram (fully described by value+lang / source+caption)
// an action carries THREE optional payload keys, each threaded onto attrs / the block
// ONLY when present (attr default null = the absence sentinel), so `{type:"action"}`
// round-trips to exactly `{id,type:"action"}` and `{href,label}` with no priority
// round-trips with no priority key. priority is a TRI-STATE at rest that the reader
// (walk.ex button/2) collapses to BINARY: primary iff =="primary", else secondary — so
// the change-detector normalizes nil≡secondary and selecting "Secondary" on a never-set
// block is a ZERO-op.
//
// KEEP LOCKSTEP with paper_canvas.ex @canvas_action_types and
// action-node.js:BP_ACTION_NODE_NAME.
const CANVAS_ACTION_TYPES = new Set(["action"]);
const CANVAS_ACTION_NODE_NAME = "bpAction";

// True when a portable-doc BLOCK type is the CTA action (runToTiptap dispatch).
function isCanvasActionType(t) {
  return CANVAS_ACTION_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas action control-atom ("bpAction").
// runToOps/classifyNode read node.type off a getJSON node (the NODE name).
function isCanvasActionNode(nt) {
  return nt === CANVAS_ACTION_NODE_NAME;
}

function isProseType(type) {
  return PROSE_TYPES.has(type);
}

function isCanvasAtomType(type) {
  return CANVAS_ATOM_TYPES.has(type);
}

function isCanvasContentType(type) {
  return CANVAS_CONTENT_TYPES.has(type);
}

// True when a portable-doc BLOCK type is a canvas attr-atom (e.g. "code").
function isCanvasAttrAtomType(type) {
  return CANVAS_ATTR_ATOM_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas attr-atom (e.g. "bpCode"). runToOps
// reads node.type off a getJSON node, which is the NODE name, not the bpType.
function isCanvasAttrAtomNode(nodeType) {
  return Object.prototype.hasOwnProperty.call(
    CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE,
    nodeType,
  );
}

// True when a portable-doc BLOCK type is a canvas field-* control-atom — the 7
// native field-* types PLUS the 2 picker types (field-image / field-reference).
// CANVAS_FIELD_TYPES is native ∪ picker, so this returns TRUE for the pickers too:
// they are canvas-editable, dispatched to fieldBlockToNode (NOT boundaries).
function isCanvasFieldType(type) {
  return CANVAS_FIELD_TYPES.has(type);
}

// True when a TipTap NODE type is the canvas field control-atom ("bpField").
// runToOps reads node.type off a getJSON node (the NODE name); ALL 7 native field
// types share the single `bpField` node, so the specific kind comes off the bpType
// attr, not the node type.
function isCanvasFieldNode(nodeType) {
  return nodeType === CANVAS_FIELD_NODE_NAME;
}

// True when a portable-doc BLOCK type is a canvas read-only atom (S3.6: "sheet" |
// "embed"). These ride INTO the canvas as read-only atoms carrying the whole block
// verbatim; they never emit a value/content op.
function isCanvasReadOnlyAtomType(type) {
  return CANVAS_READONLY_ATOM_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas read-only atom (e.g. "bpSheet" / "bpEmbed").
// runToOps reads node.type off a getJSON node (the NODE name, not the bpType).
function isCanvasReadOnlyAtomNode(nodeType) {
  return Object.prototype.hasOwnProperty.call(
    CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE,
    nodeType,
  );
}

// True when a portable-doc BLOCK type is a canvas fleet block (pdd-t8: "tasks" |
// "cards" | "pipeline" | "form" | …). These ride INTO the canvas as server-painted
// read-only atoms carrying the whole block verbatim; they never emit a value/content
// op — structurally they behave EXACTLY like a sheet/embed read-only atom.
function isCanvasFleetType(type) {
  // The DataViz kinds ride the same bpFleet node + server-paint channel
  // (pd-ee-dataviz-editors) — a parallel set, same projection.
  return CANVAS_FLEET_TYPES.has(type) || CANVAS_DATAVIZ_TYPES.has(type);
}

// True when a TipTap NODE type is the canvas fleet node ("bpFleet"). runToOps reads
// node.type off a getJSON node (the NODE name); ALL fleet types share the single
// `bpFleet` node, so the specific kind comes off the bpType attr, not the node type
// (the same multiplexing bpField uses).
function isCanvasFleetNode(nodeType) {
  return nodeType === CANVAS_FLEET_NODE_NAME;
}

// True when a portable-doc BLOCK type is a canvas container (S10: "columns"). These
// ride INTO the canvas as recursive nested-block nodes (bpColumns > bpColumn+ > child
// nodes); an interior change re-emits ONE coarse `columns` patch (V1 coarse round-trip).
function isCanvasContainerType(type) {
  return CANVAS_CONTAINER_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas container (e.g. "bpColumns"). runToOps reads
// node.type off a getJSON node (the NODE name, not the bpType).
function isCanvasContainerNode(nodeType) {
  return Object.prototype.hasOwnProperty.call(
    CANVAS_CONTAINER_BP_TYPE_BY_NODE,
    nodeType,
  );
}

// True when a TipTap NODE type is the per-column verbatim child-carrier atom
// ("bpColumnAtom"). Never a TOP-LEVEL node — always nested inside a bpColumn — so the
// top-level classify/diff never sees it; used only by the column-child reconstruction.
function isCanvasColumnAtomNode(nodeType) {
  return nodeType === BP_COLUMN_ATOM_NODE_NAME;
}

// Structural deep clone, DOM-free and Node-API-free. structuredClone is a
// global in modern V8 (and browsers); fall back to JSON for older runtimes.
// Both are pure and create zero shared references with the source.
function deepClone(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

// True for a plain (non-array, non-null) object — the presence-of-query discriminant
// for the LIVE task-list widget (a `query` MAP → bpTaskList; anything else → the
// bpFleet fallback). Mirrors task_resolver.ex's `is_map(query)` guard.
function isPlainObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

// ── doctrine template attrs (pdd-t2): locked / role round-trip ───────────────
//
// A mandated template block carries `locked: true` + a `role` ("title" |
// "featured"). These are TOP-LEVEL block keys (see Content.Papers.Template), NOT
// content — so the canvas must carry them through the blocks ⇄ node ⇄ blocks
// round-trip for the prose title (an opaque image carries them for free inside
// its verbatim bpBlock). Both directions are D3-additive: an UNLOCKED block gets
// NO locked/role key, so it saves byte-identically (the pre-#1161 corpus is
// untouched). locked/role are NEVER a diff-relevant field (the stable-key
// change-detectors ignore them) and NEVER ride a patch (patch.ex strips them):
// they are immutable template identity, seeded at create, carried here for
// fidelity + so the live node can be recognized as locked.

// Stamp locked/role onto a NODE attrs bag from its source block — only when set.
function stampTemplateAttrs(attrs, block) {
  if (block && block.locked === true) attrs.locked = true;
  if (block && block.role != null) attrs.role = block.role;
  return attrs;
}

// Carry locked/role back onto a reconstructed BLOCK from its node attrs — only
// when set (the inverse of stampTemplateAttrs). BpAttrs' parseHTML yields null
// for an absent attr, so an unlocked node adds nothing.
function carryTemplateAttrs(block, attrs) {
  if (attrs && attrs.locked === true) block.locked = true;
  if (attrs && attrs.role != null) block.role = attrs.role;
  return block;
}

// ── projection: blocks → one doc ───────────────────────────────────────────

// runToTiptap(blocks) → { type:"doc", content:[ node, … ] }
//
// One top-level node per block, IN ORDER. Every node is stamped with
// attrs:{ bpId, bpType } so the reverse diff can key by bpId.
//
//   PROSE block → blockToTiptap(block).content[0] (the single prose node),
//     with { bpId, bpType } MERGED into its attrs (preserving any attrs
//     blockToTiptap already set, e.g. heading level).
//   CANVAS ATOM block (S3: divider) → a native leaf node of that type carrying
//     ONLY { bpId, bpType } attrs — e.g. { type:"divider", attrs:{bpId,bpType} }.
//     No bpBlock: a divider is a content-free leaf, fully described by its type +
//     id, so it round-trips through the canvas schema's own node (divider-node.js)
//     rather than as an opaque blob.
//   OTHER NON-PROSE block → an opaque placeholder:
//       { type:"bpOpaque", attrs:{ bpId, bpType, bpBlock:<deep-cloned block> } }
//     carrying the original block JSON verbatim so it round-trips untouched.
export function runToTiptap(blocks) {
  return { type: "doc", content: (blocks || []).map(blockToNode) };
}

// blockToNode(block) → ONE ProseMirror node. The per-block dispatch runToTiptap maps
// over its block list — factored out so a CONTAINER (section) can recurse it over its
// nested children (sectionBlockToNode). The container branch is checked BEFORE the
// opaque fallback so a top-level section projects to the editable bpSection.
function blockToNode(block) {
  {
    const bpId = block && block.id;
    const bpType = block && block.type;

    if (isProseType(bpType)) {
      // Lift the single prose node convert.js produced and merge our stamp into
      // its attrs without clobbering blockToTiptap's own attrs (heading level).
      const node = blockToTiptap(block).content[0];
      const attrs = { ...(node.attrs || {}), bpId, bpType };
      // Doctrine template attrs (pdd-t2): stamp locked/role so the live PM node
      // carries them (BpAttrs declares them → they survive getJSON, and the
      // filterTransaction veto reads node.attrs.locked). D3 additive: ONLY when
      // present, so an unlocked prose block projects with no locked/role attr and
      // round-trips byte-identically.
      stampTemplateAttrs(attrs, block);
      return { ...node, attrs };
    }

    if (isCanvasAtomType(bpType)) {
      // A canvas atom (divider): a native leaf node of that type, stamped with
      // bpId/bpType only. The canvas schema (divider-node.js) declares the node,
      // so getJSON() round-trips it. No content, no bpBlock — a leaf is fully
      // described by type + id.
      return { type: bpType, attrs: { bpId, bpType } };
    }

    if (isCanvasContentType(bpType)) {
      // A canvas CONTENT node (S3.2: callout; notes-grid split: note): a native node
      // of that type whose BODY is editable inline content. callout chrome (tone/
      // title/collapsible/collapsed) rides node attrs; note chrome (label/lead) rides
      // node attrs too (edited via input islands). The canvas schema declares each, so
      // getJSON() round-trips the body + chrome attrs. Sub-route by bpType.
      if (isNoteType(bpType)) return noteBlockToNode(block, bpId, bpType);
      return calloutBlockToNode(block, bpId, bpType);
    }

    if (isCanvasCardType(bpType)) {
      // STEP 4: the card WIDGET — a slots-native node whose BODY slot becomes an
      // editable inline contentDOM and whose title/tone/media/action ride attrs
      // (present-only). card-node.js declares the bpCard node, so getJSON() round-
      // trips the body + the chrome attrs. node.type is the NODE name (bpCard), not
      // the bpType (card).
      return cardBlockToNode(block, bpId, bpType);
    }

    if (isCanvasStageType(bpType)) {
      // The stage WIDGET — a control-atom whose five scalars ride node.attrs (kind/
      // title/detail text + files/source chrome), edited by native controls. stage-
      // node.js declares the bpStage node, so getJSON() round-trips the attrs. node.type
      // is the NODE name (bpStage), not the bpType (stage).
      return stageBlockToNode(block, bpId, bpType);
    }

    if (isCanvasAttrAtomType(bpType)) {
      // A canvas ATTR-ATOM node (S3.3: code; S3.4: diagram): an atom node whose body
      // TEXT rides in an attr (a plain string, edited by a non-PM textarea) plus an
      // optional second field. The canvas schema declares the node (code-node.js /
      // diagram-node.js), so getJSON() round-trips the body + optional field. NOTE the
      // node.type is the NODE name (bpCode / bpDiagram), not the bpType (code /
      // diagram). Dispatch by bpType: code → value/lang; diagram → source/caption.
      if (bpType === "diagram") return diagramBlockToNode(block, bpId, bpType);
      return codeBlockToNode(block, bpId, bpType);
    }

    if (isCanvasFieldType(bpType)) {
      // A canvas CONTROL-ATOM node (S3.5): the 7 native field-* types PLUS the 2
      // picker types (field-image / field-reference). An atom node whose VALUE rides
      // in an attr, edited by a NATIVE control (the 7) or by a picker WC —
      // bp-media-picker / bp-reference-picker (field-node.js) — for the pickers. ALL
      // project to the SAME `bpField` node, discriminated by the bpType attr. The
      // node carries the FULL config (label/options/rows/fieldName) so the round-trip
      // is byte-identical — UNLIKE code/diagram, a field block has config keys the
      // canvas must not lose. field-image/field-reference ARE in this set
      // (CANVAS_PICKER_FIELD_TYPES): they dispatch here to fieldBlockToNode and mount
      // an editable picker — they are NOT boundaries, do NOT fall through to bpOpaque.
      return fieldBlockToNode(block, bpId, bpType);
    }

    if (isCanvasActionType(bpType)) {
      // A canvas CONTROL-ATOM node (editable-action): a LEAF whose href/label/priority
      // ride attrs, edited by native controls. It projects to the `bpAction` node
      // (node.type !== bpType "action"). Each payload key is threaded ONLY when present
      // (null = absence) so an untouched action's getJSON re-projection matches and
      // emits zero ops.
      return actionBlockToNode(block, bpId, bpType);
    }

    if (isCanvasReadOnlyAtomType(bpType)) {
      // A canvas READ-ONLY ATOM node (S3.6: sheet / embed): an atom node that is a
      // REFERENCE, NOT editable text. It carries the WHOLE block VERBATIM (deep-cloned,
      // no shared ref) on `bpBlock` — the bpOpaque verbatim-carry, but on a
      // canvas-eligible node (so it no longer SPLITS a run) with a dedicated read-only
      // node-view (embed-node.js) instead of the generic opaque placeholder. NOTE the
      // node.type is the NODE name (bpSheet / bpEmbed), not the bpType (sheet / embed).
      return readOnlyAtomBlockToNode(block, bpId, bpType);
    }

    if (isLiveTaskListBlock(block)) {
      // A LIVE task-list WIDGET (a `task-list` carrying a `query` map): an
      // EDITABLE-QUERY + server-painted-ROWS atom (bpTaskList). Checked BEFORE the
      // fleet branch — a snapshot-only task-list (no query) falls through to bpFleet
      // (read-only), the additive presence-of-query discriminant. It carries ONLY the
      // editable data (query/title/config) as typed attrs; the rows are NEVER on the
      // node (server-painted projection). NOTE the node.type is the NODE name
      // (bpTaskList), not the bpType (task-list).
      return taskListBlockToNode(block, bpId, bpType);
    }

    if (isCanvasFleetType(bpType)) {
      // A canvas FLEET node (pdd-t8: tasks / cards / pipeline / form / …): a
      // SERVER-PAINTED read-only atom. Structurally identical to the sheet/embed
      // read-only atom — the WHOLE block rides VERBATIM on `bpBlock`, ZERO
      // value/content ops — but ALL fleet kinds share the ONE `bpFleet` node
      // (discriminated by bpType), and its node-view paints the reader's own pushed
      // HTML (bp:block-html) rather than a client-computed chip. NOTE the node.type
      // is the NODE name (bpFleet), not the bpType.
      return fleetBlockToNode(block, bpId, bpType);
    }

    if (isCanvasFigureType(bpType)) {
      // A canvas FIGURE atom (editable-figure: figure): a SERVER-PAINTED
      // read-only-child + editable-caption atom. The CHILD rides VERBATIM
      // (deep-cloned) on `bpChild` and paints read-only via the fleet hook; the
      // CAPTION is the sole editable attr (patch-block{caption}). NOTE the node.type
      // is the NODE name (bpFigure), not the bpType (figure).
      return figureBlockToNode(block, bpId, bpType);
    }

    if (isCanvasContainerType(bpType)) {
      // A canvas CONTAINER node — sub-route by bpType (all fold into a run):
      //   * section → bpSection: nested block+ body + editable title; a nested
      //     (depth>=1) section child is carried opaque (V1 forbid-nesting) — see
      //     sectionBlockToNode's depth-guard.
      //   * terminal → bpTerminal: a nested block+ body wrapped in reader chrome
      //     (title/live/footer); non-first-class body children ride a bpTerminalAtom.
      //   * columns → bpColumns: a recursive nested-block node whose column
      //     child-block trees become editable PM regions (prose+divider); any
      //     non-first-class child rides a read-only bpColumnAtom (columns-node.js).
      // node.type is the NODE name (bpSection/bpTerminal/bpColumns), not the bpType.
      if (bpType === "section") return sectionBlockToNode(block, bpId, bpType);
      if (bpType === "terminal") return terminalBlockToNode(block, bpId, bpType);
      return columnsBlockToNode(block, bpId, bpType);
    }

    if (isCanvasRoleType(bpType)) {
      // An article-chrome ROLE node (eyebrow / byline / ingress / pullquote): a
      // native prose node of that type whose BODY carries the role's persisted text/
      // items/inline, styled by a bp-role-* class to MATCH THE READER. role-nodes.js
      // declares the node, so getJSON() round-trips the body + bpId/bpType. node.type
      // === bpType (no NODE_NAME indirection).
      return roleBlockToNode(block, bpId, bpType);
    }

    if (isCanvasTableType(bpType)) {
      // The table as a NESTED node tree (bpTable > bpTableRow > cells). Its rows/head
      // live in PM child nodes (each cell body = inline runs), NOT attrs — which is
      // what earns free inline-mark editing. table-node.js declares the four nodes so
      // getJSON() round-trips the whole grid. node.type is the NODE name (bpTable),
      // not the bpType (table).
      return tableBlockToNode(block, bpId, bpType);
    }

    // Opaque carry-through: the original block JSON, deep-cloned (no shared refs).
    return {
      type: "bpOpaque",
      attrs: { bpId, bpType, bpBlock: deepClone(block) },
    };
  }
}

// ── section ⇄ canvas container node ─────────────────────────────────────────
//
// A `section` block { id, type:"section", title?, blocks:[child, …] } ⇄ a bpSection
// node { type:"bpSection", attrs:{ bpId, bpType, title? }, content:[childNode, …] }.
// Each child recurses through blockToNode; a nested section child is carried opaque
// (V1 forbid-nesting). The title rides node.attrs, PRESENT-ONLY (a null/absent title
// round-trips as ABSENT, byte-mirroring callout.title).

// sectionBlockToNode(block, bpId, bpType) → the bpSection node.
//
// STEP-2 LAYOUT ENGINE: a section MAY carry `layout` ({mode,tracks?,gap?,
// breakpoints?}) and its children MAY carry span/order. Both are PRESENT-ONLY —
// a no-layout section adds NOTHING new to attrs, so it projects byte-identically
// to the pre-layout path (backward-compat: runToOps zero-ops on open/save).
//
// CELLS HOIST: prose/canvas child nodes DROP unknown keys on getJSON, so a child's
// span/order can't ride the child node without touching ~10 node files. Instead we
// hoist them into the section's OWN declared `cells` attr (a JSON data-attr,
// getJSON-safe — the bpColumnAtom bpBlock precedent), keyed BY CHILD bpId, ONLY
// when some child actually carries span/order. STEP-6 (RISK #1 fix, LANDED): cells
// is a bpId-keyed OBJECT map `{ [childBpId]: { span?, order? } }`, NOT a positional
// array. A positional array misassigned span/order under a canvas reorder (the
// coarse replace path rebuilds children in the new order but attrs.cells is
// independent of content) — bpId keying is position-independent, so a reorder pulls
// each child's OWN cell regardless of where it sits. Present-only: a section with no
// child span/order adds NO cells attr (byte-identical to a plain section).
function sectionBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "section" };
  if (block && block.title != null) attrs.title = block.title;
  if (block && block.layout != null) attrs.layout = block.layout;
  // FRAMED-FINALE (charter D34): the scalar `variant` ("framed") rides node.attrs
  // VERBATIM, PRESENT-ONLY (a no-variant section adds NOTHING — byte-identical to
  // the pre-variant path; mirrors layout above). Without this thread the canvas
  // silently DROPPED the frame on open.
  if (block && block.variant != null) attrs.variant = block.variant;

  const children = (block && block.blocks) || [];

  // Hoist child span/order into a bpId-keyed cells object — present-only (omitted
  // entirely when no child carries either key, so a plain section is unchanged). A
  // child with no id (should not happen for a persisted child) is skipped.
  const cellsById = {};
  for (const child of children) {
    const cid = child && child.id;
    if (cid == null) continue;
    const cell = {};
    if (child.span != null) cell.span = child.span;
    if (child.order != null) cell.order = child.order;
    if (Object.keys(cell).length) cellsById[cid] = cell;
  }
  if (Object.keys(cellsById).length) attrs.cells = cellsById;

  const content = children.map((child) => {
    // DEPTH-GUARD (V1 forbid-nesting): a child of type "section" is carried VERBATIM
    // as bpOpaque (read-only), NOT projected as another bpSection — so a legacy nested
    // section round-trips byte-identical and is never restructured (the silent-lift
    // trap). Every other child projects normally via blockToNode (which itself falls
    // to bpOpaque for a non-canvas child like composite/codelist).
    if (child && isCanvasContainerType(child.type)) {
      return {
        type: "bpOpaque",
        attrs: {
          bpId: child.id,
          bpType: child.type,
          bpBlock: deepClone(child),
        },
      };
    }
    return blockToNode(child);
  });

  const node = { type: CANVAS_CONTAINER_NODE_NAME, attrs };
  if (content.length) node.content = content;
  return node;
}

// sectionNodeToBlock(node, id, taken) → the reconstructed `section` block. Each child
// keeps its bpId or is CLIENT-MINTED one from the CALL-SHARED `taken` set (so a nested
// mint never collides with a nested prev id — the duplicate_id-abort guard). RECURSES:
// a nested bpOpaque section child rebuilds verbatim via nextNodeToBlock's opaque path.
function sectionNodeToBlock(node, id, taken) {
  const seen = taken || new Set();
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "section" };
  if (attrs.title != null) block.title = attrs.title;
  // STEP-2: lower the layout VERBATIM (present-only; NO cells inside — cells is a
  // SEPARATE attr). The persisted layout stays cells-free (doctrine: span/order
  // live on children, hoisted into attrs.cells for canvas transport only).
  if (attrs.layout != null) block.layout = attrs.layout;
  // FRAMED-FINALE (charter D34): lower the scalar variant back, present-only. This
  // ONE site covers replace-block, insert, docToBlocks AND the source-mode
  // sentinels — every reconstruction path funnels through here.
  if (attrs.variant != null) block.variant = attrs.variant;

  // STEP-6: cells is a bpId-keyed OBJECT map (not a positional array). Split each
  // child's cell back BY THE CHILD'S OWN bpId, so a canvas reorder (which changes
  // content order but leaves attrs.cells untouched) pulls the correct span/order
  // onto each child regardless of position — the reorder-safety fix.
  const cells =
    attrs.cells && typeof attrs.cells === "object" && !Array.isArray(attrs.cells)
      ? attrs.cells
      : null;

  const children = (node && node.content) || [];
  block.blocks = children.map((child) => {
    const cls = classifyNode(child);
    const childBpId = child.attrs && child.attrs.bpId;
    const cid = childBpId != null ? childBpId : mintId(seen);
    const built = nextNodeToBlock({ ...cls, id: cid, isNew: childBpId == null }, seen);
    // Key by the child's OWN bpId (present-only). A canvas-new (null-bpId) child has
    // NO cell — correct, a freshly created child carries no span/order.
    const cell = cells && childBpId != null ? cells[childBpId] : null;
    if (cell && cell.span != null) built.span = cell.span;
    if (cell && cell.order != null) built.order = cell.order;
    return built;
  });
  return block;
}

// The child-id sequence of a section node (each child's bpId, or null for a
// canvas-created child). Structural equality of this sequence is the coarse-path
// pivot: ANY difference (add / remove / reorder / reparent / a null-id child) →
// replace-block the whole rebuilt subtree; an IDENTICAL sequence → recurse per-child
// fine-grained patches.
function sectionChildIdSeq(node) {
  return ((node && node.content) || []).map((c) =>
    c && c.attrs && c.attrs.bpId != null ? c.attrs.bpId : null,
  );
}

// True when two child-id sequences differ (length or any position). A null-id child
// makes them differ (a null !== a real prev id), forcing the coarse replace path.
function sectionChildSeqChanged(prevNode, nextNode) {
  const a = sectionChildIdSeq(prevNode);
  const b = sectionChildIdSeq(nextNode);
  if (a.length !== b.length) return true;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return true;
  }
  return false;
}

// True when a section node's OWN title attr changed prev↔next (independent of its
// children). The fine-grained else path (identical child-id seq) diffs child interiors
// only — WITHOUT this a title-only edit would emit ZERO ops and silently revert to the
// server title on the next echo. Normalizes absent/"" to null (both mean "no title"),
// so a "" ⇄ absent flip is NOT a spurious change.
function sectionTitleChanged(prevNode, nextNode) {
  const norm = (n) => {
    const t = n && n.attrs && n.attrs.title;
    return t == null || t === "" ? null : t;
  };
  return norm(prevNode) !== norm(nextNode);
}

// The title patch for a section: { title } when set, { title: null } when cleared
// (patch.ex drops a null key → the section renders no title line, reader parity). The
// SAME normalization as sectionNodeToBlock (attrs.title != null gates block.title).
function sectionTitlePatch(nextNode) {
  const t = nextNode && nextNode.attrs && nextNode.attrs.title;
  return { title: t == null || t === "" ? null : t };
}

// STEP-2: True when a section node's OWN `layout` attr changed prev↔next
// (independent of its children / title). Compares canonicalJSON of the normalized
// layout — cells are EXCLUDED (cells is not a layout key, it is a separate attr), so
// a hypothetical span echo never masquerades as a layout change (RISK #4). A missing
// layout normalizes to null, so absent ⇄ absent is NOT a change (zero-ops on an
// unedited no-layout section).
function normLayout(node) {
  const l = node && node.attrs && node.attrs.layout;
  return l == null ? null : l;
}

function sectionLayoutChanged(prevNode, nextNode) {
  return canonicalJSON(normLayout(prevNode)) !== canonicalJSON(normLayout(nextNode));
}

// The layout patch for a section: { layout } when set, { layout: null } when cleared.
// patch.ex merge_block shallow-merges {layout:{…}} onto the section; {layout:null}
// merges null → compose grid_layout→nil→stack (reader parity, mirrors title:null).
function sectionLayoutPatch(nextNode) {
  const l = nextNode && nextNode.attrs && nextNode.attrs.layout;
  return { layout: l == null ? null : l };
}

// When a section's child-id sequence is IDENTICAL prev↔next (no structural change),
// emit a fine-grained patch-block per child whose INTERIOR changed — keyed by the
// childId (patch.ex resolves nested ids). Reuses the SAME per-kind change-detectors as
// the top-level patch pass. Returns an ordered op list.
function sectionChildPatchOps(prevNode, nextNode) {
  const ops = [];
  const prevChildren = (prevNode && prevNode.content) || [];
  const nextChildren = (nextNode && nextNode.content) || [];
  for (let i = 0; i < nextChildren.length; i++) {
    const nextChild = nextChildren[i];
    const prevChild = prevChildren[i];
    const cid = nextChild && nextChild.attrs && nextChild.attrs.bpId;
    if (cid == null) continue; // an identical seq means every child has an id
    const cls = classifyNode(nextChild);
    const patch = childInteriorPatch(cls, prevChild, nextChild, cid);
    if (patch) ops.push({ op: "patch-block", id: cid, patch });
  }
  return ops;
}

// The mutable-fields patch for a nested child whose interior changed, dispatched by
// its canvas KIND — the SAME detectors + patch builders the top-level patch pass uses.
// Returns null when unchanged (or a no-interior kind: atom / read-only / fleet /
// opaque never report an interior change). A nested container is impossible (v1
// forbids it), so there is no recursive container case here.
function childInteriorPatch(cls, prevChild, nextChild, cid) {
  if (cls.isContent) {
    // callout OR note (the notes-grid split) — sub-route by node type.
    if (isNoteType(nextChild && nextChild.type)) {
      return noteNodeChanged(prevChild, nextChild)
        ? noteNodeToPatch(nextChild)
        : null;
    }
    return calloutNodeChanged(prevChild, nextChild)
      ? calloutNodeToPatch(nextChild)
      : null;
  }
  if (cls.isCard) {
    // STEP 4: a card child of a grid section — diff body + chrome; emit the slots+tone
    // patch when it changed (the same detector/builder the top-level pass uses).
    return cardNodeChanged(prevChild, nextChild) ? cardNodeToPatch(nextChild) : null;
  }
  if (cls.isStage) {
    // A stage child of a section (a pipeline flow) — diff the five scalars; emit the
    // present-or-null patch when it changed (same detector/builder as the top-level pass).
    return stageNodeChanged(prevChild, nextChild) ? stageNodeToPatch(nextChild) : null;
  }
  if (cls.isAttrAtom) {
    if (nextChild.type === "bpDiagram") {
      return diagramNodeChanged(prevChild, nextChild)
        ? diagramNodeToPatch(nextChild)
        : null;
    }
    return codeNodeChanged(prevChild, nextChild)
      ? codeNodeToPatch(nextChild)
      : null;
  }
  if (cls.isField) {
    return fieldNodeChanged(prevChild, nextChild)
      ? fieldNodeToPatch(nextChild)
      : null;
  }
  if (cls.isRole) {
    return roleNodeChanged(prevChild, nextChild)
      ? roleNodeToPatch(nextChild)
      : null;
  }
  if (cls.isAtom || cls.isReadOnlyAtom || cls.isFleet || cls.isOpaque) {
    // No interior to patch — a divider / sheet / embed / fleet / opaque child never
    // reports a content change (identical child-id sequence + verbatim carry).
    return null;
  }
  // Prose child (paragraph / heading / list).
  if (proseNodeChanged(prevChild, nextChild)) {
    const bpType =
      cls.bpType || (prevChild && prevChild.attrs && prevChild.attrs.bpType);
    return buildPatchBlockOp(nodeToDocEnvelope(nextChild), cid, bpType).patch;
  }
  return null;
}

// ── the duplicate_id-abort guard: recursive id seeds (the make-or-break) ─────
//
// runToOps / docToBlocks mint ids for canvas-created (null-id) blocks. mintId keys
// collision-freedom off a `taken` set. If that set is seeded from TOP-LEVEL ids only,
// a nested child id (living inside block.blocks / a bpSection body's content) is
// INVISIBLE to the seed → a mint can collide with it → patch.ex duplicate_id
// (patch.ex:182/191) ABORTS THE WHOLE ATOMIC BATCH, losing every co-batched edit. The
// two walkers below seed `taken` from the ENTIRE tree (top-level + section bodies at
// any depth), closing that gap.

// Walk a portable-doc BLOCK tree (descend section.blocks at any depth), adding every
// id into `sink`.
function walkBlockIds(blocks, sink) {
  for (const block of blocks || []) {
    if (!block) continue;
    if (block.id != null) sink.add(block.id);
    if (Array.isArray(block.blocks)) walkBlockIds(block.blocks, sink);
  }
}

// Walk a canvas NODE tree (descend a bpSection node's content at any depth), adding
// every node.attrs.bpId into `sink`.
function walkNodeIds(nodes, sink) {
  for (const node of nodes || []) {
    if (!node) continue;
    const id = node.attrs && node.attrs.bpId;
    if (id != null) sink.add(id);
    if (isCanvasContainerNode(node.type) && Array.isArray(node.content)) {
      walkNodeIds(node.content, sink);
    }
  }
}

// ── callout ⇄ canvas content node (S3.2) ────────────────────────────────────
//
// convert.js has NO callout path (it only round-trips paragraph|heading|list), so
// the callout block ⇄ TipTap-node mapping lives HERE, mirroring how blockToTiptap
// /tiptapToBlock handle inline — REUSING convert.js's exported inlineArrayToTiptap
// /tiptapInlineToPd verbatim for the body (the body IS inline runs; do not
// reinvent inline serialization).
//
// The chrome rides node.attrs:
//   tone        — string, defaults "info" (compose.ex:157 `tone || "info"`)
//   title       — optional; ABSENT (null) round-trips as no `title` field
//   collapsible — boolean; ABSENT (false) → no `collapsible` field
//   collapsed   — boolean; ABSENT (false) → no `collapsed` field
// Omitting absent chrome fields is the byte-fidelity contract: compose.ex
// maybe_put / maybe_put_true only thread these when present, so a callout that
// never had a title must round-trip WITHOUT a title key (not title:"").

// calloutBodyInline(block) → the callout body's inline array (STEP 3 slot model).
//
// The `body` slot is the source of truth: when the block carries a materialized
// `slots.body` (a list whose lone element is a paragraph), read that paragraph's
// `content`; otherwise fall back to the legacy `content` array. Both encodings of
// the SAME body yield the SAME inline array, so a slot-form and a content-form
// callout project to an IDENTICAL node — which is what keeps zero-op-on-load true
// (stableCalloutKey keys on node.content, so a legacy-loaded callout and its
// re-projection compare EQUAL). Mirrors Elixir Slots.callout_body_inline/1.
function calloutBodyInline(block) {
  const slotBody = block && block.slots && block.slots.body;
  if (Array.isArray(slotBody) && slotBody.length) {
    const first = slotBody[0];
    return (first && first.content) || [];
  }
  return (block && block.content) || [];
}

// calloutBlockToNode(block) → { type:"callout", attrs:{…}, content:[inline…] }
//
// The body inline array (calloutBodyInline: slots.body[0].content else content) →
// TipTap inline nodes via the shared serializer. Chrome fields → attrs (only the
// present ones; tone always present with its "info" default so a tone swap is
// always diffable). title/collapsible/collapsed stay WIDGET attrs OUTSIDE the slot.
function calloutBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    tone: (block && block.tone) || "info",
  };
  // Only carry title/collapsible/collapsed when PRESENT in the source block, so
  // an untouched callout's getJSON re-projection matches and emits zero ops.
  if (block && block.title != null) attrs.title = block.title;
  if (block && block.collapsible === true) attrs.collapsible = true;
  if (block && block.collapsed === true) attrs.collapsed = true;

  const node = { type: bpType || "callout", attrs };
  const inline = inlineArrayToTiptap(calloutBodyInline(block));
  if (inline.length) node.content = inline;
  return node;
}

// calloutNodeToBlock(node, id) → { id, type:"callout", tone, title?, collapsible?,
//   collapsed?, content:[inline…] }
//
// Reconstruct the portable-doc callout block from a callout NODE (the inverse of
// calloutBlockToNode). Body inline ← tiptapInlineToPd (the shared deserializer).
// Chrome fields read off node.attrs, threaded ONLY when present/true so the
// reconstructed block is byte-identical to one that round-tripped through
// compose.ex (no stray title:"" / collapsible:false).
function calloutNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "callout",
    tone: attrs.tone || "info",
    content: tiptapInlineToPd((node && node.content) || []),
  };
  if (attrs.title != null) block.title = attrs.title;
  if (attrs.collapsible === true) block.collapsible = true;
  if (attrs.collapsed === true) block.collapsed = true;
  return block;
}

// The mutable-fields PATCH for a callout (the analogue of buildPatchBlockOp's
// patch map for prose). It is calloutNodeToBlock MINUS id/type — patch.ex re-pins
// those (the same contract tiptapToBlock follows).
//
// CRITICAL: the patch emits the chrome fields (title/collapsible/collapsed)
// EXPLICITLY even when false/null. patch-block is a SHALLOW Map.merge (patch.ex
// merge_block) that can REPLACE or PRESERVE a key but never DELETE one — so
// OMITTING a now-false/null field would leave the STALE old value, silently
// reverting an EXPAND (collapsed true→false via the fold button), a TITLE-CLEAR
// (set→null), or a collapsible-off on persist/reload. An explicit collapsible/
// collapsed:false round-trips byte-identically (compose.ex), and title:null is
// dropped by compose maybe_put. The INSERT path (calloutNodeToBlock) correctly
// OMITS absent fields — only the patch is explicit, so removals actually land.
function calloutNodeToPatch(node) {
  const block = calloutNodeToBlock(node, null);
  const attrs = (node && node.attrs) || {};
  return {
    tone: block.tone,
    content: block.content,
    title: attrs.title == null ? null : attrs.title,
    collapsible: attrs.collapsible === true,
    collapsed: attrs.collapsed === true,
  };
}

// True when a callout node's body OR chrome changed (an interior edit). We
// compare the canonical (key-order-insensitive) projection of the diff-relevant
// fields — tone, title, collapsible, collapsed, content — so a tone swap, title
// edit, fold toggle, or body edit flips it, but a pure reorder (bpId/bpType only)
// does not. Uses the SAME canonicalJSON the prose path uses, so a node serialized
// by calloutBlockToNode and the SAME node from the live editor's getJSON compare
// EQUAL despite differing attr/text key order.
function calloutNodeChanged(prevNode, nextNode) {
  return stableCalloutKey(prevNode) !== stableCalloutKey(nextNode);
}

function stableCalloutKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    tone: a.tone || "info",
    title: a.title == null ? null : a.title,
    collapsible: a.collapsible === true,
    collapsed: a.collapsed === true,
    content: node.content || null,
  });
}

// ── note ⇄ canvas content node (the notes-grid split) ────────────────────────
//
// The NEW singular `note` block ⇄ a native `note` content node. Persisted shape
// (COMPAT/wire form — the callout precedent, flat strings the default):
//   { id, type:"note", label, lead?, text }
// (or, MATERIALIZED/additive: { …, slots:{ label:[<p>], lead?:[<p>], body:[<p>] } }).
//
// A note is a SUPERSET of callout: it exposes THREE editable fields, not one.
//   body  → the ONE editable inline contentDOM (the callout body precedent — a widget
//           FLATTENS its body slot to inline). The `text` flat field is its plain
//           encoding; a note body persists as PLAIN TEXT (marks dropped) to match the
//           legacy `escape_html(text)` reader contract (a DELIBERATE lossy tradeoff).
//   label → a plain string on node.attrs, edited by a non-PM input island.
//   lead  → a plain string on node.attrs, edited by a non-PM input island; ABSENT
//           (null) round-trips as no `lead` field (byte-fidelity, the callout title
//           precedent — an absent lead is never "").

// noteBodyInline(block) → the note body's inline array (Elixir Slots.note_body_text's
// SOURCE, before the plain flatten). slots.body[0].content when materialized, else the
// flat `text` field wrapped as a single inline text run (the compat encoding).
function noteBodyInline(block) {
  const slotBody = block && block.slots && block.slots.body;
  if (Array.isArray(slotBody) && slotBody.length) {
    const first = slotBody[0];
    return (first && first.content) || [];
  }
  const t = block && block.text;
  if (typeof t === "string" && t !== "") return [{ type: "text", value: t }];
  if (typeof t === "number") return [{ type: "text", value: String(t) }];
  return [];
}

// noteFieldText(block, slotName, flatKey) → a note field as a plain string. The slot's
// lone paragraph inline FLATTENED to plain text (marks dropped) when materialized, else
// the flat field. JS twin of Elixir Slots.note_{label,lead}_text/1.
function noteFieldText(block, slotName, flatKey) {
  const slot = block && block.slots && block.slots[slotName];
  if (Array.isArray(slot) && slot.length) {
    const first = slot[0];
    return flattenInlineText((first && first.content) || []);
  }
  const v = block && block[flatKey];
  if (typeof v === "string") return v;
  if (typeof v === "number") return String(v);
  return "";
}

function noteLabelText(block) {
  return noteFieldText(block, "label", "label");
}
function noteLeadText(block) {
  return noteFieldText(block, "lead", "lead");
}

// Flatten a portable-doc inline array to plain text, marks dropped — the JS twin of
// Elixir Slots.flatten_inline_text/1. A text / inline-code leaf contributes its
// `value`; a mark wrapper (strong/em/link/…) contributes its `children` flattened.
function flattenInlineText(arr) {
  if (typeof arr === "string") return arr;
  if (!Array.isArray(arr)) return "";
  return arr.map(flattenInlineNode).join("");
}
function flattenInlineNode(n) {
  if (typeof n === "string") return n;
  if (!n || typeof n !== "object") return "";
  if (n.type === "text" || n.type === "code")
    return n.value == null ? "" : String(n.value);
  if (Array.isArray(n.children)) return flattenInlineText(n.children);
  return "";
}

// The plain-text body string of a note NODE — its inline content (via the shared
// deserializer) flattened to plain text (marks dropped), matching the reader's
// note_body_text plain contract. This is what the flat `text` field persists.
function noteNodeBodyText(node) {
  return flattenInlineText(tiptapInlineToPd((node && node.content) || []));
}

// noteBlockToNode(block) → { type:"note", attrs:{ bpId, bpType, label?, lead? },
//   content:[inline…] }. body slot inline → contentDOM via the shared serializer;
// label/lead → attrs, PRESENT-ONLY ("" and absent both → no attr) so an untouched
// note's getJSON re-projection matches and emits zero ops (stableNoteKey).
function noteBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "note" };
  const label = noteLabelText(block);
  if (label !== "") attrs.label = label;
  const lead = noteLeadText(block);
  if (lead !== "") attrs.lead = lead;

  const node = { type: bpType || "note", attrs };
  const inline = inlineArrayToTiptap(noteBodyInline(block));
  if (inline.length) node.content = inline;
  return node;
}

// noteNodeToBlock(node, id) → { id, type:"note", label?, lead?, text }. Reconstruct
// the FLAT wire form (the callout precedent — note keeps flat strings as the persisted
// encoding, slots additive server-side). label/lead threaded ONLY when present; body
// → the plain `text` field (always, even ""). Absent lead → ABSENT key (byte-fidelity).
function noteNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "note" };
  if (attrs.label != null && attrs.label !== "") block.label = attrs.label;
  if (attrs.lead != null && attrs.lead !== "") block.lead = attrs.lead;
  block.text = noteNodeBodyText(node);
  return block;
}

// The mutable-fields PATCH for a note. patch-block is a SHALLOW Map.merge (patch.ex
// merge_block) that REPLACES or PRESERVES a key but never DELETES one — so a cleared
// label/lead must be emitted EXPLICITLY as null (else the stale value survives),
// mirroring calloutNodeToPatch's removal-safe contract. `text` is emitted always. On
// the reader, compose maybe_put/note_lead_text drops an empty lead, so lead:null and
// an absent lead render identically.
function noteNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return {
    label: attrs.label == null || attrs.label === "" ? null : attrs.label,
    lead: attrs.lead == null || attrs.lead === "" ? null : attrs.lead,
    text: noteNodeBodyText(node),
  };
}

// True when a note node's body OR chrome (label/lead) changed — an interior edit.
// Canonical (key-order-insensitive) compare on the diff-relevant fields, so a body/
// label/lead edit flips it but a pure reorder (bpId/bpType only) does not. Keys on
// node.content so a legacy-loaded note and its re-projection compare EQUAL
// (zero-op-on-load), the stableCalloutKey precedent.
function noteNodeChanged(prevNode, nextNode) {
  return stableNoteKey(prevNode) !== stableNoteKey(nextNode);
}

function stableNoteKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    label: a.label == null || a.label === "" ? null : a.label,
    lead: a.lead == null || a.lead === "" ? null : a.lead,
    content: (node && node.content) || null,
  });
}

// ── card ⇄ canvas content node (STEP 4) ──────────────────────────────────────
//
// The NEW slots-native `card` block ⇄ a bpCard node. Persisted shape (slots-native,
// no legacy inline encoding):
//   { id, type:"card", tone?, slots:{ title?:[{type:"heading",text}],
//     body:[{type:"paragraph",content:[<inline>…]}], media?:[<image>], action?:[<action>] } }
//
// The body slot becomes the ONE editable inline contentDOM (the callout precedent —
// a widget FLATTENS its body slot to inline); title/tone/media/action ride node.attrs.
//   tone   — string, PRESENT-ONLY (DIVERGES from callout's always-"info" default: a
//            tone-less card must NOT gain a tone on round-trip, or it emits a spurious
//            op; card_html treats absent tone as NO modifier, matching a legacy item).
//   title  — the title slot heading's `text`; PRESENT-ONLY (absent → no attr).
//   media  — the OPTIONAL media slot's lone element, carried VERBATIM on attrs.media.
//   action — the OPTIONAL action slot's lone element, carried VERBATIM on attrs.action.
// Omitting absent chrome is the byte-fidelity contract: cardNodeToBlock threads each
// field ONLY when present, so a card that never entered the canvas round-trips byte-
// identical.

// cardBodyInline(block) → the card body slot's inline array (slots.body[0].content).
// A card has NO legacy `content` encoding (it is slots-native), so an absent/empty
// body slot yields []. JS twin of Slots.card_body_text's SOURCE (the inline array
// before it is flattened to plain text server-side).
function cardBodyInline(block) {
  const slotBody = block && block.slots && block.slots.body;
  if (Array.isArray(slotBody) && slotBody.length) {
    const first = slotBody[0];
    return (first && first.content) || [];
  }
  return [];
}

// cardTitle(block) → the card title slot heading's `text`, or null when absent/empty.
// JS twin of Slots.card_title_text (present-only; "" and absent both → null so a
// title-less card round-trips WITHOUT a title attr).
function cardTitle(block) {
  const slotTitle = block && block.slots && block.slots.title;
  if (Array.isArray(slotTitle) && slotTitle.length) {
    const t = slotTitle[0] && slotTitle[0].text;
    return t == null || t === "" ? null : t;
  }
  return null;
}

// The lone element of a card's OPTIONAL media/action slot (verbatim), or null.
function cardMedia(block) {
  const s = block && block.slots && block.slots.media;
  return Array.isArray(s) && s.length && s[0] ? s[0] : null;
}
function cardAction(block) {
  const s = block && block.slots && block.slots.action;
  return Array.isArray(s) && s.length && s[0] ? s[0] : null;
}

// cardBlockToNode(block) → { type:"bpCard", attrs:{…}, content:[inline…] }
// The body slot inline → TipTap inline nodes via the shared serializer (the callout
// body path). Chrome → attrs, PRESENT-ONLY (tone/title/media/action omitted when
// absent) so an untouched card's getJSON re-projection matches and emits zero ops.
function cardBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "card" };
  const title = cardTitle(block);
  if (title != null) attrs.title = title;
  if (block && block.tone != null) attrs.tone = block.tone; // PRESENT-ONLY (no default)
  const media = cardMedia(block);
  if (media != null) attrs.media = deepClone(media);
  const action = cardAction(block);
  if (action != null) attrs.action = deepClone(action);

  const node = { type: CANVAS_CARD_NODE_NAME, attrs };
  const inline = inlineArrayToTiptap(cardBodyInline(block));
  if (inline.length) node.content = inline;
  return node;
}

// cardNodeToSlots(node) → the reconstructed slots map. body ALWAYS present (a card is
// slots-native, its body slot is the contentDOM); title/media/action threaded ONLY
// when present so the rebuild is byte-identical to a card that never entered the canvas.
function cardNodeToSlots(node) {
  const attrs = (node && node.attrs) || {};
  const slots = {};
  if (attrs.title != null && attrs.title !== "") {
    slots.title = [{ type: "heading", text: attrs.title }];
  }
  slots.body = [
    { type: "paragraph", content: tiptapInlineToPd((node && node.content) || []) },
  ];
  if (attrs.media != null) slots.media = [deepClone(attrs.media)];
  if (attrs.action != null) slots.action = [deepClone(attrs.action)];
  return slots;
}

// cardNodeToBlock(node, id) → { id, type:"card", slots:{…}, tone? }
// Reconstruct the portable-doc card block from a bpCard NODE (the inverse of
// cardBlockToNode). tone threaded ONLY when present (present-only, byte-fidelity).
function cardNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "card", slots: cardNodeToSlots(node) };
  if (attrs.tone != null) block.tone = attrs.tone;
  return block;
}

// The mutable-fields PATCH for a card. patch-block is a SHALLOW Map.merge (patch.ex
// merge_block) — a top-level key is REPLACED wholesale or preserved, never deleted.
// So we emit the WHOLE rebuilt `slots` map (a cleared title/media/action simply drops
// that slot key ⇒ the removal LANDS via the wholesale replace) + `tone` EXPLICITLY
// (null when cleared, so a tone-clear reverts to the no-modifier legacy look instead
// of leaving the stale tone). The callout removal-safe precedent, adapted to a
// slots-native block.
function cardNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return {
    slots: cardNodeToSlots(node),
    tone: attrs.tone == null ? null : attrs.tone,
  };
}

// True when a card node's body OR chrome (tone/title/media/action) changed — an
// interior edit. Canonical (key-order-insensitive) compare so a body/tone/title/
// media/action edit flips it but a pure reorder (bpId only) does not.
function cardNodeChanged(prevNode, nextNode) {
  return stableCardKey(prevNode) !== stableCardKey(nextNode);
}

function stableCardKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    tone: a.tone == null ? null : a.tone,
    title: a.title == null || a.title === "" ? null : a.title,
    media: a.media == null ? null : a.media,
    action: a.action == null ? null : a.action,
    content: node.content || null,
  });
}

// ── stage ⇄ canvas control-atom node (the pipeline-node twin) ────────────────
//
// The `stage` block ⇄ a bpStage node. WIRE-canonical (scalar) shape, byte-aligned with
// one legacy pipeline `nodes[]` entry:
//   { id, type:"stage", kind?, title?, detail?, files?, source? }
// The three text fields ride via the slot API (slots OR scalar → the SAME plain string);
// files/source are chrome scalars. Every field ATTR is PRESENT-ONLY (absence sentinel
// null), so a stage that never entered the canvas round-trips byte-identical (zero ops).
//   kind/title/detail — string, PRESENT-ONLY (empty/absent → no attr).
//   files             — string chrome, PRESENT-ONLY.
//   source            — chrome flag carried VERBATIM (true|"true"|1), PRESENT-ONLY, so a
//                       hand-authored `source:"true"` round-trips byte-identical; the
//                       accent + change key interpret it truthy.

// The reader `truthy` (compose truthy/1): true | "true" | 1. Mirrors stage-node.js.
function stageTruthy(v) {
  return v === true || v === "true" || v === 1;
}

// stageFieldText(block, name) → the PLAIN string of a stage text slot. JS twin of
// Slots.stage_field_text/2: the lone slot element's text-runs FLATTENED to plain text
// (marks dropped) when a `slots` map carries it, ELSE the top-level scalar. A pasted
// `<strong>` must NOT survive — plain text only, so byte-identity with the escaped-plain
// reader holds.
function stageFieldText(block, name) {
  const slot = block && block.slots && block.slots[name];
  if (Array.isArray(slot) && slot.length) {
    return flattenInlineTextPlain((slot[0] && slot[0].content) || []);
  }
  const v = block && block[name];
  return v == null ? "" : String(v);
}

// Flatten a ProseMirror-style inline array to concatenated PLAIN text (marks dropped):
// a text/code leaf contributes its `value`; a mark node contributes its children
// flattened; a bare string is itself. JS twin of Slots.flatten_inline_text/1.
function flattenInlineTextPlain(list) {
  if (typeof list === "string") return list;
  if (!Array.isArray(list)) return "";
  let out = "";
  for (const n of list) {
    if (typeof n === "string") out += n;
    else if (n && (n.type === "text" || n.type === "code")) out += n.value == null ? "" : String(n.value);
    else if (n && Array.isArray(n.children)) out += flattenInlineTextPlain(n.children);
  }
  return out;
}

// stageBlockToNode(block) → { type:"bpStage", attrs:{…} }. Every field PRESENT-ONLY:
// an empty text field / absent chrome adds NO attr, so an untouched stage's getJSON
// re-projection matches and emits zero ops. `source` is carried VERBATIM.
function stageBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "stage" };
  const kind = stageFieldText(block, "kind");
  if (kind !== "") attrs.kind = kind;
  const title = stageFieldText(block, "title");
  if (title !== "") attrs.title = title;
  const detail = stageFieldText(block, "detail");
  if (detail !== "") attrs.detail = detail;
  const files = block && block.files;
  if (files != null && files !== "") attrs.files = String(files);
  if (block && block.source != null) attrs.source = block.source; // VERBATIM present-only
  return { type: CANVAS_STAGE_NODE_NAME, attrs };
}

// stageNodeToBlock(node, id) → { id, type:"stage", kind?, title?, detail?, files?,
// source? }. The inverse of stageBlockToNode — PRESENT-ONLY (byte-fidelity), source
// VERBATIM. This is the INSERT / reconstruct / docToBlocks path; a fresh-loaded stage
// re-projects to the SAME present-only scalars ⇒ zero ops on open.
function stageNodeToBlock(node, id) {
  const a = (node && node.attrs) || {};
  const block = { id, type: "stage" };
  if (a.kind != null && a.kind !== "") block.kind = a.kind;
  if (a.title != null && a.title !== "") block.title = a.title;
  if (a.detail != null && a.detail !== "") block.detail = a.detail;
  if (a.files != null && a.files !== "") block.files = a.files;
  if (a.source != null) block.source = a.source; // VERBATIM
  return block;
}

// The mutable-fields PATCH for a stage. patch-block is a SHALLOW Map.merge that CANNOT
// delete a key, so — the card `tone:null` precedent generalized — emit the WHOLE
// scalar field set EXPLICITLY: a cleared text field / unchecked source rides `null`
// (renders as an absent/empty cell — reader parity), a set field rides its value.
// source rides VERBATIM when truthy (a title-only edit preserves the original `"true"`),
// else null. So a removal LANDS despite the shallow merge.
function stageNodeToPatch(node) {
  const a = (node && node.attrs) || {};
  const norm = (v) => (v == null || v === "" ? null : v);
  return {
    kind: norm(a.kind),
    title: norm(a.title),
    detail: norm(a.detail),
    files: norm(a.files),
    source: stageTruthy(a.source) ? a.source : null,
  };
}

// True when a stage node's fields changed — a canonical (absence-insensitive) compare
// so a real edit flips it but a pure reorder (bpId only) or a null≡""≡absent flip does
// not. Mirrors stage-node.js:stageKey (kept in lockstep by construction).
function stageNodeChanged(prevNode, nextNode) {
  return stableStageKey(prevNode) !== stableStageKey(nextNode);
}

function stableStageKey(node) {
  const a = (node && node.attrs) || {};
  const s = (v) => (v == null || v === "" ? "" : String(v));
  return canonicalJSON({
    kind: s(a.kind),
    title: s(a.title),
    detail: s(a.detail),
    files: s(a.files),
    source: stageTruthy(a.source),
  });
}

// ── table ⇄ canvas nested node tree ──────────────────────────────────────────
//
// The `table` block ⇄ the bpTable > bpTableRow > bpTableHeaderCell|bpTableCell node
// tree. Block shape (compose.ex:406-425): { type:"table", rows:[[cell,…],…], head:[cell,
// …]? }. `rows` is a list of body rows; `head` is an OPTIONAL single header row (a list
// of cells). A cell is an INLINE array — the SAME shape a paragraph/callout body carries
// — so cell↔node uses inlineArrayToTiptap / tiptapInlineToPd verbatim. The header row is
// modeled as a bpTableRow of bpTableHeaderCell; body rows are bpTableRow of bpTableCell.
// The bpTable node carries bpId/bpType; rows/cells carry NO bpId (one id per table).

// Normalize a cell to an inline array before the shared serializer. A scalar cell
// (string/number — upstream paper_to_blocks.py emits text-only cells as plain strings;
// inline.ex:25-27 tolerates them) becomes a single text run; an inline array passes
// through; anything else → empty (defensive; renders an empty cell).
function cellToInline(cell) {
  if (Array.isArray(cell)) return cell;
  if (cell == null) return [];
  if (typeof cell === "string" || typeof cell === "number")
    return [{ type: "text", value: String(cell) }];
  return [];
}

// One cell block → a bpTableHeaderCell|bpTableCell node. Omit the `content` key when
// the inline array is empty (empty-body fidelity, callout precedent).
function cellToNode(nodeName, cell) {
  const node = { type: nodeName };
  const inline = inlineArrayToTiptap(cellToInline(cell));
  if (inline.length) node.content = inline;
  return node;
}

// tableBlockToNode(block) → { type:"bpTable", attrs:{bpId,bpType},
//   content:[ headRow?, ...bodyRows ] }. The header row (only when block.head is present
// & non-empty) leads with bpTableHeaderCell cells; body rows follow with bpTableCell.
// Guards keep the node schema-valid (bpTableRow+ ; each row (cell)+) for a degenerate
// empty table — real tables always carry rows, so the guards never fire on live data.
function tableBlockToNode(block, bpId, bpType) {
  const rowsSrc = Array.isArray(block && block.rows) ? block.rows : [];
  const headSrc = block && block.head;
  const content = [];

  const mkRow = (nodeName, cells) => {
    const list = Array.isArray(cells) ? cells : [];
    const cellNodes = list.map((cell) => cellToNode(nodeName, cell));
    if (!cellNodes.length) cellNodes.push({ type: nodeName });
    return { type: "bpTableRow", content: cellNodes };
  };

  if (Array.isArray(headSrc) && headSrc.length) {
    content.push(mkRow("bpTableHeaderCell", headSrc));
  }
  for (const row of rowsSrc) content.push(mkRow("bpTableCell", row));

  if (!content.length) {
    content.push({ type: "bpTableRow", content: [{ type: "bpTableCell" }] });
  }

  return { type: "bpTable", attrs: { bpId, bpType: bpType || "table" }, content };
}

// tableNodeToBlock(node, id) → { id, type:"table", rows:[…], head?:[…] }. Walk the row
// nodes: a LEADING row whose cells are ALL bpTableHeaderCell → block.head; every other
// row → a body row. Each cell → tiptapInlineToPd(cell.content||[]) (the shared
// deserializer). head is OMITTED when there is no header row (byte-fidelity; the INSERT
// path drops absent fields, like calloutNodeToBlock).
function tableNodeToBlock(node, id) {
  const rowNodes = (node && node.content) || [];
  let head = null;
  const rows = [];
  rowNodes.forEach((rowNode, i) => {
    const cells = (rowNode && rowNode.content) || [];
    const isHeaderRow =
      cells.length > 0 && cells.every((c) => c.type === "bpTableHeaderCell");
    const mapped = cells.map((c) => tiptapInlineToPd((c && c.content) || []));
    if (i === 0 && isHeaderRow) head = mapped;
    else rows.push(mapped);
  });
  const block = { id, type: "table", rows };
  if (head) block.head = head;
  return block;
}

// The COARSE whole-table PATCH: { rows:<all body rows>, head:<header cells OR []> }.
// CRITICAL (the calloutNodeToPatch removal contract): patch-block is a SHALLOW Map.merge
// that can REPLACE but never DELETE a key — so head is emitted EXPLICITLY as `[]` when the
// header row was removed, otherwise the stale old head survives and the header band
// silently reappears on reload. compose.ex maps head:[] → no thead, so `head:[]`
// round-trips clean. `rows` is always the full body (a whole-table replace — one cell
// edit re-emits the entire rows/head, the v1 greenlit coarse round-trip).
function tableNodeToPatch(node) {
  const block = tableNodeToBlock(node, null);
  return {
    rows: block.rows,
    head: block.head ? block.head : [],
  };
}

// True when a table's grid/content changed. Canonical (key-order-insensitive) compare
// of the header cells + body rows — a cell edit / add-remove row-col flips it, a pure
// reorder (bpId only) emits nothing.
function tableNodeChanged(prevNode, nextNode) {
  return stableTableKey(prevNode) !== stableTableKey(nextNode);
}

function stableTableKey(node) {
  const b = tableNodeToBlock(node, null);
  return canonicalJSON({ head: b.head ? b.head : null, rows: b.rows });
}

// ── eyebrow / byline / ingress / pullquote ⇄ canvas role prose node ──────────
//
// The four article-chrome ROLE blocks ⇄ their same-named TipTap prose nodes. UNLIKE
// the callout (chrome + inline body) these are chrome-free styled prose, but their
// PERSIST shape differs by role — so the block ⇄ node body mapping dispatches on
// ROLE_BODY_MODEL:
//   text  (eyebrow)  — a PLAIN string in `text`. The node body is a single text run;
//     an empty string → a CONTENTLESS node (no `content` key) so an empty eyebrow's
//     getJSON re-projection matches (nodeText of a contentless node is "").
//   items (byline)   — an `items` LIST. The reader joins with " · "; the canvas shows
//     the JOINED display string as the node's text, and splits it back on "·" (the
//     BYTE-MIRROR of blocks.ex build_block_patch byline). A legacy text-only byline
//     (no `items`) falls back to its `text` on display and MIGRATES to items on first
//     save — the SAME behaviour the form has (its input value = items joined).
//   inline (ingress/pullquote) — an inline `content` array, via the SHARED
//     inlineArrayToTiptap / tiptapInlineToPd (the callout body path). Marks work.
//
// bpId/bpType ride node.attrs; node.type === bpType for all four (no NODE_NAME map).

// The concatenated text of a node's inline text children (an eyebrow/byline body is a
// single text run; a contentless node yields "").
function roleNodeText(node) {
  return ((node && node.content) || []).map((n) => n.text || "").join("");
}

// Split a byline display string into its items — the BYTE-MIRROR of blocks.ex:60-67
// build_block_patch byline: split on "·", trim each, drop the empties.
function splitBylineItems(s) {
  return String(s == null ? "" : s)
    .split("·")
    .map((x) => x.trim())
    .filter((x) => x !== "");
}

// The DISPLAY text a byline block shows in its node: the items joined with " · ", or
// (legacy) the plain `text` when there are no items. Mirrors the form input value.
function bylineDisplay(block) {
  const items = block && block.items;
  if (Array.isArray(items) && items.length) return items.join(" · ");
  return (block && block.text) || "";
}

// roleBlockToNode(block) → { type:<role>, attrs:{ bpId, bpType }, content?:[text|inline] }
//
// The body is built per ROLE_BODY_MODEL:
//   text  → a single text run of block.text (or a CONTENTLESS node when empty).
//   items → a single text run of the " · "-joined display (contentless when empty).
//   inline→ inlineArrayToTiptap(block.content) (the shared serializer; may be empty).
function roleBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType };
  const model = ROLE_BODY_MODEL[bpType];
  const node = { type: bpType, attrs };

  if (model === "inline") {
    const inline = inlineArrayToTiptap((block && block.content) || []);
    if (inline.length) node.content = inline;
    return node;
  }

  // text / items → a single text run of the display string (contentless when "").
  const text =
    model === "items" ? bylineDisplay(block) : (block && block.text) || "";
  if (text) node.content = [{ type: "text", text }];
  return node;
}

// roleNodeToBlock(node, id) → the reconstructed portable-doc role block. The inverse of
// roleBlockToNode, dispatched by ROLE_BODY_MODEL[node.type]:
//   text  → { id, type:"eyebrow", text:<nodeText> }
//   items → { id, type:"byline", items:splitBylineItems(<nodeText>) }
//   inline→ { id, type:<role>, content:tiptapInlineToPd(node.content) }
function roleNodeToBlock(node, id) {
  const bpType = (node && node.type) || "eyebrow";
  const model = ROLE_BODY_MODEL[bpType];
  if (model === "inline") {
    return {
      id,
      type: bpType,
      content: tiptapInlineToPd((node && node.content) || []),
    };
  }
  if (model === "items") {
    return { id, type: bpType, items: splitBylineItems(roleNodeText(node)) };
  }
  return { id, type: bpType, text: roleNodeText(node) };
}

// The mutable-fields PATCH for a role block (the analogue of calloutNodeToPatch). It
// is roleNodeToBlock MINUS id/type — the shallow-merge fields patch.ex re-pins. Every
// role has exactly ONE mutable field (text / items / content), emitted UNCONDITIONALLY
// (simpler than the callout's removal-safe maybe_put — there is no optional field to
// drop), so a shallow merge always lands the current body.
function roleNodeToPatch(node) {
  const bpType = (node && node.type) || "eyebrow";
  const model = ROLE_BODY_MODEL[bpType];
  if (model === "inline") {
    return { content: tiptapInlineToPd((node && node.content) || []) };
  }
  if (model === "items") {
    return { items: splitBylineItems(roleNodeText(node)) };
  }
  return { text: roleNodeText(node) };
}

// True when a role node's body changed. We compare the canonical projection of the
// DERIVED stable body — for a byline the DERIVED `items` (NOT the raw " · " display
// string), so join/split is idempotent and an unedited byline emits ZERO ops. Uses the
// SAME canonicalJSON the prose/callout paths use, so a node from roleBlockToNode and the
// SAME node from getJSON compare EQUAL despite key-order differences.
function roleNodeChanged(prevNode, nextNode) {
  return stableRoleKey(prevNode) !== stableRoleKey(nextNode);
}

function stableRoleKey(node) {
  const bpType = (node && node.type) || "eyebrow";
  const model = ROLE_BODY_MODEL[bpType];
  if (model === "inline") {
    return canonicalJSON({ content: (node && node.content) || null });
  }
  if (model === "items") {
    return canonicalJSON({ items: splitBylineItems(roleNodeText(node)) });
  }
  return canonicalJSON({ text: roleNodeText(node) });
}

// ── code ⇄ canvas attr-atom node (S3.3) ─────────────────────────────────────
//
// The code block { id, type:"code", value:"<text>", lang?:"<lang>" } ⇄ the TipTap
// `bpCode` ATOM node. UNLIKE the callout (whose body is inline runs), code's body
// is a PLAIN STRING in the `value` attr — there is NO inline serialization; the
// string rides verbatim (multi-line and all). `lang` is OPTIONAL: put_if_present
// drops a nil/"" lang on persist (blocks.ex:113-115), so an absent/empty lang must
// round-trip as NO `lang` key — we omit it on insert and emit it explicitly only
// when set on the patch (mirroring the callout's removal-safe contract).
//
// node.type is `bpCode` (the NODE name), NOT `code` (the bpType) — see the
// CANVAS_ATTR_ATOM_NODE_NAMES note; the StarterKit inline code MARK owns `code`.

// codeBlockToNode(block) → { type:"bpCode", attrs:{ bpId, bpType, value, lang? } }
//
// The code TEXT → the `value` attr verbatim (default "" — Map.put always writes a
// value). `lang` → the `lang` attr ONLY when present + non-empty (byte-fidelity:
// an absent lang has no key).
function codeBlockToNode(block, bpId, bpType) {
  const nodeName = CANVAS_ATTR_ATOM_NODE_NAMES[bpType] || "bpCode";
  const attrs = {
    bpId,
    bpType,
    value: (block && block.value) || "",
  };
  // Carry lang ONLY when present + non-empty, so an untouched lang-less code
  // block's getJSON re-projection matches and emits zero ops.
  if (block && block.lang != null && block.lang !== "") attrs.lang = block.lang;
  return { type: nodeName, attrs };
}

// codeNodeToBlock(node, id) → { id, type:"code", value, lang? }
//
// Reconstruct the portable-doc code block from a bpCode NODE (the inverse of
// codeBlockToNode). `value` reads off the attr (default ""); `lang` is threaded
// ONLY when present + non-empty so the reconstructed block is byte-identical to
// one that round-tripped through compose.ex/build_block_patch (no stray lang:"").
function codeNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "code",
    value: attrs.value || "",
  };
  if (attrs.lang != null && attrs.lang !== "") block.lang = attrs.lang;
  return block;
}

// The mutable-fields PATCH for a code block (the analogue of calloutNodeToPatch).
// `value` always rides the patch (Map.put always writes it). `lang` rides
// EXPLICITLY — but the explicit value is the empty string "" when absent, NOT a
// dropped key. The canvas paper-ops path folds via Patch.apply_patches, where
// patch-block is a SHALLOW Map.merge (patch.ex merge_block) that can REPLACE or
// PRESERVE a key but never DELETE one (it does NOT run build_block_patch's
// put_if_present). So clearing a previously-set lang must emit lang:"" — the merge
// then STORES lang:"", which is render-equivalent to a lang-less block
// (compose/walk treat ""/absent the same) and round-trips (stableCodeKey below
// normalizes ""/null equal → zero spurious ops). Omitting lang would instead leave
// the STALE old lang. So: value always; lang as the string ("" when cleared).
function codeNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return {
    value: attrs.value || "",
    lang: attrs.lang == null ? "" : attrs.lang,
  };
}

// True when a code node's value OR lang changed (an attr edit). Canonical
// (key-order-insensitive) compare of the diff-relevant fields — value + lang — so
// a value edit or a lang change flips it, but a pure reorder (bpId/bpType only)
// does not. An absent lang normalizes to "" so a lang-less node and one carrying
// lang:"" / lang:null compare EQUAL (they persist identically).
function codeNodeChanged(prevNode, nextNode) {
  return stableCodeKey(prevNode) !== stableCodeKey(nextNode);
}

function stableCodeKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    value: a.value || "",
    lang: a.lang == null ? "" : a.lang,
  });
}

// ── diagram ⇄ canvas attr-atom node (S3.4) ──────────────────────────────────
//
// MIRRORS the code mapping (S3.3) ALMOST VERBATIM with two field renames: the body
// field is `source` (not `value`) and the optional second field is `caption` (not
// `lang`). The diagram block { id, type:"diagram", source:"<text>", caption?:"<short>" }
// ⇄ the TipTap `bpDiagram` ATOM node. UNLIKE the callout (whose body is inline runs),
// the diagram's body is a PLAIN STRING in the `source` attr — there is NO inline
// serialization; the string rides verbatim (multi-line Mermaid and all).
//
// caption handling MIRRORS code's lang: although the STORED diagram always carries
// caption (build_block_patch writes it UNCONDITIONALLY, NOT via put_if_present —
// blocks.ex:47), the CANVAS round-trip treats caption like the optional/droppable
// `lang`: omit it on insert and on the projection when absent/empty (compose.ex
// defaults a missing caption to "", so an omitted caption is render-equivalent to ""),
// and emit it EXPLICITLY ("" when cleared) on the patch for the removal-safe shallow
// merge. So an absent/empty caption round-trips as ABSENT and the canonical compare
// treats ""/null/absent EQUAL → zero spurious ops.
//
// node.type is `bpDiagram` (the NODE name), NOT `diagram` (the bpType) — see the
// CANVAS_ATTR_ATOM_NODE_NAMES note.

// diagramBlockToNode(block) → { type:"bpDiagram", attrs:{ bpId, bpType, source, caption? } }
//
// The Mermaid SOURCE → the `source` attr verbatim (default "" — the diagram patch
// always writes a source). `caption` → the `caption` attr ONLY when present +
// non-empty (byte-fidelity: an absent caption has no key). Mirrors codeBlockToNode.
function diagramBlockToNode(block, bpId, bpType) {
  const nodeName = CANVAS_ATTR_ATOM_NODE_NAMES[bpType] || "bpDiagram";
  const attrs = {
    bpId,
    bpType,
    source: (block && block.source) || "",
  };
  // Carry caption ONLY when present + non-empty, so an untouched caption-less diagram
  // block's getJSON re-projection matches and emits zero ops.
  if (block && block.caption != null && block.caption !== "")
    attrs.caption = block.caption;
  return { type: nodeName, attrs };
}

// diagramNodeToBlock(node, id) → { id, type:"diagram", source, caption? }
//
// Reconstruct the portable-doc diagram block from a bpDiagram NODE (the inverse of
// diagramBlockToNode). `source` reads off the attr (default ""); `caption` is
// threaded ONLY when present + non-empty so the reconstructed block is byte-identical
// to a caption-less round-trip (no stray caption:""). Mirrors codeNodeToBlock.
function diagramNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "diagram",
    source: attrs.source || "",
  };
  if (attrs.caption != null && attrs.caption !== "")
    block.caption = attrs.caption;
  return block;
}

// The mutable-fields PATCH for a diagram block (the analogue of codeNodeToPatch).
// `source` always rides the patch. `caption` rides EXPLICITLY — but the explicit
// value is the empty string "" when absent, NOT a dropped key (removal-safe). The
// canvas paper-ops path folds via Patch.apply_patches, where patch-block is a SHALLOW
// Map.merge (patch.ex merge_block) that can REPLACE or PRESERVE a key but never DELETE
// one. So clearing a previously-set caption must emit caption:"" — the merge then
// STORES caption:"", render-equivalent to a caption-less diagram (compose/walk treat
// ""/absent the same) and round-tripping (stableDiagramKey normalizes ""/null equal →
// zero spurious ops). Omitting caption would instead leave the STALE old caption. So:
// source always; caption as the string ("" when cleared). Mirrors codeNodeToPatch.
function diagramNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return {
    source: attrs.source || "",
    caption: attrs.caption == null ? "" : attrs.caption,
  };
}

// True when a diagram node's source OR caption changed (an attr edit). Canonical
// (key-order-insensitive) compare of the diff-relevant fields — source + caption — so
// a source edit or a caption change flips it, but a pure reorder (bpId/bpType only)
// does not. An absent caption normalizes to "" so a caption-less node and one carrying
// caption:"" / caption:null compare EQUAL (they persist render-identically). Mirrors
// codeNodeChanged.
function diagramNodeChanged(prevNode, nextNode) {
  return stableDiagramKey(prevNode) !== stableDiagramKey(nextNode);
}

function stableDiagramKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    source: a.source || "",
    caption: a.caption == null ? "" : a.caption,
  });
}

// ── field ⇄ canvas control-atom node (S3.5) ─────────────────────────────────
//
// The 7 NATIVE field blocks { id, type:"field-*", value:<typed>, label?, fieldName?,
// rows?(text), options?(select) } ⇄ the TipTap `bpField` CONTROL-ATOM node. UNLIKE
// code/diagram (fully described by value+lang / source+caption), a field block
// carries CONFIG keys (label / options / rows / fieldName) the canvas must NOT lose,
// so the node carries the FULL config and fieldNodeToBlock merges the edited `value`
// over it. The value's TYPE is BOOLEAN for field-boolean, STRING for the rest —
// COERCED by the node-view exactly like BarkparkFieldBlockBridge (boolean →
// control.checked; else control.value).
//
// node.type is `bpField` (the NODE name) for ALL 7 types; the specific bpType
// ("field-string" | … | "field-color") rides the node's bpType attr and is what
// reconstructs block.type.

// Normalize a value to its per-type stored form. A field-boolean coerces to a
// strict boolean (true ONLY for the boolean true / "true"); every other native
// type coerces to a string ("" when absent). Mirrors the BarkparkFieldBlockBridge
// coercion target (boolean vs string) so a round-tripped value matches the
// per-block path byte-for-byte.
function normalizeFieldValue(bpType, value) {
  if (bpType === "field-boolean") {
    return value === true || value === "true";
  }
  if (value == null) return "";
  return typeof value === "string" ? value : String(value);
}

// fieldBlockToNode(block) → { type:"bpField", attrs:{ bpId, bpType, value, fieldName?,
//   label?, options?, rows? } }
//
// The editable VALUE → the `value` attr (normalized to its per-type stored form).
// The CONFIG keys ride attrs ONLY when present so an untouched field block's getJSON
// re-projection matches and emits zero ops:
//   * fieldName — only when present + non-empty (an unbound block has no key).
//   * label     — only when present (label is a string; carry it as-is when set).
//   * options   — only when present (field-select carries it; others don't).
//   * rows      — only when present (field-text's optional row count).
function fieldBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    value: normalizeFieldValue(bpType, block && block.value),
  };
  if (block && block.fieldName != null && block.fieldName !== "")
    attrs.fieldName = block.fieldName;
  if (block && block.label != null) attrs.label = block.label;
  if (block && block.options != null) attrs.options = block.options;
  if (block && block.rows != null) attrs.rows = block.rows;
  // PICKER config (field-image / field-reference) carried verbatim so the round-trip is
  // byte-identical: refType (field-reference's target schema) + dataset (a per-block
  // fetch-scope override). Carried ONLY when present so an untouched picker's getJSON
  // re-projection matches and emits zero ops (a field-reference's default refType is ""
  // — present and kept; an unset dataset has no key).
  if (block && block.refType != null) attrs.refType = block.refType;
  if (block && block.dataset != null) attrs.dataset = block.dataset;
  // Doctrine template attrs (pdd-t2): a field block could itself be a mandated
  // template block (a future doc type's forced field) — carry locked/role so the
  // round-trip is byte-identical and the node can be recognized as locked. D3:
  // only when present.
  stampTemplateAttrs(attrs, block);
  return { type: CANVAS_FIELD_NODE_NAME, attrs };
}

// fieldNodeToBlock(node, id) → { id, type:"field-*", value, fieldName?, label?,
//   options?, rows? }
//
// Reconstruct the portable-doc field block from a bpField NODE (the inverse of
// fieldBlockToNode). block.type comes off the bpType attr (the specific kind);
// `value` is normalized to its per-type stored form; config keys are threaded ONLY
// when present so the reconstructed block is byte-identical to one that round-tripped
// through the per-block path (no stray fieldName:"" / null options).
function fieldNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const bpType = attrs.bpType || "field-string";
  const block = {
    id,
    type: bpType,
    value: normalizeFieldValue(bpType, attrs.value),
  };
  if (attrs.fieldName != null && attrs.fieldName !== "")
    block.fieldName = attrs.fieldName;
  if (attrs.label != null) block.label = attrs.label;
  if (attrs.options != null) block.options = attrs.options;
  if (attrs.rows != null) block.rows = attrs.rows;
  // PICKER config (field-image / field-reference): refType + dataset threaded ONLY when
  // present so the reconstructed block is byte-identical to one that round-tripped
  // through the per-block path (no stray refType/dataset on a native field). The inverse
  // of fieldBlockToNode.
  if (attrs.refType != null) block.refType = attrs.refType;
  if (attrs.dataset != null) block.dataset = attrs.dataset;
  // Doctrine template attrs (pdd-t2): carry locked/role back — the inverse of
  // fieldBlockToNode's stamp. D3: only when present.
  carryTemplateAttrs(block, attrs);
  return block;
}

// The mutable-fields PATCH for a field block (the analogue of codeNodeToPatch). The
// ONLY mutable field is `value` — EXACTLY what BarkparkFieldBlockBridge emits
// ({op:"patch-block", id, patch:{value}}). label/options/rows/fieldName are CONFIG,
// not edited through the control, so they NEVER ride the patch — matching the
// per-block bridge byte-for-byte. The value is normalized to its per-type stored
// form (boolean for field-boolean; string otherwise) so a canvas field edit persists
// IDENTICALLY to a per-block field edit.
function fieldNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  const bpType = attrs.bpType || "field-string";
  return { value: normalizeFieldValue(bpType, attrs.value) };
}

// True when a field node's VALUE changed (the only mutable datum). Canonical
// (key-order-insensitive) compare of the normalized value, so a value edit flips it
// but a pure reorder (or a config-only re-render) does not. The value is normalized
// to its per-type stored form before comparison so a boolean true and "true", or a
// null and "" string, compare EQUAL (they persist identically).
function fieldNodeChanged(prevNode, nextNode) {
  return stableFieldKey(prevNode) !== stableFieldKey(nextNode);
}

function stableFieldKey(node) {
  const a = (node && node.attrs) || {};
  const bpType = a.bpType || "field-string";
  return canonicalJSON({ value: normalizeFieldValue(bpType, a.value) });
}

// ── action ⇄ canvas control-atom node (editable-action) ──────────────────────
//
// The CTA action block { id, type:"action", href?, label?, priority? } ⇄ the TipTap
// `bpAction` CONTROL-ATOM node. UNLIKE the field control-atom (one `value`, coerced by
// field type) an action carries THREE optional payload keys edited by native controls,
// and serves ONE bpType. UNLIKE code/diagram (droppable optional field emitted "" on
// clear) the V1 coarse re-emit threads each key ONLY when present — a user edit sets
// href+label via the inputs (both present after a touch) and priority when non-nil.
//
// priority is a TRI-STATE at rest that the reader (walk.ex button/2 :article) collapses
// to BINARY: primary iff =="primary", else secondary. normalizeActionPriority mirrors
// that collapse so nil≡secondary — selecting "Secondary" on a never-set-priority block
// is a ZERO-op and only href/label text or a primary↔secondary flip emits.
//
// node.type is `bpAction` (the NODE name), NOT `action` (the bpType).

// Collapse a tri-state priority to the reader's binary value (walk.ex button/2).
function normalizeActionPriority(p) {
  return p === "primary" ? "primary" : "secondary";
}

// actionBlockToNode(block) → { type:"bpAction", attrs:{ bpId, bpType, href?, label?,
//   priority? } }
//
// Each payload key rides an attr ONLY when present (null = the absence sentinel), so an
// untouched action's getJSON re-projection matches and emits zero ops. Doctrine
// template attrs (locked/role) carried when set (an action could be a mandated block).
function actionBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType };
  if (block && block.href != null) attrs.href = block.href;
  if (block && block.label != null) attrs.label = block.label;
  if (block && block.priority != null) attrs.priority = block.priority;
  stampTemplateAttrs(attrs, block);
  return { type: CANVAS_ACTION_NODE_NAME, attrs };
}

// actionNodeToBlock(node, id) → { id, type:"action", href?, label?, priority? }
//
// The inverse of actionBlockToNode — absence preserved. block.type is the FIXED
// "action" (the node serves one bpType); each payload key is threaded ONLY when present
// so the reconstructed block is byte-identical to one that round-tripped through
// compose.ex (no stray href:"" / null priority).
function actionNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "action" };
  if (attrs.href != null) block.href = attrs.href;
  if (attrs.label != null) block.label = attrs.label;
  if (attrs.priority != null) block.priority = attrs.priority;
  carryTemplateAttrs(block, attrs);
  return block;
}

// The COARSE whole-attrs PATCH for an action block. href/label/priority are threaded
// when !=null. Since any user edit sets href+label via the inputs, both are present
// after a touch; priority is present when non-nil. This is the v1 coarse re-emit
// (the greenlit coarse round-trip).
function actionNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  const patch = {};
  if (attrs.href != null) patch.href = attrs.href;
  if (attrs.label != null) patch.label = attrs.label;
  if (attrs.priority != null) patch.priority = attrs.priority;
  return patch;
}

// The canonical (order/absence-insensitive) key of an action node's diff-relevant
// attrs — href/label as their display strings ("" when absent), priority collapsed to
// its binary value. The normalize collapses nil≡secondary so selecting "Secondary" on a
// never-set block is a ZERO-op (matches the reader). Mirrors action-node.js:actionKey.
function stableActionKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    href: a.href == null ? "" : a.href,
    label: a.label == null ? "" : a.label,
    priority: normalizeActionPriority(a.priority),
  });
}

// True when an action node's href/label/priority changed (a control edit). Canonical
// compare so a pure reorder (bpId/bpType only) does not flip it, and a nil→secondary
// select is a no-op.
function actionNodeChanged(prevNode, nextNode) {
  return stableActionKey(prevNode) !== stableActionKey(nextNode);
}

// ── sheet / embed ⇄ canvas read-only atom node (S3.6) ────────────────────────
//
// The sheet { id, type:"sheet", ref?, snapshot:<cached value-grid> } and embed
// { id, type:"embed", target:"<note title>" } blocks ⇄ the TipTap `bpSheet` /
// `bpEmbed` READ-ONLY ATOM nodes. UNLIKE every other canvas node, NOTHING here is
// EDITED in the editor: a sheet is edited in its own surface and an embed resolves at
// VIEW render (walk.ex), so the editor only ever renders a READ-ONLY chip. The WHOLE
// block rides VERBATIM on the `bpBlock` attr (the bpOpaque verbatim-carry), so the
// block round-trips byte-identically with ZERO value/content ops. The node carries NO
// individually-mutable attr — there is nothing for the editor to write back.
//
// node.type is `bpSheet` / `bpEmbed` (the NODE name), NOT the bpType (sheet / embed) —
// see the CANVAS_READONLY_ATOM_NODE_NAMES note.

// readOnlyAtomBlockToNode(block) → { type:"bpSheet"|"bpEmbed",
//   attrs:{ bpId, bpType, bpBlock:<the WHOLE block, deep-cloned> } }
//
// The whole block is deep-cloned onto bpBlock (no shared ref / no mutation), so an
// UNCHANGED sheet/embed is deep-equal to the original. The node name comes off the
// bpType (sheet → bpSheet; embed → bpEmbed).
function readOnlyAtomBlockToNode(block, bpId, bpType) {
  const nodeName = CANVAS_READONLY_ATOM_NODE_NAMES[bpType] || "bpSheet";
  return {
    type: nodeName,
    attrs: { bpId, bpType, bpBlock: deepClone(block) },
  };
}

// readOnlyAtomNodeToBlock(node, id) → the carried block VERBATIM, with the given id
// stamped on. The inverse of readOnlyAtomBlockToNode: it returns the deep-cloned
// bpBlock (so callers never share a ref with the node's attr) with `id` pinned —
// EXACTLY the bpOpaque insert reconstruction. A node with no bpBlock (a freshly-typed
// read-only atom, which the canvas never produces) degrades to a bare { id, type }.
function readOnlyAtomNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const bpType =
    attrs.bpType || CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE[node && node.type] || "sheet";
  if (attrs.bpBlock != null) {
    const block = deepClone(attrs.bpBlock);
    block.id = id;
    return block;
  }
  return { id, type: bpType };
}

// ── fleet ⇄ canvas server-painted read-only atom node (pdd-t8) ────────────────
//
// The component-fleet blocks ({ id, type:"tasks"|"cards"|"pipeline"|"form"|…, … })
// ⇄ the SINGLE TipTap `bpFleet` READ-ONLY ATOM node. Structurally these are the
// sheet/embed read-only atom (the WHOLE block rides VERBATIM on `bpBlock`; ZERO
// value/content ops; structural-only participation) — the ONLY differences are (1)
// ALL fleet kinds share the ONE `bpFleet` node (the specific kind rides the bpType
// attr, exactly like bpField multiplexes the 9 field-* kinds) and (2) the node-view
// paints the reader's OWN pushed HTML (bp:block-html) instead of a client-computed
// chip. Nothing here is EDITED in the editor — a task board / card grid / pipeline /
// grill is authored elsewhere and rendered read-only in the canvas exactly as the
// /papers reader renders it.

// fleetBlockToNode(block) → { type:"bpFleet", attrs:{ bpId, bpType, bpBlock:<whole
//   block, deep-cloned> } }
//
// The whole block is deep-cloned onto bpBlock (no shared ref / no mutation), so an
// UNCHANGED fleet block is deep-equal to the original. The node name is ALWAYS
// bpFleet; the original kind rides bpType (so runToOps/reconstruct read it back).
function fleetBlockToNode(block, bpId, bpType) {
  return {
    type: CANVAS_FLEET_NODE_NAME,
    attrs: { bpId, bpType, bpBlock: deepClone(block) },
  };
}

// fleetNodeToBlock(node, id) → the carried block VERBATIM, with the given id stamped
// on. The inverse of fleetBlockToNode: it returns the deep-cloned bpBlock (so callers
// never share a ref with the node's attr) with `id` pinned — EXACTLY the bpOpaque /
// read-only-atom insert reconstruction. A node with no bpBlock (which the canvas never
// produces) degrades to a bare { id, type } off the bpType attr.
function fleetNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  if (attrs.bpBlock != null) {
    const block = deepClone(attrs.bpBlock);
    block.id = id;
    return block;
  }
  return { id, type: attrs.bpType || "tasks" };
}

// The mutable-fields PATCH for an EDITABLE fleet block (pd-ee-fleet-editors). UNLIKE
// the read-only sheet/embed atom (which never patches), a fleet block carries authored
// content — cards/notes/pipeline items, task-* query/id config — on `bpBlock`, edited
// by the node-view's structured island. patch.ex's patch-block is a SHALLOW Map.merge,
// so we emit the block's EDITABLE PAYLOAD: every key EXCEPT the immutable `id`/`type`
// (patch.ex re-pins both and strips locked/role anyway). The shallow merge REPLACES the
// edited arrays/query (e.g. { cards:[…] } / { items:[…] } / { stages:[…] } /
// { query:{…} }) and leaves unknown sibling keys intact. Deep-cloned so the emitted op
// never shares a ref with the node attr.
function fleetNodeToPatch(node) {
  const block = (node && node.attrs && node.attrs.bpBlock) || {};
  const patch = {};
  for (const key of Object.keys(block)) {
    if (key === "id" || key === "type") continue;
    patch[key] = deepClone(block[key]);
  }
  return patch;
}

// True when a fleet block's carried content changed. Canonical (key-order-insensitive)
// compare of the bpBlock with `id` STRIPPED (id is STRUCTURAL — a reorder/move changes
// it, not the content), so an authored edit (a card added, a note's text changed, a
// pipeline stage removed, a task query relabelled) flips it while a pure reorder does
// NOT — an UNEDITED fleet block emits ZERO ops (D3 byte-stability). `type` stays in the
// key (it never changes; keeping it self-documents the compared shape).
function fleetNodeChanged(prevNode, nextNode) {
  return stableFleetKey(prevNode) !== stableFleetKey(nextNode);
}

function stableFleetKey(node) {
  const block = (node && node.attrs && node.attrs.bpBlock) || {};
  const { id, ...rest } = block;
  return canonicalJSON(rest);
}

// ── figure ⇄ canvas server-painted-child + editable-caption atom ─────────────
//
// The `figure` block { id, type:"figure", caption?:<string>, child:<BLOCK> } ⇄ the
// TipTap `bpFigure` ATOM (figure-node.js). UNLIKE the fleet/sheet read-only atoms
// (whole block verbatim on bpBlock, ZERO ops) OR the diagram attr-atom (a fully
// self-describing source+caption), a figure is a HYBRID: the CHILD rides VERBATIM/
// immutable on `bpChild` (deep-cloned, no shared ref) AND is server-painted
// read-only, while the CAPTION is the SOLE editable datum and emits a
// patch-block{caption}. Carrying ONLY the child (NOT the whole figure) keeps the
// editable caption the single source of truth, so echo-equality compares child-only
// (no stale-caption-in-a-carried-block misdetect). node.type is `bpFigure` (the NODE
// name), NOT `figure` (the bpType).

// figureBlockToNode(block) → { type:"bpFigure", attrs:{ bpId, bpType, caption, bpChild } }
//
// caption → the `caption` attr ONLY when non-empty (byte-fidelity: ""/absent → null,
// mirrors the diagram caption). bpChild → the deep-cloned child block (VERBATIM), or
// null when the figure carries no child.
function figureBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    // "" → null so a caption-less figure round-trips with no caption key.
    caption:
      block && block.caption != null && block.caption !== ""
        ? block.caption
        : null,
    bpChild: block && block.child != null ? deepClone(block.child) : null,
  };
  return { type: CANVAS_FIGURE_NODE_NAME, attrs };
}

// figureNodeToBlock(node, id) → { id, type:"figure", child, ...(caption?) }
//
// Reconstruct the portable-doc figure block from a bpFigure NODE (the inverse of
// figureBlockToNode). `child` is the deep-cloned bpChild VERBATIM (so callers never
// share a ref with the node attr); `caption` is threaded ONLY when non-empty so an
// absent caption reconstructs byte-identically (no stray caption:"").
function figureNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "figure",
    child: attrs.bpChild != null ? deepClone(attrs.bpChild) : null,
  };
  if (attrs.caption != null && attrs.caption !== "") block.caption = attrs.caption;
  return block;
}

// The mutable-fields PATCH for a figure block. The caption is the WHOLE editable
// interior; the child is immutable in v1. patch.ex's patch-block is a SHALLOW
// Map.merge, so emitting ONLY { caption } leaves the stored `child` untouched. The
// value is null when cleared/absent (compose/walk treat ""/absent the same, and the
// merge stores null → render-equivalent to a caption-less figure). Extend to
// { caption, child } only if a future editable child lands (harmless additive).
function figureNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return { caption: attrs.caption == null ? null : attrs.caption };
}

// True when a figure node's caption changed. Canonical (key-order-insensitive)
// compare of the diff-relevant fields — caption + child — so a caption edit flips it
// but a pure reorder (bpId/bpType only) does not. The child rides the key so a future
// editable child would be detected too; today it is immutable, so only the caption
// ever moves. An absent caption normalizes to null so a caption-less node and one
// carrying caption:"" / caption:null compare EQUAL (they persist render-identically).
function figureNodeChanged(prevNode, nextNode) {
  return stableFigureKey(prevNode) !== stableFigureKey(nextNode);
}

function stableFigureKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    caption: a.caption == null || a.caption === "" ? null : a.caption,
    child: a.bpChild != null ? a.bpChild : null,
  });
}

// ── task-list ⇄ canvas editable-query + server-painted-rows atom ──────────────
//
// The LIVE `task-list` block { id, type:"task-list", query:{…}, title?, config? } ⇄
// the TipTap `bpTaskList` ATOM (task-list-node.js). UNLIKE the fleet/sheet read-only
// atoms (whole block verbatim on bpBlock, ZERO ops) the task-list carries ONLY its
// EDITABLE data as typed attrs: `query` (the filter, JSON — the sole authored datum,
// analogous to figure's caption over a server-painted child), an optional `title`
// string, and an optional `config` JSON. There is NO snapshot on the node — the rows
// are a resolve-at-read PROJECTION the server paints. An edit emits patch-block{query}
// (a SHALLOW Map.merge replacing the stored query, leaving unknown sibling keys
// intact); the server RE-RESOLVES + repaints. node.type is `bpTaskList` (the NODE
// name), NOT `task-list` (the bpType). Mirrors figureBlockToNode..stableFigureKey.

// taskListBlockToNode(block) → { type:"bpTaskList", attrs:{ bpId, bpType, query,
//   title, config } }. query is deep-cloned (VERBATIM — non-label keys like parent_id
//   /labels/status round-trip untouched); title "" → null; config passes through
//   (null when absent).
function taskListBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    query: block && isPlainObject(block.query) ? deepClone(block.query) : {},
    // "" → null so a title-less task-list round-trips with no title key.
    title:
      block && block.title != null && block.title !== "" ? block.title : null,
    config: block && block.config != null ? deepClone(block.config) : null,
  };
  return { type: CANVAS_TASK_LIST_NODE_NAME, attrs };
}

// taskListNodeToBlock(node, id) → { id, type:"task-list", query, ...(title?),
//   ...(config?) }. The inverse of taskListBlockToNode: query is the deep-cloned attr
//   VERBATIM (so callers never share a ref); title/config are threaded ONLY when
//   present so an absent key reconstructs byte-identically (no stray title:"" /
//   config:null). NEVER emits a snapshot — a live task-list has none.
function taskListNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "task-list",
    query: isPlainObject(attrs.query) ? deepClone(attrs.query) : {},
  };
  if (attrs.title != null && attrs.title !== "") block.title = attrs.title;
  if (attrs.config != null) block.config = deepClone(attrs.config);
  return block;
}

// The mutable-fields PATCH for a task-list block. The query is the WHOLE editable
// datum; patch.ex's patch-block is a SHALLOW Map.merge, so { query } REPLACES the
// stored query and leaves unknown sibling keys intact. `query` is ALWAYS present (an
// emptied query is null → the reader shows the "configure me" empty state). `title`
// rides as the string (or "" when cleared, so the shallow merge overwrites a stale
// title — the code/diagram caption rule) ONLY when it changed; `config` likewise.
function taskListNodeToPatch(node, prevNode) {
  const a = (node && node.attrs) || {};
  const patch = { query: isPlainObject(a.query) ? a.query : null };

  const prev = (prevNode && prevNode.attrs) || {};
  const prevTitle = prev.title == null || prev.title === "" ? null : prev.title;
  const nextTitle = a.title == null || a.title === "" ? null : a.title;
  if (prevTitle !== nextTitle) patch.title = nextTitle == null ? "" : nextTitle;

  if (canonicalJSON(prev.config ?? null) !== canonicalJSON(a.config ?? null)) {
    patch.config = a.config ?? null;
  }
  return patch;
}

// True when a task-list node's editable data changed. Canonical (key-order-
// insensitive) compare of query + title + config, so an edit flips it but a pure
// reorder (bpId/bpType only) does not — an UNEDITED task-list emits ZERO ops (D3). An
// absent/"" title and an absent config normalize to null so absent ⇄ "" ⇄ null
// compare EQUAL.
function taskListNodeChanged(prevNode, nextNode) {
  return stableTaskListKey(prevNode) !== stableTaskListKey(nextNode);
}

function stableTaskListKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    query: isPlainObject(a.query) ? a.query : null,
    title: a.title == null || a.title === "" ? null : a.title,
    config: a.config == null ? null : a.config,
  });
}

// ── columns ⇄ canvas container node (S10) ────────────────────────────────────
//
// The `columns` block { id, type:"columns", columns:[ [childBlock,…], [childBlock,…] ] }
// ⇄ the TipTap `bpColumns` CONTAINER node (columns-node.js). UNLIKE every other canvas
// node, a columns block's interior is a NESTED BLOCK TREE: `columns` is a LIST OF
// COLUMNS, each column a LIST OF BLOCKS (a list-of-lists — NOT `[{blocks:[…]}]`;
// verified against compose.ex:731-743). Each column maps to a `bpColumn` node holding
// its child blocks; a prose/divider child projects to its NORMAL editable node, and
// ANY other kind (callout/code/sheet/fleet/image/terminal/nested-container/composite/
// table) — none of which is a valid bpColumn child by NAME — is carried VERBATIM on a
// read-only `bpColumnAtom` (else PM would DROP it = DATA LOSS).
//
// V1 COARSE round-trip: any interior change (a keystroke in a column, a child add/
// delete, a column-child reorder) re-emits ONE `patch-block` REPLACING the whole
// `columns` array. patch.ex merges the patch into the block content, so `{columns:[…]}`
// overwrites `columns` and leaves sibling keys (an unknown top-level `children`/`gap`)
// INTACT — byte-fidelity of unknown keys comes for free from patching only `columns`.
//
// node.type is `bpColumns` (the NODE name), NOT `columns` (the bpType).

// True when a reconstructed child block is a lone empty-paragraph SENTINEL — the
// placeholder an EMPTY source column is seeded with so bpColumn's `…+` content is
// satisfiable (PM rejects a contentless container). Stripped on the way back ONLY when
// it is the column's SOLE child, so a truly-empty column round-trips as `[]` while a
// column that also holds real blocks keeps every child (mirrors the featured-
// placeholder sentinel pattern).
function isEmptyParagraphBlock(block) {
  return (
    block &&
    block.type === "paragraph" &&
    (!block.content || block.content.length === 0)
  );
}

// Project ONE column child block → its canvas node. Prose (paragraph/heading/list) →
// its native editable node (via blockToTiptap, the SAME per-block prose path); divider
// → the divider atom; EVERYTHING ELSE → a bpColumnAtom carrying the whole child block
// VERBATIM (deep-cloned) so it round-trips byte-identically and PM never drops it. NO
// bpId/bpType stamp on prose/divider children — the reader ignores child ids, and an
// unstamped node matches the depth>0-normalized live doc (index.js normalizeCanvasDoc
// strips a child's phantom null bpId/bpType).
function childBlockToNode(child) {
  const bpType = child && child.type;
  if (isProseType(bpType)) {
    // The single prose node convert.js produces — the byte-identical per-block path.
    return blockToTiptap(child).content[0];
  }
  if (isCanvasAtomType(bpType)) {
    // divider — a content-free leaf, fully described by its type.
    return { type: bpType };
  }
  // Any non-first-class child → the verbatim read-only carrier.
  return columnAtomBlockToNode(child);
}

// columnAtomBlockToNode(child) → { type:"bpColumnAtom", attrs:{ bpType, bpId?, bpBlock } }
//
// The whole child block is deep-cloned onto bpBlock (no shared ref), so an UNCHANGED
// child round-trips deep-equal to the original. bpType is the CARRIED child's kind (so
// the chip can label it and the reverse read it back). bpId rides only when the child
// carries one (child ids are not load-bearing; fixtures are id-less).
function columnAtomBlockToNode(child) {
  const attrs = { bpType: child && child.type, bpBlock: deepClone(child) };
  if (child && child.id != null) attrs.bpId = child.id;
  return { type: BP_COLUMN_ATOM_NODE_NAME, attrs };
}

// Reconstruct ONE column child NODE → its portable-doc block (the inverse of
// childBlockToNode). bpColumnAtom → the carried bpBlock VERBATIM (deep-cloned). divider
// → { type:"divider" }. prose → the per-type block via tiptapToBlock (NO id — child ids
// are omitted for byte-parity with id-less fixtures).
function childNodeToBlock(childNode) {
  const type = childNode && childNode.type;
  if (type === BP_COLUMN_ATOM_NODE_NAME) {
    const bpBlock = childNode.attrs && childNode.attrs.bpBlock;
    if (bpBlock != null) return deepClone(bpBlock);
    return { type: (childNode.attrs && childNode.attrs.bpType) || "paragraph" };
  }
  if (type === "divider") return { type: "divider" };
  const env = nodeToDocEnvelope(childNode);
  if (type === "heading") return { type: "heading", ...tiptapToBlock(env, null, "heading") };
  if (type === "bulletList" || type === "orderedList") {
    return { type: "list", ...tiptapToBlock(env, null, "list") };
  }
  return { type: "paragraph", ...tiptapToBlock(env, null, "paragraph") };
}

// Reconstruct ONE bpColumn node → its column (a LIST OF blocks). A lone empty-paragraph
// sentinel (the seed for an empty source column) collapses back to `[]`.
function columnNodeChildren(colNode) {
  const kids = ((colNode && colNode.content) || []).map(childNodeToBlock);
  if (kids.length === 1 && isEmptyParagraphBlock(kids[0])) return [];
  return kids;
}

// columnsBlockToNode(block) → { type:"bpColumns", attrs:{ bpId, bpType, cols }, content:[bpColumn…] }
//
// Each source column → a bpColumn node holding its child nodes; an EMPTY source column
// is seeded with a single empty paragraph so bpColumn's `…+` content is satisfiable
// (stripped on the way back). A columns block with no columns at all is seeded with one
// empty column. `cols` = the rendered bpColumn count (= max(sourceColumns,1) = the
// reader's own `n`), so `--bp-cols:N` matches the reader.
function columnsBlockToNode(block, bpId, bpType) {
  const srcCols = (block && block.columns) || [];
  const cols = (Array.isArray(srcCols) ? srcCols : []).map((col) => {
    const kids = (Array.isArray(col) ? col : []).map(childBlockToNode);
    return {
      type: BP_COLUMN_NODE_NAME,
      content: kids.length ? kids : [{ type: "paragraph" }],
    };
  });
  const content = cols.length
    ? cols
    : [{ type: BP_COLUMN_NODE_NAME, content: [{ type: "paragraph" }] }];
  return {
    type: CANVAS_CONTAINER_NODE_NAMES[bpType] || "bpColumns",
    attrs: { bpId, bpType, cols: content.length },
    content,
  };
}

// columnsNodeToColumns(node) → the `columns` array of portable-doc blocks (a list of
// columns, each a list of blocks). The projection columnsNodeToBlock uses minus id/type
// — and the SAME derivation the coarse diff (columnsNodeChanged) and the patch use, so
// an UNEDITED columns emits ZERO ops (the reconstruction is byte-stable).
function columnsNodeToColumns(node) {
  return ((node && node.content) || []).map(columnNodeChildren);
}

// columnsNodeToBlock(node, id) → { id, type:"columns", columns:[…] }
//
// Reconstruct the whole columns block from a bpColumns node (used by docToBlocks + the
// insert path). NOTE: a SURVIVING columns block never rebuilds through this — its diff
// emits ONLY a `{columns:[…]}` patch (patch.ex merges it, so unknown sibling keys
// survive). This full rebuild is for a genuinely-NEW columns block (no unknown keys) and
// the source-mode baseline.
function columnsNodeToBlock(node, id) {
  return { id, type: "columns", columns: columnsNodeToColumns(node) };
}

// True when a columns node's interior changed (any child edit / add / delete / reorder
// in any column). CRITICAL: an UNEDITED columns must emit ZERO ops (else every mount
// spuriously patches). We compare the canonical (key-order-insensitive) projection of
// the reconstructed `columns` array — which reconstructs to BLOCKS and thus IGNORES
// child node attrs (phantom null bpId/bpType a nested paragraph gains via BpAttrs), so
// the coarse diff is immune to the depth>0 attr-presence gap.
function columnsNodeChanged(prevNode, nextNode) {
  return (
    canonicalJSON(columnsNodeToColumns(prevNode)) !==
    canonicalJSON(columnsNodeToColumns(nextNode))
  );
}

// ── terminal ⇄ canvas container node ─────────────────────────────────────────
//
// The `terminal` block { id, type:"terminal", title?, footer?, live?, children:[BLOCK…]
// (or legacy `blocks`) } ⇄ the TipTap `bpTerminal` CONTAINER node (terminal-node.js).
// UNLIKE columns (a list-of-lists) a terminal has a SINGLE body child array + THREE
// chrome scalars (title/footer/live). Each body child maps like a column child: a
// prose/divider child → its NORMAL editable node, ANY other kind (callout/code/sheet/
// fleet/image/nested-container/table) → a VERBATIM read-only `bpTerminalAtom` (else PM
// would DROP it = DATA LOSS). Reader source: compose.ex:708-727 + container_children
// (compose.ex:902 — `children || blocks || []`; canonical key = "children").
//
// V1 COARSE round-trip (mirrors calloutNodeToPatch — EXPLICIT chrome, omit-on-insert):
// any interior change re-emits ONE `patch-block` carrying the whole body child array +
// the three chrome scalars EXPLICITLY (title/footer null, live false) so a title-CLEAR
// / live-OFF actually LANDS through patch.ex's shallow Map.merge (a shallow merge can't
// DELETE a key — so we send explicit null/false, which compose renders byte-identically
// to absent: Map.get(b,"title","") and the live-in-[…] gate — VERIFIED compose.ex).
//
// node.type is `bpTerminal` (the NODE name), NOT `terminal` (the bpType).

// Project ONE terminal body child block → its canvas node. IDENTICAL to childBlockToNode
// (columns) but routes a non-first-class child to a bpTerminalAtom. Prose → native
// editable node; divider → the leaf atom; EVERYTHING ELSE → the verbatim carrier.
function terminalChildBlockToNode(child) {
  const bpType = child && child.type;
  if (isProseType(bpType)) return blockToTiptap(child).content[0];
  if (isCanvasAtomType(bpType)) return { type: bpType };
  return terminalAtomBlockToNode(child);
}

// terminalAtomBlockToNode(child) → { type:"bpTerminalAtom", attrs:{ bpType, bpId?, bpBlock } }
// The whole child block deep-cloned onto bpBlock (no shared ref) so an UNCHANGED child
// round-trips deep-equal. IDENTICAL to columnAtomBlockToNode, only the node name differs.
function terminalAtomBlockToNode(child) {
  const attrs = { bpType: child && child.type, bpBlock: deepClone(child) };
  if (child && child.id != null) attrs.bpId = child.id;
  return { type: BP_TERMINAL_ATOM_NODE_NAME, attrs };
}

// Reconstruct ONE terminal body child NODE → its portable-doc block (inverse of
// terminalChildBlockToNode). bpTerminalAtom → the carried bpBlock VERBATIM; divider →
// { type:"divider" }; prose → the per-type block via tiptapToBlock (NO id — child ids
// are omitted for byte-parity with id-less fixtures).
function terminalChildNodeToBlock(childNode) {
  const type = childNode && childNode.type;
  if (type === BP_TERMINAL_ATOM_NODE_NAME) {
    const bpBlock = childNode.attrs && childNode.attrs.bpBlock;
    if (bpBlock != null) return deepClone(bpBlock);
    return { type: (childNode.attrs && childNode.attrs.bpType) || "paragraph" };
  }
  if (type === "divider") return { type: "divider" };
  const env = nodeToDocEnvelope(childNode);
  if (type === "heading") return { type: "heading", ...tiptapToBlock(env, null, "heading") };
  if (type === "bulletList" || type === "orderedList") {
    return { type: "list", ...tiptapToBlock(env, null, "list") };
  }
  return { type: "paragraph", ...tiptapToBlock(env, null, "paragraph") };
}

// terminalBlockToNode(block) → { type:"bpTerminal", attrs:{ bpId, bpType, title, footer,
//   live }, content:[child…] }. An EMPTY body is seeded with one paragraph so bpTerminal's
// `…+` content is satisfiable (stripped on the way back via the isEmptyParagraphBlock
// sentinel — the columns/featured-placeholder pattern). title/footer normalize to null
// when null; live normalizes the compose [true,"true","live"] gate to a strict boolean.
function terminalBlockToNode(block, bpId, bpType) {
  const src = (block && (block.children || block.blocks)) || [];
  const kids = (Array.isArray(src) ? src : []).map(terminalChildBlockToNode);
  return {
    type: CANVAS_CONTAINER_NODE_NAMES[bpType] || "bpTerminal",
    attrs: {
      bpId,
      bpType,
      title: block && block.title != null ? block.title : null,
      footer: block && block.footer != null ? block.footer : null,
      live: !!(
        block &&
        (block.live === true || block.live === "true" || block.live === "live")
      ),
    },
    content: kids.length ? kids : [{ type: "paragraph" }],
  };
}

// terminalNodeChildren(node) → the body child BLOCK array. A lone empty-paragraph
// sentinel (an empty source body's seed) collapses back to []. The SAME derivation the
// coarse diff (terminalNodeChanged), the patch, and the insert reconstruction share, so
// an UNEDITED terminal is byte-stable (→ ZERO ops).
function terminalNodeChildren(node) {
  const kids = ((node && node.content) || []).map(terminalChildNodeToBlock);
  if (kids.length === 1 && isEmptyParagraphBlock(kids[0])) return [];
  return kids;
}

// terminalNodeToBlock(node, id) → { id, type:"terminal", children:[…], title?, footer?,
//   live? } — the INSERT path (a genuinely-NEW terminal, no unknown sibling keys). OMITS
// absent chrome: title/footer only when != null, live only when true (byte-parity with
// the reader emitting nothing for absent chrome).
function terminalNodeToBlock(node, id) {
  const a = (node && node.attrs) || {};
  const block = { id, type: "terminal", children: terminalNodeChildren(node) };
  if (a.title != null) block.title = a.title;
  if (a.footer != null) block.footer = a.footer;
  if (a.live === true) block.live = true;
  return block;
}

// terminalNodeToPatch(node) → the COARSE patch (EXPLICIT chrome — the shallow-merge-
// can't-delete contract). Explicit null title/footer + false live so a title-CLEAR /
// live-OFF actually lands; null/false render as absent in compose, so byte-parity holds.
// patch.ex shallow-merges { children, title, footer, live }, overwriting those keys and
// leaving any unknown sibling key (a legacy `blocks`, a custom prop) intact.
function terminalNodeToPatch(node) {
  const a = (node && node.attrs) || {};
  return {
    title: a.title == null ? null : a.title,
    footer: a.footer == null ? null : a.footer,
    live: a.live === true,
    children: terminalNodeChildren(node),
  };
}

// The stable diff key: chrome scalars (normalized) + the RECONSTRUCTED children (→
// blocks, ignoring depth>0 phantom bpId/bpType attrs) so an UNEDITED terminal emits
// ZERO ops (the columns immunity).
function stableTerminalKey(node) {
  const a = (node && node.attrs) || {};
  return {
    title: a.title == null ? null : a.title,
    footer: a.footer == null ? null : a.footer,
    live: a.live === true,
    children: terminalNodeChildren(node),
  };
}

// True when a terminal node's interior OR chrome changed. CRITICAL: an UNEDITED terminal
// must emit ZERO ops. Canonical (key-order-insensitive) compare on the reconstructed key.
function terminalNodeChanged(prevNode, nextNode) {
  return (
    canonicalJSON(stableTerminalKey(prevNode)) !==
    canonicalJSON(stableTerminalKey(nextNode))
  );
}

// NOTE: `columns`, `section` and `terminal` containers do NOT share a single generic
// dispatcher — each has a materially different op strategy (columns = coarse
// {columns:[…]}; section = seq-changed replace-block else fine-grained child+title
// patches; terminal = coarse whole-body+chrome patch). The op-branch / echo / insert
// paths sub-route by bpType directly and call the per-container round-trip fns
// (columnsNode* / sectionNode* / terminalNode*). Keep in lockstep with
// CANVAS_CONTAINER_TYPES + CANVAS_CONTAINER_BP_TYPE_BY_NODE.

// ── reverse diff: prev blocks + edited doc → ordered ops ────────────────────

// Strip our { bpId, bpType } stamp back off a prose node so the node is the
// plain convert.js shape buildPatchBlockOp expects (it reads node.attrs.level
// for headings; the extra keys are harmless but we keep the doc tidy and the
// emitted op byte-identical to the per-block path by leaving level intact).
//
// We DON'T need to remove bpId/bpType for correctness — buildPatchBlockOp only
// reads top.type, top.attrs.level, top.content — but wrapping the node back in
// the {type:"doc",content:[node]} envelope is what it expects.
function nodeToDocEnvelope(node) {
  return { type: "doc", content: [node] };
}

// ── id minting for new/split blocks ─────────────────────────────────────────
//
// The reverse diff MUST give every next-doc node a KNOWN id, because the op
// vocabulary can only express a front-insert / reorder via move-block, and
// move-block keys by a known id. So a new block (a split, a typed paragraph,
// anything with no surviving bpId) is CLIENT-MINTED an id here.
//
// The id must be unique within the call AND collision-free against every prev
// id and every other minted id — patch.ex rejects a duplicate id on both
// append-block and insert-after. We use a per-call monotonic counter prefixed
// "c-" plus a high-entropy nonce; the caller hands us a `taken` set so we can
// retry on the astronomically-unlikely collision.
function mintId(taken) {
  let id;
  do {
    mintCounter += 1;
    // Counter guarantees per-call uniqueness; the nonce guarantees the id can
    // never collide with a server/prev id of the conventional shape.
    id = "c-" + mintCounter.toString(36) + "-" + randomNonce();
  } while (taken.has(id));
  taken.add(id);
  return id;
}

let mintCounter = 0;

// A short high-entropy token. crypto.randomUUID is a global in modern V8 and
// browsers; fall back to Math.random (uniqueness within a call is all we need —
// the per-call counter already guarantees that, the nonce only widens the gap
// against externally-minted ids).
function randomNonce() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID().slice(0, 8);
  }
  return Math.random().toString(36).slice(2, 10);
}

// True when two prose nodes carry different content (an interior edit). We
// compare the node minus our bp* stamp via a stable JSON of the fields
// buildPatchBlockOp actually reads (type, attrs.level, content). Cheap + exact:
// any text/mark/level/list-shape change flips this; a pure reorder does not.
function proseNodeChanged(prevNode, nextNode) {
  return stableProseKey(prevNode) !== stableProseKey(nextNode);
}

// Order-insensitive deep stringify: sorts OBJECT keys recursively (array order
// is preserved — content/marks order is significant). Without this, two
// semantically-identical text nodes that differ only in KEY ORDER would hash
// differently — exactly the runToTiptap `{type,text,marks}` vs ProseMirror
// getJSON `{type,marks,text}` mismatch that otherwise flags EVERY marked block
// as "changed" on every keystroke.
function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJSON).join(",") + "]";
  }
  if (value && typeof value === "object") {
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonicalJSON(value[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(value);
}

// The byte-significant projection of a prose node for change detection: its
// type, heading level (if any), and content — i.e. exactly the inputs to
// buildPatchBlockOp / tiptapToBlock. bpId/bpType are excluded so an identity
// move never looks like an edit. Canonicalized (key-order-insensitive) so a
// node serialized by runToTiptap and the SAME node serialized by the live
// editor's getJSON compare EQUAL despite their differing attr/text key order.
function stableProseKey(node) {
  const level = node.attrs && node.attrs.level;
  return canonicalJSON({
    type: node.type,
    level: level == null ? null : level,
    content: node.content || null,
  });
}

// classifyNode(node) → { node, bpType, isOpaque, isAtom, isContent, isAttrAtom,
//   isField, isReadOnlyAtom }
//
// The PURE per-node classification both runToOps (op-emission) and docToBlocks
// (live-doc → blocks projection) share — the SINGLE place a getJSON node is
// mapped to its canvas KIND + resolved bpType. Factored out so the two callers
// agree byte-for-byte on what a node IS (an own-echo stamp and a source-mode
// baseline must classify a node identically). It does NOT resolve the id — that
// is the caller's job (runToOps keys against prev ids + mints; docToBlocks reads
// the live bpId + mints) — because id resolution is the ONE thing that differs.
function classifyNode(node) {
  const isOpaque = node.type === "bpOpaque";
  const isAtom = isCanvasAtomType(node.type);
  const isContent = isCanvasContentType(node.type);
  // STEP 4: the card WIDGET (bpCard). A callout-shaped content node (inline body +
  // chrome attrs) but slots-native, so it gets its OWN kind flag + diff path.
  const isCard = isCanvasCardNode(node.type);
  // The stage WIDGET (bpStage). A control-atom (five scalar attrs, no interior), so it
  // gets its OWN kind flag + diff path — like bpAction but multi-field + slots-aware.
  const isStage = isCanvasStageNode(node.type);
  const isAttrAtom = isCanvasAttrAtomNode(node.type);
  const isField = isCanvasFieldNode(node.type);
  // editable-action: a canvas control-atom node (bpAction). Its bpType resolves to
  // "action" via the node.attrs.bpType default below.
  const isAction = isCanvasActionNode(node.type);
  const isReadOnlyAtom = isCanvasReadOnlyAtomNode(node.type);
  const isFleet = isCanvasFleetNode(node.type);
  // editable-figure: a canvas figure atom (bpFigure). Its bpType resolves to "figure"
  // off node.attrs.bpType (the isFigure fallback below).
  const isFigure = isCanvasFigureNode(node.type);
  // live-data task-list: a canvas task-list widget (bpTaskList). Its bpType resolves
  // to "task-list" off node.attrs.bpType (the isTaskList fallback below).
  const isTaskList = isCanvasTaskListNode(node.type);
  // S10: a canvas container node (bpColumns). Its bpType resolves to "columns" via
  // CANVAS_CONTAINER_BP_TYPE_BY_NODE below.
  const isContainer = isCanvasContainerNode(node.type);
  // Article-chrome role node — node.type IS the bpType (eyebrow/byline/ingress/
  // pullquote), so the bpType fallback below resolves it via `node.type`.
  const isRole = isCanvasRoleType(node.type);
  // Table container node — node.type is bpTable, bpType resolves to "table" off attrs.
  const isTable = isCanvasTableNode(node.type);
  const bpType =
    (node.attrs && node.attrs.bpType) ||
    CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE[node.type] ||
    CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE[node.type] ||
    CANVAS_CONTAINER_BP_TYPE_BY_NODE[node.type] ||
    (isField
      ? "field-string"
      : isFleet
        ? "tasks"
        : isFigure
          ? "figure"
          : isTaskList
            ? "task-list"
            : isCard
              ? "card"
          : isCard
            ? "card"
            : isStage
              ? "stage"
              : node.type);
  return {
    node,
    bpType,
    isOpaque,
    isAtom,
    isContent,
    isCard,
    isStage,
    isAttrAtom,
    isField,
    isAction,
    isReadOnlyAtom,
    isFleet,
    isFigure,
    isTaskList,
    isContainer,
    isRole,
    isTable,
  };
}

// docToBlocks(doc) → [ block, … ]
//
// Project an EDITED canvas doc (the getJSON shape, after normalizeCanvasDoc) BACK
// to a portable-doc block LIST — the SAME node→block path runToOps uses internally
// (classifyNode + nextNodeToBlock), exposed so a caller can derive the LIVE run
// from the live editor. This is what source-mode needs for its baseline: the diff
// baseline (this._blocks) is ECHO-CONFIRMED and LAGS the live doc by the round-trip
// to the server; the LIVE doc (getJSON) carries the user's just-typed,
// not-yet-confirmed edits. docToBlocks(normalizeCanvasDoc(getJSON())) is exactly the
// run _emitOps diffs the live doc to internally (runToOps maps each node via the
// same classify + nextNodeToBlock), so the markdown the user sees in source mode
// reflects everything on screen, not the stale confirmed run.
//
// A node that already carries a bpId keeps it; a freshly-typed / split node
// (bpId:null) is CLIENT-MINTED a unique id here (so blocksToMarkdown has a stable
// key and the exit realign can donate it back). The `taken` set guards uniqueness
// within the call. PURE, DOM-free — like runToOps it touches no editor.
export function docToBlocks(doc) {
  const nodes = (doc && doc.content) || [];
  const taken = new Set();
  // Seed `taken` with every id ALREADY on a node so a mint can never collide with a
  // surviving id. RECURSIVE (descend bpSection bodies at any depth) — the make-or-break
  // duplicate_id-abort guard: a nested child id is invisible to a top-level-only seed,
  // so a mint could collide with it and abort the whole atomic batch.
  walkNodeIds(nodes, taken);
  return nodes.map((node) => {
    const cls = classifyNode(node);
    const bpId = node.attrs && node.attrs.bpId;
    const id = bpId != null ? bpId : mintId(taken);
    return nextNodeToBlock({ ...cls, id, isNew: bpId == null }, taken);
  });
}

// runToOps(prevBlocks, nextDoc) → [ op, … ] (ordered)
//
// Diff the ORIGINAL block list against the edited doc (the runToTiptap shape
// after edits) and emit an ordered op set in the EXISTING vocabulary that, when
// FOLDED through patch.ex left-to-right, reproduces nextDoc EXACTLY — id order
// and surviving content both.
//
// The pivot that makes this provable: EVERY new block (a split, a typed
// paragraph, anything with no surviving bpId) is CLIENT-MINTED a unique id up
// front, so every next node has a KNOWN id. The op vocabulary has no
// prepend / insert-before — a front-insert or any reorder can ONLY be expressed
// via move-block, which keys by a known id. Minting closes that gap.
//
// Emission order: removes → inserts → moves → patches.
//   1. removes shrink the running list to the surviving prev ids.
//   2. inserts graft every new block in (anchored to the FIRST surviving prev
//      block, or appended when nothing survives). Position here does NOT matter.
//   3. moves permute the running list — now exactly nextSeq's id SET in some
//      order — into nextSeq ORDER. An already-correct subsequence emits nothing.
//   4. interior patches mutate surviving prose content in place (order-free).
export function runToOps(prevBlocks, nextDoc, options = {}) {
  const prev = prevBlocks || [];
  const nextNodes = (nextDoc && nextDoc.content) || [];

  // prev id → index, and the block.
  const prevIndex = new Map();
  const prevById = new Map();
  prev.forEach((block, i) => {
    const id = block && block.id;
    if (id != null) {
      prevIndex.set(id, i);
      prevById.set(id, block);
    }
  });

  // ── 0) BUILD nextSeq: every next node gets a KNOWN id (existing or minted) ──
  //
  // `taken` seeds with every prev id so a minted id can never collide with a
  // surviving block (patch.ex rejects duplicate ids on append/insert-after).
  // RECURSIVE (descend section.blocks at any depth) — the make-or-break
  // duplicate_id-abort guard: a NESTED prev child id is invisible to a top-level-only
  // seed, so a mint (for a new top-level block OR a new nested section child) could
  // collide with it and patch.ex duplicate_id (patch.ex:182/191) would abort the whole
  // atomic batch, silently dropping every co-batched edit. prevIndex/prevById stay
  // TOP-LEVEL (they key the top-level structural diff); only `taken` walks the full
  // tree.
  const taken = new Set();
  walkBlockIds(prev, taken);
  const claimedNewIds = new Set();

  // Classify each node into its canvas KIND + resolved bpType via the SHARED
  // classifyNode (the same path docToBlocks uses), then resolve the id HERE: a
  // surviving prev id keeps its id (existing); anything else (a split / typed /
  // paste node with bpId:null, or a bpId not in prev) is CLIENT-MINTED. This is
  // the one piece runToOps owns over docToBlocks — id resolution is keyed against
  // the PREV run, not just the live bpId.
  const nextSeq = nextNodes.map((node) => {
    const bpId = node.attrs && node.attrs.bpId;
    const existing = bpId != null && prevIndex.has(bpId);
    const preservedNew = options.preserveNewIds === true && bpId != null &&
      !taken.has(bpId) && !claimedNewIds.has(bpId);
    const id = existing || preservedNew ? bpId : mintId(taken);
    if (preservedNew) {
      taken.add(id);
      claimedNewIds.add(id);
    }
    return { ...classifyNode(node), id, isNew: !existing };
  });

  const nextIds = new Set(nextSeq.map((e) => e.id));

  // Doctrine template locks (pdd-t2): the ids of template-locked blocks. A locked
  // block can NEVER be removed or moved by a canvas diff — the server backstops it
  // (patch.ex:192-274 rejects a locked remove/move, halting the whole atomic batch
  // and losing co-batched edits) and the editor vetoes it live (filterTransaction).
  // This is the DIFF-layer guard so a remove/move op for a locked id is never even
  // EMITTED — belt-and-braces for any path that could still produce a doc missing
  // or reordering a locked block (e.g. a markdown source-mode round-trip). Locked-
  // ness is authoritative from the PREV (source) blocks: `locked` is server-seeded
  // and immutable through patch-block, so the prev run is the truth.
  const lockedIds = new Set();
  for (const block of prev) {
    if (block && block.locked === true && block.id != null) lockedIds.add(block.id);
  }

  const ops = [];

  // ── 1) REMOVES — prev id not present in nextSeq (a merge/delete) ───────────
  //
  // A LOCKED id is NEVER removed (pdd-t2): even if it went missing from the live
  // doc (which filterTransaction prevents), emitting remove-block would be rejected
  // by the server and halt the batch — so we skip it and let the block persist.
  for (const block of prev) {
    const id = block && block.id;
    if (id != null && !nextIds.has(id) && !lockedIds.has(id)) {
      ops.push({ op: "remove-block", id });
    }
  }

  // The running fold's id order, tracked as WE apply our own ops so move
  // emission can skip no-ops. After removes it is the surviving prev ids in
  // prev order.
  let running = prev
    .map((b) => b && b.id)
    .filter((id) => id != null && nextIds.has(id));

  // ── 2) INSERTS — each NEW entry grafted in with its MINTED id ──────────────
  //
  // Anchor every insert to the FIRST surviving prev block (guaranteed present
  // through the whole insert pass — inserts never remove it). When nothing
  // survives (prev empty or all-removed) the first insert appends and each
  // subsequent insert anchors after the previously-inserted block. Final
  // position is irrelevant — the moves pass fixes order.
  let firstSurvivor = running.length > 0 ? running[0] : null;
  for (const entry of nextSeq) {
    if (!entry.isNew) continue;
    // Pass the CALL-SHARED `taken` so a NEW section's nested null-id children mint ids
    // that never collide with any tree id (the duplicate_id-abort guard).
    const block = nextNodeToBlock(entry, taken);
    if (firstSurvivor == null) {
      // No anchor yet: append the first new block at the end, then use it as the
      // anchor for the rest so every later insert has a present afterId.
      ops.push({ op: "append-block", block });
      running.push(entry.id);
      firstSurvivor = entry.id;
    } else {
      ops.push({ op: "insert-after", afterId: firstSurvivor, block });
      // insert-after splices directly after firstSurvivor; reflect that in the
      // running order (position irrelevant for correctness — moves fix it).
      const at = running.indexOf(firstSurvivor);
      running.splice(at + 1, 0, entry.id);
    }
  }

  // WHY ONE ENTER AT THE TAIL OF A RUN EMITS ~N MOVE-BLOCKS (spd-bl-enter-at-tail-
  // block-drop). Pass 2 anchors EVERY insert at the FIRST SURVIVOR (there is no
  // prepend / insert-before op), so a paragraph typed at the END of a 13-block run is
  // grafted in at position 1 and this pass then walks it back down with a move for
  // every block it jumped. The batch reads alarming — `insert-after: pp-001` plus a
  // dozen `move-block`s for one keypress — and it is CORRECT: folded left-to-right
  // through patch.ex it reproduces the doc exactly, and every prev block survives.
  //
  // THE DISCRIMINANT, if you are staring at such a batch wondering if it ate a block:
  // look for a `remove-block` on the run's LAST id. Enter never emits one — pass 1
  // only removes a prev id that is ABSENT from the live doc. So a remove-block here
  // means the tail node was never IN the doc the diff read: a node type the mounted
  // schema does not register is dropped by ProseMirror on setContent (a stale
  // committed bundle is how that happens in the wild — .github/workflows/paper-
  // editor.yml gates it). That is real loss, and it is a BUNDLE/SCHEMA fault, not an
  // Enter fault. Both batches are pinned, mounted and folded, in
  // canvas/__enter_tail.test.mjs + api/test/barkpark/portable_doc/
  // patch_enter_at_tail_test.exs.
  // ── 3) MOVES — permute `running` (now exactly nextSeq's id SET) into order ──
  //
  // Walk nextSeq left-to-right. For each entry, the target predecessor is the
  // previous entry's id (or null for the first). Emit a move ONLY when the entry
  // is not ALREADY immediately after that predecessor in the running order — so
  // an already-correct subsequence (e.g. a pure interior edit) emits zero moves.
  // We apply each move to `running` as we go, so subsequent checks see the
  // post-move order and we never emit a redundant move.
  for (let i = 0; i < nextSeq.length; i++) {
    const id = nextSeq[i].id;
    // A LOCKED block holds its position (pdd-t2): never emit a move for it. The
    // filterTransaction veto keeps a locked node at its fixed index, so `running`
    // already has it correctly placed; skipping leaves the following entry's
    // `after` anchor pointing at the (stable) locked id.
    if (lockedIds.has(id)) continue;
    const after = i === 0 ? null : nextSeq[i - 1].id;
    const curIdx = running.indexOf(id);
    const afterIdx = after == null ? -1 : running.indexOf(after);
    // Already correctly placed iff it sits exactly one slot after its target
    // predecessor (or at the head when there is no predecessor).
    if (curIdx === afterIdx + 1) continue;
    ops.push({ op: "move-block", id, after });
    // Mirror patch.ex move-block on `running`: lift the id, splice after `after`
    // (or head when null).
    running.splice(curIdx, 1);
    const dest = after == null ? 0 : running.indexOf(after) + 1;
    running.splice(dest, 0, id);
  }

  // ── 4) PATCHES — surviving prose / content / attr-atom nodes whose interior
  //      changed ───────────────────────────────────────────────────────────────
  //
  // PROSE → byte-identical to the per-block editor's patch-block (buildPatchBlockOp).
  // CANVAS CONTENT (S3.2: callout) → a patch-block carrying the changed body/chrome
  //   fields (calloutNodeToPatch), keyed by id. An UNCHANGED callout emits NO op
  //   (canonical key-order-insensitive compare, same as prose).
  // CANVAS ATTR-ATOM (S3.3: code) → a patch-block carrying the changed value/lang
  //   (codeNodeToPatch), keyed by id. An UNCHANGED code emits NO op (canonical
  //   compare on value+lang). UNLIKE the divider atom (which can never change), an
  //   attr-atom's value/lang ARE mutable, so it IS diffed here.
  // A surviving opaque node is a no-op (opaque blocks just round-trip).
  // A surviving canvas ATOM (S3: divider) is likewise a no-op: a content-free leaf
  // has no interior to change, so it NEVER reports an interior patch.
  // A surviving canvas READ-ONLY ATOM (S3.6: sheet / embed) is ALSO a no-op: it is a
  // REFERENCE carrying the whole block verbatim — nothing is edited in the editor, so
  // it NEVER emits a value/content patch (the read-only-never-patches guarantee).
  for (const entry of nextSeq) {
    if (
      entry.isNew ||
      entry.isOpaque ||
      entry.isAtom ||
      entry.isReadOnlyAtom
    )
      continue;
    const prevBlock = prevById.get(entry.id);
    const prevNode = runToTiptap([prevBlock]).content[0];

    if (entry.isTable) {
      // Canvas table (nested node tree): diff the grid; emit one COARSE whole-table
      // patch-block (rows + head, head explicit-[] on header removal) when anything
      // changed. prevNode is reconstructed via tableBlockToNode so the compare is
      // apples-to-apples. An UNCHANGED table emits NO op.
      if (tableNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: tableNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isContainer) {
      // Canvas container node — sub-route by bpType (section | terminal | columns).
      if (entry.bpType === "section") {
        // section: op strategy hinges on whether the child-id SEQUENCE changed:
        //   * DIFFERS (child add/remove/reorder/reparent, or a canvas-created null-id
        //     child) → ONE coarse replace-block carrying the fully-rebuilt section
        //     subtree; sectionNodeToBlock mints ids for null children off the
        //     CALL-SHARED `taken`.
        //   * IDENTICAL → recurse per-child fine-grained patch-block{id:childId,patch}
        //     for each child whose INTERIOR changed; an unchanged section emits NOTHING.
        // NEVER a move-block/append-block on a nested id (top-level only, patch.ex:42).
        if (sectionChildSeqChanged(prevNode, entry.node)) {
          ops.push({
            op: "replace-block",
            id: entry.id,
            block: sectionNodeToBlock(entry.node, entry.id, taken),
          });
        } else {
          // Fine-grained path: the section's own LAYOUT and TITLE are each diffed
          // separately from its children (a layout- or title-only edit leaves the
          // child-id seq identical, so without this it would emit nothing and revert).
          // Emit the LAYOUT patch FIRST (step 2), THEN the title patch, THEN each
          // changed child's interior patch. patch.ex shallow-merges {layout} onto the
          // section; {layout:null} → compose stack path (reader parity, mirrors title).
          if (sectionLayoutChanged(prevNode, entry.node)) {
            ops.push({
              op: "patch-block",
              id: entry.id,
              patch: sectionLayoutPatch(entry.node),
            });
          }
          if (sectionTitleChanged(prevNode, entry.node)) {
            ops.push({
              op: "patch-block",
              id: entry.id,
              patch: sectionTitlePatch(entry.node),
            });
          }
          for (const childOp of sectionChildPatchOps(prevNode, entry.node)) {
            ops.push(childOp);
          }
        }
      } else if (entry.bpType === "terminal") {
        // terminal: the V1 COARSE whole-body+chrome round-trip. ANY interior change
        // (a body keystroke, a child add/delete/reorder, a title/footer/live edit)
        // re-emits ONE patch-block replacing children + chrome scalars. An UNEDITED
        // terminal emits NO op. patch.ex shallow-merges, leaving unknown sibling keys
        // (a legacy `blocks` key) intact.
        if (terminalNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: terminalNodeToPatch(entry.node),
          });
        }
      } else {
        // columns: the V1 COARSE round-trip. ANY interior change (a keystroke in a
        // column, a child add/delete, a column-child reorder) re-emits ONE patch-block
        // REPLACING the whole `columns` array. An UNEDITED columns emits NO op
        // (canonical compare on the reconstructed columns). patch.ex merges
        // { columns:[…] } into the block content, leaving unknown sibling keys intact.
        if (columnsNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: { columns: columnsNodeToColumns(entry.node) },
          });
        }
      }
      continue;
    }

    if (entry.isTaskList) {
      // Canvas task-list widget (live-data): the QUERY is the WHOLE editable datum
      // (+ optional title/config); the rows are server-painted, never on the node.
      // Emit ONE patch-block{query,…} when the editable data changed; the shallow
      // patch-block merge replaces the stored query and leaves unknown sibling keys
      // intact. An UNEDITED task-list emits NO op (canonical compare on
      // query+title+config). prevNode is passed so title/config only ride the patch
      // when they actually changed.
      if (taskListNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: taskListNodeToPatch(entry.node, prevNode),
        });
      }
      continue;
    }

    if (entry.isFigure) {
      // Canvas figure atom (editable-figure): the caption is the WHOLE editable
      // interior (the child is immutable in v1). Emit ONE patch-block{caption} when
      // the caption changed; the shallow patch-block merge leaves `child` untouched.
      // An UNEDITED figure emits NO op (canonical compare on caption + child).
      if (figureNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: figureNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isFleet) {
      // Canvas FLEET atom (pd-ee-fleet-editors): the authored content — cards/notes/
      // pipeline items and the task-* query/id config — rides VERBATIM on `bpBlock`
      // and is edited by the node-view's structured EDIT ISLAND (embed-node.js). This
      // is the read-only-atom shape made EDITABLE (like task-list vs the snapshot
      // fleet): the whole block still round-trips on bpBlock, but a structured edit
      // mutates it via setNodeMarkup → this diff. Emit ONE patch-block carrying the
      // block's EDITABLE PAYLOAD (every key EXCEPT the immutable id/type) when the
      // carried block changed; patch.ex's SHALLOW Map.merge REPLACES the edited
      // arrays/query and leaves unknown sibling keys intact, then the server repaints
      // the fleet HTML (shared/paper.ex push_block_renders / @fleet_render_types — the
      // ONE-producer contract / D8: the canvas never hand-renders fleet markup). An
      // UNEDITED fleet block emits ZERO ops (canonical compare on bpBlock with id
      // ignored — the D3 byte-stability guarantee).
      if (fleetNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: fleetNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isContent) {
      // Canvas content node (callout OR note): diff body + chrome; emit one patch-block
      // carrying ONLY the mutable fields when anything changed. Sub-route by node type.
      if (isNoteType(entry.node.type)) {
        if (noteNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: noteNodeToPatch(entry.node),
          });
        }
        continue;
      }
      if (calloutNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: calloutNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isCard) {
      // STEP 4 card WIDGET: diff body + chrome (tone/title/media/action); emit ONE
      // patch-block carrying the rebuilt slots map + explicit tone when anything
      // changed. An UNCHANGED card emits NO op (canonical compare). The whole-slots
      // replace makes a cleared title/media/action removal LAND; explicit tone makes
      // a tone-clear land (patch-block can't delete a key otherwise).
      if (cardNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: cardNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isStage) {
      // The stage WIDGET: diff the five scalars; emit ONE patch-block carrying the
      // present-or-null field set when anything changed. An UNCHANGED stage emits NO op
      // (canonical compare). The explicit-null fields make a cleared text/source removal
      // LAND (patch-block can't delete a key otherwise — the card `tone:null` precedent).
      if (stageNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: stageNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isAttrAtom) {
      // Canvas attr-atom node (S3.3: code; S3.4: diagram): diff the body + optional
      // field; emit one patch-block carrying the body (always) + the optional field
      // (the string, "" when cleared) when changed. Dispatch by NODE type:
      //   bpDiagram → source/caption (diagramNodeChanged / diagramNodeToPatch);
      //   bpCode    → value/lang     (codeNodeChanged    / codeNodeToPatch).
      if (entry.node.type === "bpDiagram") {
        if (diagramNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: diagramNodeToPatch(entry.node),
          });
        }
        continue;
      }
      if (codeNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: codeNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isField) {
      // Canvas control-atom node (S3.5: the 7 native field-* types): diff the VALUE
      // (the only mutable datum); emit one patch-block carrying { value } — EXACTLY
      // the BarkparkFieldBlockBridge shape — when it changed. The value is normalized
      // to its per-type stored form (boolean for field-boolean; string otherwise) so
      // a canvas field edit persists IDENTICALLY to a per-block field edit. An
      // UNCHANGED field emits NO op (canonical compare on the normalized value).
      if (fieldNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: fieldNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isAction) {
      // Canvas control-atom node (editable-action): diff href/label/priority; emit ONE
      // COARSE whole-attrs patch-block (href/label/priority threaded when set) when it
      // changed. prevNode is reconstructed via runToTiptap([prevBlock]) so the compare
      // is apples-to-apples. An UNCHANGED action (incl. a nil→secondary re-select)
      // emits NO op (canonical compare collapses nil≡secondary).
      if (actionNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: actionNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isRole) {
      // Article-chrome role node (eyebrow/byline/ingress/pullquote): diff the single
      // mutable body (text/items/content); emit one patch-block carrying only that
      // field when it changed. An UNCHANGED role emits NO op (canonical compare on the
      // DERIVED body — for a byline the split items, so join/split is idempotent).
      if (roleNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: roleNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (proseNodeChanged(prevNode, entry.node)) {
      const bpType = entry.bpType || (prevBlock && prevBlock.type);
      ops.push(buildPatchBlockOp(nodeToDocEnvelope(entry.node), entry.id, bpType));
    }
  }

  return ops;
}

// ── echo reconciliation: server-confirmed blocks ⇄ live doc (S4a) ────────────
//
// reconcileServerEcho(serverBlocks, liveContent) → { ownEcho, idWrites }
//
// THE PROBLEM this solves. When the canvas emits an `insert-after` for a NEW
// block (Enter-split / paste / typed paragraph), the live ProseMirror node has
// bpId:null (a freshly-typed block has no id yet). The server mints an id (say
// "srv-9") and echoes the confirmed blocks carrying it. A naive own-echo gate —
// runToOps(serverBlocks, liveDoc).length === 0 — MISDETECTS this as an external
// edit: the live new-block node still has bpId:null while the confirmed block
// has "srv-9", so runToOps mints a FRESH id for the null node and reports
// remove-block("srv-9") + insert-after(fresh) — a non-empty diff. Worse, because
// the live node never learns "srv-9", every later batch re-mints it: the op size
// never shrinks and the server block-id churns.
//
// THE FIX. Treat a live bpId:null at index i as a WILDCARD that matches
// serverBlocks[i].id. We build serverDoc = runToTiptap(serverBlocks) (the
// canonical node shape per kind) and compare it to the live doc node-by-node:
//
//   ownEcho IFF liveContent.length === serverBlocks.length AND for every i:
//     • the live node and the server node are the SAME node KIND/type, AND
//     • the live node's bpId === server id  OR  the live node's bpId == null
//       (a just-minted block at that position), AND
//     • the block's mutable content matches per kind — the SAME stable/canonical
//       comparison runToOps uses (prose/heading/list/callout/code/diagram/field/
//       read-only-atom/opaque), so an own echo carrying an UNRELATED content
//       change still falls through to the external path.
//
//   idWrites — for every live node whose bpId == null AND that passed the match,
//     { index, id: serverBlocks[index].id, bpType: serverBlocks[index].type }.
//     applyServerBlocks stamps these onto the live nodes (an ATTR-ONLY change PM
//     maps the selection through → the caret does NOT move) so the echo no-ops
//     AND the NEXT diff is truly incremental.
//
// Precise, not over-matching: a length mismatch, a kind/type mismatch, a real
// content change, or a bpId that is neither the server id nor null → ownEcho
// false (external path). Pure, DOM-free, testable without an editor.
export function reconcileServerEcho(serverBlocks, liveContent) {
  const server = serverBlocks || [];
  const live = liveContent || [];

  // Length mismatch → structurally different → external.
  if (live.length !== server.length) return { ownEcho: false, idWrites: [] };

  // Canonical server node shapes (one top-level node per block, per kind).
  const serverNodes = runToTiptap(server).content;

  const idWrites = [];
  for (let i = 0; i < live.length; i++) {
    const liveNode = live[i];
    const serverNode = serverNodes[i];
    const serverBlock = server[i];
    const serverId = serverBlock && serverBlock.id;
    const liveId = liveNode && liveNode.attrs && liveNode.attrs.bpId;

    // The id wildcard: the live id must EQUAL the server id, or be null (a
    // just-minted block at this position whose id we will stamp).
    const idOk = liveId == null || liveId === serverId;
    if (!idOk) return { ownEcho: false, idWrites: [] };

    // Same node KIND/type (and same mutable content per kind). bpId is excluded
    // from every comparison below (the stable-key fns ignore it), so the null
    // wildcard never trips the content check.
    if (!nodeContentEqual(serverNode, liveNode)) {
      return { ownEcho: false, idWrites: [] };
    }

    // A matched, just-minted live node → record the id (and bpType) to stamp.
    if (liveId == null) {
      idWrites.push({
        index: i,
        id: serverId,
        bpType: liveNode && liveNode.attrs && liveNode.attrs.bpType == null
          ? serverBlock && serverBlock.type
          : undefined,
      });
    }
  }

  return { ownEcho: true, idWrites };
}

// True when two top-level canvas nodes are the SAME kind AND carry the SAME
// MUTABLE content — bpId/bpType EXCLUDED. Dispatches by node kind exactly as
// runToOps's patch pass does, reusing the SAME stable-key change-detection so an
// own echo is recognized despite live-editor vs projector key-order differences,
// and an UNRELATED content change is NOT.
function nodeContentEqual(serverNode, liveNode) {
  if (!serverNode || !liveNode) return false;
  // Kind/type must match first (a paragraph echo onto a heading is external).
  if (serverNode.type !== liveNode.type) return false;
  const type = serverNode.type;

  // Table (nested node tree): the header cells + body rows.
  if (isCanvasTableNode(type)) {
    return !tableNodeChanged(serverNode, liveNode);
  }
  // Content node — callout (tone/title/collapsible/collapsed/body) OR note
  // (label/lead/body, the notes-grid split). Sub-route by node type.
  if (isCanvasContentType(type)) {
    if (isNoteType(type)) return !noteNodeChanged(serverNode, liveNode);
    return !calloutNodeChanged(serverNode, liveNode);
  }
  // Card (STEP 4 widget, bpCard): tone/title/media/action/body.
  if (isCanvasCardNode(type)) {
    return !cardNodeChanged(serverNode, liveNode);
  }
  // Stage (widget, bpStage): the five scalars, canonically compared.
  if (isCanvasStageNode(type)) {
    return !stageNodeChanged(serverNode, liveNode);
  }
  // Code / diagram (attr-atom): value+lang / source+caption.
  if (isCanvasAttrAtomNode(type)) {
    if (type === "bpDiagram") return !diagramNodeChanged(serverNode, liveNode);
    return !codeNodeChanged(serverNode, liveNode);
  }
  // Field (control-atom): the normalized value.
  if (isCanvasFieldNode(type)) {
    return !fieldNodeChanged(serverNode, liveNode);
  }
  // Action (control-atom): href/label/priority (priority collapsed nil≡secondary).
  if (isCanvasActionNode(type)) {
    return !actionNodeChanged(serverNode, liveNode);
  }
  // Divider (content-free atom leaf): same type with no interior → equal.
  if (isCanvasAtomType(type)) {
    return true;
  }
  // Read-only atom (sheet / embed): the whole carried block, id excluded.
  if (isCanvasReadOnlyAtomNode(type)) {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Fleet (pdd-t8: bpFleet — tasks / cards / pipeline / form / …): the whole carried
  // block, id excluded — same verbatim-carry equality as the read-only atom.
  if (isCanvasFleetNode(type)) {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Figure (editable-figure: bpFigure): caption + child (child immutable in v1). The
  // own-echo of a caption edit — and the id-wildcard for a just-minted figure — is
  // recognized by the SAME stable-key compare runToOps uses.
  if (isCanvasFigureNode(type)) {
    return !figureNodeChanged(serverNode, liveNode);
  }
  // Task-list (live-data: bpTaskList): query + title + config (rows server-painted,
  // never on the node). The own-echo of a query edit — and the id-wildcard for a
  // just-minted task-list — is recognized by the SAME stable-key compare runToOps uses.
  if (isCanvasTaskListNode(type)) {
    return !taskListNodeChanged(serverNode, liveNode);
  }
  // Opaque carry-through: the whole carried block, id excluded.
  if (type === "bpOpaque") {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Container node — sub-route by bpType (node.type → bpType via the reverse map):
  //   * columns (bpColumns): the reconstructed columns array (child attrs excluded).
  //   * terminal (bpTerminal): the reconstructed body + chrome (child attrs excluded).
  //   * section (bpSection): V1 does NOT recurse reconcile (product decision 1 defers
  //     recursive idWrites) — compare the WHOLE subtree canonically (title on attrs +
  //     the nested children incl. bpIds). A section holding a canvas-CREATED child (a
  //     live bpId:null vs a server minted id) never own-echo-matches, so each batch
  //     re-emits replace-block{wholeSection} — the accepted V1 churn; a section with
  //     all-stable children whose echoed interior edit matched DOES own-echo. bpId of
  //     the section itself is excluded (stableSectionKey ignores it).
  if (isCanvasContainerNode(type)) {
    const bp = CANVAS_CONTAINER_BP_TYPE_BY_NODE[type];
    if (bp === "section") {
      return stableSectionKey(serverNode) === stableSectionKey(liveNode);
    }
    if (bp === "terminal") {
      return !terminalNodeChanged(serverNode, liveNode);
    }
    return !columnsNodeChanged(serverNode, liveNode);
  }
  // Article-chrome role (eyebrow/byline/ingress/pullquote): the derived body.
  if (isCanvasRoleType(type)) {
    return !roleNodeChanged(serverNode, liveNode);
  }
  // Prose (paragraph / heading / list nodes): type + level + content.
  return !proseNodeChanged(serverNode, liveNode);
}

// The byte-significant projection of a section node for echo-equality: its title +
// the nested child content (each child's own bpId/content). The section's OWN bpId is
// excluded (an id-stamp echo must still match). Canonical so key order never trips it.
function stableSectionKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    title: a.title == null ? null : a.title,
    // STEP-2: layout + cells join the echo key so a layout-only own-echo is
    // recognized (no phantom replace-block). A layout-bearing section the server
    // just confirmed must still match the live node.
    layout: a.layout == null ? null : a.layout,
    cells: a.cells == null ? null : a.cells,
    // FRAMED-FINALE (charter D34): variant joins the echo key so a variant-bearing
    // section the server just confirmed still matches the live node (and a DROPPED
    // variant is never mistaken for an own-echo).
    variant: a.variant == null ? null : a.variant,
    content: node.content || null,
  });
}

// Compare the WHOLE block carried on a read-only-atom / opaque node's bpBlock
// attr, with `id` excluded (a just-minted live node carries no id yet). Canonical
// so key order never trips it.
function carriedBlockEqual(serverNode, liveNode) {
  const sb = serverNode && serverNode.attrs && serverNode.attrs.bpBlock;
  const lb = liveNode && liveNode.attrs && liveNode.attrs.bpBlock;
  return canonicalJSON(stripId(sb)) === canonicalJSON(stripId(lb));
}

// A shallow clone of a block with `id` removed, for id-insensitive comparison.
function stripId(block) {
  if (!block || typeof block !== "object") return block;
  const { id: _id, ...rest } = block;
  return rest;
}

// Reconstruct a portable-doc block from a NEW nextSeq entry, carrying its
// CLIENT-MINTED id. PROSE → the convert.js patch fields plus { id, type };
// CANVAS ATOM (S3: divider) → a bare { id, type } leaf block (no body); the id
// is minted on insert and the leaf carries no other fields. OPAQUE → its carried
// bpBlock verbatim, with the minted id stamped on (so move-block / later folds
// can key it). Every inserted block carries an id — that is what makes a
// front-insert / reorder expressible via move-block.
function nextNodeToBlock(entry, taken) {
  const node = entry.node;
  if (entry.isContainer) {
    // Canvas container insert — sub-route by bpType:
    //   * section → rebuild the WHOLE section subtree (title + nested children) with
    //     the minted id; nested null-id children mint ids off the CALL-SHARED `taken`
    //     (the duplicate_id-abort guard) — a fresh Set only when none is threaded.
    //   * terminal → reconstruct the full terminal block (body children + chrome) with
    //     the minted id; a NEW terminal carries no unknown sibling keys, lossless.
    //   * columns → reconstruct the full columns block (its column child-block trees)
    //     with the minted id; a NEW columns carries no unknown sibling keys, lossless.
    if (entry.bpType === "section") {
      return sectionNodeToBlock(node, entry.id, taken || new Set());
    }
    if (entry.bpType === "terminal") {
      return terminalNodeToBlock(node, entry.id);
    }
    return columnsNodeToBlock(node, entry.id);
  }
  if (entry.isAtom) {
    // Canvas atom insert (divider): a content-free leaf, fully described by its
    // type + the minted id. No body fields to reconstruct.
    return { id: entry.id, type: entry.bpType || node.type };
  }
  if (entry.isTable) {
    // Canvas table insert: reconstruct the full table block (rows + optional head)
    // from the nested node tree with the minted id, via the dedicated mapper.
    return tableNodeToBlock(node, entry.id);
  }
  if (entry.isContent) {
    // Canvas content insert (callout OR note): reconstruct the full block from the
    // node (body + chrome) with the minted id, via the dedicated mapper. Sub-route
    // by node type — a note reconstructs its flat { label?, lead?, text } wire form.
    if (isNoteType(node.type)) return noteNodeToBlock(node, entry.id);
    return calloutNodeToBlock(node, entry.id);
  }
  if (entry.isCard) {
    // STEP 4 card WIDGET insert: reconstruct the full slots-native card block (body
    // slot + title/tone/media/action chrome) with the minted id, via the mapper.
    return cardNodeToBlock(node, entry.id);
  }
  if (entry.isStage) {
    // The stage WIDGET insert: reconstruct the WIRE-canonical scalar stage block
    // (kind/title/detail + files/source, present-only) with the minted id, via the mapper.
    return stageNodeToBlock(node, entry.id);
  }
  if (entry.isAttrAtom) {
    // Canvas attr-atom insert (S3.3: code; S3.4: diagram): reconstruct the block (body
    // + optional field) with the minted id. The optional field is OMITTED on insert
    // when absent/empty — the insert path mirrors the persist default (a lang-less
    // code / caption-less diagram has no key). Dispatch by NODE type.
    if (node.type === "bpDiagram") return diagramNodeToBlock(node, entry.id);
    return codeNodeToBlock(node, entry.id);
  }
  if (entry.isField) {
    // Canvas control-atom insert (S3.5: a native field-* block): reconstruct the
    // full field block (value + carried config) with the minted id. block.type comes
    // off the bpType attr; config keys (label/options/rows/fieldName) ride only when
    // present, mirroring the per-type persist default. The value is normalized to its
    // per-type stored form.
    return fieldNodeToBlock(node, entry.id);
  }
  if (entry.isAction) {
    // Canvas control-atom insert (editable-action): reconstruct the full action block
    // (href/label/priority, each only when present) with the minted id, via the
    // dedicated mapper. block.type is the fixed "action".
    return actionNodeToBlock(node, entry.id);
  }
  if (entry.isReadOnlyAtom) {
    // Read-only atom insert (S3.6: sheet / embed): the carried WHOLE block, deep-cloned
    // VERBATIM, with the minted id stamped on — EXACTLY the bpOpaque insert
    // reconstruction (the read-only atom carries the full block, not just a value).
    return readOnlyAtomNodeToBlock(node, entry.id);
  }
  if (entry.isFleet) {
    // Fleet insert (pdd-t8: tasks / cards / pipeline / form / …): the carried WHOLE
    // block, deep-cloned VERBATIM, with the minted id stamped on — identical to the
    // sheet/embed read-only-atom reconstruction (the whole block, not just a value).
    return fleetNodeToBlock(node, entry.id);
  }
  if (entry.isTaskList) {
    // Task-list insert/move (live-data): reconstruct the task-list block (its query
    // + optional title/config) with the minted id. title/config are OMITTED when
    // absent (mirrors the persist default); NO snapshot (a live task-list has none —
    // the rows are server-resolved at read).
    return taskListNodeToBlock(node, entry.id);
  }
  if (entry.isFigure) {
    // Figure insert/move (editable-figure): reconstruct the figure block (its
    // verbatim child + optional caption) with the minted id. The caption is OMITTED
    // when absent/empty (mirrors the persist default: a caption-less figure has no
    // caption key); the child rides VERBATIM.
    return figureNodeToBlock(node, entry.id);
  }
  if (entry.isRole) {
    // Article-chrome role insert (eyebrow/byline/ingress/pullquote): reconstruct the
    // full role block (its text/items/content body) with the minted id, via the
    // dedicated mapper. block.type comes off the node.type (=== bpType).
    return roleNodeToBlock(node, entry.id);
  }
  if (entry.isOpaque) {
    // Opaque insert: the carried block JSON, deep-cloned, with the minted id.
    const block = deepClone((node.attrs && node.attrs.bpBlock) || {});
    block.id = entry.id;
    return block;
  }
  const bpType = entry.bpType || node.type;
  // buildPatchBlockOp().patch is exactly the mutable-fields map — the body of a
  // new block of this type. Stamp the minted id + type.
  const op = buildPatchBlockOp(nodeToDocEnvelope(node), entry.id, bpType);
  const block = { id: entry.id, type: bpType, ...op.patch };
  // Doctrine template attrs (pdd-t2): carry locked/role from the prose node so a
  // reconstructed locked title (e.g. the source-mode baseline via docToBlocks)
  // stays byte-identical. D3: only when present.
  return carryTemplateAttrs(block, node.attrs);
}

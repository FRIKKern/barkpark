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
export function isNoteType(t) {
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
// `blockquote` is the plain quote (inline content + an optional `cite` the canvas
// carries but never patches) — a role in shape, not in chrome; see role-nodes.js.
const CANVAS_ROLE_TYPES = new Set(["eyebrow", "byline", "ingress", "pullquote", "blockquote"]);
export const ROLE_BODY_MODEL = {
  eyebrow: "text",
  byline: "items",
  ingress: "inline",
  pullquote: "inline",
  blockquote: "inline",
};

// True when a portable-doc BLOCK type (and, since node.type === bpType, a NODE type)
// is an article-chrome role block.
export function isCanvasRoleType(t) {
  return CANVAS_ROLE_TYPES.has(t);
}

// Prose/role kinds a block can be turned into inside the canvas (block menu, chords, Backspace
// lifts, `> ` shorthand). A same-id block whose kind changed is REPLACED, since patch-block
// keeps `type` immutable.
export const CONVERTIBLE_NODE_KIND = { paragraph: "paragraph", heading: "heading", bulletList: "list", orderedList: "list", taskList: "list" };
export const CONVERTIBLE_KINDS = new Set(["paragraph", "heading", "list", "pullquote", "blockquote", "eyebrow", "byline", "ingress"]);
const LIST_KIND_ALIASES = new Set(["list", "bulletList", "bullet_list", "bullet-list", "bulletedList", "bulleted_list", "bulleted-list", "orderedList", "ordered-list", "ordered_list", "numbered_list", "numberedList"]);
export function blockKind(block) {
  const t = block && block.type;
  return LIST_KIND_ALIASES.has(t) ? "list" : t;
}

// True when one id may carry `prev` over to `next`: the same kind, or two kinds
// runToOps turns into each other with a replace-block. Any other kind change is a
// different block (a remove and an insert), since patch-block cannot change `type`.
export function idCarriesKind(prev, next) {
  const a = blockKind(prev);
  const b = blockKind(next);
  return a === b || (CONVERTIBLE_KINDS.has(a) && CONVERTIBLE_KINDS.has(b));
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
export function isCanvasTableType(t) {
  return CANVAS_TABLE_TYPES.has(t);
}

// Match the writer's saveable table boundary. Legacy header aliases are normalized at
// the server write boundary; numeric/null/unknown cell carriers and malformed grids
// are not publishable. If any reaches the canvas directly, keep the entire block opaque
// rather than offering an edit that cannot save or risking deletion on first change.
// The stricter contextual table admission keeps its existing independent guard.
function tableCellCarrierSupported(cell) {
  return Array.isArray(cell) || typeof cell === "string" ||
    (cell && typeof cell === "object" && !Array.isArray(cell) &&
      Array.isArray(cell.content));
}

export function tableBlockEditable(block) {
  if (["content", "header", "headers", "columns"].some((key) =>
    Object.hasOwn(block || {}, key))) return false;
  const rows = block?.rows;
  if (!Array.isArray(rows) || !rows.length || !Array.isArray(rows[0]) ||
      !rows[0].length) return false;
  const width = rows[0].length;
  if (!rows.every((row) => Array.isArray(row) && row.length === width &&
      row.every(tableCellCarrierSupported))) return false;
  if (!Object.hasOwn(block, "head") || block.head == null ||
      (Array.isArray(block.head) && block.head.length === 0)) return true;
  return Array.isArray(block.head) && block.head.length === width &&
    block.head.every(tableCellCarrierSupported);
}

// True when a TipTap NODE type is the canvas table container. runToOps/classifyNode
// read node.type off a getJSON node (the NODE name, not the bpType).
export function isCanvasTableNode(nodeType) {
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
export const CANVAS_CARD_NODE_NAME = "bpCard";

// True when a portable-doc BLOCK type is the card widget (runToTiptap dispatch).
export function isCanvasCardType(t) {
  return CANVAS_CARD_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas card node. runToOps/classifyNode read
// node.type off a getJSON node (the NODE name `bpCard`, not the bpType "card").
export function isCanvasCardNode(nodeType) {
  return nodeType === CANVAS_CARD_NODE_NAME;
}

// The `stage` WIDGET — the editable per-node twin of ONE legacy `pipeline` node. UNLIKE
// the card (a slots-native CONTENT node with an inline body), a stage is a CONTROL-ATOM:
// five PLAIN scalars (kind/title/detail text + files/source chrome) ride node.attrs,
// edited by native controls (stage-node.js) — no contentDOM. node.type is the NODE name
// `bpStage`; the bpType stays "stage". KEEP LOCKSTEP with paper_canvas.ex
// @canvas_widget_types and stage-node.js.
const CANVAS_STAGE_TYPES = new Set(["stage"]);
export const CANVAS_STAGE_NODE_NAME = "bpStage";

// True when a portable-doc BLOCK type is the stage widget (runToTiptap dispatch).
export function isCanvasStageType(t) {
  return CANVAS_STAGE_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas stage node. runToOps/classifyNode read
// node.type off a getJSON node (the NODE name `bpStage`, not the bpType "stage").
export function isCanvasStageNode(nodeType) {
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
// scaffy-backlog-blocks-editable-studio adds `diff` and `filetree` to this SAME
// set. Both are VERBATIM-TEXT blocks whose body rides one attr plus optional scalar
// metadata (diff → diff/file/lang; filetree → text/legend), edited by a non-PM
// textarea island exactly like code/diagram. They differ from code/diagram in ONE
// respect: their PREVIEW is the reader's own server-pushed HTML (bp:block-html),
// because no client runtime can produce diff/filetree markup and the parity gate
// (§3) forbids hand-mirroring it. See technical-node.js.
const CANVAS_ATTR_ATOM_TYPES = new Set([
  "code",
  "diagram",
  "diff",
  "filetree",
]);

// The per-type SHAPE of a TECHNICAL attr-atom: the verbatim-body attr name plus the
// OPTIONAL scalar metadata keys. Drives technicalBlockToNode / technicalNodeToBlock /
// technicalNodeToPatch, so the projection, the reconstruction and the patch can never
// disagree about which keys a type owns.
//
// KEEP LOCKSTEP with technical-node.js TECHNICAL_ATOM_SPECS and
// TechnicalBlockEditor.build_patch/2 (~w(diff file lang) / ~w(text legend)).
export const TECHNICAL_ATOM_SHAPES = {
  diff: { body: "diff", meta: ["file", "lang"] },
  filetree: { body: "text", meta: ["legend"] },
};

// The TipTap NODE name for an attr-atom block differs from its bpType. For code it is
// `bpCode`, NOT `code` — `code` is the StarterKit inline code MARK (a node + mark
// can't share a name). For diagram it is `bpDiagram` (the canvas naming convention;
// there is no StarterKit `diagram` node to collide with, but the canvas keeps the
// bp-prefix). runToTiptap maps a block.type → its node.type; runToOps maps it back
// via bpType. Keep aligned with code-node.js:BP_CODE_NODE_NAME and
// diagram-node.js:BP_DIAGRAM_NODE_NAME.
export const CANVAS_ATTR_ATOM_NODE_NAMES = {
  code: "bpCode",
  diagram: "bpDiagram",
  diff: "bpDiff",
  filetree: "bpFiletree",
};
// Reverse: node.type "bpCode" → bpType "code", "bpDiagram" → "diagram". Used by
// runToOps to detect an attr-atom by its NODE type (the type carried on a getJSON
// node).
export const CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE = {
  bpCode: "code",
  bpDiagram: "diagram",
  bpDiff: "diff",
  bpFiletree: "filetree",
};

// S3.5: the 8 NATIVE-CONTROL field-* block kinds the canvas handles as CONTROL-ATOM
// nodes — atom nodes (no PM-managed body, like the divider/code) whose VALUE rides
// in an attr and is edited by a NATIVE HTML control (input / textarea / checkbox /
// select / datetime-local / color / number; see field-node.js). UNLIKE the code/diagram
// attr-atoms (one bpType per TipTap node, body text in a free textarea), the field
// control-atom serves 8 bpTypes through ONE node (`bpField`), the edit surface is a
// TYPED control, and the value is COERCED BY FIELD TYPE exactly like the shipped
// BarkparkFieldBlockBridge (field-boolean → a BOOLEAN via control.checked;
// field-number → a NUMBER or null; every other native type → a STRING via
// control.value).
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
// STILL OUT of the editable field contract: composite / object / arrayOf / codelist /
// localizedText. They retain their contextual server editors and split newly-created
// runs. The bounded static-render compatibility path below recognizes four of them
// if they occur in an already-mounted/nested canvas. (`section` is NO LONGER here —
// it rides its own bpSection CONTAINER node; see CANVAS_CONTAINER_TYPES below.)
const CANVAS_NATIVE_FIELD_TYPES = new Set([
  "field-string",
  "field-slug",
  "field-text",
  "field-boolean",
  "field-select",
  "field-datetime",
  "field-color",
  "field-number",
]);
export const CANVAS_PICKER_FIELD_TYPES = new Set(["field-image", "field-reference"]);
const CANVAS_FIELD_TYPES = new Set([
  ...CANVAS_NATIVE_FIELD_TYPES,
  ...CANVAS_PICKER_FIELD_TYPES,
]);

// The TipTap NODE name for ALL 7 native field types is the SAME single node
// `bpField` (UNLIKE code/diagram, which are one-node-per-type). The specific
// field-* kind rides the node's bpType attr; the node-view dispatches the control
// by it. Keep aligned with field-node.js:BP_FIELD_NODE_NAME.
export const CANVAS_FIELD_NODE_NAME = "bpField";

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
// EXPLICITLY OUT of new runs (still contextual boundaries): composite / object /
// arrayOf / codelist / localizedText (the nested-structure kinds). Four have a
// static-render compatibility receiver below, but remain absent from this editable/
// read-only-atom roster. field-image / field-reference are
// NO LONGER out — they ride CANVAS_PICKER_FIELD_TYPES (∈ CANVAS_FIELD_TYPES), so
// blockToNode dispatches them to the editable fieldBlockToNode and field-node.js
// mounts bp-media-picker / bp-reference-picker as canvas-editable control-atoms.
// After S3.6 sheet/embed are canvas-eligible too, so those nested-structure kinds
// remain the run splitters even though mounted compatibility projection is available.
// Keep aligned with
// embed-node.js:BP_SHEET_NODE_NAME / BP_EMBED_NODE_NAME and
// paper_canvas.ex:@canvas_readonly_atom_types.
const CANVAS_READONLY_ATOM_TYPES = new Set(["sheet", "embed"]);

// The TipTap NODE name for a read-only atom block differs from its bpType: for sheet
// it is `bpSheet`, for embed `bpEmbed` (the canvas bp-prefix convention; there is no
// StarterKit sheet/embed node to collide with). runToTiptap maps a block.type → its
// node.type; runToOps maps it back via bpType. Keep aligned with embed-node.js.
export const CANVAS_READONLY_ATOM_NODE_NAMES = { sheet: "bpSheet", embed: "bpEmbed" };
// Reverse: node.type "bpSheet" → bpType "sheet", "bpEmbed" → "embed". Used by runToOps
// to detect a read-only atom by its NODE type (the type carried on a getJSON node).
export const CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE = { bpSheet: "sheet", bpEmbed: "embed" };

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
export const CANVAS_FLEET_NODE_NAME = "bpFleet";

// Chat snapshots use the same reader paint channel without exposing chat actions.
const CANVAS_CHAT_TYPES = new Set([
  "chat-approval", "chat-plan", "chat-question",
  "chat-thinking", "chat-todo", "chat-tool-diff",
]);

// R6 static reader compatibility: blocks that use the SAME bpFleet paint receiver
// without becoming members of the component-fleet contract above. The four structured
// field kinds and paper-links remain contextual run boundaries on new Studio mounts,
// preserving their full server-side editors; recognizing them here keeps legacy/nested
// mounted canvases reader-shaped instead of degrading to the generic opaque chip.
// pre-gate-badge has no edit surface, so paper_canvas.ex also admits it into new runs.
// All six carry their whole source block verbatim and paint only server-produced
// reader HTML.
//
// Keep aligned with shared/paper.ex @canvas_static_render_types. Only
// pre-gate-badge is aligned with paper_canvas.ex @canvas_static_render_types.
const CANVAS_STATIC_RENDER_TYPES = new Set([
  "arrayOf",
  "codelist",
  "composite",
  "localizedText",
  "paper-links",
  "pre-gate-badge",
]);

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

// Reader-authored specialty blocks whose display contract is canonical server
// HTML, with no canvas-local renderer. They use the same mounted bpFleet atom and
// bp:block-html host paint as DataViz: the source block rides verbatim on bpBlock
// and Render.render_block(:article) remains the sole HTML producer. Kept separate
// from CANVAS_FLEET_TYPES so classic fleet preview/editor ownership is unchanged.
// KEEP LOCKSTEP with paper_canvas.ex @canvas_specialty_types and
// shared/paper.ex @specialty_render_types.
const CANVAS_SPECIALTY_TYPES = new Set([
  "api-endpoint",
  "bar-chart",
  "code-tabs",
  "criteria-progress",
  "gauge-list",
  "route",
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
export const CANVAS_FIGURE_NODE_NAME = "bpFigure";

// editable-image: the `image` block as a self-painting atom (`bpImage`; image-node.js).
// src + alt are the editable data (one patch-block{src, alt}); width/height/unknown keys
// ride verbatim on bpRest; locked/role ride the doctrine template attrs. KEEP LOCKSTEP
// with image-node.js BP_IMAGE_NODE_NAME.
const CANVAS_IMAGE_TYPES = new Set(["image"]);

// The "data + island" atoms (island-node.js): equation / footnote / toc / video. Each
// is a bag of editable keys on typed attrs (`fields`), everything else verbatim on
// bpRest, one patch-block of the fields on change. KEEP LOCKSTEP with ISLAND_SPECS.
export const CANVAS_ISLAND_SPECS = {
  equation: { nodeName: "bpEquation", fields: ["tex", "display"] },
  footnote: { nodeName: "bpFootnote", fields: ["notes"] },
  toc: { nodeName: "bpToc", fields: ["items", "numbered"] },
  video: { nodeName: "bpVideo", fields: ["src", "poster", "loop"] },
};
export const CANVAS_ISLAND_BP_TYPE_BY_NODE = Object.fromEntries(
  Object.entries(CANVAS_ISLAND_SPECS).map(([t, s]) => [s.nodeName, t]),
);
export function isCanvasIslandType(t) {
  return Object.hasOwn(CANVAS_ISLAND_SPECS, t);
}
export function isCanvasIslandNode(nodeType) {
  return Object.hasOwn(CANVAS_ISLAND_BP_TYPE_BY_NODE, nodeType);
}
export const CANVAS_IMAGE_NODE_NAME = "bpImage";
export function isCanvasImageType(t) {
  return CANVAS_IMAGE_TYPES.has(t);
}
export function isCanvasImageNode(nodeType) {
  return nodeType === CANVAS_IMAGE_NODE_NAME;
}

// True when a portable-doc BLOCK type is the figure (runToTiptap dispatch).
export function isCanvasFigureType(t) {
  return CANVAS_FIGURE_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas figure atom ("bpFigure"). runToOps /
// classifyNode read node.type off a getJSON node (the NODE name, not the bpType).
export function isCanvasFigureNode(nodeType) {
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
export const CANVAS_TASK_LIST_NODE_NAME = "bpTaskList";

// True when a portable-doc BLOCK is a LIVE task-list (a `task-list` type carrying a
// `query` MAP). A snapshot-only task-list returns false (→ the bpFleet fallback). This
// is the runToTiptap dispatch guard — the presence-of-query discriminant.
export function isLiveTaskListBlock(block) {
  return (
    block && block.type === "task-list" && isPlainObject(block.query)
  );
}

// True when a TipTap NODE type is the canvas task-list widget ("bpTaskList").
// runToOps / classifyNode read node.type off a getJSON node (the NODE name).
export function isCanvasTaskListNode(nodeType) {
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
export const CANVAS_CONTAINER_TYPES = new Set(["columns", "section", "terminal", "expandable", "steps", "tabs"]);

// block.type → its TipTap NODE name (they differ): columns→bpColumns, section→bpSection,
// terminal→bpTerminal. runToTiptap maps block.type → node.type; runToOps/classifyNode
// map back via bpType.
export const CANVAS_CONTAINER_NODE_NAMES = {
  columns: "bpColumns",
  section: "bpSection",
  terminal: "bpTerminal",
  expandable: "bpExpandable",
  steps: "bpSteps",
  tabs: "bpTabs",
};
// The expandable (native toggle) container's NODE name (expandable-node.js).
export const CANVAS_EXPANDABLE_NODE_NAME = "bpExpandable";
// steps / tabs: containers of titled rows (rows-node.js). The row node names are
// what a container's content holds; the row's title key differs per kind.
export const CANVAS_ROWS = {
  steps: { containerName: "bpSteps", rowName: "bpStep", rowsKey: "steps", titleKey: "title" },
  tabs: { containerName: "bpTabs", rowName: "bpTab", rowsKey: "tabs", titleKey: "label" },
};
export const CANVAS_ROW_NODE_NAMES = new Set(["bpStep", "bpTab"]);
// The section container's NODE name (singular alias used by sectionBlockToNode).
export const CANVAS_CONTAINER_NODE_NAME = "bpSection";
// Reverse: node.type → bpType. Used by classifyNode/isCanvasContainerNode to resolve
// the bpType off a getJSON node (the NODE name, not the bpType).
export const CANVAS_CONTAINER_BP_TYPE_BY_NODE = {
  bpColumns: "columns",
  bpSection: "section",
  bpTerminal: "terminal",
  bpExpandable: "expandable",
  bpSteps: "steps",
  bpTabs: "tabs",
};

// The per-column node name + the verbatim child-carrier atom node name (columns-node.js).
export const BP_COLUMN_NODE_NAME = "bpColumn";
export const BP_COLUMN_ATOM_NODE_NAME = "bpColumnAtom";
// The terminal verbatim child-carrier atom node name (terminal-node.js). The terminal
// container has NO per-column wrapper — its body children mount directly.
export const BP_TERMINAL_ATOM_NODE_NAME = "bpTerminalAtom";

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
export const CANVAS_ACTION_NODE_NAME = "bpAction";

// True when a portable-doc BLOCK type is the CTA action (runToTiptap dispatch).
export function isCanvasActionType(t) {
  return CANVAS_ACTION_TYPES.has(t);
}

// True when a TipTap NODE type is the canvas action control-atom ("bpAction").
// runToOps/classifyNode read node.type off a getJSON node (the NODE name).
export function isCanvasActionNode(nt) {
  return nt === CANVAS_ACTION_NODE_NAME;
}

export function isProseType(type) {
  return PROSE_TYPES.has(type);
}

export function isCanvasAtomType(type) {
  return CANVAS_ATOM_TYPES.has(type);
}

export function isCanvasContentType(type) {
  return CANVAS_CONTENT_TYPES.has(type);
}

// True when a portable-doc BLOCK type is a canvas attr-atom (e.g. "code").
export function isCanvasAttrAtomType(type) {
  return CANVAS_ATTR_ATOM_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas attr-atom (e.g. "bpCode"). runToOps
// reads node.type off a getJSON node, which is the NODE name, not the bpType.
export function isCanvasAttrAtomNode(nodeType) {
  return Object.prototype.hasOwnProperty.call(
    CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE,
    nodeType,
  );
}

// True when a portable-doc BLOCK type is a canvas field-* control-atom — the 7
// native field-* types PLUS the 2 picker types (field-image / field-reference).
// CANVAS_FIELD_TYPES is native ∪ picker, so this returns TRUE for the pickers too:
// they are canvas-editable, dispatched to fieldBlockToNode (NOT boundaries).
export function isCanvasFieldType(type) {
  return CANVAS_FIELD_TYPES.has(type);
}

// True when a TipTap NODE type is the canvas field control-atom ("bpField").
// runToOps reads node.type off a getJSON node (the NODE name); ALL 7 native field
// types share the single `bpField` node, so the specific kind comes off the bpType
// attr, not the node type.
export function isCanvasFieldNode(nodeType) {
  return nodeType === CANVAS_FIELD_NODE_NAME;
}

// True when a portable-doc BLOCK type is a canvas read-only atom (S3.6: "sheet" |
// "embed"). These ride INTO the canvas as read-only atoms carrying the whole block
// verbatim; they never emit a value/content op.
export function isCanvasReadOnlyAtomType(type) {
  return CANVAS_READONLY_ATOM_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas read-only atom (e.g. "bpSheet" / "bpEmbed").
// runToOps reads node.type off a getJSON node (the NODE name, not the bpType).
export function isCanvasReadOnlyAtomNode(nodeType) {
  return Object.prototype.hasOwnProperty.call(
    CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE,
    nodeType,
  );
}

// True when a portable-doc BLOCK type is a canvas fleet block (pdd-t8: "tasks" |
// "cards" | "pipeline" | "form" | …). These ride INTO the canvas as server-painted
// read-only atoms carrying the whole block verbatim; they never emit a value/content
// op — structurally they behave EXACTLY like a sheet/embed read-only atom.
export function isCanvasFleetType(type) {
  // DataViz, chat, static compatibility, and specialty kinds ride the same
  // bpFleet node + server-paint channel as parallel sets with the same projection.
  return (
    CANVAS_FLEET_TYPES.has(type) ||
    CANVAS_DATAVIZ_TYPES.has(type) ||
    CANVAS_CHAT_TYPES.has(type) ||
    CANVAS_STATIC_RENDER_TYPES.has(type) ||
    CANVAS_SPECIALTY_TYPES.has(type)
  );
}

// True when a TipTap NODE type is the canvas fleet node ("bpFleet"). runToOps reads
// node.type off a getJSON node (the NODE name); ALL fleet types share the single
// `bpFleet` node, so the specific kind comes off the bpType attr, not the node type
// (the same multiplexing bpField uses).
export function isCanvasFleetNode(nodeType) {
  return nodeType === CANVAS_FLEET_NODE_NAME;
}

// True when a portable-doc BLOCK type is a canvas container (S10: "columns"). These
// ride INTO the canvas as recursive nested-block nodes (bpColumns > bpColumn+ > child
// nodes); an interior change re-emits ONE coarse `columns` patch (V1 coarse round-trip).
export function isCanvasContainerType(type) {
  return CANVAS_CONTAINER_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas container (e.g. "bpColumns"). runToOps reads
// node.type off a getJSON node (the NODE name, not the bpType).
export function isCanvasContainerNode(nodeType) {
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

// True for a plain (non-array, non-null) object — the presence-of-query discriminant
// for the LIVE task-list widget (a `query` MAP → bpTaskList; anything else → the
// bpFleet fallback). Mirrors task_resolver.ex's `is_map(query)` guard.
export function isPlainObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

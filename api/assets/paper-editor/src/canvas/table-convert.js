import { inlineArrayToTiptap, tiptapInlineToPd } from "../convert.js";
import { canonicalJSON, deepClone } from "./projection-json.js";
import { gridToVisible, visibleToGrid, PLACEHOLDER_CELL } from "./table-grid.js";

// ── table ⇄ canvas nested node tree ──────────────────────────────────────────
//
// The `table` block ⇄ the bpTable > bpTableRow > bpTableHeaderCell|bpTableCell node
// tree. Block shape (compose.ex): { type:"table", rows:[[cell,…],…], head:[cell,
// …]? }. `rows` is a list of body rows; `head` is an OPTIONAL single header row (a list
// of cells). A cell is an INLINE array — the SAME shape a paragraph/callout body carries
// — so cell↔node uses inlineArrayToTiptap / tiptapInlineToPd verbatim. The header row is
// modeled as a bpTableRow of bpTableHeaderCell; body rows are bpTableRow of bpTableCell.
// The bpTable node carries bpId/bpType; rows/cells carry NO bpId (one id per table).

// Project an admitted cell to an inline array before the shared serializer. A scalar
// string becomes a text run; inline arrays and content-map arrays pass through. The
// number/null branches remain defensive for already-mounted historical source nodes,
// but tableBlockEditable keeps those unsaveable storage shapes opaque on fresh load.
function cellToInline(cell) {
  if (Array.isArray(cell)) return cell;
  if (cell == null) return [];
  if (cell && typeof cell === "object" && Array.isArray(cell.content)) {
    return cell.content;
  }
  if (typeof cell === "string" || typeof cell === "number")
    return [{ type: "text", value: String(cell) }];
  return [];
}

// One cell block → a bpTableHeaderCell|bpTableCell node. Omit the `content` key when
// the inline array is empty (empty-body fidelity, callout precedent).
function cellAlign(cell) {
  const a = cell && typeof cell === "object" && !Array.isArray(cell) ? cell.align : null;
  return a === "center" || a === "right" ? a : null;
}
function cellToNode(nodeName, cell, colspan = 1, rowspan = 1, head = false) {
  const node = {
    type: nodeName,
    attrs: { bpTableCellSource: { cell: deepClone(cell) }, colspan: colspan > 1 ? colspan : 1, rowspan: rowspan > 1 ? rowspan : 1, align: cellAlign(cell), head: !!head },
  };
  const inline = inlineArrayToTiptap(cellToInline(cell));
  if (inline.length) node.content = inline;
  return node;
}

// tableBlockToNode(block) → { type:"bpTable", attrs:{bpId,bpType},
//   content:[ headRow?, ...bodyRows ] }. The header row (only when block.head is present
// & non-empty) leads with bpTableHeaderCell cells; body rows follow with bpTableCell.
// Guards keep the node schema-valid (bpTableRow+ ; each row (cell)+) for a degenerate
// empty table — real tables always carry rows, so the guards never fire on live data.
export function tableBlockToNode(block, bpId, bpType) {
  const rowsSrc = Array.isArray(block && block.rows) ? block.rows.map((r) => (Array.isArray(r) ? r : Array.isArray(r && r.cells) ? r.cells : [])) : [];
  const headSrc = block && block.head;
  const content = [];
  // Merged cells (plan #24): `spans` on the block; covered positions hold placeholders and get no
  // node, the origin carries colspan / rowspan (table-grid.js).
  const grid = { head: Array.isArray(headSrc) && headSrc.length ? headSrc : null, rows: rowsSrc, spans: Array.isArray(block && block.spans) ? block.spans : [] };
  const headCol = !!(block && block.headCol === true);
  const coveredFirst = new Set();
  for (const sp of grid.spans) if (sp && sp.col === 0) for (let r = sp.row + 1; r < sp.row + (sp.rowspan || 1); r++) coveredFirst.add(r);
  const mkRow = (nodeName, cells, bodyIndex) => {
    const cellNodes = cells.map((vc, i) => cellToNode(nodeName, vc.cell, vc.colspan, vc.rowspan, headCol && bodyIndex != null && i === 0 && !coveredFirst.has(bodyIndex)));
    if (!cellNodes.length) cellNodes.push({ type: nodeName });
    return { type: "bpTableRow", content: cellNodes };
  };
  let bodyIndex = 0;
  for (const vrow of gridToVisible(grid)) content.push(mkRow(vrow.header ? "bpTableHeaderCell" : "bpTableCell", vrow.cells, vrow.header ? null : bodyIndex++));

  if (!content.length) {
    content.push({ type: "bpTableRow", content: [{ type: "bpTableCell" }] });
  }

  // Column widths (plan #25): `cols[i].width` → the node's colWidths (null where unset), only when
  // at least one column has one; the node view paints them as a <colgroup>.
  const colsSrc = Array.isArray(block && block.cols) ? block.cols : [];
  const widths = colsSrc.map((c) => (c && typeof c === "object" && Number.isInteger(c.width) && c.width > 0 ? c.width : null));
  const colWidths = widths.some((w) => w != null) ? widths : null;
  return {
    type: "bpTable",
    attrs: {
      bpId,
      bpType: bpType || "table",
      bpTableSource: { block: deepClone(block) },
      colWidths,
      headCol,
    },
    content,
  };
}

function sourceCellFromNode(cell) {
  const source = cell?.attrs?.bpTableCellSource;
  return source && typeof source === "object" && Object.hasOwn(source, "cell")
    ? source.cell
    : undefined;
}

function cellNodeInline(cell) {
  return tiptapInlineToPd((cell && cell.content) || []);
}

function sourceCellInline(cell) {
  return inlineArrayToTiptap(cellToInline(cell));
}

function comparableTableInline(content) {
  const normalized = inlineArrayToTiptap(tiptapInlineToPd(content || []));
  const out = [];
  for (const value of normalized) {
    const next = deepClone(value);
    if (!next.marks?.length) delete next.marks;
    const previous = out[out.length - 1];
    if (previous?.type === "text" && next.type === "text" &&
        canonicalJSON(previous.marks || null) === canonicalJSON(next.marks || null)) {
      previous.text += next.text;
    } else {
      out.push(next);
    }
  }
  return out;
}

function cellNodeMatchesSource(cell, source) {
  // Schema mounting may merge adjacent text nodes and add default link attrs
  // (target/rel/class). Compare through the shared portable-inline lens so those
  // presentation-only defaults never make an untouched cell look edited.
  return canonicalJSON(comparableTableInline(sourceCellInline(source))) ===
    canonicalJSON(comparableTableInline((cell && cell.content) || []));
}

// Preserve the exact carrier while its visible inline projection is untouched.
// Once edited, retain a supported content-map's opaque sibling metadata and replace
// only its content. Other edited carriers become the canonical inline-array shape.
function cellNodeToSource(cell) {
  return withCellAlign(cellNodeToSourcePlain(cell), cell);
}
function cellNodeToSourcePlain(cell) {
  const source = sourceCellFromNode(cell);
  const inline = cellNodeInline(cell);
  if (source !== undefined && cellNodeMatchesSource(cell, source)) {
    return deepClone(source);
  }
  if (source && typeof source === "object" && !Array.isArray(source) &&
      Array.isArray(source.content)) {
    const next = deepClone(source);
    next.content = inline;
    return next;
  }
  return inline;
}
// Per-cell alignment (plan #26) on the way back: "center" | "right" make the stored cell a
// content-map `{ content, align }` (other map keys kept); left drops `align`, and a map left with
// nothing but `content` becomes the plain inline array again.
function withCellAlign(stored, cell) {
  const align = cell?.attrs?.align === "center" || cell?.attrs?.align === "right" ? cell.attrs.align : null;
  // Unchanged alignment must preserve the source carrier and unknown metadata.
  if (align === cellAlign(sourceCellFromNode(cell))) return stored;
  const isMap = stored && typeof stored === "object" && !Array.isArray(stored);
  if (align) {
    if (isMap) return { ...stored, content: Array.isArray(stored.content) ? stored.content : cellToInline(stored), align };
    return { content: cellToInline(stored), align };
  }
  if (isMap && Object.hasOwn(stored, "align")) {
    const next = { ...stored };
    delete next.align;
    const keys = Object.keys(next);
    if (keys.length === 1 && keys[0] === "content") return next.content;
    return next;
  }
  return stored;
}

// tableNodeToBlock(node, id) → { id, type:"table", rows:[…], head?:[…] }. Walk the row
// nodes: a LEADING row whose cells are ALL bpTableHeaderCell → block.head; every other
// row → a body row. Each cell → tiptapInlineToPd(cell.content||[]) (the shared
// deserializer). head is OMITTED when there is no header row (byte-fidelity; the INSERT
// path drops absent fields, like calloutNodeToBlock).
export function tableNodeToBlock(node, id) {
  const rowNodes = (node && node.content) || [];
  const visible = rowNodes.map((rowNode, i) => {
    const cells = (rowNode && rowNode.content) || [];
    const isHeaderRow = i === 0 && cells.length > 0 && cells.every((c) => c.type === "bpTableHeaderCell");
    return { header: isHeaderRow, cells: cells.map((c) => ({ cell: cellNodeToSource(c), colspan: isHeaderRow ? 1 : Math.max(1, c.attrs?.colspan || 1), rowspan: isHeaderRow ? 1 : Math.max(1, c.attrs?.rowspan || 1) })) };
  });
  // Back to the rectangular grid: covered positions get the placeholder cell, spans ride `spans`.
  const grid = visibleToGrid(visible, () => deepClone(PLACEHOLDER_CELL));
  const head = grid.head;
  const rows = grid.rows;
  const source = node?.attrs?.bpTableSource?.block;
  const block = source && typeof source === "object" && !Array.isArray(source)
    ? deepClone(source)
    : {};
  block.id = id;
  block.type = "table";
  block.rows = rows;
  if (grid.spans.length) block.spans = grid.spans;
  else delete block.spans;
  if (node?.attrs?.headCol) block.headCol = true;
  else if (block.headCol === true) block.headCol = false;
  // Column widths back onto `cols` (kept beside the reader's column types); a column list with
  // nothing left in it is dropped.
  const widths = Array.isArray(node?.attrs?.colWidths) ? node.attrs.colWidths : null;
  if (widths || (Array.isArray(block.cols) && block.cols.some((c) => c && typeof c === "object" && c.width != null))) {
    const width = Math.max(rows.length ? rows[0].length : 0, head ? head.length : 0, widths ? widths.length : 0);
    const cols = Array.from({ length: width }, (_, i) => {
      const src = Array.isArray(block.cols) && block.cols[i] && typeof block.cols[i] === "object" ? { ...block.cols[i] } : {};
      const w = widths ? widths[i] : null;
      if (Number.isInteger(w) && w > 0) src.width = w;
      else delete src.width;
      return src;
    });
    while (cols.length && Object.keys(cols[cols.length - 1]).length === 0) cols.pop();
    if (cols.some((c) => Object.keys(c).length)) block.cols = cols;
    else delete block.cols;
  }
  if (head) block.head = head;
  else if (Array.isArray(source?.head) && source.head.length) block.head = [];
  else if (!source || !Object.hasOwn(source, "head")) delete block.head;
  return block;
}

// The COARSE whole-table PATCH: { rows:<all body rows>, head:<header cells OR []> }.
// CRITICAL (the calloutNodeToPatch removal contract): patch-block is a SHALLOW Map.merge
// that can REPLACE but never DELETE a key — so head is emitted EXPLICITLY as `[]` when the
// header row was removed, otherwise the stale old head survives and the header band
// silently reappears on reload. compose.ex maps head:[] → no thead, so `head:[]`
// round-trips clean. `rows` is always the full body (a whole-table replace — one cell
// edit re-emits the entire rows/head, the v1 greenlit coarse round-trip).
export function tableNodeToPatch(node, prevBlock) {
  const block = tableNodeToBlock(node, null);
  const patch = { rows: block.rows };
  if (Object.hasOwn(block, "head")) patch.head = block.head;
  // Source-free/pasted table nodes retain the historical removal-safe fallback.
  if (!node?.attrs?.bpTableSource && !Object.hasOwn(patch, "head")) patch.head = [];
  // Spans ride the patch; a table that lost its last span says so (a shallow merge would keep the old list).
  // "Had spans" is read from the BASELINE the patch merges onto (the acknowledged block), not the
  // mount-time source the node still carries: a table merged and split within one session has
  // spans on the server and none on its source.
  const hadSpans = (Array.isArray(prevBlock?.spans) && prevBlock.spans.length > 0) ||
    (Array.isArray(node?.attrs?.bpTableSource?.block?.spans) && node.attrs.bpTableSource.block.spans.length > 0);
  if (Array.isArray(block.spans) && block.spans.length) patch.spans = block.spans;
  else if (hadSpans) patch.spans = [];
  // Column widths ride `cols` on the patch; a table that lost its last column entry says `cols: []`.
  const hadCols = (Array.isArray(prevBlock?.cols) && prevBlock.cols.length > 0) ||
    (Array.isArray(node?.attrs?.bpTableSource?.block?.cols) && node.attrs.bpTableSource.block.cols.length > 0);
  if (Array.isArray(block.cols) && block.cols.length) patch.cols = block.cols;
  else if (hadCols) patch.cols = [];
  // The header column rides as a boolean; false is sent only when the table had one.
  const hadHeadCol = prevBlock?.headCol === true || node?.attrs?.bpTableSource?.block?.headCol === true;
  if (block.headCol === true) patch.headCol = true;
  else if (hadHeadCol) patch.headCol = false;
  return patch;
}

// True when a table's grid/content changed. Canonical (key-order-insensitive) compare
// of the header cells + body rows — a cell edit / add-remove row-col flips it, a pure
// reorder (bpId only) emits nothing.
export function tableNodeChanged(prevNode, nextNode) {
  return stableTableKey(prevNode) !== stableTableKey(nextNode);
}

function stableTableKey(node) {
  const b = tableNodeToBlock(node, null);
  return canonicalJSON({ head: b.head ? b.head : null, rows: b.rows, spans: b.spans || null, cols: b.cols || null, headCol: b.headCol === true });
}

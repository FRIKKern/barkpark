// Pure table projection and table operation conversion.
import { deepClone, jsonEqual } from "./convert-json.js";
import { inlineArrayToTiptap, tiptapInlineToPd } from "./inline-codec.js";

function tableInlineToTiptap(inline) {
  if (!Array.isArray(inline)) return null;
  try {
    const projected = inlineArrayToTiptap(inline);
    return jsonEqual(tiptapInlineToPd(projected), inline) ? projected : null;
  } catch (_error) {
    return null;
  }
}

function tableRowToTiptap(cells, header, rowShape) {
  if (!Array.isArray(cells) || cells.length === 0) return null;
  const projected = cells.map((inline, index) => {
    const descriptor = tableCellDescriptor(rowShape?.cells?.[index]);
    if (descriptor && !tableProtectedSourceMatches(inline, descriptor)) return null;
    return tableInlineToTiptap(inline);
  });
  if (projected.some((inline) => inline == null)) return null;
  return {
    type: "bpTableRow",
    content: projected.map((inline) => ({
      type: header ? "bpTableHeaderCell" : "bpTableCell",
      ...(inline.length ? { content: inline } : {}),
    })),
  };
}

function exactObjectKeys(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const keys = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return keys.length === wanted.length && keys.every((key, index) => key === wanted[index]);
}

const TABLE_CELL_KINDS = new Set(["inline-array", "content-map"]);
const TABLE_PROTECTED_CHAIN_TYPES = new Set([
  "link", "wikilink", "strong", "em", "underline", "strikethrough", "highlight", "sub", "sup", "text",
]);

function tableCellDescriptor(cellShape) {
  return cellShape && typeof cellShape === "object" && !Array.isArray(cellShape)
    ? cellShape : null;
}

function validTableCellShape(cellShape, version) {
  if (typeof cellShape === "string") return TABLE_CELL_KINDS.has(cellShape);
  if (version !== 2 || !exactObjectKeys(cellShape, ["kind", "inline"]) ||
      !TABLE_CELL_KINDS.has(cellShape.kind) ||
      !exactObjectKeys(cellShape.inline, ["v", "anchors", "opaque"]) ||
      cellShape.inline.v !== 1) return false;
  const { anchors, opaque } = cellShape.inline;
  if (!Array.isArray(anchors) || !Array.isArray(opaque) || anchors.length === 0 ||
      opaque.length === 0 || anchors.at(-1) !== "text" ||
      anchors.some((type) => !TABLE_PROTECTED_CHAIN_TYPES.has(type)) ||
      new Set(anchors).size !== anchors.length || new Set(opaque).size !== opaque.length) return false;
  return jsonEqual(anchors, [...opaque.filter((type) => type !== "text"), "text"]);
}

function validTableRowShape(shape, width, version, header = false) {
  return exactObjectKeys(shape, ["kind", "cells"]) &&
    (header ? shape.kind === "array" : ["array", "cells-map"].includes(shape.kind)) &&
    Array.isArray(shape.cells) && shape.cells.length === width &&
    shape.cells.every((cellShape) => validTableCellShape(cellShape, version));
}

function validTableShape(shape, head, rows, width) {
  if (!exactObjectKeys(shape, ["v", "head", "rows"]) || ![1, 2].includes(shape.v) ||
      !Array.isArray(shape.rows) || shape.rows.length !== rows.length ||
      !shape.rows.every((row) => validTableRowShape(row, width, shape.v))) return false;
  const headShape = shape.head;
  if (!headShape || typeof headShape !== "object" || Array.isArray(headShape)) return false;
  const descriptors = shape.rows.flatMap((row) => row.cells).filter(tableCellDescriptor);
  if (head === null) {
    return exactObjectKeys(headShape, ["state"]) &&
      ["absent", "null", "empty"].includes(headShape.state) &&
      (shape.v === 2 ? descriptors.length > 0 : descriptors.length === 0);
  }
  if (!exactObjectKeys(headShape, ["state", "row"]) || headShape.state !== "row" ||
      !validTableRowShape(headShape.row, width, shape.v, true)) return false;
  descriptors.push(...headShape.row.cells.filter(tableCellDescriptor));
  return shape.v === 2 ? descriptors.length > 0 : descriptors.length === 0;
}

function tablePdInlineChain(inline) {
  if (!Array.isArray(inline) || inline.length !== 1) return null;
  const chain = [];
  let node = inline[0];
  while (node && typeof node === "object" && !Array.isArray(node)) {
    if (!TABLE_PROTECTED_CHAIN_TYPES.has(node.type) ||
        chain.some((entry) => entry.type === node.type)) return null;
    if (node.type === "text") {
      if (!exactObjectKeys(node, ["type", "value"]) ||
          typeof node.value !== "string" || node.value === "") return null;
      chain.push({ type: "text", node });
      return chain;
    }
    const allowed = node.type === "link"
      ? ["type", "href", "children"]
      : node.type === "wikilink"
        ? ["type", "target", "children", ...(
          Object.hasOwn(node, "alias") ? ["alias"] : []),
        ...(
          Object.hasOwn(node, "docId") ? ["docId"] : [])]
        : ["type", "children"];
    if (!exactObjectKeys(node, allowed) || !Array.isArray(node.children) ||
        node.children.length !== 1 ||
        (node.type === "link" && typeof node.href !== "string") ||
        (node.type === "wikilink" && typeof node.target !== "string")) return null;
    chain.push({ type: node.type, node });
    node = node.children[0];
  }
  return null;
}

function tableOpaqueRoleSemanticsMatch(source, current) {
  if (source.type === "text") return true;
  if (source.type === "link") return source.node.href === current.node.href;
  if (source.type === "wikilink") {
    return source.node.target === current.node.target &&
      source.node.alias === current.node.alias && source.node.docId === current.node.docId;
  }
  return true;
}

function tableProtectedSourceMatches(inline, descriptor) {
  const chain = tablePdInlineChain(inline);
  return chain != null && jsonEqual(
    chain.map(({ type }) => type).filter((type) =>
      type === "text" || descriptor.inline.opaque.includes(type)),
    descriptor.inline.anchors,
  );
}

function tableProtectedInlineSupported(inline, sourceInline, descriptor) {
  const source = tablePdInlineChain(sourceInline);
  const current = tablePdInlineChain(tiptapInlineToPd(inline));
  if (!source || !current || !tableProtectedSourceMatches(sourceInline, descriptor)) return false;
  return descriptor.inline.opaque.every((type) => {
    const sourceRole = source.find((entry) => entry.type === type);
    const currentRole = current.find((entry) => entry.type === type);
    return sourceRole && currentRole && tableOpaqueRoleSemanticsMatch(sourceRole, currentRole);
  });
}

const TABLE_MARKS = new Set([
  "bold", "italic", "underline", "strike", "highlight", "subscript", "superscript", "code", "link", "wikilink",
  "blockref", "tag", "valueref",
]);

function tableCellAttrsPlain(attrs) {
  if (attrs == null) return true;
  if (!tableAttrsHaveOnly(attrs, ["bpTableCellSource", "colspan", "rowspan", "align", "head"])) return false;
  if (attrs.bpTableCellSource != null) return false;
  // A per-cell alignment or a row-header cell (plan #26) is canvas-only here: fail closed.
  if (attrs.align != null || attrs.head === true) return false;
  return (attrs.colspan == null || attrs.colspan === 1) && (attrs.rowspan == null || attrs.rowspan === 1);
}

function tableAttrsHaveOnly(attrs, allowed) {
  return attrs && typeof attrs === "object" && !Array.isArray(attrs) &&
    Object.keys(attrs).every((key) => allowed.includes(key));
}

function validTableMark(mark) {
  if (!mark || typeof mark !== "object" || Array.isArray(mark) ||
      !TABLE_MARKS.has(mark.type)) return false;
  if (["bold", "italic", "underline", "strike", "highlight", "subscript", "superscript", "code"].includes(mark.type)) {
    return exactObjectKeys(mark, ["type"]);
  }
  if (!exactObjectKeys(mark, ["type", "attrs"])) return false;
  const attrs = mark.attrs;
  if (mark.type === "link") {
    if (!tableAttrsHaveOnly(attrs, ["href", "target", "rel", "class"]) ||
        typeof attrs.href !== "string") return false;
    const keys = Object.keys(attrs).sort();
    return jsonEqual(keys, ["href"]) ||
      (jsonEqual(keys, ["class", "href", "rel", "target"]) &&
        attrs.target === "_blank" && attrs.rel === "noopener noreferrer nofollow" &&
        attrs.class === null);
  }
  if (mark.type === "wikilink") {
    return tableAttrsHaveOnly(attrs, ["target", "alias", "docId"]) &&
      typeof attrs.target === "string";
  }
  if (mark.type === "blockref") {
    return exactObjectKeys(attrs, ["target", "anchor"]) &&
      typeof attrs.target === "string" && typeof attrs.anchor === "string";
  }
  if (mark.type === "tag") {
    return exactObjectKeys(attrs, ["name"]) && typeof attrs.name === "string";
  }
  return tableAttrsHaveOnly(attrs, ["target", "field", "as", "fallback", "label", "children"]) &&
    typeof attrs.target === "string" && typeof attrs.field === "string";
}

function tableTiptapInlineEqual(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false;
  const valid = left.every((node, index) => {
    const other = right[index];
    const keys = node?.marks == null ? ["type", "text"] : ["type", "text", "marks"];
    const otherKeys = other?.marks == null ? ["type", "text"] : ["type", "text", "marks"];
    if (!exactObjectKeys(node, keys) || !exactObjectKeys(other, otherKeys) ||
        node.type !== "text" || other.type !== "text" || node.text !== other.text) return false;
    const marks = Array.isArray(node.marks) ? node.marks : [];
    const otherMarks = Array.isArray(other.marks) ? other.marks : [];
    const markTypes = marks.map((mark) => mark?.type);
    const otherMarkTypes = otherMarks.map((mark) => mark?.type);
    const unique = new Set(markTypes);
    const otherUnique = new Set(otherMarkTypes);
    const leaves = markTypes.filter((type) => ["code", "blockref", "tag", "valueref"].includes(type));
    const otherLeaves = otherMarkTypes.filter((type) =>
      ["code", "blockref", "tag", "valueref"].includes(type));
    return marks.every(validTableMark) && otherMarks.every(validTableMark) &&
      unique.size === markTypes.length && otherUnique.size === otherMarkTypes.length &&
      leaves.length <= 1 && otherLeaves.length <= 1;
  });
  return valid && jsonEqual(tiptapInlineToPd(left), tiptapInlineToPd(right));
}

// The server owns the lossless storage lens. This client accepts only its
// JSON-safe projection envelope; raw carrier maps never enter ProseMirror.
export function tableProjection(projection) {
  const emptyDoc = { type: "doc", content: [{ type: "paragraph" }] };
  if (!projection || typeof projection !== "object" || Array.isArray(projection) ||
      projection.type !== "table" || typeof projection.id !== "string" ||
      projection.id.trim() !== projection.id || projection.id === "" ||
      !projection.shape || typeof projection.shape !== "object" ||
      Array.isArray(projection.shape) || !Array.isArray(projection.rows) ||
      projection.rows.length === 0 || !Object.prototype.hasOwnProperty.call(projection, "head")) {
    return { editable: false, shape: null, head: null, rows: [], doc: emptyDoc };
  }
  const width = projection.rows[0]?.length;
  if (!Number.isSafeInteger(width) || width < 1 ||
      !validTableShape(projection.shape, projection.head, projection.rows, width)) {
    return { editable: false, shape: null, head: null, rows: [], doc: emptyDoc };
  }
  const body = projection.rows.map((row, index) =>
    tableRowToTiptap(row, false, projection.shape.rows[index]));
  const head = projection.head == null ? null
    : tableRowToTiptap(projection.head, true, projection.shape.head.row);
  if (body.some((row, index) => row == null || projection.rows[index].length !== width) ||
      (projection.head != null && (head == null || projection.head.length !== width))) {
    return { editable: false, shape: null, head: null, rows: [], doc: emptyDoc };
  }
  const rows = head ? [head, ...body] : body;
  return {
    editable: true,
    shape: deepClone(projection.shape),
    head: deepClone(projection.head),
    rows: deepClone(projection.rows),
    doc: {
      type: "doc",
      content: [{
        type: "bpTable",
        attrs: { bpId: projection.id, bpType: "table" },
        content: rows,
      }],
    },
  };
}

function tableCellRows(editorJSON, projection) {
  const source = tableProjection(projection);
  const nodes = editorJSON?.content;
  if (!source.editable || !Array.isArray(nodes) || nodes.length !== 1 ||
      nodes[0]?.type !== "bpTable" || nodes[0]?.attrs?.bpId !== projection.id ||
      !tableAttrsHaveOnly(nodes[0]?.attrs, ["bpId", "bpType", "bpTableSource", "colWidths", "headCol"]) ||
      nodes[0]?.attrs?.headCol === true ||
      nodes[0]?.attrs?.bpTableSource != null ||
      // Column widths (plan #25) are a canvas attribute; the per-block Studio editor edits plain
      // grids, so a table carrying one fails closed here (read-only) and no widths reads as plain.
      (Array.isArray(nodes[0]?.attrs?.colWidths) && nodes[0].attrs.colWidths.some((w) => w != null)) ||
      !Array.isArray(nodes[0].content)) return null;
  const liveRows = nodes[0].content;
  const hasHead = source.head != null;
  if (liveRows.length !== source.rows.length + (hasHead ? 1 : 0)) return null;
  const readRow = (row, header, sourceCells, rowShape) => {
    if (row?.type !== "bpTableRow" || !Array.isArray(row.content) ||
        row.content.length !== source.rows[0].length) return null;
    const expectedType = header ? "bpTableHeaderCell" : "bpTableCell";
    const cells = row.content.map((cell, column) => {
      // The canvas cell carries colspan / rowspan (merged cells, plan #24); the per-block Studio
      // editor edits plain grids only, so a spanning cell fails closed here (read-only), and 1/1
      // reads as the plain cell it is.
      if (cell?.type !== expectedType || !tableCellAttrsPlain(cell.attrs)) return null;
      const inline = cell.content || [];
      if (!Array.isArray(inline)) return null;
      try {
        if (!tableTiptapInlineEqual(inlineArrayToTiptap(tiptapInlineToPd(inline)), inline)) {
          return null;
        }
        const descriptor = tableCellDescriptor(rowShape.cells[column]);
        if (descriptor && !tableProtectedInlineSupported(
          inline,
          sourceCells[column],
          descriptor,
        )) return null;
      } catch (_error) {
        return null;
      }
      return tiptapInlineToPd(inline);
    });
    return cells.some((cell) => cell == null) ? null : cells;
  };
  let offset = 0;
  const head = hasHead
    ? readRow(liveRows[offset++], true, source.head, projection.shape.head.row) : null;
  const rows = liveRows.slice(offset).map((row, index) =>
    readRow(row, false, source.rows[index], projection.shape.rows[index]));
  return (hasHead && head == null) || rows.some((row) => row == null)
    ? null
    : { source, head, rows };
}

export function tableTiptapDocSupported(editorJSON, projection) {
  return tableCellRows(editorJSON, projection) != null;
}

function tableCellKey(area, row, column) {
  return `${area}:${row}:${column}`;
}

export function buildTableCellsOp(editorJSON, projection, forceCells = []) {
  const current = tableCellRows(editorJSON, projection);
  if (!current) return null;
  const forced = new Set((Array.isArray(forceCells) ? forceCells : []).map((cell) =>
    tableCellKey(cell?.area, cell?.row, cell?.column)));
  const cells = [];
  if (current.head) current.head.forEach((content, column) => {
    if (forced.has(tableCellKey("head", 0, column)) ||
        !jsonEqual(content, current.source.head[column])) {
      cells.push({ area: "head", row: 0, column, content });
    }
  });
  current.rows.forEach((row, rowIndex) => row.forEach((content, column) => {
    if (forced.has(tableCellKey("body", rowIndex, column)) ||
        !jsonEqual(content, current.source.rows[rowIndex][column])) {
      cells.push({ area: "body", row: rowIndex, column, content });
    }
  }));
  if (!cells.length) return null;
  return {
    op: "patch-table-cells",
    id: projection.id,
    shape: deepClone(current.source.shape),
    cells,
  };
}

export function tableProjectionMatchesCells(projection, cells) {
  const source = tableProjection(projection);
  if (!source.editable || !Array.isArray(cells)) return false;
  return cells.every(({ area, row, column, content }) => {
    const actual = area === "head" && row === 0
      ? source.head?.[column]
      : area === "body" ? source.rows?.[row]?.[column] : undefined;
    return actual !== undefined && jsonEqual(actual, content);
  });
}

export function tableProjectionMatchesAction(before, after, action) {
  if (before?.id !== after?.id) return false;
  const source = tableProjection(before);
  const target = tableProjection(after);
  if (!source.editable || !target.editable || typeof action !== "string") return false;
  const expected = {
    shape: deepClone(source.shape),
    head: deepClone(source.head),
    rows: deepClone(source.rows),
  };
  const shapeRows = expected.shape?.rows;
  const shapeHead = expected.shape?.head;
  if (!Array.isArray(shapeRows) || !shapeHead || typeof shapeHead !== "object") return false;
  const swap = (items, left, right) => {
    [items[left], items[right]] = [items[right], items[left]];
  };
  const indexed = /^(remove|up|down)-row:(0|[1-9]\d*)$/.exec(action);
  const column = /^(remove|left|right)-column:(0|[1-9]\d*)$/.exec(action);
  if (action === "add-row") {
    expected.rows.push(Array(expected.rows[0].length).fill([]));
    shapeRows.push({ kind: "array", cells: Array(expected.rows[0].length).fill("inline-array") });
  } else if (action === "add-column") {
    expected.rows.forEach((row) => row.push([]));
    shapeRows.forEach((row) => row?.cells?.push("inline-array"));
    if (expected.head) {
      expected.head.push([]);
      shapeHead.row?.cells?.push("inline-array");
    }
  } else if (action === "add-header") {
    expected.head = Array(expected.rows[0].length).fill([]);
    expected.shape.head = {
      state: "row",
      row: { kind: "array", cells: Array(expected.rows[0].length).fill("inline-array") },
    };
  } else if (action === "remove-header") {
    expected.head = null;
    expected.shape.head = { state: "empty" };
  } else if (indexed) {
    const index = Number(indexed[2]);
    if (indexed[1] === "remove") {
      expected.rows.splice(index, 1);
      shapeRows.splice(index, 1);
    } else {
      const other = indexed[1] === "up" ? index - 1 : index + 1;
      swap(expected.rows, index, other);
      swap(shapeRows, index, other);
    }
  } else if (column) {
    const index = Number(column[2]);
    const editRow = (row) => {
      if (column[1] === "remove") row.splice(index, 1);
      else swap(row, index, column[1] === "left" ? index - 1 : index + 1);
    };
    expected.rows.forEach(editRow);
    shapeRows.forEach((row) => editRow(row.cells));
    if (expected.head) {
      editRow(expected.head);
      editRow(expected.shape.head.row.cells);
    }
  } else {
    return false;
  }
  const protectedCells = [
    ...shapeRows.flatMap((row) => row.cells),
    ...(expected.head ? shapeHead.row.cells : []),
  ].filter(tableCellDescriptor);
  expected.shape.v = protectedCells.length > 0 ? 2 : 1;
  return jsonEqual(expected.shape, target.shape) && jsonEqual(expected.head, target.head) &&
    jsonEqual(expected.rows, target.rows);
}

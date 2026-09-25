// Clipboard-only normalization into the existing inline-cell table schema.
// Source identities and private metadata never come from foreign HTML.
export function prepareHTMLTablePaste(html) {
  if (!html || !/<table[\s>]/i.test(html)) return null;
  const doc = new DOMParser().parseFromString(html, "text/html");
  const tables = [...doc.body.querySelectorAll("table")];
  if (!tables.length) return null;
  const blocked = (reason) => ({ blocked: reason });
  for (const table of tables) {
    if (table.querySelector("table, ul, ol, pre, blockquote, img, video, audio, iframe")) {
      return blocked("This table contains content that cannot fit inside a table cell.");
    }
    if (table.caption?.textContent.trim()) return blocked("This table has a caption that cannot be kept inside the table.");
    const rows = [...table.rows];
    if (!rows.length || rows.some((row) => !row.cells.length)) return blocked("This table has an empty row that cannot be represented.");
    const header = [...rows[0].cells].every((cell) => cell.tagName === "TH" && cell.getAttribute("scope") !== "row");
    const body = rows.slice(header ? 1 : 0);
    if (rows.some((row) => [...row.cells].some((cell) => cell.rowSpan === 0))) return blocked("Open-ended row spans cannot be kept.");
    // The storage grid's width comes from visible span sums. Reject malformed
    // overlaps/overflow before its forgiving converter could drop a source cell.
    const width = Math.max(...rows.map((row) => [...row.cells].reduce((sum, cell) => sum + cell.colSpan, 0)));
    const covered = new Set();
    for (const [rowIndex, row] of body.entries()) {
      let column = 0;
      for (const cell of row.cells) {
        while (covered.has(`${rowIndex},${column}`)) column++;
        if (column + cell.colSpan > width) return blocked("This table has an irregular span layout that cannot be kept.");
        for (let c = column; c < column + cell.colSpan; c++) {
          if (covered.has(`${rowIndex},${c}`)) return blocked("This table has overlapping cells that cannot be kept.");
          for (let r = rowIndex; r < rowIndex + cell.rowSpan; r++) covered.add(`${r},${c}`);
        }
        column += cell.colSpan;
      }
    }
    for (const [index, row] of rows.entries()) {
      for (const cell of row.cells) {
        if (header && index === 0 && (cell.colSpan > 1 || cell.rowSpan > 1)) return blocked("Merged header cells are not supported.");
        if (!(header && index === 0) && cell.tagName === "TH" && cell.getAttribute("scope") !== "row") return blocked("Only a first header row or a first header column can be kept.");
        if (!(header && index === 0) && cell.rowSpan > rows.length - index) return blocked("This table has a cell spanning beyond its last row.");
        if ([...cell.querySelectorAll("*")].some((el) => !/^(A|SPAN|B|STRONG|I|EM|S|DEL|STRIKE|U|CODE|MARK|SUB|SUP|BR|P|DIV|FONT)$/.test(el.tagName))) return blocked("This table contains unsupported cell structure.");
        const align = cell.style.textAlign || cell.getAttribute("align") || cell.getAttribute("data-align");
        // HTML block wrappers inside a cell represent line boundaries, not sibling blocks.
        cell.replaceChildren(flattenCell(doc, [...cell.childNodes]));
        // PortableDoc stores line breaks as literal text, not PM hardBreak nodes.
        if (cell.querySelector("p, div")) return blocked("This table contains nested paragraph structure that cannot be kept.");
        for (const br of cell.querySelectorAll("br")) br.replaceWith(doc.createTextNode("\n"));
        for (const el of [cell, ...cell.querySelectorAll("*")]) {
          for (const attr of [...el.attributes]) if (attr.name.startsWith("data-bp-")) el.removeAttribute(attr.name);
        }
        cell.removeAttribute("data-align");
        if (align === "center" || align === "right") cell.setAttribute("data-align", align);
      }
    }
    const rowHeaders = body.map((row) => [...row.cells].map((cell, index) => cell.getAttribute("scope") === "row" ? index : -1).filter((index) => index >= 0));
    if (rowHeaders.some((indices) => indices.some((index) => index !== 0)) || (rowHeaders.some((indices) => indices.length) && rowHeaders.some((indices) => !indices.length))) return blocked("Only a consistent first header column can be kept.");
    for (const attr of [...table.attributes]) table.removeAttribute(attr.name);
    table.setAttribute("data-bp-type", "table");
    if (rowHeaders.length && rowHeaders.every((indices) => indices.length === 1)) table.setAttribute("data-head-col", "true");
  }
  return { dom: doc.body };
}

function flattenCell(doc, nodes) {
  const result = doc.createDocumentFragment();
  let previousBlock = false;
  let seen = false;
  for (const node of nodes) {
    if (node.nodeType === 3 && !node.textContent.trim()) {
      // Formatting whitespace between HTML block wrappers is not a new authored line.
      if (previousBlock || nodes.some((child) => child.nodeType === 1 && /^(P|DIV)$/.test(child.tagName))) continue;
    }
    const block = node.nodeType === 1 && /^(P|DIV)$/.test(node.tagName);
    if (seen && (previousBlock || block)) result.append(doc.createElement("br"));
    if (block) {
      const children = [...node.childNodes];
      // A lone BR in an empty paragraph is its browser placeholder.
      if (!(children.length === 1 && children[0].nodeName === "BR")) result.append(flattenCell(doc, children));
    } else {
      result.append(node);
    }
    previousBlock = block;
    seen = true;
  }
  return result;
}

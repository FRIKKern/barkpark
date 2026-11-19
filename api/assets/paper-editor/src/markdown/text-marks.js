// Marks held on text, written as the inline nodes the Markdown writer knows
// (task-5f0ba8904b973a3a).
//
//   marksAsNodes(inline) -> the same inline with every text run's `marks` turned into
//                           strong / em / strikethrough / highlight / underline / sub /
//                           sup / link nodes and inline code leaves; null when a mark
//                           has no node (a comment, a link with a title), so the caller
//                           writes the block whole on its JSON line
//   holdsMarkedText(inline) -> true when any run in it carries a mark
//
// The editor holds bold as { type: "text", value: "x", marks: ["strong"] }; the writer
// writes only { type: "strong", children: [...] }, so before this a marked run was
// written as plain text and the mark was gone. A mark is spelled one way here as in the
// source wall (markdown/carries.js): bold is strong, italic is em, s and strike are
// strikethrough, and a link mark is { type, href } or { type, attrs: { href } }.
//
// Adjacent runs that share a mark go under one node: the mark that spans the most runs
// from where a group starts is the outer node, ties going by WRAPPERS order, so
// "a **b *c***" is one strong around "b " and an em, not two strongs side by side.
// Inline code has no children, so it is always the innermost: runs whose only mark
// left is code become one code leaf.

const WRAPPER_NAMES = {
  strong: "strong", bold: "strong", em: "em", italic: "em", strike: "strikethrough", s: "strikethrough",
  strikethrough: "strikethrough", highlight: "highlight", underline: "underline", sub: "sub", sup: "sup",
};
// The order a tie is settled in, outermost first.
const WRAPPERS = ["link", "strong", "em", "strikethrough", "highlight", "underline", "sub", "sup"];

export function holdsMarkedText(inline) {
  return Array.isArray(inline) && inline.some((node) =>
    isMap(node) && ((node.type === "text" && Array.isArray(node.marks) && node.marks.length > 0) ||
      (Array.isArray(node.children) && holdsMarkedText(node.children))));
}

export function marksAsNodes(inline) {
  if (!Array.isArray(inline)) return inline;
  const items = [];
  for (const node of inline) {
    if (isMap(node) && node.type === "text" && Array.isArray(node.marks) && node.marks.length > 0) {
      if (Object.keys(node).some((key) => key !== "type" && key !== "value" && key !== "marks")) return null;
      if (typeof node.value !== "string") return null;
      const marks = [];
      for (const mark of node.marks) {
        const one = markOf(mark);
        if (one === null) return null;
        if (!marks.some((m) => m.key === one.key)) marks.push(one);
      }
      items.push({ value: node.value, marks });
    } else if (isMap(node) && Array.isArray(node.children) && holdsMarkedText(node.children)) {
      const children = marksAsNodes(node.children);
      if (children === null) return null;
      items.push({ node: { ...node, children } });
    } else {
      items.push({ node });
    }
  }
  return group(items);
}

// One mark: { key, wrap(children) } for a wrapper, { key: "code" } for inline code,
// or null when the writer has no node for it.
function markOf(mark) {
  const name = typeof mark === "string" ? mark : isMap(mark) && Object.keys(mark).length === 1 ? mark.type : null;
  if (name === "code") return { key: "code" };
  const type = typeof name === "string" ? WRAPPER_NAMES[name] : undefined;
  if (type) return { key: type, wrap: (children) => ({ type, children }) };
  if (isMap(mark) && mark.type === "link") {
    const keys = Object.keys(mark).sort().join(",");
    let href = null;
    if (keys === "href,type") href = mark.href;
    else if (keys === "attrs,type" && isMap(mark.attrs) && Object.keys(mark.attrs).join(",") === "href") href = mark.attrs.href;
    if (typeof href === "string") return { key: `link ${href}`, rank: "link", wrap: (children) => ({ type: "link", href, children }) };
  }
  return null;
}

function group(items) {
  const out = [];
  let i = 0;
  while (i < items.length) {
    const item = items[i];
    if (item.node) {
      out.push(item.node);
      i += 1;
      continue;
    }
    const wrappers = item.marks.filter((mark) => mark.key !== "code")
      .sort((a, b) => WRAPPERS.indexOf(a.rank || a.key) - WRAPPERS.indexOf(b.rank || b.key));
    if (wrappers.length === 0) {
      if (item.marks.length === 0) {
        out.push({ type: "text", value: item.value });
        i += 1;
        continue;
      }
      let value = "";
      while (i < items.length && !items[i].node && items[i].marks.length === 1 && items[i].marks[0].key === "code") {
        value += items[i].value;
        i += 1;
      }
      out.push({ type: "code", value });
      continue;
    }
    let outer = null;
    let end = i;
    for (const mark of wrappers) {
      let j = i;
      while (j < items.length && !items[j].node && items[j].marks.some((m) => m.key === mark.key)) j += 1;
      if (j > end) {
        outer = mark;
        end = j;
      }
    }
    const inner = items.slice(i, end).map((run) => ({ value: run.value, marks: run.marks.filter((m) => m.key !== outer.key) }));
    out.push(outer.wrap(group(inner)));
    i = end;
  }
  return out;
}

function isMap(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

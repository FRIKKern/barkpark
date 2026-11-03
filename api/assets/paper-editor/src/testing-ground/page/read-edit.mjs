const CHROME = ".ProseMirror-trailingBreak, .ProseMirror-separator, .ProseMirror-gapcursor, .bp-paper-contextual-controls";
const PLUMBING = new Set(["contenteditable", "draggable", "spellcheck", "tabindex", "data-bp-id", "data-bp-type", "data-test-id", "data-tg-painted"]);

const text = (value) => value.replace(/\s+/g, " ");

function semanticTag(node) {
  if (node.tagName.toLowerCase() !== "span" || node.style.length !== 1) return null;
  const property = node.style.item(0);
  const value = node.style.getPropertyValue(property).trim();
  if (property === "font-weight" && value === "bold") return "strong";
  if (property === "font-style" && value === "italic") return "em";
  if (property === "text-decoration" && value === "underline") return "u";
  if (property === "text-decoration" && value === "line-through") return "s";
  return null;
}

function nodesOf(nodes) {
  const out = [];
  for (const node of nodes) {
    if (node.nodeType === 3) {
      const value = text(node.nodeValue);
      if (value && out.at(-1)?.text !== undefined) out.at(-1).text += value;
      else if (value) out.push({ text: value });
      continue;
    }
    if (node.nodeType !== 1 || node.matches(CHROME)) continue;
    const semantic = semanticTag(node);
    const tag = semantic || node.tagName.toLowerCase();
    const attrs = {};
    for (const { name, value } of [...node.attributes].sort((a, b) => a.name.localeCompare(b.name))) {
      if (name === "class" || PLUMBING.has(name) || (semantic && name === "style") || (tag === "a" && (name === "target" || name === "rel"))) continue;
      attrs[name] = text(value).trim();
    }
    out.push({
      tag,
      classes: [...node.classList].filter((name) => !name.startsWith("ProseMirror") && !name.startsWith("bp-canvas-")).sort(),
      attrs,
      children: nodesOf(node.childNodes),
    });
  }
  if (out[0]?.text) out[0].text = out[0].text.trimStart();
  if (out.at(-1)?.text) out.at(-1).text = out.at(-1).text.trimEnd();
  return out.filter((node) => node.text !== "");
}

export function blockShapes(root, blocks) {
  return [...root.children].filter((element) => !element.matches(CHROME)).map((element, at) => ({
    id: element.getAttribute("data-bp-id") || blocks[at]?.id || null,
    node: nodesOf([element])[0],
  }));
}

export function readEditDiff(reader, editor, blocks) {
  const read = blockShapes(reader, blocks);
  const edit = blockShapes(editor, blocks);
  const length = Math.max(read.length, edit.length);
  for (let at = 0; at < length; at++) {
    if (JSON.stringify(read[at]) === JSON.stringify(edit[at])) continue;
    return { at, id: edit[at]?.id || read[at]?.id || blocks[at]?.id || "unknown" };
  }
  return null;
}

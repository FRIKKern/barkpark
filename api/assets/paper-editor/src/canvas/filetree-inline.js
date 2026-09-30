import { wirePaintedTextInline } from "./painted-text-inline.js";

// filetree: each tree line and the legend edit where the reader paints them
// (task-bbfdcf4c80b8300d long tail). The paint is the reader's own server HTML
// (components.ex filetree_html/1): one white-space:pre <div> per stored line,
// whose text is that line verbatim (the annotation span holds the rest of the
// same line), then an optional legend row. Only the three read-only queries
// below touch reader classes (the parity gate allows exactly those). Each line row is a native host over its
// slice of `text`; lines are matched 1:1 or the rows stay panel-edited.
export function splitLines(text) {
  if (typeof text !== "string" || text === "") return [];
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

export function replaceLine(text, index, value) {
  const lines = String(text).split("\n");
  lines[index] = value;
  return lines.join("\n");
}

export function wireFiletreeInline(body, options) {
  return wirePaintedTextInline(body, options, (body, block) => {
    const tree = body.querySelector(".bp-filetree");
    if (!tree) return [];
    const lines = splitLines(block.text);
    const rows = [...tree.children].filter(el => el.tagName === "DIV" && !el.matches(".bp-filetree-legend"));
    const out = [];
    if (rows.length === lines.length && rows.every((row, i) => row.textContent === lines[i])) {
      rows.forEach((row, i) => out.push({
        el: row, item: block, index: null, key: "text", label: `File tree line ${i + 1}`, verbatim: true,
        read: b => splitLines(b.text)[i],
        write: (b, value) => ({ ...b, text: replaceLine(b.text, i, value) }),
      }));
    }
    const legend = tree.querySelector(":scope > .bp-filetree-legend");
    if (legend) out.push({ el: legend, item: block, index: null, key: "legend", label: "File tree legend" });
    return out;
  });
}

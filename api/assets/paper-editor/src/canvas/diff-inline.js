import { wirePaintedTextInline } from "./painted-text-inline.js";
import { splitLines, replaceLine } from "./filetree-inline.js";

// diff: each painted +/-/context/hunk row's text edits where the reader paints it
// (task-bbfdcf4c80b8300d long tail). The paint is the reader's own server HTML
// (components.ex diff_html/1): a dim tally row, then one row per displayed line,
// each "<two-char prefix><line text>", folded behind <details> past the budget.
// This module only MAPS rows back to stored lines, with the reader's own line
// classes (header lines paint nothing; "+++ b/<path>" paints a bold <path> row).
// Every row must match its stored line 1:1 or nothing is decorated. A row's text
// after its two-character marker is wrapped in a bare span so the marker stays
// generated; a path row edits the path after its stored "+++ b/". Only the one
// read-only query below touches a reader class (the parity gate allows exactly
// that).
const HEADERS = ["--- ", "diff --git ", "index "];

// Stored lines → the rows the reader paints, each with the line index, the
// stored prefix the row's text follows ("+", "-", " " or none) and the painted
// prefix ("" for a path row, whose stored prefix is "+++ " or "+++ b/").
export function diffRows(text) {
  const rows = [];
  splitLines(text).forEach((line, index) => {
    if (line.startsWith("+++ ")) {
      const stored = line.startsWith("+++ b/") ? "+++ b/" : "+++ ";
      rows.push({ index, stored, shown: "", text: line.slice(stored.length), painted: line.slice(stored.length) });
    } else if (HEADERS.some(h => line.startsWith(h))) {
      return;
    } else {
      const op = line.startsWith("@@") ? "" : ["+", "-", " "].includes(line[0]) ? line[0] : "";
      const shown = op === "+" ? "+ " : op === "-" ? "- " : "\u00a0\u00a0";
      rows.push({ index, stored: op, shown, text: line.slice(op.length), painted: shown + line.slice(op.length) });
    }
  });
  return rows;
}

export function wireDiffInline(body, options) {
  return wirePaintedTextInline(body, options, (body, block) => {
    const root = body.querySelector(".bp-diff");
    if (!root) return [];
    const painted = [...root.querySelectorAll(":scope > div, :scope > details > summary > div, :scope > details > div")]
      .filter(el => !el.classList.contains("text-dim"));
    const rows = diffRows(block.diff);
    if (painted.length !== rows.length || !rows.every((row, i) => painted[i].textContent === row.painted)) return [];
    return rows.flatMap((row, i) => {
      const el = painted[i];
      const node = el.firstChild;
      if (row.text === "" || el.childNodes.length !== 1 || node.nodeType !== 3) return [];
      const span = document.createElement("span");
      span.dataset.bpDiffText = "";
      (row.shown ? node.splitText(row.shown.length) : node).replaceWith(span);
      span.textContent = row.text;
      const stored = row.stored;
      return [{
        el: span, item: block, index: null, key: "diff", label: `Diff line ${row.index + 1}`, verbatim: true,
        read: b => {
          const line = splitLines(b.diff)[row.index];
          return typeof line === "string" && line.startsWith(stored) ? line.slice(stored.length) : undefined;
        },
        write: (b, value) => ({ ...b, diff: replaceLine(b.diff, row.index, stored + value) }),
      }];
    });
  });
}

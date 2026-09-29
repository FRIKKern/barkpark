import { wirePaintedTextInline } from "./painted-text-inline.js";

// notes: each row's label, lead and body edit where the reader paints them
// (task-bbfdcf4c80b8300d wave 2). The row is the reader's own server paint
// (components.ex note_item_html/1): a label span, then a description div holding
// an optional <b>lead</b>, one space, and the body text. Only the four read-only
// queries below touch reader classes (the parity gate allows exactly those).
// The body is a bare text node after the lead; it is wrapped in a span so it
// becomes its own native host. Only flat items are decorated: an item carrying
// slots or a `content` inline array paints from those, so a flat-key write
// would not reach the reader and the row stays panel-edited.
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);

export function wireNotesInline(body, options) {
  return wirePaintedTextInline(body, options, (body, block) => {
    const rows = Array.isArray(block.items) ? block.items : [];
    const grid = body.querySelector(".bp-notes");
    const cells = [...(grid?.children || [])].filter(el => el.matches(".bp-note"));
    if (rows.length !== cells.length) return [];
    return rows.flatMap((item, index) => {
      if (!object(item) || "slots" in item || "content" in item) return [];
      const cell = cells[index];
      const out = [];
      const label = cell.querySelector(":scope > .bp-note__k");
      if (label) out.push({ el: label, item, index, key: "label", label: "Note label" });
      const d = cell.querySelector(":scope > .bp-note__d");
      if (!d) return out;
      const lead = d.querySelector(":scope > b");
      if (lead) out.push({ el: lead, item, index, key: "lead", label: "Note lead" });
      // The body: the last child text node (after "<b>lead</b> " when a lead exists).
      const text = d.lastChild;
      if (text && text.nodeType === 3 && text.nodeValue !== "" && text !== lead) {
        const leading = lead ? text.nodeValue.match(/^ /)?.[0] || "" : "";
        // A bare span (no reader class): the canvas never produces reader markup.
        const span = document.createElement("span");
        span.dataset.bpNoteBody = "";
        if (leading) text.nodeValue = text.nodeValue.slice(leading.length);
        text.replaceWith(span);
        if (leading) span.before(document.createTextNode(leading));
        span.appendChild(text);
        out.push({ el: span, item, index, key: "text", label: "Note body" });
      }
      return out;
    });
  });
}

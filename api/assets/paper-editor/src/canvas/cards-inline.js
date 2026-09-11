import { wirePaintedTextInline } from "./painted-text-inline.js";

export function wireCardsInline(body, options) {
  return wirePaintedTextInline(body, options, (body, block) => {
    const rows = Array.isArray(block.items) ? block.items : [];
    const grid = body.querySelector(".bp-cards");
    const cells = [...(grid?.children || [])].filter(el => el.matches(".bp-card"));
    // The legacy renderer includes empty cards for malformed items. Preserve
    // their indices instead of shifting the next authored card onto that row.
    if (rows.length !== cells.length) return [];
    return rows.flatMap((item, index) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return [];
      return ["title", "text"].map(key => ({
        el: cells[index].querySelector(key === "title" ? ".bp-card__t" : ".bp-card__d"),
        item, index, key, label: key === "title" ? "Card title" : "Card body",
      }));
    });
  });
}

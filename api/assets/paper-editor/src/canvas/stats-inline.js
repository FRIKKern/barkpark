import { wirePaintedTextInline } from "./painted-text-inline.js";

export const isStatsType = type => ["stat", "stats", "stat-grid"].includes(type);
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);

export function wireStatsInline(body, options) {
  return wirePaintedTextInline(body, options, (body, block) => {
    const rows = block.type === "stat" ? [{ item: block, index: null }] :
      (Array.isArray(block.items) ? block.items : []).flatMap((item, index) => object(item) ? [{ item, index }] : []);
    const grid = body.querySelector(".bp-stats");
    const cells = block.type === "stat" ? [...body.querySelectorAll(":scope > .bp-stat")] :
      [...(grid?.children || [])].filter(el => el.matches(".bp-stat, .bp-dataviz--empty"));
    if (rows.length !== cells.length) return [];
    return rows.flatMap(({ item, index }, i) => {
      const cell = cells[i];
      if (item.locked === true || item.query != null || !cell.matches(".bp-stat")) return [];
      return ["value", "label"].flatMap(key => {
        if (typeof item[key] !== "string" && typeof item[key] !== "number") return [];
        let el = cell.querySelector(key === "value" ? ".bp-stat__v" : ".bp-stat__l");
        if (!el) return [];
        if (key === "value") {
          // Target the reader's bare value text in place. Denominator and unit
          // remain separate, protected reader spans.
          const textNode = el.firstChild;
          if (!textNode || textNode.nodeType !== 3) return [];
          return [{ el, textNode, item, index, key, label: "Stat value" }];
        }
        return [{ el, item, index, key, label: key === "value" ? "Stat value" : "Stat label" }];
      });
    });
  });
}

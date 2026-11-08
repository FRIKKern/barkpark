import { SLASH_ITEMS } from "../slash-menu.js";
import { CANVAS_SECTION_PRESETS } from "./section-presets.js";
import { CANVAS_SLASH_TYPES, CANVAS_COMPOUND_INSERTS } from "./slash-insert.js";

// The canvas slash menu's item list = SLASH_ITEMS narrowed to the insertable set.
// Computed ONCE at module load (SLASH_ITEMS is a static array; CANVAS_SLASH_TYPES is
// the allowlist from ./slash-insert.js). SlashMenu reads EXPECTED-group items fresh
// from the DOM on every open() on top of this base, so a bound-field pick still works
// — and an EXPECTED item whose type is NOT canvas-insertable (field-image /
// field-reference / composite) is filtered the same way at _chooseSlash (a defensive
// guard: such a pick is a no-op rather than a bad insert). Filtering via this
// allowlist (NOT by editing SLASH_ITEMS) keeps the per-block menu's items byte-intact.
// …plus the CANVAS-ONLY compound starters (CANVAS_COMPOUND_INSERTS): each becomes a
// "Starters" row carrying a `compound` marker _chooseSlash branches on. They are NOT
// added to SLASH_ITEMS itself — the per-block menu dispatches bp-slash-insert to the
// SERVER (default_block/2), which has no compound path; the canvas inserts the whole
// pre-composed subtree client-side (insertCompoundAtSelection). `type` mirrors the
// kind only for the row's dataset/filter haystack — it is NOT a portable-doc type,
// and _chooseSlash's CANVAS_SLASH_TYPES guard would no-op it defensively anyway.
// Canvas-only, like the checklist row: SLASH_ITEMS also feeds the per-block menu,
// whose server default_block/2 has no sheet clause. It rides WITH the other Visual
// rows: appended after the field rows it opened a second "Visual" heading
// (task-347897df84f96882).
const SHEET_SLASH_ITEM = { group: "Visual", type: "sheet", label: "Sheet", hint: "▦", desc: "embed a spreadsheet" };

function withSheetAfterVisual(items) {
  let last = -1;
  items.forEach((it, i) => { if (it.group === "Visual") last = i; });
  if (last < 0) return [...items, SHEET_SLASH_ITEM];
  return [...items.slice(0, last + 1), SHEET_SLASH_ITEM, ...items.slice(last + 1)];
}

// The chords _onKeyDown answers, named on the slash rows they match (task-2a659a853f02c2cc).
export const CANVAS_SLASH_CHORDS = { list: "Mod-Shift-8", checklist: "Mod-Shift-4", code: "Mod-Alt-c" };

export const CANVAS_SLASH_ITEMS = [
  ...withSheetAfterVisual(SLASH_ITEMS.filter((it) => CANVAS_SLASH_TYPES.has(it.type)).flatMap((it) => {
    if (it.type === "list") return [it, { group: "Text", type: "checklist", label: "Checklist", hint: "☑", desc: "to-do items" }];
    // One row per heading level, H1–H6 (owner ruling 2026-10-03 #63). Canvas-only:
    // the per-block menu's server default_block/2 inserts one default heading.
    if (it.type === "heading") {
      return [1, 2, 3, 4, 5, 6].map((level) => ({
        ...it,
        level,
        label: `Heading ${level}`,
        hint: `H${level}`,
        desc: level === 1 ? "page title size" : `level ${level} heading`,
      }));
    }
    return [it];
  })),
  ...CANVAS_COMPOUND_INSERTS.map((c) => ({
    group: "Starters",
    type: c.kind,
    compound: c.kind,
    label: c.label,
    hint: c.hint,
    desc: c.desc,
  })),
  // …and the CANVAS-ONLY section presets (CANVAS_SECTION_PRESETS): each becomes a
  // "Presets" row carrying a `preset` marker _chooseSlash branches on, the exact
  // Starters precedent one shape up — a preset inserts N TOP-LEVEL blocks, so it is
  // likewise absent from SLASH_ITEMS (the per-block menu dispatches bp-slash-insert to
  // default_block/2, which has no multi-block path) and lands client-side via
  // insertSectionPresetAtSelection. `type` mirrors the kind for the row's dataset /
  // filter haystack only — it is NOT a portable-doc type.
  ...CANVAS_SECTION_PRESETS.map((p) => ({
    group: "Presets",
    type: p.kind,
    preset: p.kind,
    label: p.label,
    hint: p.hint,
    desc: p.desc,
  })),
];

// embed-node.js — Phase-4 Stage S3.6: the canvas READ-ONLY ATOM node-views — the
// FIFTH (and LAST S3) node-view variant, after divider (atom), callout (content),
// code/diagram (attr-atom), and field (control-atom).
//
// Brings the `sheet` (a cached value-grid embed) and `embed` (a note transclusion,
// ![[note]]) blocks INTO the continuous canvas as READ-ONLY ATOM node-views. Both
// are REFERENCES, not editable text:
//   * a sheet is edited in its OWN surface (the Sheets plugin); its `snapshot` is a
//     cached projection the paper renders READ-ONLY in VIEW mode (compose.ex:302
//     reads `snapshot.rows`, no DB call). In the canvas (edit mode) we render a
//     read-only SUMMARY CHIP — the editor does not edit a sheet's data.
//   * an embed transcludes another note by `target`; the transclusion resolves at
//     VIEW render (walk.ex:421 `embed/2`, injecting `pal.embeds[target]`). The
//     editor does NOT resolve transclusions, so in the canvas we render a read-only
//     EMBED CHIP showing the target (mirroring walk.ex:437's unresolved fallback
//     marker `↪ <target>`).
//
// ── THE bpOpaque MECHANISM, MADE CANVAS-ELIGIBLE ──────────────────────────────
//
// These are the bpOpaque pattern (carry the WHOLE block verbatim, deep-cloned, emit
// ZERO value/content ops) but made CANVAS-ELIGIBLE (they no longer SPLIT a run) and
// given a dedicated READ-ONLY node-view instead of the generic opaque placeholder.
// UNLIKE the field control-atom (whose `value` IS edited and DOES emit a patch),
// these atoms NEVER emit a value/content patch — nothing is edited in the editor.
// They DO participate in STRUCTURAL ops (insert / remove / move by bpId) like any
// block, so Backspace deletes the atom → remove-block, and the block round-trips
// VERBATIM through the WHOLE block carried on `bpBlock` (NOT just a value).
//
// Why an ATOM (not a content / attr-atom / control-atom):
//   * group:"block"   — a top-level sibling of paragraph/heading/list/… inside the
//     ONE canvas document (doc content is block+), so it joins the run.
//   * atom:true       — NO PM-editable interior. There is nothing to type into; the
//     whole node is one indivisible read-only unit (caret-select + Backspace/Delete-
//     of-a-selected-atom come free, like the divider).
//   * content absent  — a pure leaf; it carries no PM children. UNLIKE code/field it
//     carries NO mutable attr the editor writes — the whole block rides VERBATIM on
//     `bpBlock` (the read-only atom holds the full block, config and all, NOT just a
//     value), so run-convert.js never emits a value/content patch for it.
//
// ── THE READ-ONLY REPRESENTATION (purely presentational; the block rides verbatim) ─
//
//   sheet → a SUMMARY CHIP: "Sheet · <ref> · <rows>×<cols>". We pick the chip over
//     a read-only table render because a sheet snapshot can carry merges / styles /
//     col_widths whose faithful read-only render risks mis-representing the data; the
//     BLOCK rides verbatim on bpBlock regardless, so the chip is the simpler choice
//     that cannot corrupt the block. Dimensions come from snapshot.rows (NxM).
//   embed → an EMBED CHIP: "↪ <target>" — the editor does not resolve transclusions,
//     so it shows the reference, mirroring walk.ex:437's unresolved fallback marker.
//
// bpId / bpType ride the node as data-* attrs — IDENTICAL id contract to BpAttrs /
// divider / callout / code / diagram / field. data-bp-id is what makes getJSON()
// preserve the id run-convert.js keys by. UNLIKE those, the WHOLE block also rides on
// `bpBlock` (a data-bp-block JSON attr) so the read-only atom round-trips the block
// VERBATIM (the bpOpaque verbatim-carry, but on a canvas-eligible node).
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node (it imports ONLY @tiptap/core and references `document` lazily, inside the
// NodeView factory, which never runs in the pure-Node smoke harness). So __smoke.mjs
// imports run-convert.js (which references the read-only node TYPES only, never the
// NodeView) without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS } from "../contract.js";

// The TipTap node NAMES are `bpSheet` / `bpEmbed` (the canvas naming convention, like
// bpCode/bpDiagram/bpField). The portable-doc `bpType` stays "sheet" / "embed"
// (run-convert.js maps a block.type → its node and back), so the persist contract is
// unchanged. There is NO StarterKit collision for either name (StarterKit ships no
// sheet/embed node), so NO StarterKit node is disabled for them.
export const BP_SHEET_NODE_NAME = "bpSheet";
export const BP_EMBED_NODE_NAME = "bpEmbed";

// The shared attribute set for both read-only atoms: the id stamp (bpId/bpType) plus
// the WHOLE block carried VERBATIM on `bpBlock`. UNLIKE the field control-atom, these
// nodes carry NO individually-mutable attr — the editor never writes any of them;
// the whole block round-trips on bpBlock (the bpOpaque verbatim-carry). data-bp-block
// holds the block as a JSON string so it survives the setContent->getJSON DOM
// round-trip (the live editor reads bpBlock off node.attrs in the doc JSON, not the
// DOM; the data-* form only matters for the schema-fallback round-trip).
function readOnlyAtomAttributes() {
  return {
    // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
    // setContent->getJSON round-trip (same role as every other canvas node).
    bpId: {
      default: null,
      parseHTML: (el) => el.getAttribute("data-bp-id"),
      renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
    },
    // bpType — the original portable-doc block kind ("sheet" | "embed"). Carried for
    // symmetry so runToOps can read the type back off node.attrs.
    bpType: {
      default: null,
      parseHTML: (el) => el.getAttribute("data-bp-type"),
      renderHTML: (attrs) =>
        attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
    },
    // bpBlock — the WHOLE block, carried VERBATIM (the bpOpaque verbatim-carry, but
    // on a canvas-eligible node). The read-only atom holds the FULL block (the
    // sheet's snapshot/ref, the embed's target) — NOT just a value — so the block
    // round-trips byte-identically with ZERO value/content ops. data-bp-block is the
    // JSON-string DOM carrier so the block survives the setContent->getJSON cycle.
    bpBlock: {
      default: null,
      parseHTML: (el) => {
        const raw = el.getAttribute("data-bp-block");
        if (raw == null || raw === "") return null;
        try {
          return JSON.parse(raw);
        } catch (_) {
          return null;
        }
      },
      renderHTML: (attrs) =>
        attrs.bpBlock != null
          ? { "data-bp-block": JSON.stringify(attrs.bpBlock) }
          : {},
    },
  };
}

// Compute the sheet summary chip's text from the carried block. Dimensions read off
// snapshot.rows (an N-row × M-col grid; M = the widest row). A sheet with no snapshot
// yet (freshly authored, never written through) reads as 0×0 — mirroring compose.ex's
// empty-grid fallback, so the chip never crashes on a snapshot-less block.
export function sheetChipLabel(block) {
  const ref = (block && block.ref) || "";
  const snap = (block && block.snapshot) || {};
  const rows = Array.isArray(snap.rows) ? snap.rows : [];
  const nRows = rows.length;
  const nCols = rows.reduce(
    (max, row) => Math.max(max, Array.isArray(row) ? row.length : 0),
    0,
  );
  const dims = `${nRows}×${nCols}`;
  return ref ? `Sheet · ${ref} · ${dims}` : `Sheet · ${dims}`;
}

// Compute the embed chip's text from the carried block — "↪ <target>", mirroring
// walk.ex:437's unresolved-embed fallback marker. A blank target renders just the
// arrow + "(untitled)" (no dangling trailing space); the editor never resolves the
// transclusion.
export function embedChipLabel(block) {
  const target = (block && block.target) || "";
  return target ? `↪ ${target}` : "↪ (untitled)";
}

// Build a read-only atom Node.create config. Both sheet + embed share the SAME shape
// (an atom carrying the whole block verbatim, a read-only chip node-view) and differ
// ONLY in the node name + the chip label function + a CSS class — so they are one
// factory, two registrations.
function readOnlyAtomNode({ name, bpType, chipLabel, className }) {
  return Node.create({
    name,

    // A top-level block sibling inside the one canvas document. group:"block" lets it
    // sit in the doc's `block+` content without any schema surgery on the doc node.
    group: "block",

    // An atom leaf: NO PM-editable interior, treated as a single read-only unit. There
    // is nothing to type into (the sheet is edited in its own surface; the embed
    // resolves at VIEW render), so PM's atom selection + Backspace/Delete-of-a-
    // selected-atom come free — the entire STRUCTURAL delete affordance v1 needs.
    atom: true,

    // The node is clickable/selectable so the caret can select the whole atom and
    // Backspace/Delete it → remove-block. PM only ever sees a NodeSelection of the
    // whole read-only block.
    selectable: true,

    // A read-only reference is a leaf container, not a textblock — defining keeps PM
    // from merging an adjacent textblock into it on backspace-at-edge.
    defining: true,

    addAttributes() {
      return readOnlyAtomAttributes();
    },

    // Parse a rendered chip back into the read-only node (so a setContent of the
    // node-view's own DOM round-trips). We match ONLY our own data-attributed wrapper
    // (a <div data-bp-type='sheet'> / <div data-bp-type='embed'>), reading the block
    // off data-bp-block; no bare-tag claim, so we never contend with another node's
    // parse rule.
    parseHTML() {
      return [{ tag: `div[data-bp-type='${bpType}']` }];
    },

    // A schema-level fallback render (used when NO node-view is mounted — e.g. the
    // pure-Node round-trip, or a non-editable export). The node-view (below) OVERRIDES
    // this in the live editor; this keeps the schema self-describing and gives
    // parseHTML a target. All data rides the typed attrs (via their renderHTML), so
    // the <div> body is empty. data-bp-type is the parse anchor.
    renderHTML({ HTMLAttributes }) {
      return [
        "div",
        mergeAttributes(HTMLAttributes, { "data-bp-type": bpType }),
      ];
    },

    // ── the NodeView: a READ-ONLY chip (NO edit surface) ────────────────────────
    //
    // Builds:
    //   <div class="bp-canvas-readonly <className>" data-bp-type="<bpType>"
    //        contenteditable="false">
    //     <span class="bp-canvas-readonly-chip">…chipLabel…</span>
    //
    // There is NO control, NO contentDOM, NO write-back path — nothing is edited, so
    // the atom NEVER emits a value/content patch. The whole block rides on bpBlock and
    // round-trips verbatim. PM never reads/writes inside this view:
    //   * contentEditable false  — the chrome is inert; the caret can SELECT the atom
    //     (selectable) but cannot type into it.
    //   * stopEvent: () => true  — PM never turns a click inside the chip into a
    //     transaction (a click selects the atom; it never mutates the doc).
    //   * ignoreMutation: () => true — PM never reads the chip's DOM mutations back
    //     into the document (there is no contentDOM on an atom).
    addNodeView() {
      return ({ node, getPos, editor }) => {
        const block = (node.attrs && node.attrs.bpBlock) || {};

        const dom = document.createElement("div");
        dom.className = `bp-canvas-readonly ${className}`;
        dom.setAttribute("data-bp-type", bpType);
        dom.setAttribute("contenteditable", "false");
        dom.setAttribute("data-test-id", `paper-readonly-${bpType}`);

        const chip = document.createElement("span");
        chip.className = "bp-canvas-readonly-chip";
        chip.textContent = chipLabel(block);
        dom.appendChild(chip);

        // pdd-t12c: keyboard + screen-reader parity — a tab stop with an accessible
        // name, a locked-state announcement, and Enter/Space → select (→ Backspace
        // deletes). The chip carries no interior focusable content, so the wrapper
        // tab stop is the ONLY non-mouse way to reach and delete it.
        wireAtomAccessibility(dom, {
          block,
          chipText: chipLabel(block),
          editor,
          getPos,
        });

        return {
          dom,
          // NO contentDOM — this is a read-only atom; there is no PM content hole and
          // no edit surface. The whole block lives on the bpBlock attr, untouched.

          // Re-render the chip when the node's attrs change (an echo / undo / a
          // server re-projection of the same block). Return false for a different node
          // type so PM rebuilds the view.
          update: (updated) => {
            if (updated.type.name !== name) return false;
            const b = (updated.attrs && updated.attrs.bpBlock) || {};
            chip.textContent = chipLabel(b);
            // Keep the accessible name + lock cue in lockstep with the re-rendered
            // chip (an echo/undo may change the block's locked state or content).
            dom.setAttribute("aria-label", atomAriaLabel(chipLabel(b), b));
            if (isBlockLocked(b)) dom.setAttribute("data-bp-locked", "true");
            else dom.removeAttribute("data-bp-locked");
            return true;
          },

          // PM must NOT turn a click/keystroke inside the chip into a transaction —
          // there is nothing to edit; a click only ever SELECTS the atom.
          stopEvent: () => true,

          // PM must NOT read the chip's DOM mutations back into the document (the chip
          // is outside any contentDOM; there is none on an atom).
          ignoreMutation: () => true,
        };
      };
    },
  });
}

// The two read-only atom nodes. `bpSheet` renders the sheet summary chip; `bpEmbed`
// renders the embed reference chip. Both carry the whole block verbatim on bpBlock and
// emit ZERO value/content ops.
export const Sheet = readOnlyAtomNode({
  name: BP_SHEET_NODE_NAME,
  bpType: "sheet",
  chipLabel: sheetChipLabel,
  className: "bp-canvas-sheet",
});

export const Embed = readOnlyAtomNode({
  name: BP_EMBED_NODE_NAME,
  bpType: "embed",
  chipLabel: embedChipLabel,
  className: "bp-canvas-embed",
});

// ── pdd-t8: the fleet SERVER-PAINTED read-only atom (`bpFleet`) ────────────────
//
// The component-fleet blocks (tasks / task-board / roadmap / cards / pipeline /
// notes / status-legend / form / asciicast / …) ride the canvas as READ-ONLY atoms
// — structurally IDENTICAL to sheet/embed (the WHOLE block rides verbatim on
// bpBlock; ZERO value/content ops; structural-only participation) — but with two
// differences: (1) ALL fleet kinds share the ONE `bpFleet` node (the specific kind
// rides bpType, like bpField multiplexes the field-* kinds), and (2) the node-view
// paints the reader's OWN pushed HTML rather than a client-computed chip.
//
// THE ONE-PRODUCER CONTRACT (rule 3 / D8): the editor NEVER hand-renders a fleet
// block. The node-view emits an EMPTY paint hole (`[data-bp-fleet-body]`, a
// `.bp-paper-surface` sink so the canonical stylesheet styles it identically to
// /papers) carrying the block id; the Studio hook (root.html.heex, `bp:block-html`)
// injects the server-rendered HTML keyed by `data-bp-fleet-id`. Until that HTML
// arrives the hole shows an honest loading CHIP (the block's human label) — never a
// blank strip (mirrors the loading/empty/error honesty of task_block_preview/1).
export const BP_FLEET_NODE_NAME = "bpFleet";

// The human label for the loading chip, derived from the fleet block's kind. A
// terse, capitalized noun ("Task board", "Cards", …) so the pre-paint fallback
// reads as an intentional placeholder, not a broken block. Unknown kinds fall back
// to the raw type so a never-seen fleet kind still shows SOMETHING legible.
const FLEET_KIND_LABELS = {
  tasks: "Task list",
  "task-list": "Task list",
  "task-detail": "Task detail",
  "task-board": "Task board",
  roadmap: "Roadmap",
  notes: "Notes",
  cards: "Cards",
  pipeline: "Pipeline",
  "status-legend": "Status legend",
  asciicast: "Terminal cast",
  form: "Form",
  questionnaire: "Questionnaire",
  // pd-ee-dataviz-editors: the 7 data-viz kinds ride the same bpFleet paint.
  stat: "Stat",
  stats: "Stats",
  "stat-grid": "Stat grid",
  heatmap: "Heatmap",
  chart: "Chart",
  duel: "Duel",
  lineage: "Lineage",
};

export function fleetChipLabel(block) {
  const type = (block && block.type) || "";
  return FLEET_KIND_LABELS[type] || (type ? `Block · ${type}` : "Block");
}

// ── pdd-t12c: one-surface a11y helpers (keyboard + screen-reader parity) ───────
//
// The read-only atoms (sheet / embed / fleet) are made keyboard-reachable (a
// tabindex tab stop) with an accessible NAME and a locked-state announcement, so
// every affordance the mouse has (select → Backspace-delete, hover cue) has a
// keyboard + screen-reader twin (rule 5: chrome around content, never a mode).
// These are PURE (no DOM) so they unit-test in node:vm — the node-view wiring that
// consumes them is manual-verify (needs a browser).

// A block is template-locked when it carries `locked === true` (the BpAttrs
// round-trip / server contract). Anything else (absent, false, truthy-but-not-true)
// is NOT locked — locks are an explicit, strict flag (pdd-t2).
export function isBlockLocked(block) {
  return !!(block && block.locked === true);
}

// The accessible NAME for a read-only atom: the same terse chip text the sighted
// user sees, plus an explicit locked-state clause when the block is a mandated
// template block. Screen-reader users hear WHAT the block is ("Task board") and,
// when it applies, that it is immovable ("locked, part of the document template")
// — mirroring the quiet hover cue (rule 5). `chipText` is whatever chip-label
// helper the atom uses (sheetChipLabel / embedChipLabel / fleetChipLabel), so the
// name is always in lockstep with the visible chip, never hand-mirrored.
export function atomAriaLabel(chipText, block) {
  const base = chipText || "Block";
  return isBlockLocked(block)
    ? `${base} — locked, part of the document template`
    : base;
}

// Enter / Space is the "select this block" activation on a keyboard-focused atom —
// it bridges DOM focus (Tab landed on the wrapper) to a ProseMirror NodeSelection,
// so the very next Backspace/Delete removes the atom (the same structural delete a
// mouse gets by click-selecting + Backspace). Space arrives as " " (or the legacy
// "Spacebar"); we accept both, matching field-node.js's placeholder activation.
export function isActivateKey(event) {
  if (!event) return false;
  return event.key === "Enter" || event.key === " " || event.key === "Spacebar";
}

// Bridge a keyboard-focused read-only atom to a ProseMirror NodeSelection so the
// next Backspace/Delete removes it. Best-effort + guarded: a detached test env, a
// stale getPos, or a mid-teardown editor must never throw out of a keydown.
function selectAtomNode(editor, getPos) {
  if (!editor || typeof getPos !== "function") return false;
  let pos;
  try {
    pos = getPos();
  } catch (_) {
    return false;
  }
  if (pos == null) return false;
  try {
    editor.chain().setNodeSelection(pos).focus().run();
    return true;
  } catch (_) {
    return false;
  }
}

// Apply the shared read-only-atom a11y contract to a node-view wrapper: a tab stop
// with a role + accessible name, a locked-state data hook + announcement, and an
// Enter/Space handler that selects the atom (→ Backspace deletes). The interior
// stays fully interactive (the island `stopEvent`/`ignoreMutation` contract lets
// painted links/inputs/scrollers work natively) — this only ADDS the keyboard path
// to the WHOLE-block affordance, and only when the wrapper itself is the key target
// (an interior link/input owns its own keys).
export function wireAtomAccessibility(dom, { block, chipText, editor, getPos }) {
  dom.setAttribute("tabindex", "0");
  dom.setAttribute("role", "group");
  dom.setAttribute("aria-label", atomAriaLabel(chipText, block));
  if (isBlockLocked(block)) dom.setAttribute("data-bp-locked", "true");

  dom.addEventListener("keydown", (e) => {
    // Only the wrapper itself — never an interior link / form control / scroller
    // the painted fleet HTML carries; those own their keystrokes.
    if (e.target !== dom) return;
    if (isActivateKey(e)) {
      e.preventDefault();
      selectAtomNode(editor, getPos);
    }
  });
}

// ── pd-ee-fleet-editors: the fleet EDIT ISLAND ────────────────────────────────
//
// A fleet block's AUTHORED content is editable in-canvas via a STRUCTURED ISLAND —
// the SAME contract as the code / task-list islands: a non-PM control tree kept
// invisible to ProseMirror by the node-view's stopEvent/ignoreMutation. The island is
// a SIBLING of the server-paint hole, so the `bp:block-html` hook's innerHTML write
// (into [data-bp-fleet-body]) never touches it. It mutates the carried `bpBlock` (the
// D8 single source): an edit → setNodeMarkup(bpBlock) → run-convert emits ONE
// patch-block{items|nodes|query} → the server REPAINTS the hole. The editor NEVER
// hand-renders fleet markup — the preview stays 100% server-painted (D8 / rule 3).

// Item-array editors: cards/notes/pipeline carry an authored array the author edits.
// Each descriptor names the block's AUTHORITATIVE array key — the exact key the reader
// emitter reads (render/components.ex: cards_html/notes_html read "items"; pipeline_html
// reads "nodes"), so an edit lands on the SAME key the server repaints from. Items are
// objects (card {title,text,tone}; note {label,lead,text}; pipeline node
// {kind,title,detail,files,source}), edited as structured JSON in ONE <textarea> island
// (the code-node textarea pattern): add / remove / reorder / edit are ALL expressed by
// editing text — NO edit-only <button> chrome (rule 6 / __atom_chrome guard).
const FLEET_ITEM_EDITORS = {
  cards: { arrayKey: "items" },
  notes: { arrayKey: "items" },
  pipeline: { arrayKey: "nodes" },
  // pd-ee-dataviz-editors: stats + its stat-grid alias carry an authored array of
  // stat-cell objects on `items` — the exact key stats_html reads (data_viz.ex).
  stats: { arrayKey: "items" },
  "stat-grid": { arrayKey: "items" },
};

// task-* kinds edit their QUERY (filter label) + optional id ref, not an item array.
const FLEET_QUERY_KINDS = new Set([
  "tasks",
  "task-list",
  "task-detail",
  "task-board",
  "roadmap",
]);

// pd-ee-dataviz-editors: CONFIG-OBJECT island kinds — the authored payload is a
// flat set of top-level keys on the block itself (not one array, not a query).
// Each descriptor enumerates EXACTLY the keys its reader emitter consumes
// (data_viz.ex: stat_html reads value/label/max/denom/spark; heatmap_html reads
// cells/rowLabels/colLabels/mode/marginals/values; chart_html reads series/axes —
// series/axes only in v1, the structured grid/series editors are deferred to
// pd-ee-dataviz-structured-editors). The island edits those keys as ONE JSON
// object; parse writes ONLY the enumerated keys (present → set, absent → delete),
// so id/type/anything-else can never be clobbered from the island.
const FLEET_CONFIG_EDITORS = {
  stat: { keys: ["value", "label", "max", "denom", "spark", "unit", "body", "source"] },
  heatmap: { keys: ["cells", "rowLabels", "colLabels", "mode", "marginals", "values"] },
  chart: { keys: ["series", "axes"] },
  // jdf-bl-historiene-renderer-reconciliation: the jarl figure family — the
  // whole authored payload (legends + rows / nodes + sourceDefault) edits as
  // ONE config island; data_viz.ex duel_html/lineage_html read exactly these.
  duel: { keys: ["legendA", "legendB", "sourceDefault", "rows"] },
  lineage: { keys: ["sourceDefault", "nodes"] },
};

// Is this fleet kind editable in-canvas? (status-legend has no authored data;
// asciicast/form/questionnaire are ref/complex config, left read-only in v1.)
export function fleetKindEditable(type) {
  return (
    !!FLEET_ITEM_EDITORS[type] ||
    !!FLEET_CONFIG_EDITORS[type] ||
    FLEET_QUERY_KINDS.has(type)
  );
}

// A canvas-editor local deep clone (the carried block is plain JSON, so a round-trip
// is exact and dependency-free — keeps embed-node.js importable in pure Node).
function cloneFleetBlock(b) {
  return b == null ? b : JSON.parse(JSON.stringify(b));
}

// ── the island's PURE serialize/parse pair (exported for the pure-Node tests) ──
//
// Serialize the current block → the island textarea's text representation.
// Three shapes, keyed by the block's kind:
//   * item kinds (cards/notes/pipeline/stats/stat-grid) → the authored array,
//     pretty JSON;
//   * config kinds (stat/heatmap/chart) → ONE object holding exactly the
//     descriptor keys PRESENT on the block, pretty JSON (absent keys stay absent —
//     never rendered as null);
//   * query kinds (task-*) → the query object, pretty JSON.
export function fleetEditorText(block) {
  const type = (block && block.type) || "";
  const itemEditor = FLEET_ITEM_EDITORS[type];
  if (itemEditor) {
    const arr = Array.isArray(block[itemEditor.arrayKey])
      ? block[itemEditor.arrayKey]
      : [];
    return JSON.stringify(arr, null, 2);
  }
  const configEditor = FLEET_CONFIG_EDITORS[type];
  if (configEditor) {
    const cfg = {};
    for (const key of configEditor.keys) {
      if (block && block[key] !== undefined) cfg[key] = block[key];
    }
    return JSON.stringify(cfg, null, 2);
  }
  // query kind
  const q =
    block && block.query && typeof block.query === "object" && !Array.isArray(block.query)
      ? block.query
      : {};
  return JSON.stringify(q, null, 2);
}

// Parse the island text → a mutated clone of `initialBlock`, or null when the text
// is not yet valid (a mid-edit JSON) — null means "don't commit, keep the last good
// state". Config kinds write ONLY the descriptor's enumerated keys: a key present
// in the parsed object is set, an enumerated key absent from it is DELETED (so
// removing `"max"` from the JSON really drops the stat's bar mode), and any
// non-enumerated key in the text is ignored — id/type can never be clobbered.
export function fleetEditorParse(initialBlock, text) {
  const type = (initialBlock && initialBlock.type) || "";
  const next = cloneFleetBlock(initialBlock) || { type };
  const itemEditor = FLEET_ITEM_EDITORS[type];
  if (itemEditor) {
    let arr;
    try {
      arr = JSON.parse(text);
    } catch (_) {
      return null;
    }
    if (!Array.isArray(arr)) return null;
    next[itemEditor.arrayKey] = arr;
    return next;
  }
  const configEditor = FLEET_CONFIG_EDITORS[type];
  if (configEditor) {
    let cfg;
    try {
      cfg = text.trim() === "" ? {} : JSON.parse(text);
    } catch (_) {
      return null;
    }
    if (cfg == null || typeof cfg !== "object" || Array.isArray(cfg)) return null;
    for (const key of configEditor.keys) {
      if (cfg[key] !== undefined) next[key] = cfg[key];
      else delete next[key];
    }
    return next;
  }
  // query kind
  let q;
  try {
    q = text.trim() === "" ? {} : JSON.parse(text);
  } catch (_) {
    return null;
  }
  if (q == null || typeof q !== "object" || Array.isArray(q)) return null;
  next.query = Object.keys(q).length ? q : null;
  return next;
}

// Build the fleet edit island DOM for a block. Returns { el, refresh, destroy }.
//   onEdit(nextBlock) — called (debounced) with a fresh mutated block clone; the
//     node-view writes it to attrs.bpBlock via setNodeMarkup, which the diff turns
//     into ONE patch-block{items|nodes|query} → server repaint.
//   isEditable() — gates the control (view mode leaves it read-only + hidden).
//
// ── ONE <textarea> island, NO buttons (rule 6 / __atom_chrome guard) ──────────
//
// The whole authored payload rides a SINGLE non-PM <textarea> — the exact code-node
// island shape (stopEvent/ignoreMutation come from the node-view, so PM never sees a
// keystroke). Editing text IS add / remove / reorder / edit: a new line adds an item,
// a deleted line removes one, moving lines reorders, typing edits — no edit-only
// <button> chrome. On `input` (debounced) the text is PARSED back to the block; a
// parse that fails (a half-typed JSON) simply doesn't commit, so the last valid state
// stands. Item kinds (cards/pipeline) edit the array as pretty JSON; notes edit as
// newline-separated lines; task-* kinds edit `query.label` + `query.id` as one small
// JSON object. The DOM is built lazily inside the node-view factory (references
// `document`), so this is never called in the pure-Node harness.
function buildFleetEditor(initialBlock, { onEdit, isEditable }) {
  const type = (initialBlock && initialBlock.type) || "";
  const itemEditor = FLEET_ITEM_EDITORS[type];
  const configEditor = FLEET_CONFIG_EDITORS[type];
  const el = document.createElement("div");
  el.className = "bp-fleet-edit";
  el.setAttribute("contenteditable", "false");
  el.setAttribute("data-test-id", `paper-fleet-editor-${type}`);
  el.style.marginTop = "0.5rem";
  el.style.paddingTop = "0.5rem";
  el.style.borderTop = "1px dashed currentColor";
  el.style.fontSize = "0.85rem";

  const hint = document.createElement("div");
  hint.style.opacity = "0.65";
  hint.style.marginBottom = "0.25rem";
  hint.textContent = itemEditor
    ? "Edit items as JSON — add / remove / reorder rows"
    : configEditor
      ? `Edit config as JSON — keys: ${configEditor.keys.join(", ")}`
      : "Edit query — filter label + task id";
  el.appendChild(hint);

  const area = document.createElement("textarea");
  area.className = "bp-fleet-edit-area";
  area.setAttribute("spellcheck", "false");
  area.setAttribute("aria-label", `edit ${type} content`);
  area.rows = 6;
  area.style.width = "100%";
  area.style.fontFamily = "var(--paper-font-mono, monospace)";
  el.appendChild(area);

  // Serialize / parse delegate to the module-level PURE pair (fleetEditorText /
  // fleetEditorParse — exported so __dataviz.test.mjs exercises the exact island
  // logic in pure Node). A block echoed on refresh keeps its type, so the
  // per-kind branch never shifts mid-life.
  function toText(block) {
    return fleetEditorText({ type, ...(block || {}) });
  }

  function toBlock(text) {
    return fleetEditorParse(initialBlock || { type }, text);
  }

  let textTimer = null;
  const commitText = (text = area.value) => {
    const next = toBlock(text);
    if (next != null) onEdit(next);
  };
  const onInput = () => {
    if (!isEditable()) return;
    if (textTimer) clearTimeout(textTimer);
    const text = area.value;
    textTimer = setTimeout(() => {
      textTimer = null;
      commitText(text);
    }, DEBOUNCE_MS);
  };
  area.addEventListener("input", onInput);

  const paint = (block) => {
    area.readOnly = !isEditable();
    // Never clobber the field while the user is actively typing in it.
    if (document.activeElement !== area) {
      const text = toText(block || {});
      if (area.value !== text) area.value = text;
    }
  };
  paint(initialBlock || {});

  return {
    el,
    // Re-seed from an echo / undo. Skips while the textarea is focused (mid-edit) via
    // the paint() activeElement guard; `focusInside` is accepted for symmetry with the
    // other islands but paint() already protects the active field.
    refresh: (block) => {
      paint(block || {});
    },
    flush: () => {
      if (!textTimer) return;
      clearTimeout(textTimer);
      textTimer = null;
      commitText();
    },
    destroy: () => {
      if (textTimer) clearTimeout(textTimer);
      area.removeEventListener("input", onInput);
    },
  };
}

// The `bpFleet` node. Shares the read-only atom SCHEMA (atom, group:"block",
// selectable, defining, the id/type/bpBlock attrs, the data-bp-type parse anchor)
// but overrides the NodeView to render a server-paint hole instead of a chip. The
// schema object loads in pure Node (the NodeView factory references `document`
// lazily), so __smoke.mjs / __fleet.test.mjs import run-convert.js without a browser.
export const Fleet = Node.create({
  name: BP_FLEET_NODE_NAME,
  group: "block",
  atom: true,
  selectable: true,
  defining: true,

  addAttributes() {
    return readOnlyAtomAttributes();
  },

  // Parse ONLY our own data-attributed wrapper (a <div data-bp-fleet='true'>),
  // reading the whole block off data-bp-block. No bare-tag claim, so we never
  // contend with sheet/embed (which anchor on their own data-bp-type) or any other
  // node's parse rule.
  parseHTML() {
    return [{ tag: "div[data-bp-fleet='true']" }];
  },

  // Schema-level fallback render (no node-view mounted — pure-Node round-trip /
  // non-editable export). All data rides the typed attrs; data-bp-fleet is the
  // parse anchor.
  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-bp-fleet": "true" })];
  },

  // The NodeView: a read-only paint hole. Builds
  //   <div class="bp-canvas-readonly" data-bp-fleet-id="<id>" data-bp-type="<type>"
  //        contenteditable="false">
  //     <div class="bp-paper-surface" data-bp-fleet-body>
  //       <div class="bp-canvas-readonly-chip">…loading label…</div>
  //   The Studio hook replaces the hole's contents with the server HTML on
  //   bp:block-html. contentEditable false + stopEvent/ignoreMutation so PM never
  //   turns a click (or the hook's own innerHTML write) into a transaction or reads
  //   it back into the document.
  addNodeView() {
    return ({ node, getPos, editor }) => {
      const block = (node.attrs && node.attrs.bpBlock) || {};
      const bpType = (node.attrs && node.attrs.bpType) || (block && block.type) || "";
      const bpId = (node.attrs && node.attrs.bpId) || "";

      const dom = document.createElement("div");
      dom.className = "bp-canvas-readonly bp-canvas-fleet";
      dom.setAttribute("data-bp-type", bpType);
      dom.setAttribute("data-bp-fleet-id", bpId);
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", `paper-fleet-${bpType}`);

      const body = document.createElement("div");
      // The `.bp-paper-surface` sink: the injected reader HTML is styled by the ONE
      // canonical stylesheet exactly as /papers renders it (D8 — no hand-mirrored
      // markup, no editor-only CSS).
      body.className = "bp-paper-surface";
      body.setAttribute("data-bp-fleet-body", "");

      const chip = document.createElement("div");
      chip.className = "bp-canvas-readonly-chip";
      chip.textContent = fleetChipLabel(block);
      body.appendChild(chip);
      dom.appendChild(body);

      // pd-ee-fleet-editors: the structured EDIT ISLAND, a SIBLING of the paint hole
      // (so the server hook's innerHTML write into [data-bp-fleet-body] never touches
      // it). Built ONLY for an editable fleet kind (cards/notes/pipeline items, task-*
      // query) that is NOT template-locked; other kinds stay purely read-only. An edit
      // writes the mutated block to attrs.bpBlock via setNodeMarkup → run-convert emits
      // ONE patch-block → the server repaints the hole (D8: still 100% server-painted).
      // The editor is revealed on hover / focus (resting-chrome, editability-gated),
      // exactly like the code / task-list config islands.
      const isEditableKind = fleetKindEditable(bpType) && !isBlockLocked(block);
      let fleetEditor = null;
      let hovered = false;
      let focused = false;
      const syncReveal = () => {
        if (!fleetEditor) return;
        fleetEditor.el.style.display =
          editor.isEditable && (hovered || focused) ? "" : "none";
      };
      const onEnter = () => {
        hovered = true;
        syncReveal();
      };
      const onLeave = () => {
        hovered = false;
        syncReveal();
      };
      const onFocusIn = () => {
        focused = true;
        syncReveal();
      };
      const onFocusOut = (e) => {
        // Focus-within guard (code/task-list pattern): keep revealed while focus only
        // MOVES within the atom (relatedTarget still inside).
        if (e && e.relatedTarget && dom.contains(e.relatedTarget)) return;
        focused = false;
        syncReveal();
      };
      if (isEditableKind) {
        fleetEditor = buildFleetEditor(block, {
          isEditable: () => editor.isEditable,
          onEdit: (nextBlock) => {
            if (!editor.isEditable) return;
            if (typeof getPos !== "function") return;
            const pos = getPos();
            if (pos == null) return;
            const cur = editor.state.doc.nodeAt(pos);
            if (!cur) return;
            editor
              .chain()
              .command(({ tr }) => {
                tr.setNodeMarkup(pos, undefined, {
                  ...cur.attrs,
                  bpBlock: nextBlock,
                });
                return true;
              })
              .run();
          },
        });
        dom.appendChild(fleetEditor.el);
        dom.addEventListener("mouseenter", onEnter);
        dom.addEventListener("mouseleave", onLeave);
        dom.addEventListener("focusin", onFocusIn);
        dom.addEventListener("focusout", onFocusOut);
        syncReveal();
      }
      const flushFleetEditor = () => {
        if (fleetEditor) fleetEditor.flush();
      };
      dom.addEventListener("bp-flush-node", flushFleetEditor);

      // pdd-t12c: keyboard + screen-reader parity — a tab stop with the fleet block's
      // human name + locked-state announcement, and Enter/Space → select (→ Backspace
      // deletes). The painted reader HTML keeps ALL its own interactivity: interior
      // links/inputs/scrollers stay native (the island stopEvent/ignoreMutation
      // contract below never swallows them), and the aria-label names the WHOLE block
      // for a screen reader landing on the atom. `e.target !== dom` guards so a
      // keystroke inside a painted form control is never hijacked for atom selection.
      wireAtomAccessibility(dom, {
        block,
        chipText: fleetChipLabel(block),
        editor,
        getPos,
      });

      return {
        dom,
        // KEEP the existing DOM across attr updates (echo / undo): returning true
        // preserves the paint hole AND whatever server HTML the hook already
        // injected into it — a re-created node-view would flash back to the chip.
        // A fresh paint for changed content arrives on the hook's own channel
        // (bp:block-html, keyed by the stable data-bp-fleet-id), never from PM.
        update: (updated) => {
          if (updated.type.name !== BP_FLEET_NODE_NAME) return false;
          // Keep the accessible name + lock cue in lockstep with the carried block
          // (an echo/undo could change locked state) WITHOUT touching the painted
          // body — the aria lives on the wrapper, so the server HTML is untouched.
          const b = (updated.attrs && updated.attrs.bpBlock) || {};
          dom.setAttribute("aria-label", atomAriaLabel(fleetChipLabel(b), b));
          if (isBlockLocked(b)) dom.setAttribute("data-bp-locked", "true");
          else dom.removeAttribute("data-bp-locked");
          // Re-seed the editor from an echo / undo WITHOUT clobbering an in-progress
          // edit (refresh no-ops when the block is content-equal or focus is inside).
          if (fleetEditor) fleetEditor.refresh(b, focused);
          syncReveal();
          return true;
        },
        // PM must NOT turn a click inside the painted body into a transaction — a
        // click only ever SELECTS the atom.
        stopEvent: () => true,
        // PM must NOT read the body's DOM mutations back into the document — the
        // hook mutates the paint hole's innerHTML directly and PM must ignore it.
        ignoreMutation: () => true,
        destroy: () => {
          dom.removeEventListener("bp-flush-node", flushFleetEditor);
          if (fleetEditor) {
            fleetEditor.destroy();
            dom.removeEventListener("mouseenter", onEnter);
            dom.removeEventListener("mouseleave", onLeave);
            dom.removeEventListener("focusin", onFocusIn);
            dom.removeEventListener("focusout", onFocusOut);
          }
        },
      };
    };
  },
});

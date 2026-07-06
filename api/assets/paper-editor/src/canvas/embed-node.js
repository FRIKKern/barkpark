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
      return ({ node }) => {
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
};

export function fleetChipLabel(block) {
  const type = (block && block.type) || "";
  return FLEET_KIND_LABELS[type] || (type ? `Block · ${type}` : "Block");
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
    return ({ node }) => {
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

      return {
        dom,
        // KEEP the existing DOM across attr updates (echo / undo): returning true
        // preserves the paint hole AND whatever server HTML the hook already
        // injected into it — a re-created node-view would flash back to the chip.
        // A fresh paint for changed content arrives on the hook's own channel
        // (bp:block-html, keyed by the stable data-bp-fleet-id), never from PM.
        update: (updated) => {
          if (updated.type.name !== BP_FLEET_NODE_NAME) return false;
          return true;
        },
        // PM must NOT turn a click inside the painted body into a transaction — a
        // click only ever SELECTS the atom.
        stopEvent: () => true,
        // PM must NOT read the body's DOM mutations back into the document — the
        // hook mutates the paint hole's innerHTML directly and PM must ignore it.
        ignoreMutation: () => true,
      };
    };
  },
});

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
import { isStatsType, wireStatsInline } from "./stats-inline.js";
import { canvasScope, coercePickerValue } from "./field-node.js";
import { wireCardsInline } from "./cards-inline.js";

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

// ── pd-ee-sheet-embed-retarget: the REFERENCE retarget affordance ─────────────
//
// A read-only atom has exactly ONE thing about it an author authors: the REFERENCE.
// For a `sheet` that is `ref` (a sheet document id); for an `embed` it is `target`
// (the transcluded note's TITLE). Everything else — a sheet's cells, an embed's
// transcluded prose — belongs to the referenced document and stays out of reach here
// (the read-only-atom contract above is unchanged for all of it). So each atom gains
// EXACTLY one control: the EXISTING <bp-reference-picker> Web Component, scoped by
// `ref-type`. There is no second picker and no bespoke search — the same element the
// field control-atom mounts for field-reference (see buildPickerNodeView in
// field-node.js), so a scope/permission change lands on every surface at once.
//
// THE PERMISSION BOUNDARY. The picker browses `/v1/data/search/<dataset>` with
// `credentials: "same-origin"` — the server decides what the acting member may READ,
// and the client asserts nothing. Retargeting writes ONLY the paper's own block; it
// issues no write to the referenced document and confers no grant on it. An embed's
// target is resolved LATER, at VIEW render (Papers.resolve_embeds_in_blocks →
// walk.ex embed/2 reads `pal.embeds[target]`), against the READER's own authority —
// so picking a target can never widen anyone's read: a reader who cannot read the
// target still lands on the unresolved fallback marker. Where the host denies dataset
// browse (`data-picker-browse="false"` — the item-share edit grant, which authorizes
// this ONE paper, not discovery) no picker is mounted at all, exactly as the field
// picker behaves. A template-locked block and a non-editable editor likewise mount no
// control.
//
// WHERE EMBED DIVERGES FROM SHEET — three seams, each load-bearing:
//
//  1. VALUE SPACE. The picker's `bp-change` detail.value is a canonical DOC ID
//     (bp-reference-picker.js `_select`). A sheet's `ref` IS a doc id, so it is
//     forwarded unchanged. An embed's `target` is a human TITLE — resolution runs
//     through `Content.resolve_doc_by_title_or_alias`, the same authority a wikilink
//     uses — so an id written there would resolve to NOTHING. The embed adapter
//     therefore commits the picked document's TITLE, read off the pill the picker
//     renders synchronously before it emits.
//  2. FREE TEXT. `![[Some Note]]` is the shorthand authors already type, and the
//     picker must not be a worse door than markdown: Enter in the typeahead commits
//     the typed string verbatim as the target, resolved or not. A sheet ref has no
//     such shorthand and takes picked ids only.
//  3. THE SNAPSHOT CLEAR. A sheet carries `snapshot`, a cached projection of the OLD
//     sheet, which a retarget must explicitly null or the old grid renders under the
//     new name. An embed caches NOTHING — its transclusion is resolved fresh on every
//     render — so its patch carries `target` alone. Mirroring the sheet's
//     `snapshot: null` here would write a key the embed block does not own.
//
// NOTHING IS VALIDATED ON THE WAY OUT. A target naming nothing must still SAVE: notes
// get renamed, and a cross-dataset draft points at something that does not exist yet.
// The reader already paints an unresolved-transclusion fallback for it (walk.ex
// embed/2's unresolved branch), so a validate-on-save would only make those workflows
// impossible. CLEARING to "" is the one refusal, and it is not validation:
// a blank target leaves a chip with no identity and no route back to the note it
// named — deleting the block is the affordance for "I do not want this".

// Per-bpType retarget descriptor. The node-view is ONE factory, so the two atoms'
// differences live here as data rather than as branches in the mount path.
const RETARGET_SPECS = {
  sheet: {
    // The carried block key this control authors.
    key: "ref",
    // The picker's `ref-type` — the document type its browse is scoped to.
    refType: "sheet",
    testId: "paper-sheet-retarget",
    // A sheet's ref lives in the picker's OWN value space (a doc id), so the picker
    // can be seeded with it and kept in sync with echoes/undo.
    seedFromBlock: true,
    // Keys the retarget must CLEAR because they cache the OLD reference.
    clearKeys: ["snapshot"],
    freeText: false,
    fromPick: (detail) => coercePickerValue(detail),
  },
  embed: {
    key: "target",
    // An embed target resolves against PAPERS (Content.Papers @paper_type "paper"),
    // by title-or-alias.
    refType: "paper",
    // The word order is NOT cosmetic. canvas_reader_parity_gate_test.exs §3 forbids
    // the reader's own transclusion class literal (chip_carry/0's `embed` sig)
    // ANYWHERE in the canvas JS — a substring check over the whole concatenated
    // blob — so the editor can never grow a second, hand-written producer for it.
    // The obvious id would have contained that literal as a substring and reddened a
    // REQUIRED gate for a test hook. Same family as the sheet's id, ordered so the
    // forbidden substring cannot appear.
    testId: "paper-retarget-embed",
    // A TITLE is not a doc id: seeding the picker with one would make it fetch a
    // document whose id is a title and render a bogus pill. The chip beside it already
    // says what this block transcludes, so the picker stays a pure "change it to…"
    // door.
    seedFromBlock: false,
    clearKeys: [],
    freeText: true,
    fromPick: (detail, picker) => pickerSelectedTitle(picker, coercePickerValue(detail)),
  },
};

// The TITLE of the document the picker just selected. bp-reference-picker renders its
// selected pill (`.ref-selected-title`) inside `_select` BEFORE it emits bp-change, so
// the title is in the DOM by the time this runs. Falls back to the emitted value (the
// doc id) when the pill is absent or still resolving — an unresolved target SAVES, so
// a fallback is a worse target, never a dropped edit.
function pickerSelectedTitle(picker, fallbackValue) {
  const el = picker && picker.querySelector && picker.querySelector(".ref-selected-title");
  const title = el ? String(el.textContent || "").trim() : "";
  return title || fallbackValue;
}

// The carried block with a NEW reference and the OLD reference's cached keys dropped.
// Pure — it never mutates the block it is given (the node's attr object is shared with
// the PM document; mutating it in place would edit history).
export function atomBlockRetargeted(block, spec, nextValue) {
  const next = { ...(block || {}) };
  next[spec.key] = nextValue;
  for (const key of spec.clearKeys) delete next[key];
  return next;
}

// Does this atom offer a retarget control at all? Four independent nos: an atom with
// no retargetable reference, a read-only editor, a template-locked block, and a host
// that denies dataset browse. Exported so a test can assert each no separately rather
// than inferring the absence from one mounted case.
export function atomRetargetAllowed({ bpType, editor, block, scope }) {
  if (!Object.prototype.hasOwnProperty.call(RETARGET_SPECS, bpType)) return false;
  if (!editor || editor.isEditable !== true) return false;
  if (isBlockLocked(block)) return false;
  if (!scope || scope.pickerBrowse === false) return false;
  return true;
}

// Mount the retarget picker into an atom's chrome and wire its commit. Returns null
// when the affordance is not offered (see atomRetargetAllowed), and otherwise
// { picker, paint, destroy } so the node-view can keep it in lockstep with echoes /
// undo and tear its listeners down.
function mountAtomRetarget({ dom, node, editor, getPos, bpType }) {
  const block = (node && node.attrs && node.attrs.bpBlock) || {};
  const scope = canvasScope(editor);
  if (!atomRetargetAllowed({ bpType, editor, block, scope })) return null;
  const spec = RETARGET_SPECS[bpType];

  // The EXISTING reference picker — same element, same attrs, same events as the
  // field control-atom's picker branch. `ref-type` narrows the browse.
  const picker = document.createElement("bp-reference-picker");
  picker.className = "bp-canvas-readonly-retarget";
  picker.setAttribute("contenteditable", "false");
  picker.setAttribute("data-test-id", spec.testId);
  picker.setAttribute("ref-type", spec.refType);
  const seed = spec.seedFromBlock ? block[spec.key] : "";
  picker.setAttribute("value", seed == null ? "" : String(seed));
  if (scope.dataset) picker.setAttribute("dataset", scope.dataset);
  if (scope.scopePrefix) picker.setAttribute("scope-prefix", scope.scopePrefix);
  dom.appendChild(picker);

  // Write the new reference back onto the carried block. setNodeMarkup changes ONLY
  // the bpBlock attr (the node stays the same atom in the same place), so onUpdate ->
  // run-convert emits ONE patch-block. Undebounced, like the field picker: a picker
  // fires on a discrete selection, not per keystroke.
  const commit = (nextValue) => {
    if (!editor.isEditable) return;
    if (typeof getPos !== "function") return;
    // A CLEAR is not a retarget — see the note above. Unresolved is fine; blank is not.
    if (!nextValue) return;
    const pos = getPos();
    if (pos == null) return;
    const cur = editor.state.doc.nodeAt(pos);
    if (!cur) return;
    const curBlock = (cur.attrs && cur.attrs.bpBlock) || {};
    if (curBlock[spec.key] === nextValue) return; // same target — emit nothing
    editor
      .chain()
      .command(({ tr }) => {
        tr.setNodeMarkup(pos, undefined, {
          ...cur.attrs,
          bpBlock: atomBlockRetargeted(curBlock, spec, nextValue),
        });
        return true;
      })
      .run();
  };

  const onChange = (e) => commit(spec.fromPick(e.detail, picker));
  picker.addEventListener("bp-change", onChange);

  // FREE TEXT (embed only): Enter in the picker's typeahead commits what was typed,
  // verbatim. The atom's own keydown handler ignores this (wireAtomAccessibility bails
  // unless e.target IS the wrapper), but the event is stopped anyway so no ancestor
  // reads a commit as an atom activation.
  const onKeydown = (e) => {
    if (e.key !== "Enter") return;
    const input = e.target;
    if (!input || !input.classList || !input.classList.contains("bp-ref-search-input")) return;
    e.preventDefault();
    e.stopPropagation();
    commit(String(input.value == null ? "" : input.value).trim());
  };
  if (spec.freeText) picker.addEventListener("keydown", onKeydown);

  return {
    picker,
    // Keep the seeded picker in sync with an EXTERNAL attr change (an echo, an undo).
    // The WC exposes a `value` property setter that re-renders its pill and does NOT
    // re-emit bp-change; only write when it differs so a mid-interaction picker is
    // never re-rendered under the user. A picker that was never seeded from the block
    // (embed: a title is not an id) has nothing to sync.
    paint: (b) => {
      if (!spec.seedFromBlock) return;
      const v = b && b[spec.key];
      const str = v == null ? "" : String(v);
      if (picker.value !== str) picker.value = str;
    },
    destroy: () => {
      picker.removeEventListener("bp-change", onChange);
      if (spec.freeText) picker.removeEventListener("keydown", onKeydown);
    },
  };
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

        // pd-ee-sheet-embed-retarget: the atom's ONE control — the existing reference
        // picker, scoped by ref-type to the documents this atom's reference names
        // (sheet → sheets, embed → papers). null wherever the affordance is not
        // offered (see atomRetargetAllowed).
        const retarget = mountAtomRetarget({ dom, node, editor, getPos, bpType });

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
            if (retarget) retarget.paint(b);
            return true;
          },

          // PM must NOT turn a click/keystroke inside the chip into a transaction —
          // there is nothing to edit; a click only ever SELECTS the atom.
          stopEvent: () => true,

          // PM must NOT read the chip's DOM mutations back into the document (the chip
          // is outside any contentDOM; there is none on an atom).
          ignoreMutation: () => true,

          destroy: () => {
            if (retarget) retarget.destroy();
          },
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

// The public reader explicitly retains its legacy palette when no article
// style is authored. Do not introduce an article styling island inside it.
// Unmarked standalone embedders and Studio retain their existing default.
export function readerPaintClass(editor) {
  return editor.options.element.closest("[data-paper-palette]")?.getAttribute("data-paper-palette") === "legacy"
    ? "" : "bp-paper-surface";
}

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
  // jdf-bl-historiene-renderer-reconciliation: the jarl figure family. The
  // SCALAR config (legends + the fallback kilde) edits here; the per-datum
  // ARRAY (duel `rows` / lineage `nodes`) is NOT an enumerated key — it belongs
  // to the STRUCTURED grid below (FLEET_DATUM_EDITORS), so the two editors never
  // write the same key and a stale textarea can never revert a row edit. A key
  // the descriptor does not enumerate is left untouched by fleetEditorParse, so
  // rows/nodes ride every config commit verbatim.
  duel: { keys: ["legendA", "legendB", "sourceDefault"] },
  lineage: { keys: ["sourceDefault"] },
};

// ── the STRUCTURED per-datum editor (duel rows / lineage nodes) ───────────────
//
// The config island above edits a block's SCALARS as JSON. The jarl figure family
// also carries an ARRAY of authored DATA — a duel row, a lineage stop — each with
// its own `source` (the per-datum «kilde» data_viz.ex's figure_refs/3 reads, falling
// back to `sourceDefault`). Hand-editing that array as raw JSON is the thing this
// editor replaces: each datum gets one labelled <input> per field, so add / edit /
// reorder / remove are all done on real controls instead of inside a JSON blob.
//
// NO <button> anywhere (rule 6 / __atom_chrome guard — this file is on
// LEAF_ATOM_FILES). The four operations ride native form controls instead:
//   * EDIT    — type into the field's <input>.
//   * ADD     — one always-present TRAILING BLANK datum; typing into any of its
//               fields appends a new datum (the resting-scaffold pattern).
//   * REMOVE  — clear every field of a datum and it drops out of the array.
//   * REORDER — each datum carries a position <select> (1…N); picking a new
//               position moves it.
//
// Field lists are the reader's own contract, in reader order: data_viz.ex
// duel_row_html/1 reads label/valueA/valueB/delta/unit and lineage_node_html/1
// reads overline/title/value/unit/body — plus `source` on both, read by
// figure_refs/3. A field this editor does not name is never touched.
const FLEET_DATUM_EDITORS = {
  duel: {
    arrayKey: "rows",
    itemNoun: "row",
    fields: [
      { key: "label", label: "Label" },
      { key: "valueA", label: "Value A" },
      { key: "valueB", label: "Value B" },
      { key: "delta", label: "Delta" },
      { key: "unit", label: "Unit" },
      { key: "source", label: "Kilde" },
    ],
  },
  lineage: {
    arrayKey: "nodes",
    itemNoun: "stop",
    fields: [
      { key: "overline", label: "Overline" },
      { key: "title", label: "Title" },
      { key: "value", label: "Value" },
      { key: "unit", label: "Unit" },
      { key: "body", label: "Body" },
      { key: "source", label: "Kilde" },
    ],
  },
};

// The descriptor for a block kind, or null when the kind carries no per-datum array.
export function datumEditorSpec(type) {
  return FLEET_DATUM_EDITORS[type] || null;
}

function isPlainObject(v) {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

// The CURRENT data of a block's per-datum array: a fresh array of the authored
// objects, or null when this kind has no datum editor OR the array holds something
// the structured grid cannot represent (a string, a nested array, a null). Refusing
// rather than coercing is what keeps the editor LOSSLESS: a payload it cannot show
// faithfully is left to the JSON escape hatch instead of being silently rewritten.
export function datumEditorRows(block) {
  const spec = datumEditorSpec((block && block.type) || "");
  if (!spec) return null;
  const raw = block && block[spec.arrayKey];
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) return null;
  if (!raw.every(isPlainObject)) return null;
  return raw.map((d) => ({ ...d }));
}

// A datum is EMPTY when not one of its own keys holds a non-blank scalar — the
// predicate behind remove-by-clearing. Checks the datum's OWN keys, not just the
// named fields, so a datum carrying only an unnamed key (a `tone`, say) is never
// dropped out from under the author.
function datumIsEmpty(datum) {
  return !Object.keys(datum || {}).some((k) => {
    const v = datum[k];
    if (v === undefined || v === null) return false;
    if (typeof v === "string") return v.trim() !== "";
    return true;
  });
}

function withArray(block, spec, arr) {
  const next = cloneFleetBlock(block) || {};
  next[spec.arrayKey] = arr;
  return next;
}

// Write ONE field of ONE datum. Returns a mutated block clone, or null for "nothing
// to commit" (an unrepresentable array, an out-of-range index, or a blank keystroke
// in the trailing scaffold). Three behaviours in one entry point:
//   index < length     → set the field (a blank value DELETES the key); when that
//                        leaves the datum entirely empty, the datum is REMOVED.
//   index === length   → the trailing blank scaffold: a non-blank value APPENDS a
//                        new datum carrying just that field.
//   anything else      → null.
export function datumEditorSet(block, index, key, value) {
  const spec = datumEditorSpec((block && block.type) || "");
  if (!spec) return null;
  if (!spec.fields.some((f) => f.key === key)) return null;
  const rows = datumEditorRows(block);
  if (rows === null) return null;
  if (!Number.isInteger(index) || index < 0 || index > rows.length) return null;
  const text = typeof value === "string" ? value : value == null ? "" : String(value);
  const blank = text.trim() === "";

  if (index === rows.length) {
    if (blank) return null;
    rows.push({ [key]: text });
    return withArray(block, spec, rows);
  }

  const datum = { ...rows[index] };
  if (blank) delete datum[key];
  else datum[key] = text;
  if (datumIsEmpty(datum)) rows.splice(index, 1);
  else rows[index] = datum;
  return withArray(block, spec, rows);
}

// Move a datum from one position to another. Returns a mutated block clone, or null
// when there is nothing to move (no datum editor, an unrepresentable array, an index
// out of range, or from === to — a no-op must emit no op, D3 byte-stability).
export function datumEditorMove(block, from, to) {
  const spec = datumEditorSpec((block && block.type) || "");
  if (!spec) return null;
  const rows = datumEditorRows(block);
  if (rows === null) return null;
  const n = rows.length;
  if (!Number.isInteger(from) || !Number.isInteger(to)) return null;
  if (from < 0 || from >= n || to < 0 || to >= n || from === to) return null;
  const [moved] = rows.splice(from, 1);
  rows.splice(to, 0, moved);
  return withArray(block, spec, rows);
}

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
// Build the STRUCTURED per-datum grid DOM for a duel/lineage block. Returns
// { el, refresh, flush, destroy } — the same shape the JSON island returns — or
// null when the kind carries no datum array. Every control is a native <input> or
// <select>: NO <button> (rule 6 / __atom_chrome guard, which reads this file).
//
// The grid renders rows.length + 1 rows. The trailing one is the ADD scaffold: its
// fields are empty and typing into any of them appends a datum. An existing datum
// whose fields are all cleared drops out. A <select> per existing datum holds the
// positions 1…N; picking one reorders. All four operations funnel through the two
// PURE entry points (datumEditorSet / datumEditorMove) the unit tests drive, so the
// DOM here carries no editing rules of its own.
//
// Lives inside the DOM-building half of the module (references `document`), so it is
// never reached by the pure-Node harness.
function buildDatumGrid(initialBlock, { onEdit, isEditable }) {
  const type = (initialBlock && initialBlock.type) || "";
  const spec = datumEditorSpec(type);
  if (!spec) return null;
  let currentBlock = initialBlock || { type };

  const el = document.createElement("div");
  el.className = "bp-fleet-datum";
  el.setAttribute("contenteditable", "false");
  el.setAttribute("data-test-id", `paper-fleet-datum-${type}`);
  el.style.display = "grid";
  el.style.gap = "0.35rem";
  el.style.marginBottom = "0.5rem";

  const hint = document.createElement("div");
  hint.style.opacity = "0.65";
  hint.textContent =
    `Edit each ${spec.itemNoun} — type in the empty ${spec.itemNoun} to add one, ` +
    `clear every field to remove it, pick a position to reorder. ` +
    `Kilde overrides the block's default source for that ${spec.itemNoun}.`;
  el.appendChild(hint);

  const list = document.createElement("div");
  list.style.display = "grid";
  list.style.gap = "0.35rem";
  el.appendChild(list);

  let timer = null;
  let pendingCommit = null;

  // Optimistic local advance: each commit recomputes from the block the LAST commit
  // produced, never from a stale echo, so two quick edits in two fields both land.
  const applyEdit = (next) => {
    if (next == null) return false;
    currentBlock = next;
    onEdit(next);
    return true;
  };

  const flushPending = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    if (!pendingCommit) return false;
    const run = pendingCommit;
    pendingCommit = null;
    return run();
  };

  const focusKey = () => {
    const a = document.activeElement;
    if (!a || !el.contains(a)) return null;
    const idx = a.getAttribute && a.getAttribute("data-bp-datum-index");
    const key = a.getAttribute && a.getAttribute("data-bp-datum-field");
    return idx == null || key == null ? null : { idx, key };
  };

  const restoreFocus = (want) => {
    if (!want) return;
    const input = list.querySelector(
      `input[data-bp-datum-index="${want.idx}"][data-bp-datum-field="${want.key}"]`,
    );
    if (!input) return;
    try {
      input.focus();
      const end = input.value.length;
      input.setSelectionRange(end, end);
    } catch (_) {
      /* a detached/unsupported input must never throw out of a repaint */
    }
  };

  const onFieldInput = (e) => {
    if (!isEditable()) return;
    const input = e.target;
    const index = Number(input.getAttribute("data-bp-datum-index"));
    const key = input.getAttribute("data-bp-datum-field");
    const value = input.value;
    if (timer) clearTimeout(timer);
    pendingCommit = () => {
      const before = datumEditorRows(currentBlock);
      const next = datumEditorSet(currentBlock, index, key, value);
      if (!applyEdit(next)) return false;
      const after = datumEditorRows(currentBlock);
      // A structural change (append / remove) changes the row count, so the grid
      // must be rebuilt; a plain field edit leaves the DOM alone (and the caret).
      if (!before || !after || before.length !== after.length) {
        const want = focusKey();
        paint(currentBlock, true);
        restoreFocus(want);
      }
      return true;
    };
    timer = setTimeout(() => {
      timer = null;
      const run = pendingCommit;
      pendingCommit = null;
      if (run) run();
    }, DEBOUNCE_MS);
  };

  const onPositionChange = (e) => {
    if (!isEditable()) return;
    flushPending();
    const select = e.target;
    const from = Number(select.getAttribute("data-bp-datum-index"));
    const to = Number(select.value);
    const next = datumEditorMove(currentBlock, from, to);
    if (!applyEdit(next)) {
      paint(currentBlock, true);
      return;
    }
    paint(currentBlock, true);
  };

  const buildRow = (datum, index, count) => {
    const row = document.createElement("div");
    row.className = "bp-fleet-datum-row";
    row.setAttribute("data-bp-datum-index", String(index));
    if (index === count) row.setAttribute("data-bp-datum-scaffold", "true");
    row.style.display = "flex";
    row.style.flexWrap = "wrap";
    row.style.gap = "0.25rem";
    row.style.alignItems = "center";

    if (index < count) {
      const pos = document.createElement("select");
      pos.className = "bp-fleet-datum-pos";
      pos.setAttribute("data-bp-datum-index", String(index));
      pos.setAttribute(
        "aria-label",
        `position of ${spec.itemNoun} ${index + 1} of ${count}`,
      );
      for (let i = 0; i < count; i++) {
        const opt = document.createElement("option");
        opt.value = String(i);
        opt.textContent = String(i + 1);
        if (i === index) opt.selected = true;
        pos.appendChild(opt);
      }
      pos.addEventListener("change", onPositionChange);
      row.appendChild(pos);
    } else {
      const badge = document.createElement("span");
      badge.className = "bp-fleet-datum-new";
      badge.setAttribute("aria-hidden", "true");
      badge.textContent = "+";
      badge.style.opacity = "0.5";
      row.appendChild(badge);
    }

    for (const field of spec.fields) {
      const label = document.createElement("label");
      label.style.display = "inline-flex";
      label.style.flexDirection = "column";
      label.style.flex = "1 1 6rem";
      label.style.minWidth = "5rem";
      const cap = document.createElement("span");
      cap.textContent = field.label;
      cap.style.opacity = "0.6";
      cap.style.fontSize = "0.75em";
      const input = document.createElement("input");
      input.type = "text";
      input.className = "bp-fleet-datum-field";
      input.setAttribute("data-bp-datum-index", String(index));
      input.setAttribute("data-bp-datum-field", field.key);
      input.setAttribute("spellcheck", "false");
      input.setAttribute(
        "aria-label",
        index === count
          ? `${field.label} of a new ${spec.itemNoun}`
          : `${field.label} of ${spec.itemNoun} ${index + 1}`,
      );
      const v = datum ? datum[field.key] : "";
      input.value = v === undefined || v === null ? "" : String(v);
      input.readOnly = !isEditable();
      input.style.width = "100%";
      input.addEventListener("input", onFieldInput);
      label.appendChild(cap);
      label.appendChild(input);
      row.appendChild(label);
    }
    return row;
  };

  // Repaint. `force` rebuilds the rows outright (a structural change); otherwise the
  // existing inputs are re-seeded in place, skipping whichever one has focus so an
  // echo can never clobber the field the author is typing in. An unrepresentable
  // array (datumEditorRows → null) hides the grid entirely and leaves the payload to
  // the JSON island rather than showing a lossy view of it.
  function paint(block, force) {
    currentBlock = block || { type };
    const rows = datumEditorRows(currentBlock);
    if (rows === null) {
      el.style.display = "none";
      return;
    }
    el.style.display = "grid";
    const count = rows.length;
    const needRebuild = force || list.children.length !== count + 1;
    if (needRebuild) {
      while (list.firstChild) list.removeChild(list.firstChild);
      for (let i = 0; i < count; i++) list.appendChild(buildRow(rows[i], i, count));
      list.appendChild(buildRow(null, count, count));
      return;
    }
    for (const input of list.querySelectorAll("input[data-bp-datum-field]")) {
      if (document.activeElement === input) continue;
      const i = Number(input.getAttribute("data-bp-datum-index"));
      const key = input.getAttribute("data-bp-datum-field");
      const v = i < count && rows[i] ? rows[i][key] : "";
      const text = v === undefined || v === null ? "" : String(v);
      if (input.value !== text) input.value = text;
      input.readOnly = !isEditable();
    }
  }

  paint(initialBlock || { type }, true);

  return {
    el,
    refresh: (block) => {
      // Never repaint out from under an in-progress edit (the JSON island's own
      // activeElement guard, widened to the whole grid).
      if (el.contains(document.activeElement)) {
        currentBlock = block || currentBlock;
        return;
      }
      paint(block || {}, true);
    },
    flush: () => {
      flushPending();
    },
    destroy: () => {
      if (timer) clearTimeout(timer);
      timer = null;
      pendingCommit = null;
    },
  };
}

function buildFleetEditor(initialBlock, { onEdit, isEditable }) {
  let currentBlock = initialBlock;
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

  // The STRUCTURED per-datum grid rides ABOVE the JSON island for the kinds that
  // carry an authored datum array (duel rows / lineage stops). The two never write
  // the same key: the array is not an enumerated config key, so the JSON island
  // leaves it alone and only the grid moves it.
  const datumGrid = buildDatumGrid(initialBlock || { type }, { onEdit, isEditable });
  if (datumGrid) el.appendChild(datumGrid.el);

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
    return fleetEditorParse(currentBlock || { type }, text);
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
    currentBlock = block;
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
      if (datumGrid) datumGrid.refresh(block || {});
    },
    flush: () => {
      if (datumGrid) datumGrid.flush();
      if (!textTimer) return;
      clearTimeout(textTimer);
      textTimer = null;
      commitText();
    },
    destroy: () => {
      if (datumGrid) datumGrid.destroy();
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
      body.className = readerPaintClass(editor);
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
      let nativeConfig = null;
      const currentBlock = () => {
        const pos = typeof getPos === "function" ? getPos() : null;
        return pos == null ? block : editor.state.doc.nodeAt(pos)?.attrs.bpBlock || block;
      };
      const commitBlock = nextBlock => {
        if (!editor.isEditable || isBlockLocked(currentBlock()) || typeof getPos !== "function") return;
        const pos = getPos();
        const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_FLEET_NODE_NAME) return;
        editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...cur.attrs, bpBlock: nextBlock }));
      };
      const wireNative = isStatsType(bpType) ? wireStatsInline : bpType === "cards" ? wireCardsInline : null;
      const nativeInline = wireNative ? wireNative(body, {
        getBlock: currentBlock, isEditable: () => editor.isEditable,
        commit: commitBlock, undo: () => editor.commands.undo(), redo: () => editor.commands.redo(),
      }) : null;
      let hovered = false;
      let focused = false;
      const syncReveal = () => {
        if (!fleetEditor) return;
        if (nativeConfig) {
          nativeConfig.style.display = editor.isEditable && !isBlockLocked(currentBlock()) ? "" : "none";
          return;
        }
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
          isEditable: () => editor.isEditable && !isBlockLocked(currentBlock()),
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
        if (nativeInline) {
          dom.classList.add("bp-paper-contextual-editor");
          if (isStatsType(bpType)) dom.classList.add("bp-canvas-stats-inline");
          nativeConfig = document.createElement("details");
          nativeConfig.className = `bp-paper-contextual-controls bp-paper-${bpType === "cards" ? "cards" : "stats"}-config`;
          const summary = document.createElement("summary");
          summary.className = "bp-paper-contextual-toggle";
          summary.textContent = bpType === "cards" ? "Configure Cards" : "Configure Stats";
          nativeConfig.appendChild(summary);
          fleetEditor.el.classList.add("bp-paper-contextual-panel");
          nativeConfig.appendChild(fleetEditor.el);
          dom.appendChild(nativeConfig);
        } else dom.appendChild(fleetEditor.el);
        dom.addEventListener("mouseenter", onEnter);
        dom.addEventListener("mouseleave", onLeave);
        dom.addEventListener("focusin", onFocusIn);
        dom.addEventListener("focusout", onFocusOut);
        syncReveal();
      }
      const flushFleetEditor = () => {
        if (nativeInline) nativeInline.flush();
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
          if (nativeInline) nativeInline.refresh();
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
          if (nativeInline) nativeInline.destroy();
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

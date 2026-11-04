// readonly-atom-node.js — Phase-4 Stage S3.6: the canvas READ-ONLY ATOM node-views — the
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
import { canvasScope, coercePickerValue } from "./field-node.js";

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
export function readOnlyAtomAttributes() {
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
  if (scope.referenceStrings) picker.setAttribute("data-strings", scope.referenceStrings);
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
      return ({ node: initialNode, getPos, editor }) => {
        let node = initialNode;
        let destroyed = false;
        const block = (node.attrs && node.attrs.bpBlock) || {};
        const bpId = (node.attrs && node.attrs.bpId) || "";

        const dom = document.createElement("div");
        dom.className = `bp-canvas-readonly ${className}`;
        dom.setAttribute("data-bp-type", bpType);
        dom.setAttribute("data-bp-fleet-id", bpId);
        dom.setAttribute("contenteditable", "false");
        dom.setAttribute("data-test-id", `paper-readonly-${bpType}`);

        const chip = document.createElement("span");
        chip.className = "bp-canvas-readonly-chip";
        chip.textContent = chipLabel(block);

        // Inert parity receipt, painted only by the server's canonical reader
        // producer. A template keeps received custom elements, resources and ids
        // out of the active document while retaining the exact reader bytes for
        // conformance. The visible chip remains the sole mounted representation.
        const preview = document.createElement("template");
        preview.setAttribute("data-bp-fleet-body", "");
        preview.setAttribute("data-bp-conformance-root", "");
        preview.setAttribute("data-bp-type", bpType);
        dom.append(chip, preview);

        const onPaint = (event) => {
          // Always cancel the hook's generic injection. Only an exact render of
          // the block currently carried by this node may replace the receipt.
          event.preventDefault();
          const { html, sourceBlock } = event.detail || {};
          if (!sourceBlock || sourceBlock.id !== node.attrs.bpId ||
              !node.type.create({ ...node.attrs, bpBlock: sourceBlock }).eq(node)) return;
          preview.innerHTML = typeof html === "string" ? html : "";
        };
        const signalReady = () => queueMicrotask(() => {
          if (!destroyed && dom.isConnected) {
            dom.dispatchEvent(new CustomEvent("bp-ready", { bubbles: true, composed: true }));
          }
        });
        preview.addEventListener("bp-fleet-paint", onPaint);
        signalReady();

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
            const changed = !updated.eq(node);
            node = updated;
            dom.setAttribute("data-bp-fleet-id", node.attrs.bpId || "");
            if (changed) preview.innerHTML = "";
            chip.textContent = chipLabel(b);
            // Keep the accessible name + lock cue in lockstep with the re-rendered
            // chip (an echo/undo may change the block's locked state or content).
            dom.setAttribute("aria-label", atomAriaLabel(chipLabel(b), b));
            if (isBlockLocked(b)) dom.setAttribute("data-bp-locked", "true");
            else dom.removeAttribute("data-bp-locked");
            if (retarget) retarget.paint(b);
            if (changed) signalReady();
            return true;
          },

          // PM must NOT turn a click/keystroke inside the chip into a transaction —
          // there is nothing to edit; a click only ever SELECTS the atom.
          stopEvent: () => true,

          // PM must NOT read the chip's DOM mutations back into the document (the chip
          // is outside any contentDOM; there is none on an atom).
          ignoreMutation: () => true,

          destroy: () => {
            destroyed = true;
            preview.removeEventListener("bp-fleet-paint", onPaint);
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

// The public reader explicitly retains its legacy palette when no article
// style is authored. Do not introduce an article styling island inside it.
// Unmarked standalone embedders and Studio retain their existing default.
export function readerPaintClass(editor) {
  const element = editor.options.element;
  if (element.closest('[data-paper-palette="legacy"]')) return "";
  // A nested `.bp-paper-surface` would re-declare the standalone fallback
  // palette and mask the host reader's authored theme tokens. The injected
  // reader HTML already matches the canonical selectors through its ancestor.
  return element.closest(".bp-paper-surface") ? "" : "bp-paper-surface";
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
export function selectAtomNode(editor, getPos) {
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

// canvas/index.js — Phase-4 Stage S1: <bp-paper-canvas>, the CONTINUOUS-CANVAS
// engine over ONE prose run.
//
// Where <bp-paper-editor> (../index.js) mounts ONE TipTap instance PER BLOCK and
// emits a patch-block op for that one block, <bp-paper-canvas> mounts ONE TipTap
// instance over a CONTIGUOUS run of PROSE blocks (paragraph | heading | list —
// non-prose blocks are run boundaries handled in S2/S3, so a run never contains
// them). This is what proves the Obsidian continuous feel: cross-block caret,
// multi-block selection, Enter-split, Backspace-merge — ALL in ONE ProseMirror
// document, which StarterKit's keymaps give us FOR FREE (doc content is block+,
// so paragraph/heading/list as siblings is native and Enter/Backspace at block
// edges split/merge without any custom code).
//
// PROJECTOR + OP-MAPPER are S0's PURE, TESTED functions, used VERBATIM:
//   runToTiptap(blocks) -> { type:"doc", content:[node…] }   (mount content)
//   runToOps(prevBlocks, editor.getJSON()) -> ordered op array (the diff)
// We do NOT reinvent the diff. The ONE thing the canvas must add on top of S0 is
// the BpAttrs extension (./bp-attrs.js): runToTiptap stamps attrs:{bpId,bpType}
// on each top-level node, but ProseMirror DROPS unknown node attrs on the
// setContent->getJSON round-trip unless the node type declares them. BpAttrs
// declares bpId/bpType on the block nodes so editor.getJSON() preserves the ids
// runToOps keys by. Without it, runToOps mis-diffs everything as new.
//
// S1 SCOPE (tight): cross-block editing + split/merge + op-emission +
// FormatBubble. EXPLICITLY OUT (later stages, clean seams left below): the slash
// menu, the [[ wikilink + # tag autocompletes, and non-prose node-views.
//
// ADDITIVE: this is the SECOND custom element in the same bundle. ../index.js
// gains exactly one line — `import "./canvas/index.js";` — so this registers.
// The shipped <bp-paper-editor> behavior is byte-unchanged.

import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import Link from "@tiptap/extension-link";
import Placeholder from "@tiptap/extension-placeholder";
import Typography from "@tiptap/extension-typography";

// PURE S0 projector + op-mapper — used verbatim (do NOT reinvent the diff).
import { runToTiptap, runToOps } from "./run-convert.js";
// The attr-preservation extension — the make-or-break of S1 (see ./bp-attrs.js).
import { BpAttrs } from "./bp-attrs.js";
// S3: the divider as a canvas ATOM node — the first non-prose block to live
// INSIDE the canvas document (so a prose run can CONTAIN dividers). A leaf with
// no edit UI; PM's atom selection + Backspace-delete come free. See ./divider-node.js.
import { Divider } from "./divider-node.js";
// S3.2: the callout as a canvas CONTENT node — the first non-prose block with an
// EDITABLE body to live INSIDE the canvas document (so a prose run can CONTAIN
// callouts, body and all). A node-view renders the tone-framed chrome + fold
// toggle around a contentDOM body hole. See ./callout-node.js.
import { Callout } from "./callout-node.js";
// S3.3: the code block as a canvas ATTR-ATOM node — an atom (no PM-managed body,
// like the divider) whose code TEXT rides in the `value` attr and is edited by a
// NON-PM <textarea> island (stopEvent/ignoreMutation so PM never sees its
// keystrokes). UNLIKE the divider it carries a mutable value/lang and CAN emit a
// patch-block. The node is named `bpCode` to avoid the StarterKit inline `code`
// MARK; StarterKit's `codeBlock` NODE is disabled below so only this node owns
// <pre>. See ./code-node.js.
import { Code } from "./code-node.js";
// S3.4: the diagram block as a canvas ATTR-ATOM node — MIRRORS the S3.3 code node
// (an atom whose body text rides in an attr, edited by a non-PM <textarea> island)
// with two field differences: the body is `source` (the Mermaid text, not `value`)
// and there is an extra optional `caption` (where code had `lang`). The node is
// named `bpDiagram`; UNLIKE code/divider there is NO StarterKit collision (StarterKit
// ships no `diagram` node), so NO StarterKit node is disabled for it. See
// ./diagram-node.js.
import { Diagram } from "./diagram-node.js";
// S3.5: the 7 native-control field-* blocks as a canvas CONTROL-ATOM node — the
// FOURTH node-view variant. A SINGLE `bpField` node serves all 7 native field types
// (string/slug/text/boolean/select/datetime/color), discriminated by bpType; the
// value is edited by a NATIVE control (input/textarea/checkbox/select/datetime-local
// /color) wrapped in a stopEvent/ignoreMutation island, and COERCED by field type
// exactly like the per-block BarkparkFieldBlockBridge. field-image/field-reference
// (pickers) stay run boundaries (bpOpaque). See ./field-node.js.
import { Field } from "./field-node.js";
// S3.6: the sheet + embed blocks as canvas READ-ONLY ATOM nodes — the FIFTH (and LAST
// S3) node-view variant. Both are REFERENCES, NOT editable text: a sheet is edited in
// its own surface (its cached snapshot renders read-only); an embed transcludes at
// VIEW render (walk.ex). So in the canvas they are read-only atoms that carry the WHOLE
// block verbatim on `bpBlock` (the bpOpaque verbatim-carry, made canvas-eligible) and
// NEVER emit a value/content patch — they render a read-only chip (sheet summary /
// embed reference) with contentEditable false, are selectable so Backspace deletes the
// atom → remove-block, and DO participate in structural ops. See ./embed-node.js.
import { Sheet, Embed } from "./embed-node.js";
// Reused verbatim from the shipped editor (imported, never copied).
import { FormatBubble } from "../format-bubble.js";
// Internal-link marks — schema registration only, so the canvas holds existing
// wikilink/blockref/tag inline marks through a setContent->getJSON round-trip
// (identical role to ../index.js). The [[ / # AUTOCOMPLETE UI is OUT of S1.
import { Wikilink, Blockref, Tag } from "../marks.js";
import { DEBOUNCE_MS, PLACEHOLDER } from "../contract.js";

// One-shot, id-guarded self-inject of the standalone stylesheet — IDENTICAL
// contract to ../index.js:ensureStyles (same <link>, same id-guard, same
// BP_PAPER_EDITOR_NO_INJECT opt-out). Both elements share the one stylesheet, so
// the id guard means whichever mounts first injects it and the other no-ops.
function ensureStyles() {
  if (typeof window !== "undefined" && window.BP_PAPER_EDITOR_NO_INJECT) return;
  if (typeof document === "undefined") return;
  if (document.getElementById("bp-paper-editor-styles")) return;
  const link = document.createElement("link");
  link.id = "bp-paper-editor-styles";
  link.rel = "stylesheet";
  link.href = "/assets/bp-paper-editor.css";
  (document.head || document.documentElement).appendChild(link);
}

// Strip null-valued bpId/bpType from NON-top-level nodes before the diff.
//
// Why this exists: BpAttrs declares bpId/bpType GLOBALLY on the `paragraph`
// type (addGlobalAttributes targets by node TYPE, not position — it cannot say
// "top-level paragraphs only"). So the paragraph nested INSIDE a list item also
// gains the attrs, and ProseMirror serializes them as { bpId:null, bpType:null }
// in getJSON(). But runToTiptap's projection of a `list` block (via convert.js
// blockToTiptap) emits those inner paragraphs with NO attrs key. runToOps'
// proseNodeChanged compares node.content via stableProseKey, so the phantom
// { bpId:null, bpType:null } on a nested paragraph (a PRESENCE difference —
// runToTiptap omits the key entirely) makes the list look changed. This is
// ORTHOGONAL to the marked-text key-ORDER difference, which stableProseKey now
// handles itself via canonical (sorted-key) comparison; here we only close the
// attr-presence gap.
//
// Fix: at depth > 0 (anything not a direct child of the doc), drop a bpId/bpType
// that is null so the nested nodes match runToTiptap's projection.
// TOP-LEVEL nodes are left untouched — there a null bpId is MEANINGFUL: it marks
// a freshly-typed/split block runToOps must mint an id for. We only ever strip
// the phantom nested ones. This keeps S0's runToOps used verbatim, with a doc
// shaped exactly the way it was tested against.
function normalizeCanvasDoc(doc) {
  const stripNested = (node) => {
    if (node && node.attrs) {
      const a = node.attrs;
      if (a.bpId == null && a.bpType == null && hasOnlyBpKeys(a)) {
        // The node gained ONLY the (null) bp stamp — drop the whole attrs bag so
        // it matches an unstamped projection node.
        delete node.attrs;
      } else {
        if (a.bpId == null) delete a.bpId;
        if (a.bpType == null) delete a.bpType;
      }
    }
    if (node && node.content) node.content.forEach(stripNested);
  };
  // Walk only the SUBTREES of each top-level node — never the top-level nodes
  // themselves (their null bpId is the new-block signal runToOps needs).
  (doc.content || []).forEach((top) => {
    (top.content || []).forEach(stripNested);
  });

  // ── DEDUP top-level bpIds: an Enter-SPLIT clones the origin block's attrs ──
  //
  // ProseMirror's splitBlock (the Enter keymap) copies the source node's attrs
  // into the new half — INCLUDING bpId. So a split yields TWO top-level nodes
  // carrying the SAME bpId. runToOps assumes each surviving prev id appears at
  // most once (it keys edits by id); a duplicate makes it emit a self-move and
  // conflicting patches for that id. The split block is genuinely NEW, so the
  // SECOND-and-later occurrence of any bpId must read as new: null its bpId so
  // runToOps mints a fresh id — exactly S0's "split → insert-after(minted id)"
  // path. The FIRST occurrence keeps the id (it's the surviving origin block).
  const seen = new Set();
  (doc.content || []).forEach((top) => {
    const id = top.attrs && top.attrs.bpId;
    if (id == null) return;
    if (seen.has(id)) {
      // A clone of an already-seen id — strip its stamp so it diffs as NEW.
      top.attrs = { ...top.attrs, bpId: null };
    } else {
      seen.add(id);
    }
  });

  return doc;
}

// True when an attrs bag carries nothing but the bp stamp keys (so deleting them
// would leave it empty). Guards against nuking a node that also has real attrs
// (e.g. a heading's level — though headings are top-level and never walked here).
function hasOnlyBpKeys(attrs) {
  return Object.keys(attrs).every((k) => k === "bpId" || k === "bpType");
}

class BpPaperCanvas extends HTMLElement {
  static get observedAttributes() {
    return ["editable"];
  }

  constructor() {
    super();
    this._editor = null;
    this._mount = null;
    this._bubble = null; // FormatBubble instance (selection format toolbar)
    this._debounceTimer = null;
    // The RUN this canvas mounted — an array of prose blocks. This is the
    // "prev" runToOps diffs the live doc against. In S1 we DO NOT advance it on
    // edit (no server echo yet): every bp-canvas-ops detail is the cumulative
    // diff from the mounted run. S2 advances this on the server's echo. <-- SEAM
    this._blocks = [];
    this._editable = true;
  }

  connectedCallback() {
    if (this._editor) return; // double-mount guard

    ensureStyles();

    // Upgrade-safe property reclaim: a host may set `el.blocks = [...]` BEFORE
    // the custom-element definition upgrades this node; that assignment lands as
    // a plain own-property shadowing the prototype accessor. Delete + re-assign
    // so it flows back through the real setter. Mirrors ../index.js.
    this._upgradeProperty("blocks");

    // Default true; only the literal string "false" disables editing. Mount-time
    // read is authoritative — attributeChangedCallback handles later toggles.
    this._editable = this.getAttribute("editable") !== "false";

    // The contenteditable element the WC owns. TipTap mounts onto it. Same body
    // class as ../index.js so the shared stylesheet styles the canvas identically.
    this._mount = document.createElement("div");
    this._mount.className = "bp-paper-editor-body";
    this.appendChild(this._mount);

    // ONE Editor over the WHOLE run. Mirrors ../index.js's Editor config; the
    // KEY differences: (1) content is runToTiptap(this._blocks) — MANY top-level
    // blocks, not blockToTiptap of one; StarterKit's doc is block+, so the
    // siblings are native and cross-block caret/selection/split/merge come free.
    // (2) BpAttrs is in the extension list so getJSON() preserves bpId/bpType.
    this._editor = new Editor({
      element: this._mount,
      editable: this._editable,
      extensions: [
        StarterKit.configure({
          // Same as ../index.js: heading levels 1–3, lists, history on.
          heading: { levels: [1, 2, 3] },
          // Disable StarterKit's built-in horizontalRule so ONLY the canvas
          // `divider` node owns the <hr> parse rule + insert command. Otherwise
          // two nodes claim <hr> (ambiguous on paste/setContent) and
          // setHorizontalRule would insert a `horizontalRule` that runToOps —
          // which only knows `divider` as a canvas atom — mis-diffs as a paragraph.
          horizontalRule: false,
          // S3.3: disable StarterKit's built-in codeBlock NODE (name:'codeBlock',
          // parses <pre> with preserveWhitespace:'full') so ONLY the canvas
          // `bpCode` node owns the <pre> parse rule. Same lesson as horizontalRule:
          // two nodes claiming <pre> is ambiguous on paste/setContent, and
          // setCodeBlock would insert a `codeBlock` runToOps — which knows `code`
          // (the bpCode node) as a canvas attr-atom — mis-diffs as unknown. NOTE we
          // do NOT disable the inline `code` MARK (extension-code, parses <code>) —
          // the canvas KEEPS it so inline-code round-trips (convert.js inline path).
          codeBlock: false,
        }),
        // Link mark — same config as ../index.js so existing `link` inline nodes
        // render/edit and the format bubble's link button works.
        Link.configure({ openOnClick: false, autolink: false }),
        // Empty-block ghost text — same contract as ../index.js. includeChildren
        // :false so one placeholder shows on the focused top-level textblock only.
        Placeholder.configure({
          includeChildren: false,
          showOnlyWhenEditable: true,
          placeholder: ({ node }) => {
            if (node.type.name === "heading") {
              return PLACEHOLDER.heading(node.attrs && node.attrs.level);
            }
            return PLACEHOLDER.paragraph;
          },
        }),
        // Smart typography — parity with ../index.js. A prose run holds no code
        // block, so nothing to exclude.
        Typography,
        // Internal-link marks — schema registration only (see import note). This
        // keeps existing inline wikilink/blockref/tag marks round-tripping; the
        // [[ / # autocomplete UI is OUT of S1.
        Wikilink,
        Blockref,
        Tag,
        // THE make-or-break: declares bpId/bpType on the block nodes so the run's
        // ids survive the setContent->getJSON round-trip runToOps depends on.
        BpAttrs,
        // S3: the divider atom node — a non-prose leaf living INSIDE the canvas
        // document. Registers the `divider` node type (toDOM <hr>, bpId/bpType
        // attrs) so runToTiptap's { type:"divider" } node mounts as an atom and
        // getJSON() round-trips it (instead of dropping it as an unknown node).
        Divider,
        // S3.2: the callout content node + its node-view. Registers the `callout`
        // node type (content:"inline*", tone/title/collapsible/collapsed data-*
        // attrs, a NodeView rendering tone-framed chrome around a contentDOM body)
        // so runToTiptap's { type:"callout", content:[…] } node mounts with an
        // editable body that JOINS the run, and getJSON() round-trips body+chrome.
        Callout,
        // S3.3: the code attr-atom node + its node-view. Registers the `bpCode`
        // node type (atom, attrs value/lang via data-*, a NodeView rendering a
        // <pre> with a non-PM <textarea> island that uses stopEvent/ignoreMutation
        // so PM never turns code keystrokes into transactions) so runToTiptap's
        // { type:"bpCode", attrs:{value,lang?} } node mounts as an editable code
        // block whose value/lang round-trip through getJSON(). StarterKit's
        // codeBlock is disabled above so only this node owns <pre>.
        Code,
        // S3.4: the diagram attr-atom node + its node-view. Registers the `bpDiagram`
        // node type (atom, attrs source/caption via data-*, a NodeView rendering a
        // <pre> with a non-PM <textarea> island that uses stopEvent/ignoreMutation so
        // PM never turns Mermaid-source keystrokes into transactions) so runToTiptap's
        // { type:"bpDiagram", attrs:{source,caption?} } node mounts as an editable
        // diagram block whose source/caption round-trip through getJSON(). MIRRORS the
        // code node; UNLIKE code there is no StarterKit node to disable (StarterKit
        // ships no `diagram` node), and bpDiagram parses ONLY its own
        // <pre data-bp-type='diagram'> (it does NOT claim the bare <pre> the code node
        // already owns).
        Diagram,
        // S3.5: the field CONTROL-ATOM node + its node-view. Registers the SINGLE
        // `bpField` node type serving ALL 7 native field-* kinds (field-string /
        // field-slug / field-text / field-boolean / field-select / field-datetime /
        // field-color), discriminated by the bpType attr. An atom whose VALUE rides an
        // attr and is edited by a NATIVE control (input / textarea / checkbox / select
        // / datetime-local / color), with the control wrapped in a stopEvent/
        // ignoreMutation island so PM never turns its keystrokes/toggles/selections
        // into transactions. On change the value is COERCED BY FIELD TYPE exactly like
        // the per-block BarkparkFieldBlockBridge (boolean → control.checked; else
        // control.value), so a canvas field edit persists IDENTICALLY. field-image /
        // field-reference (pickers) are NOT in this set — they stay run boundaries
        // (bpOpaque). bpField parses ONLY its own <div data-bp-type='field'>.
        Field,
        // S3.6: the sheet + embed READ-ONLY ATOM nodes + their node-views. Registers
        // the `bpSheet` and `bpEmbed` node types (atom, NO edit surface; the WHOLE
        // block rides the bpBlock attr via data-bp-block, a NodeView rendering a
        // read-only chip — the sheet summary "Sheet · <ref> · NxM"; the embed
        // reference "↪ <target>" — with contentEditable false + stopEvent/
        // ignoreMutation so PM never turns a click into a transaction) so runToTiptap's
        // { type:"bpSheet"|"bpEmbed", attrs:{bpBlock} } node mounts as a read-only
        // reference that round-trips the block VERBATIM through getJSON() and emits ZERO
        // value/content ops. UNLIKE bpField, nothing is edited; they carry the whole
        // block, not just a value. Each parses ONLY its own <div data-bp-type='sheet'>
        // / <div data-bp-type='embed'>. After S3.6 sheet/embed no longer split a run —
        // only field-image/field-reference (pickers) remain boundaries.
        Sheet,
        Embed,
      ],
      content: runToTiptap(this._blocks),
      // SEAM (S2/S3): editorProps.handleKeyDown will route slash / [[ / # popup
      // navigation here exactly like ../index.js:_onKeyDown. OUT of S1.
      onUpdate: () => {
        this._scheduleEmit();
        // SEAM (S2/S3): callout shorthand + slash + [[ + # detectors plug in
        // here, mirroring ../index.js's mutually-exclusive onUpdate chain.
        if (this._bubble) this._bubble.update();
      },
      // Selection-only changes (drag-select, shift-arrow, cross-block click)
      // don't fire onUpdate — drive the format bubble from selectionUpdate too.
      // This is what makes the bubble track a MULTI-BLOCK selection.
      onSelectionUpdate: () => {
        if (this._bubble) this._bubble.update();
      },
      onBlur: () => { if (this._bubble) this._bubble.update(); },
      onFocus: () => { if (this._bubble) this._bubble.update(); },
    });

    // Selection format toolbar — REUSED verbatim from ../format-bubble.js. It is
    // agnostic to how many blocks the editor holds: it floats on any non-empty
    // text selection, including one spanning multiple blocks. Skipped in read
    // mode; every consumer is `if (this._bubble)` guarded.
    if (this._editable) {
      this._bubble = new FormatBubble({ editor: this._editor });
    }

    // Lifecycle: one-shot bubbling/composed signal a host hook can await —
    // mirrors ../index.js's bp-ready.
    this.dispatchEvent(
      new CustomEvent("bp-ready", {
        detail: { blockCount: this._blocks.length },
        bubbles: true,
        composed: true,
      }),
    );
  }

  attributeChangedCallback(name, _old, val) {
    if (name === "editable") {
      this._editable = val !== "false";
      if (this._editor) this._editor.setEditable(this._editable);
    }
  }

  disconnectedCallback() {
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }
    if (this._bubble) {
      this._bubble.destroy();
      this._bubble = null;
    }
    if (this._editor) {
      this._editor.destroy();
      this._editor = null;
    }
  }

  _scheduleEmit() {
    if (!this._editable) return; // read mode emits no ops
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => {
      this._debounceTimer = null;
      this._emitOps();
    }, DEBOUNCE_MS);
  }

  // Diff the live doc against the mounted run and, if anything changed, emit the
  // ordered op array S0 produces. The diff is runToOps VERBATIM — the canvas is
  // a thin shell over S0's PURE projector/op-mapper.
  //
  // S1 does NOT advance this._blocks here: with no server echo yet, advancing on
  // every keystroke would make each op-batch a diff-of-a-diff and double-apply
  // on the server. So we always diff from the MOUNTED run; the detail is the
  // cumulative op set that folds the mounted run to the current doc. <-- SEAM:
  // S2 replaces this with an echo-driven advance (set this._blocks = the blocks
  // the server confirmed, so the next diff is incremental).
  _emitOps() {
    if (!this._editor) return;
    const nextDoc = normalizeCanvasDoc(this._editor.getJSON());
    const ops = runToOps(this._blocks, nextDoc);
    if (!ops.length) return;
    this.dispatchEvent(
      new CustomEvent("bp-canvas-ops", {
        detail: { ops },
        bubbles: true,
        composed: true,
      }),
    );
  }

  // Upgrade-safe property reclaim (called from connectedCallback). Mirrors
  // ../index.js:_upgradeProperty.
  _upgradeProperty(name) {
    if (Object.prototype.hasOwnProperty.call(this, name)) {
      const value = this[name];
      delete this[name];
      this[name] = value;
    }
  }

  // `blocks` property — the run this canvas edits (an array of PROSE blocks). A
  // host (the harness, later the LiveView) assigns `el.blocks = [...]` before or
  // after mount. Pre-mount: stash it; connectedCallback projects it. Post-mount:
  // re-project the whole run into the live editor and reset the diff baseline.
  set blocks(value) {
    this._blocks = Array.isArray(value) ? value : [];
    if (this._editor) {
      this._editor.commands.setContent(runToTiptap(this._blocks), false);
    }
  }

  get blocks() {
    return this._blocks;
  }
}

if (!customElements.get("bp-paper-canvas")) {
  customElements.define("bp-paper-canvas", BpPaperCanvas);
}

export { BpPaperCanvas };

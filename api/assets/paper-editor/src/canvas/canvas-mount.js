
// Reused verbatim from the shipped editor (imported, never copied).
import { FormatBubble } from "../format-bubble.js";
import { loadStringsFrom, t } from "../i18n.js";
import { BlockHandle } from "./block-handle.js";
import * as editorSchema from "./canvas-editor-schema.js";
import { setCommentRanges as crSet } from "./comment-ranges.js";
import { canEditObjectBlock, editObjectBlockAt } from "./inline-object.js";

// The hover card on a link / wikilink: address, resolved title + first line, Open, Edit (plan #23).
import { LinkPreview } from "./link-preview.js";
import { setRemoteSelections as rsSet } from "./remote-selections.js";
import { setWikilinkMissing, wikilinkInfo } from "./wikilink-titles.js";


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

function connectedCallback() {
  if (this._editor || this._mountFailure) return; // double-mount guard

  ensureStyles();
  // The canvas's own words in the viewer's Studio language (task-addade22d350314a).
  loadStringsFrom(this);

  // Upgrade-safe property reclaim: a host may set `el.blocks = [...]` (or, for
  // P4, `el.wikilinkSource = …` / `el.tagSource = …`) BEFORE the custom-element
  // definition upgrades this node; that assignment lands as a plain own-property
  // shadowing the prototype accessor. Delete + re-assign so it flows back through
  // the real setter. Mirrors ../index.js.
  this._upgradeProperty("blocks");
  this._upgradeProperty("acknowledgedSaves");
  this._upgradeProperty("liveRemote");
  this._upgradeProperty("wikilinkSource");
  this._upgradeProperty("tagSource");
  this._upgradeProperty("mediaUploader");
  this._upgradeProperty("mediaPicker");
  this._upgradeProperty("editBlockObject");
  this._upgradeProperty("linkPreviewSource");
  this._upgradeProperty("wikilinkResolve");

  // Default true; only the literal string "false" disables editing. Mount-time
  // read is authoritative — attributeChangedCallback handles later toggles.
  this._editable = this.getAttribute("editable") !== "false";

  // The contenteditable element the WC owns. TipTap mounts onto it. Same body
  // class as ../index.js so the shared stylesheet styles the canvas identically.
  this._mount = document.createElement("div");
  this._mount.className = "bp-paper-editor-body";
  this.appendChild(this._mount);
  // IME (task-39cb3d6e4709054e): where an open composition started, mapped through every
  // transaction, so a save during a long composition leaves out only the composing run,
  // and a committed phrase is saved at its compositionend.
  this._compStart = null;
  this._onCompStart = () => {
    const sel = this._editor && this._editor.state.selection;
    this._compStart = sel && sel.empty ? sel.from : null;
    this._compBlockSize = sel && sel.empty ? sel.$from.parent.content.size : null;
  };
  this._onCompEnd = () => this._afterComposition();
  this._mount.addEventListener("compositionstart", this._onCompStart, true);
  this._mount.addEventListener("compositionend", this._onCompEnd, true);
  this._onWikilinkClick = (event) => this._wikilinkClicked(event);
  this._mount.addEventListener("click", this._onWikilinkClick);
  // Leaving the page sends what is committed now, not after the debounce or the composition.
  this._onPageHide = () => this.flushPendingChanges();
  this._pageWindow = this.ownerDocument.defaultView;
  this._pageWindow?.addEventListener("pagehide", this._onPageHide);



  this._editor = this._createEditorSafely(() => editorSchema.createCanvasEditor.call(this));
  // A node view that throws while the run is first painted leaves no editor
  // (construction threw) or an empty one: show the read-only fallback instead.
  if (!this._editor || !this._verifyPainted("create")) return;
  if (this._remoteSelections.length) rsSet(this._editor, this._remoteSelections);
  if (this._commentRanges.length) crSet(this._editor, this._commentRanges);

  // Selection format toolbar — REUSED verbatim from ../format-bubble.js. It is
  // agnostic to how many blocks the editor holds: it floats on any non-empty
  // text selection, including one spanning multiple blocks. Skipped in read
  // mode; every consumer is `if (this._bubble)` guarded.
  if (this._editable) {
    // A host that draws its own toolbar turns the bubble off (format-bubble="off").
    if (this._wantsBubble()) this._bubble = new FormatBubble({ editor: this._editor });
    // Notion-style block gutter: + to add below, ⋮⋮ to drag / open the block menu.
    this._handle = new BlockHandle({
      host: this,
      editor: this._editor,
      openSlash: () => this._openSlash(""),
      // Paper masters: "Save as master" in the block menu, offered only where
      // the editor carries the masters carrier (the pane may write) and the
      // block is one the server already holds.
      canSaveMaster: (node) => this._canSaveMaster(node),
      saveMaster: (node) => this._saveMaster(node),
      // A declared object block's Edit opens its field editor, as a double-click does.
      canEdit: (node) => this._editable && canEditObjectBlock(this, node),
      edit: (pos) => editObjectBlockAt(this, this._editor, pos),
    });
  }
  // The link hover card works in both modes (a reader wants the address too); Edit shows only
  // when editable. Open is the host's call first (`bp-canvas-open-link`, cancelable) — a plain
  // link falls back to a new window; a wikilink has nowhere to go without the host.
  this._linkPreview = new LinkPreview({
    editor: this._editor,
    host: this,
    editable: () => this._editable,
    // Contract 1.14.0: a block-cards host gets Sanity's annotation pill, named by the
    // annotation's schema title (Sanity's start-cased name when none: "Internal Link").
    pill: () => this.hasAttribute("block-cards"),
    label: (info) => {
      const titles = (this._toolbarVocabulary() || {}).annotationTitles || {};
      if (info.kind === "link") return titles.link || t("Link");
      return titles.wikilink || titles.internalLink || t("Internal Link");
    },
    resolve: (info) => (typeof this._linkPreviewSource === "function" ? this._linkPreviewSource(info) : null),
    known: (info) => wikilinkInfo(this._editor, info),
    onMissing: (info, missing) => setWikilinkMissing(this._editor, info, missing),
    onOpen: (detail) => {
      const ev = new CustomEvent("bp-canvas-open-link", { detail, bubbles: true, composed: true, cancelable: true });
      const go = this.dispatchEvent(ev);
      if (go && detail.kind === "link" && detail.href && typeof window !== "undefined" && window.open) {
        try { window.open(detail.href, "_blank", "noopener,noreferrer"); } catch (_e) {}
      }
    },
    onEdit: (detail) => {
      if (detail.kind === "link" && this._bubble) this._bubble.openLink();
      else if (this._bubble) this._bubble.update();
      else if (detail.kind === "link") this._requestHostLink();
    },
  });

  this._restSelectionOffAtom();
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

export { connectedCallback };

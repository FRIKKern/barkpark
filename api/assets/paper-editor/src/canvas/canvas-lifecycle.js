import { FormatBubble } from "../format-bubble.js";


function getObservedAttributes() {
  return ["editable", "format-bubble"];
}

function initialize() {
  this._editor = null;
  this._mount = null;
  this._bubble = null; // FormatBubble instance (selection format toolbar)
  this._linkPreview = null; // LinkPreview instance (hover card on links and wikilinks)
  this._composeEndEmit = null; // one-shot compositionend listener: an ops emit held back by an open IME composition
  this._linkPreviewSource = null; // injected async ({ kind, href, target, docId }) => { title, excerpt, href, missing }
  this._wikilinkResolve = null; // injected (docId) => { title?, missing? } | null, or a Promise of it
  this._modEnterPending = false;
  this._debounceTimer = null;
  // Baseline captured when a local debounce window opens. Server broadcasts may
  // advance `_blocks` while that draft is waiting; the eventual diff must still
  // describe only the local transaction, not manufacture an inverse patch that
  // reverts newly queued authority.
  this._debounceBaselineBlocks = null;
  this._emitCache = null;
  // The RUN this canvas mounted — an array of prose blocks. This is the
  // "prev" runToOps diffs the live doc against. As of S4a this baseline is
  // ECHO-ADVANCED: after the server applies a batch it echoes the confirmed
  // blocks back via applyServerBlocks(), which resets this._blocks so the
  // NEXT diff is INCREMENTAL (bounded op size over a long session) rather than
  // cumulative-from-mount. See applyServerBlocks below.
  this._blocks = [];
  // Save bridge state. Only one canvas batch is emitted at a time. New edits
  // made before its acknowledgement remain live and are diffed immediately
  // after success from the acknowledged after-snapshot.
  this._inflightOps = null;
  this._awaitingOwnEchoes = [];
  this._dirtyWhileInflight = false;
  this._opsSeq = 0;
  this._acknowledgedSaves = false;
  this._editable = true;
  // S4a: a queued external-edit echo deferred because the editor was FOCUSED
  // or composing (IME) when it arrived — applied on blur / compositionend so a
  // confirmed external edit never yanks the caret mid-edit. null when none
  // pending; otherwise the confirmed blocks array to setContent on release.
  this._pendingServerBlocks = null;
  // liveRemote (1.15.0): opt in to taking server blocks while the author edits,
  // block by block. Held blocks already reported: id -> the remote block's JSON.
  this._liveRemote = false;
  this._heldRemote = new Map();
  // flushKeepsSource (1.20.0): opt in to a source-mode flush that commits the
  // Markdown and keeps source mode open. Default false: the flush leaves source mode.
  this._flushKeepsSource = false;
  // Bound listeners for the deferred-apply release (added only while a
  // server echo is queued; removed once applied). Kept as fields so the
  // exact same function identity is removed.
  this._onComposeEnd = null;
  this._onBlurFlush = null;
  // P4 `[[` wikilink autocomplete — ported VERBATIM from ../index.js. Studio-
  // only by construction: gated on `this._editable` (read-mode never runs
  // onUpdate) AND on an injected `this._wikilinkSource` (unset → never opens).
  // The block-local trigger (parseOpenWikilink against $from.parent.textContent
  // + parentOffset) is FRAME-CORRECT in the multi-block canvas doc: a `[[` typed
  // in ANY run block opens the popup against THAT block's text. A pick inserts a
  // wikilink mark, so runToOps emits a patch-block for that one block.
  this._wikilink = null; // WikilinkMenu instance (lazy, created on first trigger)
  this._wlSeq = 0; // monotonic open/query counter — stale async-result guard
  this._wikilinkSource = null; // injected async (query) => [{ title, id, type }]
  this._wlRange = null; // { from, to } PM range to replace on the current pick
  // P4 `#` tag autocomplete — the `#` analogue, REUSING WikilinkMenu via a
  // { title, id, type } adapter. Independent seq/range so the two popups never
  // cross-contaminate. Same Studio-only gating as the wikilink popup.
  this._tag = null; // WikilinkMenu instance reused for tags (lazy)
  this._tagSeq = 0; // monotonic open/query counter — stale async-result guard
  this._tagSource = null; // injected async (query) => [ "design", "obsidian", … ]
  // injected async (file) => { src, alt?, width?, height? } — where a pasted or dropped
  // picture goes (the host's Barkpark media); unset → the image node says so.
  this._mediaUploader = null;
  // injected async ({ kind, current }) => { src, alt?, width? } | null — the host's own
  // image picker (upload / library): the Image insert and an image's Select open it.
  this._mediaPicker = null;
  // An image's Select asks for the host's picker on that image (image-node.js).
  this.addEventListener("bp-canvas-image-pick", (event) => {
    event.stopPropagation();
    if (event.detail && Number.isInteger(event.detail.pos)) void this._pickImageAt(event.detail.pos);
  });
  // injected async ({ type, title, inline, fields, value, error }) => value | null — the
  // host's own editor for a declared block or inline object (instead of the popover).
  this._editBlockObject = null;
  // Shared carets: the host's last setRemoteSelections list (re-applied on
  // mount), and the rAF-coalesced bp-canvas-selection emit.
  this._remoteSelections = [];
  this._selectionFrame = null;
  this._lastSelectionDetail = undefined;
  // Comment ranges: the host's last setCommentRanges list (re-applied on mount),
  // and the rAF-coalesced bp-canvas-comment-ranges emit.
  this._commentRanges = [];
  this._commentRangesFrame = null;
  // Toolbar state: the rAF-coalesced bp-selection-change emit.
  this._toolbarFrame = null;
  this._lastToolbarState = undefined;
  this._uploadSeq = 0;
  // Settled receipts survive native history while this editor is mounted.
  // They contain metadata only, never another upload request.
  this._uploadResults = new Map();
  this._tagRange = null; // { from, to } PM range to replace on the current pick
  this._emoji = null; // WikilinkMenu instance reused for the `:` emoji picker (lazy)
  this._emojiRange = null; // { from, to } PM range to replace on the current pick
  // P4 S-slash: the "/" insert popup (lazy, created on first trigger). UNLIKE the
  // wikilink/tag popups it needs no injected source — the item list is the static
  // CANVAS_SLASH_ITEMS (SLASH_ITEMS filtered to the insertable set) + EXPECTED-group
  // items SlashMenu reads fresh from the DOM. Gated on `this._editable` only (read
  // mode never runs onUpdate). On a pick it inserts the default NODE directly (no
  // bp-slash-insert). The callout `> [!type]` shorthand shares _maybeSlash's
  // predicate but is mutually exclusive ('>' vs '/') and inserts a callout node too.
  this._slash = null; // SlashMenu instance (lazy)
  // P5 command palette — the Cmd-P launcher (lazy, created on first Mod-p). UNLIKE
  // the slash/[[ /# popups it is NOT text-triggered: it opens on the keyboard
  // shortcut and filters the WHOLE static command registry by a fuzzy match. Gated
  // on `this._editable` (read mode runs no commands). Mutually exclusive with the
  // three text-triggered popups (see _onKeyDown: Mod-p no-ops when any is open). On
  // a pick it runs the command's run(editor), closes, and refocuses the editor; the
  // command then emits the normal bp-canvas-ops via the onUpdate path.
  this._palette = null; // CommandPalette instance (lazy)
  // P5 MARKDOWN SOURCE-MODE — the Obsidian "source mode" analog. "rich" = the
  // ProseMirror editor (this._mount) is live; "source" = the rich editor is
  // hidden and a Markdown <textarea> (this._sourceEl) owns input. The toggle
  // (Mod-Shift-m or the "Toggle Markdown source" palette command) flips between
  // them. Both never co-exist; the textarea owns ALL input while in source mode,
  // so the [[ / # / slash / palette / format-bubble seams no-op there.
  this._mode = "rich"; // "rich" | "source"
  this._sourceEl = null; // the <textarea class="bp-canvas-source"> (source mode only)
  // The blocks the source markdown was serialized FROM (a deep clone captured on
  // ENTER). On EXIT the markdown is parsed back to blocks whose ids are REALIGNED
  // against this baseline so a surviving block keeps its id → runToOps emits a
  // PATCH (not remove+insert) for an in-place text edit. The NO-EDIT exit short-
  // circuits before any of this (md unchanged → restore untouched, ZERO ops).
  this._sourceBaselineBlocks = null;
  // The blocks of the last source commit (1.20.0): the second id donor, after the
  // enter baseline, so a block born in this session keeps its id (_commitSource).
  this._sourceCommitBlocks = null;
  // The markdown the rich document holds: shown on ENTER (blocksToMarkdown of the
  // baseline), then the text of the last source commit (_commitSource). The NO-EDIT
  // guard compares the textarea value against THIS string verbatim: equal → the
  // flush or toggle is provably op-free (no re-parse, no setContent, no caret churn).
  this._sourceOriginalMd = "";
  // Bound listener for the textarea's own Mod-Shift-m (toggle BACK to rich) +
  // Escape — kept as a field so the exact identity is removed on cleanup.
  this._onSourceKeyDown = null;
  // Responsive Studio morphs can blur the rich editor immediately BEFORE the
  // custom element's disconnectedCallback. Keep the last focused intent alive
  // through the current DOM mutation only; onBlur clears it in a microtask.
  this._richFocusIntent = false;
  this._richFocusIntentVersion = 0;
  // Reconnect recovery temporarily freezes the stable editor root with `inert`.
  // Keep a separate, one-shot focus intent so that freeze-induced blur can return
  // to the exact same rich editor after a successful retry without touching its
  // ProseMirror selection or history. Deliberate focus elsewhere cancels it.
  this._resumeFocusIntent = null;
  this._resumeFocusState = "idle"; // "idle" | "armed" | "cancelled"
  this._onResumeFocusIn = null;
}

function attributeChangedCallback(name, _old, val) {
  if (name === "format-bubble") {
    if (!this._editor || this._editor.isDestroyed || !this._editable) return;
    if (!this._wantsBubble() && this._bubble) {
      this._bubble.destroy();
      this._bubble = null;
    } else if (this._wantsBubble() && !this._bubble) {
      this._bubble = new FormatBubble({ editor: this._editor });
      this._bubble.update();
    }
    return;
  }
  if (name === "editable") {
    // A run that failed to mount stays read-only whatever the host asks.
    this._editable = val !== "false" && !this._mountFailure;
    if (this._editor) this._editor.setEditable(this._editable);
  }
}

function disconnectedCallback() {
  this._clearHTMLPasteNotice();
  // LiveView may move this keyed canvas between responsive Studio columns.
  // Custom-element reactions report that connected-to-connected reparent as a
  // disconnect followed synchronously by a reconnect. Defer destructive
  // teardown one microtask so the same editor, history, and pending debounce
  // survive that move; a genuine removal is still torn down immediately after
  // the current DOM mutation finishes.
  const editor = this._editor;
  const ownerDocument = this.ownerDocument;
  const restoreRichFocus =
    this._mode === "rich" &&
    this._editable &&
    editor?.isEditable === true &&
    this._richFocusIntent === true;
  queueMicrotask(() => {
    if (!this.isConnected) {
      this._teardownDisconnected();
      return;
    }

    // A DOM move drops native focus to <body>; Blink also delivers a blur that
    // clears TipTap's live isFocused flag before this microtask. The value
    // captured above is the pre-move intent. Restore only that narrow case. A
    // prior blur, any meaningful intervening focus, an editor replacement,
    // source mode, read mode, cross-document move, or inert destination wins.
    const activeElement = ownerDocument?.activeElement;
    const focusIsEmpty =
      activeElement == null ||
      activeElement === ownerDocument.body ||
      activeElement === ownerDocument.documentElement;
    if (
      restoreRichFocus &&
      this._editor === editor &&
      this.ownerDocument === ownerDocument &&
      this._mode === "rich" &&
      this._editable &&
      editor.isEditable === true &&
      this.closest("[inert]") == null &&
      focusIsEmpty
    ) {
      editor.view.focus();
    }
  });
}

function _teardownDisconnected() {
  this._uploadResults.clear();
  if (this._selectionFrame != null) {
    cancelAnimationFrame(this._selectionFrame);
    this._selectionFrame = null;
  }
  if (this._toolbarFrame != null) {
    cancelAnimationFrame(this._toolbarFrame);
    this._toolbarFrame = null;
  }
  if (this._commentRangesFrame != null) {
    cancelAnimationFrame(this._commentRangesFrame);
    this._commentRangesFrame = null;
  }
  this._clearResumeFocusIntent();
  if (this._debounceTimer) {
    clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
  }
  this._debounceBaselineBlocks = null;
  // S4a: drop any queued external-edit echo + its release listeners.
  this._clearPendingServerBlocks();
  // P4: destroy both autocomplete popups (each owns a document.body element +
  // document-level pointer/keydown listeners — see WikilinkMenu.destroy()).
  if (this._wikilink) {
    this._wikilink.destroy();
    this._wikilink = null;
  }
  if (this._tag) {
    this._tag.destroy();
    this._tag = null;
  }
  // P4 S-slash: destroy the slash popup (owns a document.body element + document-
  // level pointer/keydown listeners — see SlashMenu.destroy()).
  if (this._slash) {
    this._slash.destroy();
    this._slash = null;
  }
  // P5: destroy the command palette (a SlashMenu subclass — owns a document.body
  // element + document-level pointer/keydown listeners + its own query <input>).
  if (this._palette) {
    this._palette.destroy();
    this._palette = null;
  }
  if (this._bubble) {
    this._bubble.destroy();
    this._bubble = null;
  }
  if (this._linkPreview) {
    this._linkPreview.destroy();
    this._linkPreview = null;
  }
  if (this._composeEndEmit && this._mount) {
    this._mount.removeEventListener("compositionend", this._composeEndEmit, true);
    this._composeEndEmit = null;
  }
  if (this._mount && this._onCompStart) {
    this._mount.removeEventListener("compositionstart", this._onCompStart, true);
    this._mount.removeEventListener("compositionend", this._onCompEnd, true);
  }
  this._pageWindow?.removeEventListener("pagehide", this._onPageHide);
  clearTimeout(this._compEndTimer);
  this._compStart = null;
  if (this._handle) {
    this._handle.destroy();
    this._handle = null;
  }
  // P5 source-mode: tear down the markdown textarea + its keydown listener if the
  // element disconnects while in source mode (so neither the node nor the listener
  // leaks). Reset the mode bookkeeping; the editor.destroy() below frees the rest.
  this._teardownSourceEl();
  this._sourceBaselineBlocks = null;
  this._sourceCommitBlocks = null;
  this._sourceOriginalMd = "";
  this._mode = "rich";
  this._richFocusIntentVersion += 1;
  this._richFocusIntent = false;
  if (this._editor) {
    this._editor.destroy();
    this._editor = null;
  }
}

// Upgrade-safe property reclaim (called from connectedCallback). Mirrors
// ../index.js:_upgradeProperty.
function _upgradeProperty(name) {
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
function setBlocks(value) {
  this._blocks = Array.isArray(value) ? value : [];
  this._inflightOps = null;
  this._awaitingOwnEchoes = [];
  this._dirtyWhileInflight = false;
  if (this._editor) {
    const caret = this._captureCaret();
    this._programmaticApply = true;
    try {
      // The seed is the run's starting point, not an edit: keep it out of
      // undo history. In history, a Cmd+Z on an untouched run inverted it to
      // the empty pre-seed doc and ProseMirror threw (doc needs a block).
      this._editor
        .chain()
        .setContent(this._rt(this._blocks), { emitUpdate: false })
        .command(({ tr }) => {
          tr.setMeta("addToHistory", false);
          return true;
        })
        .run();
    } catch (error) {
      this._failMount("seed", error);
      return;
    } finally {
      this._programmaticApply = false;
    }
    this._restoreCaret(caret);
    this._restSelectionOffAtom();
    this._verifyPainted("seed");
    if (this._mode === "source" && this._flushKeepsSource) this._syncSourceText();
    this._consumePendingFocus();
  }
}

// A run whose content could not be painted must never rest as an EMPTY editor:
// the author would see prose missing, and any structural edit on the empty run
// could persist the loss (task-7188bd8e9eb2625a). ProseMirror aborts a paint
// when a node view throws, leaving the new state behind an empty (or partial)
// DOM. Detect both shapes and fall back to a read-only paint of the run.
function _createEditorSafely(factory) {
  try {
    return factory();
  } catch (error) {
    this._failMount("create", error);
    return null;
  }
}

function _verifyPainted(stage) {
  if (this._mountFailure) return false;
  const view = this._editor && this._editor.view;
  if (!view || !view.dom) return true;
  const expected = this._editor.state.doc.childCount;
  if (expected > 0 && view.dom.childElementCount === 0) {
    this._failMount(stage, new Error("the editor painted no blocks"));
    return false;
  }
  return true;
}

function _failMount(stage, error) {
  const message = String((error && error.message) || error || "unknown failure");
  const blockIds = (this._blocks || []).map((block) => block && block.id).filter(Boolean);
  this._mountFailure = { stage, message };
  try {
    console.error("bp-paper-canvas: this run could not open for editing (" + stage + ")", error);
  } catch (_e) {}
  this._editable = false;
  if (this._debounceTimer) clearTimeout(this._debounceTimer);
  this._debounceTimer = null;
  try {
    if (this._editor) this._editor.setEditable(false);
  } catch (_e) {}
  if (this._mount) this._mount.hidden = true;
  this.setAttribute("data-mount-failed", "true");
  let fallback = [...this.children].find((child) => child.classList.contains("bp-canvas-mount-failed"));
  if (!fallback) {
    fallback = document.createElement("div");
    fallback.className = "bp-canvas-mount-failed";
    this.appendChild(fallback);
  }
  fallback.replaceChildren();
  const notice = document.createElement("p");
  notice.className = "bp-canvas-mount-failed__notice";
  notice.setAttribute("role", "alert");
  notice.textContent =
    "This part of the paper could not open for editing. It is shown read-only; nothing in it was changed.";
  fallback.appendChild(notice);
  for (const block of this._blocks || []) {
    const row = document.createElement("div");
    row.className = "bp-canvas-mount-failed__block";
    if (block && block.id) row.setAttribute("data-bp-id", block.id);
    if (block && block.type) row.setAttribute("data-bp-type", block.type);
    row.textContent = readOnlyBlockText(block);
    fallback.appendChild(row);
  }
  this.dispatchEvent(
    new CustomEvent("bp-canvas-mount-failed", {
      detail: { stage, message, blockIds },
      bubbles: true,
      composed: true,
    }),
  );
}

function getBlocks() {
  return this._blocks;
}

// Hosts with an acknowledged persistence bridge opt into ordered, one-at-a-
// time emission. Vanilla consumers retain the historical fire-and-echo API.
function setAcknowledgedSaves(value) {
  this._acknowledgedSaves = value === true;
}

// `true` (strictly) takes server blocks into the live document while the author
// edits (1.15.0, _takeServerBlocks). Default false: deferred until release.
function setLiveRemote(value) {
  this._liveRemote = value === true;
}

function getLiveRemote() {
  return this._liveRemote;
}

// `true` (strictly): flushPendingChanges() in source mode commits the Markdown and
// keeps source mode open, and a server apply reaches a textarea with no unsaved
// text (1.20.0). Default false: the flush leaves source mode, as before 1.20.0.
function setFlushKeepsSource(value) {
  this._flushKeepsSource = value === true;
}

function getFlushKeepsSource() {
  return this._flushKeepsSource;
}

function getAcknowledgedSaves() {
  return this._acknowledgedSaves;
}

// The text a reader would see in one block, for the read-only mount fallback:
// every inline `value` in document order, plus a field's label and value.
function readOnlyBlockText(block) {
  const parts = [];
  const walk = (node) => {
    if (node == null) return;
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    if (typeof node !== "object") return;
    if (node.type === "text" && typeof node.value === "string") parts.push(node.value);
    walk(node.content);
    walk(node.children);
    walk(node.items);
  };
  if (block && typeof block === "object") {
    if (typeof block.label === "string" && block.label) parts.push(block.label);
    if (typeof block.title === "string" && block.title) parts.push(block.title);
    walk(block.content);
    walk(block.items);
    if (block.value != null && typeof block.value !== "object") parts.push(String(block.value));
  }
  return parts.join(" ").trim();
}

export {
  _createEditorSafely, _failMount, _teardownDisconnected, _upgradeProperty, _verifyPainted,
  attributeChangedCallback, disconnectedCallback, getAcknowledgedSaves, getBlocks,
  getFlushKeepsSource, getLiveRemote, getObservedAttributes, initialize, setAcknowledgedSaves,
  setBlocks, setFlushKeepsSource, setLiveRemote,
};

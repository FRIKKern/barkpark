import { markdownToBlocks } from "../markdown.js";
import { paragraphAfterSelectedBlock } from "./block-boundary.js";
import { clipboardPastePolicy, stripPastedImages } from "./clipboard-paste-policy.js";
import { exactSliceFromClipboard } from "./clipboard-slice.js";
import { isFigureSingletonCanvas } from "./figure-context.js";
import { prepareHTMLTablePaste } from "./html-table-paste.js";
import { cleanPastedHTML } from "./paste-html.js";
import { blocksNeedFitting, droppedNotice, fitBlocksToVocabulary } from "./paste-vocabulary.js";
import { docToBlocks } from "./run-convert.js";
import { markAllowed, parseVocabulary } from "./vocabulary.js";
import { markdownWikilinksAsBrackets } from "./wikilink-input.js";
import { Fragment, DOMParser as PMDOMParser, Slice } from "@tiptap/pm/model";

// The key that makes a drag copy instead of move, as prosemirror-view reads it.
const DRAG_COPY_KEY = typeof navigator !== "undefined" && /Mac|iPhone|iPad|iPod/.test(navigator.platform) ? "altKey" : "ctrlKey";

// Unwrap the marks `keep` refuses, everywhere under `fragment`; text stays.
function stripMarks(fragment, keep) {
  const nodes = [];
  fragment.forEach((node) => {
    if (node.isText) nodes.push(node.mark(node.marks.filter((m) => keep(m.type.name))));
    else nodes.push(node.copy(stripMarks(node.content, keep)));
  });
  return Fragment.fromArray(nodes);
}

function figurePastePlan(slice) {
  const direct = [];
  slice.content.forEach((node) => direct.push(node));
  if (direct.length > 0 && direct.every((node) => node.isText)) {
    return { native: true };
  }
  if (slice.content.childCount !== 1) return { blocked: true };
  const paragraph = slice.content.firstChild;
  if (paragraph.type.name !== "paragraph") return { blocked: true };

  let compatible = true;
  paragraph.content.forEach((node) => {
    if (!node.isText) compatible = false;
  });
  if (!compatible) return { blocked: true };
  return { inline: new Slice(Fragment.from(paragraph.content), 0, 0) };
}

export function _onPaste(view, _event, slice) {
    const policy = this._editable ? clipboardPastePolicy(view, _event, slice) : null;
    if (this._editable) {
      if (policy?.blocked) {
        this._showHTMLPasteNotice(`Nothing was pasted. ${policy.blocked}`);
        return true;
      }
      // A paste over a selected non-text block lands in a new paragraph after it
      // and never replaces the block (block-boundary.js).
      const opened = paragraphAfterSelectedBlock(view.state);
      if (opened) view.dispatch(opened);
      // Paste as plain text keeps Sanity's line rule too (see _pastePlainText).
      if (policy?.plain && !isFigureSingletonCanvas(this)) return this._pastePlainText(view, _event, true);
      // The canvas's own clipboard: rebuild exactly what was copied, fitted to
      // this canvas's vocabulary like any paste (clipboard-slice.js).
      const exact = !isFigureSingletonCanvas(this) && exactSliceFromClipboard(view.state.schema, _event, view.state.doc);
      if (exact) {
        const fitted = this._fitPastedSlice(exact);
        const single = fitted.openStart === 0 && fitted.openEnd === 0 && fitted.content.childCount === 1 ? fitted.content.firstChild : null;
        const tr = single ? view.state.tr.replaceSelectionWith(single) : view.state.tr.replaceSelection(fitted);
        view.dispatch(tr.scrollIntoView().setMeta("paste", true).setMeta("uiEvent", "paste"));
        return true;
      }
    }
    if (this._editable && !isFigureSingletonCanvas(this) && this._pasteImageFiles(view, _event, policy?.imageAlt)) return true;
    if (this._editable && !isFigureSingletonCanvas(this) && this._pasteHTMLTables(view, _event)) return true;
    if (this._editable && !isFigureSingletonCanvas(this) && this._pasteMarkdown(view, _event)) return true;
    if (this._editable && !isFigureSingletonCanvas(this) && this._pastePlainText(view, _event)) return true;
    if (!this._editable || !isFigureSingletonCanvas(this)) return false;
    const plan = figurePastePlan(slice);
    if (plan.native) return false;
    if (plan.blocked) {
      this._showFigureConstraint(
        "A Figure keeps one content block. Paste one paragraph at a time; lists and blocks stay on the clipboard.",
      );
      return true;
    }
    view.dispatch(view.state.tr.replaceSelection(plan.inline).scrollIntoView());
    return true;
  }

export function _insertImageFiles(view, files, atPos, imageAlt = null) {
    const { state } = view;
    const imageType = state.schema.nodes.bpImage;
    if (!imageType) return;
    const $pos = atPos != null ? state.doc.resolve(atPos) : state.selection.$from;
    // Insert after the block the position sits in (top-level), never inside it.
    let insertAt = $pos.depth >= 1 ? $pos.after(1) : $pos.pos;
    const tr = state.tr;
    const nodes = files.map((file) => {
      const key = "up-" + (++this._uploadSeq) + "-" + Date.now().toString(36);
      const alt = imageAlt ?? String(file.name || "image").replace(/\.[a-z0-9]+$/i, "");
      let previewUrl = null;
      try { previewUrl = URL.createObjectURL(file); } catch (_) {}
      return { key, file, node: imageType.create({ bpId: null, bpType: "image", src: null, alt, uploading: true, previewUrl, uploadKey: key }) };
    });
    for (const n of nodes) { tr.insert(insertAt, n.node); insertAt += n.node.nodeSize; }
    view.dispatch(tr.scrollIntoView());
    for (const n of nodes) this._uploadImage(n.key, n.file, n.node.attrs.previewUrl);
  }

export function _findUploadNode(key) {
    if (!this._editor || this._editor.isDestroyed) return null;
    let found = null;
    this._editor.state.doc.descendants((node, pos) => {
      if (found) return false;
      if (node.type.name === "bpImage" && node.attrs.uploadKey === key) { found = { node, pos }; return false; }
      return true;
    });
    return found;
  }

export function _patchUploadNode(key, receipt) {
    const editor = this._editor;
    if (!editor || editor.isDestroyed || receipt.editor !== editor) return;
    let hit = this._findUploadNode(key);
    if (!hit) return;
    // Flush the image island before its async repaint can replace draft inputs.
    editor.view.nodeDOM(hit.pos)?.dispatchEvent(new CustomEvent("bp-flush-node"));
    hit = this._findUploadNode(key);
    if (!hit) return;
    const patch = { ...receipt.patch };
    // A person may edit the URL or alt while the request is in flight.
    // Completion owns the pending upload, not those subsequent edits.
    if (hit.node.attrs.src || hit.node.attrs.uploadSrcEdited) delete patch.src;
    if (hit.node.attrs.uploadAltEdited || hit.node.attrs.alt !== receipt.initialAlt) delete patch.alt;
    editor.view.dispatch(editor.state.tr
      .setNodeMarkup(hit.pos, undefined, { ...hit.node.attrs, ...patch })
      .setMeta("addToHistory", false));
  }

export function _restoreUploadResults() {
    const editor = this._editor;
    if (!editor || editor.isDestroyed || !this._uploadResults.size) return;
    const keys = [];
    editor.state.doc.descendants(node => {
      if (node.type.name === "bpImage" && node.attrs.uploadKey && this._uploadResults.has(node.attrs.uploadKey)) keys.push(node.attrs.uploadKey);
    });
    for (const key of keys) this._patchUploadNode(key, this._uploadResults.get(key));
  }

export function setMediaUploader(fn) {
    this._mediaUploader = fn;
  }

  // The host's image picker. Set: an Image insert opens it for the new block, and each
  // image offers Select (CSS shows it on [data-media-picker]). Unset: today's image block.
  export function setMediaPicker(fn) {
    this._mediaPicker = typeof fn === "function" ? fn : null;
    this.toggleAttribute("data-media-picker", !!this._mediaPicker);
  }

export function getMediaPicker() {
    return this._mediaPicker;
  }

  // After an Image insert: open the picker for the empty image the insert left at the caret.
  export function _pickInsertedImage() {
    const editor = this._editor;
    if (!this._mediaPicker || !editor) return;
    const { from } = editor.state.selection;
    let best = null;
    editor.state.doc.descendants((n, p) => {
      if (n.type.name === "bpImage" && !n.attrs.src && !n.attrs.uploadKey && (best == null || Math.abs(p - from) < Math.abs(best - from))) best = p;
      return true;
    });
    if (best != null) void this._pickImageAt(best);
  }

export function getMediaUploader() {
    return this._mediaUploader;
  }

export function _pasteHTMLTables(view, event) {
    // Shift-paste deliberately chooses the native plain-text path.
    if ((view.input?.shiftKey && view.input.lastKeyCode !== 45) || view.state.selection.$from.parent.type.spec.code) return false;
    const raw = event?.clipboardData?.getData("text/html");
    const { html, count: imagesLeftOut } = stripPastedImages(cleanPastedHTML(raw));
    const plan = prepareHTMLTablePaste(html);
    if (!plan) return false;
    const insideTable = [...Array(view.state.selection.$from.depth).keys()]
      .some((depth) => view.state.selection.$from.node(depth + 1).type.name === "bpTable");
    if (plan.blocked || insideTable) {
      this._showHTMLPasteNotice(`${plan.blocked || "A table cannot be nested inside another table."} Nothing was pasted. Paste as plain text with Ctrl+Shift+V, or copy the cell text instead.`);
      return true;
    }
    const parsed = PMDOMParser.fromSchema(view.state.schema).parse(plan.dom);
    const fitted = this._fitPastedNodes(parsed.content, imagesLeftOut);
    view.dispatch(view.state.tr.replaceSelection(fitted ? fitted.slice : new Slice(parsed.content, 0, 0)).scrollIntoView());
    if (fitted) this._noticeLeftOut(fitted.dropped);
    return true;
  }

export function _pasteMarkdown(view, event) {
    const data = event && event.clipboardData;
    if (!data) return false;
    const html = data.getData("text/html");
    const text = data.getData("text/plain");
    if (html || !text) return false;
    const lines = text.split(/\r?\n/);
    const blockish = /^(#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s|```|---\s*$)/;
    // A GFM pipe table announces itself by a delimiter row (dashes with a pipe) under a header line.
    const tableDelimiter = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
    const pipeTable = lines.some((line, k) => k + 1 < lines.length && line.includes("|") && lines[k + 1].includes("|") && tableDelimiter.test(lines[k + 1]));
    // An inline markdown link ([text](url)) is markdown too, even on one line: it
    // becomes a link over its text, not literal brackets (task-68314b1d334213e8).
    const inlineLink = /\[[^\]\n]+\]\((?:https?:\/\/|mailto:|\/|#)[^)\s]*\)/.test(text);
    if (!lines.some((line) => blockish.test(line)) && !pipeTable && !inlineLink) return false;
    let nodes;
    let dropped = [];
    try {
      let blocks = markdownToBlocks(text);
      if (!blocks.length) return false;
      if (typeof this._wikilinkSource === "function") blocks = markdownWikilinksAsBrackets(blocks);
      // A field admits only its vocabulary: a `> quote` becomes the field's quote
      // block (or a paragraph) instead of vetoing the whole paste.
      const vocab = parseVocabulary(this.getAttribute("data-vocabulary"));
      if (vocab) ({ blocks, dropped } = fitBlocksToVocabulary(blocks, vocab));
      nodes = this._rt(blocks).content.map((json) => view.state.schema.nodeFromJSON(json));
    } catch (_e) {
      return false;
    }
    if (!nodes.length) return false;
    // One paragraph flows into the line the caret is on, like typed text; blocks
    // land as blocks.
    const single = nodes.length === 1 && nodes[0].type.name === "paragraph";
    const slice = single ? Slice.maxOpen(Fragment.from(nodes)) : new Slice(Fragment.from(nodes), 0, 0);
    const tr = view.state.tr.replaceSelection(slice).scrollIntoView();
    view.dispatch(tr);
    this._noticeLeftOut(dropped);
    return true;
  }

  // Plain text, Sanity's rule (task-68314b1d334213e8): a blank line starts a new
  // block, a single newline is a soft break inside the block. ProseMirror's own
  // plain-text paste made every line its own paragraph. `force` is Paste as plain
  // text (Shift), which takes this path even when the clipboard also holds HTML.
  export function _pastePlainText(view, event, force = false) {
    const data = event && event.clipboardData;
    if (!data) return false;
    const text = data.getData("text/plain");
    if (!text || (!force && data.getData("text/html")) || !/\r?\n/.test(text)) return false;
    if (view.state.selection.$from.parent.type.spec.code) return false;
    const { schema } = view.state;
    const breakType = schema.nodes.hardBreak;
    const paragraph = schema.nodes.paragraph;
    if (!breakType || !paragraph) return false;
    // A soft break needs a block that may hold one (portable-text-boundary.js:
    // paragraphs and headings). Pasted into a quote or another role block, every
    // line becomes its own block instead, as before.
    const breakable = ["paragraph", "heading"].includes(view.state.selection.$from.parent.type.name);
    const normalized = text.replace(/\r\n?/g, "\n");
    const blocks = breakable ? normalized.split(/\n[ \t]*\n+/) : normalized.split(/\n+/);
    const nodes = [];
    for (const block of blocks) {
      const lines = block.split("\n");
      const inline = [];
      lines.forEach((line, i) => {
        if (i > 0) inline.push(breakType.create());
        if (line) inline.push(schema.text(line));
      });
      while (inline.length && inline[inline.length - 1].type === breakType) inline.pop();
      if (inline.length) nodes.push(paragraph.create(null, inline));
    }
    if (!nodes.length) return false;
    view.dispatch(view.state.tr.replaceSelection(Slice.maxOpen(Fragment.from(nodes))).scrollIntoView());
    return true;
  }

  // ── paste ⇄ field vocabulary (task-76c5440175affe20) ─────────────────────────
  //
  // The vocabulary veto drops a whole transaction that introduces anything the
  // field cannot hold, so a paste carrying ONE such node (a table, a quote, a
  // <pre>) used to vanish without a word. Every paste path fits its content first:
  // each block becomes the nearest shape the field admits (paste-vocabulary.js),
  // marks the field lacks are unwrapped, and whatever had nothing to keep (an
  // image) is named in a notice that stays until the person moves on.
  // Whether this drop moves blocks within this canvas, decided the way
  // ProseMirror's own drop does (the copy modifier), so a moved block keeps its id
  // and a copy-drop's copy reads as new. ProseMirror reads the slice right after
  // this handler, in the same event.
  export function _noteDropMoves(view, event) {
    this._dropMoves = !!view.dragging && !event[DRAG_COPY_KEY];
    queueMicrotask(() => { this._dropMoves = false; });
    return false;
  }

export function _fitPastedSlice(slice) {
    const imagesLeftOut = this._pasteImagesLeftOut || 0;
    this._pasteImagesLeftOut = 0;
    if (!this._editable) return slice;
    const vocab = parseVocabulary(this.getAttribute("data-vocabulary"));
    let out = slice;
    let dropped = Array(imagesLeftOut).fill("an image");
    if (vocab && slice.content.childCount) {
      if (slice.content.firstChild.isBlock) {
        const fitted = this._fitPastedNodes(slice.content, 0);
        if (fitted) ({ slice: out } = fitted), (dropped = dropped.concat(fitted.dropped));
      } else {
        out = new Slice(stripMarks(slice.content, (name) => markAllowed(name, vocab)), slice.openStart, slice.openEnd);
      }
    }
    this._noticeLeftOut(dropped);
    return out;
  }

  // Fit a fragment of top-level pasted nodes to the field's vocabulary. Answers
  // null when nothing needed fitting (so the native slice keeps its open ends),
  // else the fitted slice and what was left out.
  export function _fitPastedNodes(fragment, imagesLeftOut = 0) {
    const vocab = parseVocabulary(this.getAttribute("data-vocabulary"));
    const leftOut = Array(imagesLeftOut).fill("an image");
    if (!vocab) return leftOut.length ? { slice: new Slice(fragment, 0, 0), dropped: leftOut } : null;
    const blocks = docToBlocks({ type: "doc", content: fragment.toJSON() || [] });
    if (!blocksNeedFitting(blocks, vocab)) return leftOut.length ? { slice: new Slice(fragment, 0, 0), dropped: leftOut } : null;
    const fit = fitBlocksToVocabulary(blocks, vocab);
    const schema = this._editor.schema;
    // Fresh nodes: an id the paste carried (copied from this or another paper)
    // must not collide with a block the doc already holds.
    const nodes = this._rt(fit.blocks).content.map((json) =>
      schema.nodeFromJSON({ ...json, attrs: { ...(json.attrs || {}), bpId: null } }));
    return { slice: Slice.maxOpen(Fragment.from(nodes)), dropped: leftOut.concat(fit.dropped) };
  }

export function _noticeLeftOut(dropped) {
    const message = droppedNotice(dropped);
    if (message) this._showHTMLPasteNotice(message);
  }

export function _showHTMLPasteNotice(message) {
    this._clearHTMLPasteNotice();
    const notice = this.ownerDocument.createElement("div");
    notice.dataset.bpPasteNotice = "";
    notice.setAttribute("role", "status");
    notice.textContent = message;
    this.appendChild(notice);
    const viewport = this.ownerDocument.defaultView;
    const bounds = this.getBoundingClientRect();
    const availableWidth = Math.max(1, Math.min(bounds.right, viewport.innerWidth) - Math.max(0, bounds.left) - 16);
    const width = Math.min(420, availableWidth, Math.max(1, viewport.innerWidth - 16));
    notice.style.width = `${width}px`;
    notice.style.maxHeight = `${Math.max(1, viewport.innerHeight - 16)}px`;
    notice.style.left = `${Math.max(8, Math.min(bounds.left + 8, viewport.innerWidth - width - 8))}px`;
    notice.tabIndex = 0;
    const caret = this._caretRect();
    const height = notice.getBoundingClientRect().height;
    const below = caret.bottom + 8;
    const preferred = below + height <= viewport.innerHeight - 8 ? below : caret.top - height - 8;
    notice.style.top = `${Math.max(8, Math.min(preferred, viewport.innerHeight - height - 8))}px`;
    // A fixed notice does not push the document. Dismiss when its anchor moves
    // or the person resumes work; no timeout can hide the recovery guidance.
    this._pasteNoticeDismiss = (event) => {
      if (["pointerdown", "scroll"].includes(event.type) && notice.contains(event.target)) return;
      if (event.type === "keydown" && event.key !== "Escape") return;
      const restoreFocus = event.type === "keydown" && event.key === "Escape" && notice.contains(this.ownerDocument.activeElement);
      this._clearHTMLPasteNotice();
      if (restoreFocus) this._editor?.commands.focus();
    };
    for (const name of ["pointerdown", "scroll", "keydown"]) this.ownerDocument.addEventListener(name, this._pasteNoticeDismiss, true);
    viewport.addEventListener("resize", this._pasteNoticeDismiss);
  }

export function _clearHTMLPasteNotice() {
    this.querySelector("[data-bp-paste-notice]")?.remove();
    if (!this._pasteNoticeDismiss) return;
    for (const name of ["pointerdown", "scroll", "keydown"]) this.ownerDocument.removeEventListener(name, this._pasteNoticeDismiss, true);
    this.ownerDocument.defaultView?.removeEventListener("resize", this._pasteNoticeDismiss);
    this._pasteNoticeDismiss = null;
  }

export function _showFigureConstraint(message = "A Figure keeps one content block. Enter cannot split or remove it.") {
    let notice = this.querySelector("[data-bp-figure-constraint]");
    if (!notice) {
      notice = document.createElement("div");
      notice.dataset.bpFigureConstraint = "";
      notice.className = "bp-canvas-constraint-notice";
      notice.setAttribute("role", "status");
      this.appendChild(notice);
    }
    notice.textContent = message;
  }

export function _clearFigureConstraint(transaction = null) {
    // A programmatic write (an id write-back after a save, a server echo) is not
    // the person resuming work: it leaves a paste notice up, so "Left out: an
    // image" outlasts the save it rode in on (task-76c5440175affe20).
    // The paste's own transaction does not clear the notice that paste raised.
    if (!transaction || (transaction.getMeta("addToHistory") !== false && transaction.getMeta("uiEvent") !== "paste")) {
      this._clearHTMLPasteNotice();
    }
    this.querySelector("[data-bp-figure-constraint]")?.remove();
  }

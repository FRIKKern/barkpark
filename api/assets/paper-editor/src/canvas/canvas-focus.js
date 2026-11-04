import { isLockedTitle } from "./locks.js";
import { NodeSelection, Selection, TextSelection } from "@tiptap/pm/state";


// How long a focusBlock(id) for a block that has not arrived yet stays armed.
const PENDING_FOCUS_MS = 5000;


// The first control a person can type into or press inside a node view, or null.
function focusableControlIn(dom) {
  if (!dom || typeof dom.querySelectorAll !== "function") return null;
  // Something to type into first (a picker's search, a field's input); a button only
  // when the node view has nothing else (a Boolean toggle, a picker's Choose).
  for (const selector of ['input:not([type="hidden"]), select, textarea, [contenteditable="true"]', 'button, [tabindex]:not([tabindex="-1"])']) {
    for (const el of dom.querySelectorAll(selector)) {
      if (el.disabled || el.readOnly || el.getAttribute("aria-hidden") === "true") continue;
      if (el.closest && el.closest('[hidden], [aria-hidden="true"]')) continue;
      return el;
    }
  }
  return null;
}

function captureResumeFocus() {
  if (this._resumeFocusState !== "idle") {
    return this._resumeFocusState === "armed";
  }

  const editor = this._editor;
  const ownerDocument = this.ownerDocument;
  const activeElement = ownerDocument?.activeElement;
  const paperRoot = this.closest(".bp-paper-editor[data-paper-doc-key]");
  const paperRootId = paperRoot?.id;
  const paperDocKey = paperRoot?.getAttribute("data-paper-doc-key");
  const hasRichFocus =
    editor?.view?.hasFocus?.() === true &&
    activeElement != null &&
    this.contains(activeElement);

  if (
    !this.isConnected ||
    this._mode !== "rich" ||
    !this._editable ||
    editor?.isEditable !== true ||
    !hasRichFocus ||
    !paperRoot ||
    !paperRootId ||
    !paperDocKey
  ) {
    return false;
  }

  this._resumeFocusIntent = {
    editor,
    ownerDocument,
    paperRootId,
    paperDocKey,
  };
  this._resumeFocusState = "armed";
  this._onResumeFocusIn = (event) => {
    const target = event.target;
    const emptyFocusTarget =
      target == null || target === ownerDocument.body || target === ownerDocument.documentElement;
    if (!emptyFocusTarget && !this.contains(target)) this._cancelResumeFocus();
  };
  ownerDocument.addEventListener("focusin", this._onResumeFocusIn, true);
  return true;
}

function restoreResumeFocus() {
  const intent = this._resumeFocusIntent;
  const armed = this._resumeFocusState === "armed";
  this._clearResumeFocusIntent();
  if (!armed || !intent) return false;

  const { editor, ownerDocument, paperRootId, paperDocKey } = intent;
  const activeElement = ownerDocument?.activeElement;
  const paperRoot = this.closest(".bp-paper-editor[data-paper-doc-key]");
  const focusIsEmpty =
    activeElement == null ||
    activeElement === ownerDocument.body ||
    activeElement === ownerDocument.documentElement;

  if (
    !this.isConnected ||
    this._editor !== editor ||
    this.ownerDocument !== ownerDocument ||
    this._mode !== "rich" ||
    !this._editable ||
    editor.isEditable !== true ||
    paperRoot?.id !== paperRootId ||
    paperRoot?.getAttribute("data-paper-doc-key") !== paperDocKey ||
    this.closest("[inert]") != null ||
    !focusIsEmpty
  ) {
    return false;
  }

  editor.view.focus();
  return true;
}

function _cancelResumeFocus() {
  if (this._resumeFocusState !== "armed") return;
  const ownerDocument = this._resumeFocusIntent?.ownerDocument;
  if (ownerDocument && this._onResumeFocusIn) {
    ownerDocument.removeEventListener("focusin", this._onResumeFocusIn, true);
  }
  this._resumeFocusIntent = null;
  this._resumeFocusState = "cancelled";
  this._onResumeFocusIn = null;
}

function _clearResumeFocusIntent() {
  const ownerDocument = this._resumeFocusIntent?.ownerDocument;
  if (ownerDocument && this._onResumeFocusIn) {
    ownerDocument.removeEventListener("focusin", this._onResumeFocusIn, true);
  }
  this._resumeFocusIntent = null;
  this._resumeFocusState = "idle";
  this._onResumeFocusIn = null;
}

// A whole-document replace (a REORDER, which cannot be applied in place) maps
// the selection through "everything was replaced", so the caret lands at an
// edge of the doc — after a "Move up" that is inside the moved block, and the
// author's next Enter or "/" goes there (task-b2abe773242241f8). While the
// author is in the editor, remember the caret as block id + offset and put it
// back in the same block afterwards. Selection only: no doc change, no ops.
function _captureCaret() {
  const editor = this._editor;
  if (!editor || !editor.view || !editor.isFocused) return null;
  const { $head } = editor.state.selection;
  if ($head.depth < 1) return null;
  const id = $head.node(1)?.attrs?.bpId;
  if (id == null) return null;
  return { id, offset: $head.pos - $head.before(1) };
}

function _restoreCaret(caret) {
  if (!caret || !this._editor) return;
  const { state, view } = this._editor;
  let target = null;
  state.doc.forEach((node, pos) => {
    if (!target && node.attrs?.bpId === caret.id) target = { node, pos };
  });
  if (!target) return;
  const at = Math.min(target.pos + caret.offset, target.pos + target.node.nodeSize - 1);
  let selection;
  try {
    selection = TextSelection.near(state.doc.resolve(at));
  } catch (_) {
    return;
  }
  view.dispatch(state.tr.setSelection(selection).setMeta("addToHistory", false));
}

// A canvas at rest must not hold a NodeSelection on a whole block. A fresh doc (or one
// replaced by setContent) starts with the selection on block 0, and when that block is
// an atom (a bound field-string title) a click whose DOM selection never reached the
// editor state left it there, so the first keystroke REPLACED the bound block — a data
// loss (task-f24549dea0618da2). While the editor is unfocused, move such a selection to
// the first text position; with no text block, leave it. Selection-only: no doc change,
// no ops, no history.
function _restSelectionOffAtom() {
  const editor = this._editor;
  if (!editor || editor.isDestroyed) return;
  const { state, view } = editor;
  if (!(state.selection instanceof NodeSelection)) return;
  if (view && typeof view.hasFocus === "function" && view.hasFocus()) return;
  const text = TextSelection.findFrom(state.doc.resolve(0), 1, true);
  if (!text) return;
  view.dispatch(state.tr.setSelection(text).setMeta("addToHistory", false));
}

// Put the caret in the top-level block `id` and focus the editor. The host
// calls this after an Add-block / Ingress-ghost write: an EMPTY paragraph is
// collapsed at rest (resting-scaffolds.js) and only opens while the caret is
// in it, so without this the new block was invisible and typing went nowhere.
// The block may not have arrived yet (the server's run update can land after
// the request) — remember it briefly and retry on the next external apply.
// Returns true when the caret was placed. Selection-only: no doc change, no
// ops, no history entry.
function focusBlock(id) {
  if (typeof id !== "string" || id === "") return false;
  const pos = this._editor ? this._topLevelPos(id) : null;
  if (pos == null) {
    this._pendingFocus = { id, until: Date.now() + PENDING_FOCUS_MS };
    return false;
  }
  this._pendingFocus = null;
  const { state, view } = this._editor;
  // A field block (String, Select, Date & time, the Image/Reference pickers…) is an
  // atom whose node view holds its own control: a TextSelection lands BESIDE it, so
  // focus the control instead (task-13abe9408c006c96). An atom with no control — a
  // divider — falls through to the caret as before.
  const node = state.doc.nodeAt(pos);
  if (node && node.isAtom && !node.isTextblock) {
    const nodeDom = view.nodeDOM(pos);
    // Reader-shaped fields keep their controls mounted but hidden at rest.
    // Wake that field synchronously before resolving its focus target so the
    // public focusBlock contract still lands in the native control/picker.
    if (nodeDom && nodeDom.matches && nodeDom.matches("[data-field-type]")) {
      nodeDom.dispatchEvent(new CustomEvent("bp-activate-field-editor"));
    }
    const control = focusableControlIn(nodeDom);
    if (control) {
      control.focus();
      return true;
    }
  }
  let selection;
  try {
    selection = TextSelection.near(state.doc.resolve(pos + 1));
  } catch (_e) {
    return false;
  }
  view.dispatch(state.tr.setSelection(selection).setMeta("addToHistory", false));
  view.focus();
  return true;
}

// Select the top-level card `id`, an image or an object block, as a click on it does
// (contract 1.12.0, Sanity's selected block object): a host that wakes the body on a
// click on its card at rest hands that click on, instead of a caret past the card.
// Answers true when selected. Selection-only: no doc change, no ops, no history.
function selectBlock(id) {
  const pos = this._editor && typeof id === "string" && id !== "" ? this._topLevelPos(id) : null;
  if (pos == null) return false;
  const { state, view } = this._editor;
  const node = state.doc.nodeAt(pos);
  if (!node || (node.type.name !== "bpImage" && node.type.name !== "bpOpaque")) return false;
  view.dispatch(state.tr.setSelection(NodeSelection.create(state.doc, pos)).setMeta("addToHistory", false));
  view.focus();
  return true;
}

// Enter with the caret in the locked title. Returns false when the caret is not
// in it (Enter keeps its normal meaning). Otherwise the caret goes to the first
// unlocked block after the title in this run; with none, to the next run's first
// body block, else the first ghost slot or the "+ Add block" control. Selection
// only: no doc change, no op, no history entry. Returns true either way, so the
// Enter stays a no-op on the document (the D6 guarantee).
function _enterFromLockedTitle() {
  const editor = this._editor;
  if (!editor) return false;
  const { selection } = editor.state;
  const $from = selection.$from;
  if ($from.depth !== 1 || !isLockedTitle($from.parent)) return false;
  if (!selection.$to.sameParent($from)) return false;
  if (this._focusBodyFrom($from.index(0) + 1)) return true;
  this._focusBodyAfterRun();
  return true;
}

// Put the caret in the first unlocked top-level block at or after `startIndex`.
function _focusBodyFrom(startIndex = 0) {
  const editor = this._editor;
  if (!editor || !this._editable) return false;
  const { state, view } = editor;
  let target = null;
  state.doc.forEach((node, offset, index) => {
    if (target == null && index >= startIndex && node.attrs?.locked !== true) target = offset;
  });
  if (target == null) return false;
  let next;
  try {
    next = Selection.near(state.doc.resolve(target), 1);
  } catch (_e) {
    return false;
  }
  if (!next || next.from < target) return false;
  view.dispatch(state.tr.setSelection(next).setMeta("addToHistory", false).scrollIntoView());
  view.focus();
  return true;
}

// 1.22.0: focus the editing surface where its selection already is, so a host
// no longer focuses [contenteditable] or .ProseMirror inside the element.
function focusSelection() {
  const view = this._editor?.view;
  if (!view) return false;
  view.focus();
  return view.hasFocus();
}

// Public seam for a neighbouring run: focus this run's first body block.
function focusFirstBodyBlock() {
  return this._focusBodyFrom(0);
}

// The title run holds no body block: try the following canvas runs in document
// order, then the first ghost slot (Ingress / Featured), then "+ Add block".
function _focusBodyAfterRun() {
  const root = this.closest(".bp-paper-editor") || this.ownerDocument?.body;
  if (!root) return false;
  const canvases = [...root.querySelectorAll("bp-paper-canvas")];
  for (const canvas of canvases.slice(canvases.indexOf(this) + 1)) {
    if (typeof canvas.focusFirstBodyBlock === "function" && canvas.focusFirstBodyBlock()) return true;
  }
  const affordance =
    root.querySelector('[data-test-id="paper-ghost-slots"] button:not([disabled])') ||
    root.querySelector('[data-test-id="paper-add-block"] select, [data-test-id="paper-add-block"] button');
  if (!affordance) return false;
  this._editor?.commands.blur();
  affordance.focus();
  return true;
}

function _topLevelPos(id) {
  let found = null;
  this._editor.state.doc.forEach((node, pos) => {
    if (found == null && node.attrs?.bpId === id) found = pos;
  });
  return found;
}

function _consumePendingFocus() {
  const pending = this._pendingFocus;
  if (!pending) return;
  if (Date.now() > pending.until) {
    this._pendingFocus = null;
    return;
  }
  this.focusBlock(pending.id);
}

export {
  _cancelResumeFocus, _captureCaret, _clearResumeFocusIntent, _consumePendingFocus,
  _enterFromLockedTitle, _focusBodyAfterRun, _focusBodyFrom, _restSelectionOffAtom, _restoreCaret,
  _topLevelPos, captureResumeFocus, focusBlock, focusFirstBodyBlock, focusSelection,
  restoreResumeFocus, selectBlock,
};

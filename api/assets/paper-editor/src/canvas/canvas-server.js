import { normalizeCanvasDoc, replaceTopNode } from "./canvas-document.js";
import { nodeContentEqual, withObjectOverrides } from "./run-convert.js";
import { deepCloneBlocks } from "./source-realign.js";
import { TextSelection } from "@tiptap/pm/state";


// S4a: ECHO-DRIVEN BASELINE — the server's confirmed-blocks echo lands here.
//
// After apply_paper_block_ops persists a batch, the server re-partitions the
// confirmed blocks and pushes `bp:canvas-update` carrying THIS run's blocks;
// the BarkparkPaperCanvas hook routes them to this method. There are two cases:
//
//   OWN ECHO (the overwhelming common case) — the user edited, the server
//     confirmed the SAME blocks. We detect this with reconcileServerEcho (the
//     PURE S4a reconciler): it compares the confirmed blocks to the LIVE doc
//     node-by-node, treating a live bpId:null node as a WILDCARD matching the
//     server-minted id at that index. This is the make-or-break for NEW blocks
//     (Enter-split / paste / typed paragraph — the most common structural
//     edit): the live new-block node still carries bpId:null while the confirmed
//     block carries a freshly-minted id (say "m1"). A naive runToOps gate would
//     MISDETECT this as external (it mints a fresh id for the null node and
//     reports remove+insert) and, because the live node never learns "m1", every
//     later batch would re-mint it (the op size never shrinks, the id churns).
//     Instead we WRITE the server-confirmed ids back onto the live null-bpId
//     nodes (an ATTR-ONLY change — see _stampOwnEchoIds), so the echo no-ops AND
//     the next diff is truly incremental. ZERO setContent, ZERO caret movement.
//
//   EXTERNAL EDIT — the confirmed blocks DIFFER from the live doc (another tab /
//     agent / the ingest endpoint changed the run): a different STRUCTURE (length
//     or kind mismatch) or a REAL content change. We reset the baseline AND
//     update the editor to the confirmed content. The setContent transaction is
//     marked addToHistory:false so an external edit NEVER enters the user's undo
//     stack. GUARD: if the editor is FOCUSED, composing (IME), or has an edit in
//     its debounce window, we QUEUE the update and apply it after that local
//     state settles so we never yank the caret or erase an un-emitted draft —
//     the diff baseline stays with the displayed snapshot until that render lands.
// A revision-owning host may present acknowledged external content while an
// idle rich-text caret remains focused. Unlike applyServerBlocks this never
// queues: true means the content and baseline landed synchronously; false
// means the host must retain its previous revision. The caller must fence old
// read/echo responses by revision. It never discards an unacknowledged draft.
function applyServerBlocksIfIdle(blocks) {
  if (!this._editor || this._mode === "source" || this._editor.view.composing ||
      this._bubble?.hasFocus()) return false;
  const active = this.ownerDocument.activeElement;
  if (active && this.contains(active) && active !== this._editor.view.dom) return false;
  // Some node views buffer fields outside ProseMirror. Flush their real input
  // first so a recently blurred field cannot masquerade as an idle canvas.
  this.querySelectorAll("[data-bp-type]").forEach(node => {
    node.dispatchEvent(new CustomEvent("bp-flush-node"));
  });
  if (this.hasPendingChanges()) return false;
  if (!Array.isArray(blocks)) throw new TypeError("Expected confirmed Paper blocks");
  this._programmaticApply = true;
  try {
    this._applyExternalContent(blocks);
    this._blocks = deepCloneBlocks(blocks);
    this._clearPendingServerBlocks();
    // These receipts already completed successfully; this newer authority
    // supersedes them. Actual in-flight saves remain guarded above.
    this._awaitingOwnEchoes = [];
    return true;
  } finally {
    this._programmaticApply = false;
  }
}

function applyServerBlocks(blocks, echoMeta = null) {
  if (!this._editor) return;
  this._readDomTyping();
  const next = Array.isArray(blocks) ? blocks : [];
  const echoMode = echoMeta && typeof echoMeta === "object" ? echoMeta.mode : null;
  const echoRequestId = echoMeta && typeof echoMeta === "object"
    ? echoMeta.requestId
    : null;
  const coordinatorOwnMode = echoMode === "own" || echoMode === "own-stale";

  // An echo can confirm an earlier local snapshot while the user has already
  // edited beyond it. Recognize that snapshot as our own and advance only the
  // confirmed baseline; replacing the live doc here would erase the newer edit.
  if (this._inflightOps) {
    const exactInflightEcho = this._re(
      next,
      this._rt(this._inflightOps.afterBlocks).content || [],
    ).ownEcho;
    const foreignOwnRequest = coordinatorOwnMode && echoRequestId != null &&
      this._inflightOps.requestId != null && echoRequestId !== this._inflightOps.requestId;
    const correlatedOwnEcho = echoMode === "own" && echoRequestId != null &&
      echoRequestId === this._inflightOps.requestId;
    if ((!foreignOwnRequest && exactInflightEcho) || correlatedOwnEcho) {
      this._inflightOps.echoSeen = true;
      if (!exactInflightEcho) {
        this._queueServerBlocks(next);
      } else if (echoMode !== "own-stale") {
        this._clearPendingServerBlocks();
      }
      return;
    }
  }
  const awaitingIndex = this._awaitingOwnEchoes.findIndex((entry) =>
    !(coordinatorOwnMode && echoRequestId != null && entry.requestId != null &&
      echoRequestId !== entry.requestId) &&
    this._re(next, this._rt(entry.blocks).content || []).ownEcho
  );
  if (awaitingIndex !== -1) {
    this._awaitingOwnEchoes.splice(0, awaitingIndex + 1);
    if (echoMode === "own-stale") this._flushPendingServerBlocks();
    else this._clearPendingServerBlocks();
    return;
  }
  // The coordinator has already observed a newer confirmed revision. A stale
  // own receipt can close an exact snapshot above, but a non-exact payload is
  // never authority and must not replace or queue over the newer document.
  if (echoMode === "own-stale") return;
  const correlatedAwaitingIndex = echoMode === "own" && echoRequestId != null
    ? this._awaitingOwnEchoes.findIndex((entry) => entry.requestId === echoRequestId)
    : -1;
  if (correlatedAwaitingIndex !== -1) {
    this._awaitingOwnEchoes.splice(0, correlatedAwaitingIndex + 1);
    if (this._liveRemote) {
      this._takeServerBlocks(next);
    } else if (this._isEditingNow()) {
      this._queueServerBlocks(next);
    } else {
      this._blocks = deepCloneBlocks(next);
      this._clearPendingServerBlocks();
      this._programmaticApply = true;
      try {
        this._applyExternalContent(next);
      } finally {
        this._programmaticApply = false;
      }
    }
    return;
  }

  // The match check, id-tolerant. reconcileServerEcho compares the confirmed
  // blocks to the LIVE top-level nodes, treating a live bpId:null as a wildcard
  // for the server id at that index (the NEW-block case), and returns the
  // own-echo verdict + the id-writebacks. normalizeCanvasDoc first so we compare
  // against the same shape the emit path diffs (phantom nested attrs / split
  // dedup), exactly as runToOps was tested against.
  const liveContent = this._normalizedDoc(this._editor.getJSON()).content || [];
  const { ownEcho, idWrites } = this._re(next, liveContent);

  // A genuinely external echo cannot safely replace local content while one
  // or more emitted snapshots are still awaiting confirmation. Defer it; a
  // later own echo carries the server's newest folded state and supersedes it.
  if (this._inflightOps || this._dirtyWhileInflight || this._awaitingOwnEchoes.length > 0) {
    if (this._liveRemote) this._takeServerBlocks(next);
    else this._queueServerBlocks(next);
    return;
  }

  if (ownEcho) {
    this._blocks = next;
    // OWN ECHO: stamp the server-confirmed ids onto any just-minted live nodes
    // (bpId:null), an ATTR-ONLY transaction PM maps the selection through (the
    // caret does NOT move) and that does NOT enter undo. NO setContent. After
    // the stamp the live nodes carry the confirmed ids, so the next diff is
    // truly incremental (no re-mint, no id churn). If a stale external-edit echo
    // was queued, it is now superseded by this confirmation — drop it.
    this._stampOwnEchoIds(idWrites, next);
    this._clearPendingServerBlocks();
    return;
  }

  // EXTERNAL EDIT: the confirmed content differs from the live doc. If the
  // user is mid-edit (focused or IME-composing), defer the visible re-render
  // until they release; otherwise apply it now. A liveRemote canvas takes it
  // block by block instead (_takeServerBlocks).
  if (this._liveRemote) {
    this._takeServerBlocks(next);
  } else if (this._isEditingNow()) {
    this._queueServerBlocks(next);
  } else {
    this._blocks = next;
    this._clearPendingServerBlocks();
    this._programmaticApply = true;
    try {
      this._applyExternalContent(next);
    } finally {
      this._programmaticApply = false;
    }
  }
}

// OWN-ECHO ID WRITEBACK — stamp the server-confirmed ids onto the live
// just-minted (bpId:null) top-level nodes. ATTR-ONLY: each setNodeMarkup
// changes ONLY the node's attrs (bpId, and bpType if it too was null) and
// touches NO content, so ProseMirror MAPS the current selection straight
// through the transaction — the caret stays exactly where the user is typing.
// setMeta('addToHistory', false) keeps the stamp out of the user's undo stack.
// We walk the live doc's top-level nodes so `offset` is each node's start pos
// (what setNodeMarkup keys by). idWrites is index-keyed into that same top-level
// sequence (reconcileServerEcho built it from the same liveContent).
function _stampOwnEchoIds(idWrites, serverBlocks) {
  if (!this._editor || !idWrites || idWrites.length === 0) return;
  const writeByIndex = new Map();
  for (const w of idWrites) writeByIndex.set(w.index, w);

  const { state, view } = this._editor;
  const tr = state.tr;
  let mutated = false;
  state.doc.forEach((node, offset, index) => {
    const w = writeByIndex.get(index);
    if (!w) return;
    const attrs = { ...node.attrs, bpId: w.id };
    // Stamp bpType too only when it was also null on the live node and the
    // reconciler resolved it from the confirmed block.
    if (w.bpType != null && node.attrs && node.attrs.bpType == null) {
      attrs.bpType = w.bpType;
    }
    if (node.type.name === "note") {
      // Note field history must survive the non-history identity stamp.
      tr.setNodeAttribute(offset, "bpId", attrs.bpId);
      if (attrs.bpType !== node.attrs.bpType) tr.setNodeAttribute(offset, "bpType", attrs.bpType);
    } else {
      tr.setNodeMarkup(offset, undefined, attrs);
    }
    mutated = true;
  });
  if (!mutated) return;
  // Attr-only change → no content change → selection maps through → caret
  // does NOT move. addToHistory:false keeps it out of undo.
  tr.setMeta("addToHistory", false);
  view.dispatch(tr);
}

// Stamp every id minted by docToBlocks back into the corresponding live PM
// node, including editable descendants inside section/container nodes. The
// stable projection has the same preorder shape as the live document; text
// nodes participate in the walk so positions cannot drift between siblings.
function _stampMaterializedIds(stableDoc, nextDoc, { dryRun = false } = {}) {
  if (!this._editor || !stableDoc) return false;
  // A node is stamped when the diff read it as new: no id, or a copy
  // normalizeCanvasDoc cleared (freshenRepeatedIds). Typing into stamped blocks
  // has neither, and flattening the whole projection per keystroke was the
  // emit's largest remaining cost (task-fb938eb8be3bce48).
  const flatten = (nodes, out = []) => {
    for (const node of nodes || []) {
      out.push(node);
      flatten(node.content, out);
    }
    return out;
  };
  const diffed = flatten(nextDoc.content);
  if (!diffed.some((node) => node.type !== "text" && node.attrs?.bpId == null)) return false;
  const stableNodes = flatten(stableDoc.content);

  const { state, view } = this._editor;
  const tr = state.tr;
  let index = 0;
  let mutated = false;
  state.doc.descendants((node, pos) => {
    const diffedId = diffed[index]?.attrs?.bpId;
    const stable = stableNodes[index++];
    const stableId = stable?.attrs?.bpId;
    if (!node.isText && diffedId == null && stableId != null) {
      const bpType = node.attrs.bpType == null ? stable.attrs?.bpType : node.attrs.bpType;
      if (node.type.name === "note") {
        // Keep pre-save label/lead AttrSteps mapped to this same note.
        tr.setNodeAttribute(pos, "bpId", stableId);
        if (bpType !== node.attrs.bpType) tr.setNodeAttribute(pos, "bpType", bpType);
      } else {
        tr.setNodeMarkup(pos, undefined, { ...node.attrs, bpId: stableId, bpType });
      }
      mutated = true;
    }
  });
  if (!mutated || dryRun) return mutated;
  tr.setMeta("addToHistory", false);
  view.dispatch(tr);
  return true;
}

// True when the editor is actively being edited and a setContent would yank the
// caret OR clobber an unseen edit: it has focus, ProseMirror is mid-IME-
// composition, a local update is waiting in the debounce window, OR we are in
// SOURCE mode. Each is a reason to DEFER an external re-render.
//
// SOURCE mode is the MAJOR case: the rich editor is HIDDEN and a Markdown textarea
// owns input. If applyServerBlocks applied an external echo now, it would setContent
// on the hidden editor — and the subsequent source-exit setContent (L1) would then
// CLOBBER that external edit (the user never sees it; it's lost). So source mode is
// "busy" exactly like focus/IME: the external blocks are QUEUED (_pendingServerBlocks)
// and flushed on exit (_exitSourceMode → _flushPendingServerBlocks), so the queued
// external edit lands once the user is back in rich.
function _isEditingNow() {
  if (!this._editor) return false;
  // With flushKeepsSource, source mode is editing only while the textarea holds text
  // not yet committed (1.20.0); without it, for as long as source mode is open.
  if (this._mode === "source") return !this._flushKeepsSource || this._sourceEl?.value !== this._sourceOriginalMd;
  const composing = !!(this._editor.view && this._editor.view.composing);
  const noteIslandFocused = this.querySelector('.bp-canvas-note [role="textbox"]:focus, .bp-canvas-note[data-note-pending]');
  return this._editor.isFocused || noteIslandFocused || this._bubble?.hasFocus() || composing || this._debounceTimer != null;
}

// Apply the confirmed external content to the editor WITHOUT entering the undo
// stack. setContent(_, { emitUpdate: false }) does not emit an update (so we don't bounce an op
// batch back); the addToHistory:false transaction meta keeps the external edit
// out of the user's undo history. The baseline was already reset by the caller.
function _applyExternalContent(blocks) {
  if (!this._editor) return;
  const { state } = this._editor;
  const next = state.schema.nodeFromJSON(this._rt(blocks));
  const previousIds = [];
  const nextIds = [];
  state.doc.forEach((node) => previousIds.push(node.attrs.bpId));
  next.forEach((node) => nextIds.push(node.attrs.bpId));
  const previousSet = new Set(previousIds);
  const nextSet = new Set(nextIds);
  const retainedIds = previousIds.filter((id) => nextSet.has(id));
  const nextRetainedIds = nextIds.filter((id) => previousSet.has(id));
  const stableOrder = previousIds.every((id) => id != null) && nextIds.every((id) => id != null) &&
    previousSet.size === previousIds.length && nextSet.size === nextIds.length &&
    retainedIds.every((id, index) => id === nextRetainedIds[index]);
  if (stableOrder) {
    // Preserve mappings/history for untouched siblings. Replacing the entire
    // document maps their local undo steps through a deletion, even when the
    // remote update changed, inserted, or removed only other blocks.
    const tr = state.tr.setMeta("addToHistory", false).setMeta("preventUpdate", true);
    let position = 0;
    let previousIndex = 0;
    next.forEach((replacement) => {
      const id = replacement.attrs.bpId;
      if (!previousSet.has(id)) {
        tr.insert(position, replacement);
        position += replacement.nodeSize;
        return;
      }
      while (previousIds[previousIndex] !== id) {
        const removed = state.doc.child(previousIndex++);
        tr.delete(position, position + removed.nodeSize);
      }
      const node = state.doc.child(previousIndex++);
      replaceTopNode(tr, node, replacement, position);
      position += replacement.nodeSize;
    });
    while (previousIndex < state.doc.childCount) {
      const removed = state.doc.child(previousIndex++);
      tr.delete(position, position + removed.nodeSize);
    }
    if (tr.docChanged) this._editor.view.dispatch(tr);
    this._restSelectionOffAtom();
    if (this._mode === "source" && this._flushKeepsSource) this._syncSourceText();
    this._consumePendingFocus();
    return;
  }
  const caret = this._captureCaret();
  this._editor
    .chain()
    .setContent(this._rt(blocks), { emitUpdate: false })
    .command(({ tr }) => {
      tr.setMeta("addToHistory", false);
      return true;
    })
    .run();
  this._restoreCaret(caret);
  this._restSelectionOffAtom();
  if (this._mode === "source" && this._flushKeepsSource) this._syncSourceText();
  this._consumePendingFocus();
}

// ── liveRemote (1.15.0): server blocks while the author edits ─────────────
//
//   remote block is not one the author holds  ─► applied now, selection mapped
//   caret block, nothing unsaved in it          ─► applied now, caret mapped
//   a block with unsaved typing, remote differs ─► live text kept, the remote
//       block held and reported (bp-canvas-remote-held); retried at release
//
// "Holds" means: changed since the baseline, saved but not yet echoed (its
// batch is on _awaitingOwnEchoes), or the caret's block when the snapshot
// removes it. Held snapshots stay pending; the next own echo or snapshot
// supersedes them, as before.
function _takeServerBlocks(remote) {
  this._queueServerBlocks(remote);
  this._flushPendingServerBlocks();
}

// Merge the pending snapshot now. False when it cannot merge here; the
// release path then waits, as without liveRemote.
function _mergePendingServerBlocks() {
  if (!this._canMergeRemote()) return false;
  const held = this._mergeRemote(this._pendingServerBlocks);
  if (held === null) return false;
  if (held.length) this._reportHeld(held);
  else this._clearPendingServerBlocks();
  return true;
}

// Moments the live document cannot take a snapshot block by block: a batch in
// flight (its ack installs the emit's snapshot), an IME composition, source
// mode, or an input outside ProseMirror (a note, the link row, a node-view
// field) that buffers its own text.
function _canMergeRemote() {
  const editor = this._editor;
  if (!editor || editor.isDestroyed || this._mode === "source") return false;
  if (editor.view.composing || this._compStart != null || this._compEndTimer) return false;
  if (this._inflightOps || this._dirtyWhileInflight) return false;
  if (this._bubble?.hasFocus()) return false;
  if (this.querySelector('.bp-canvas-note [role="textbox"]:focus, .bp-canvas-note[data-note-pending]')) return false;
  const active = this.ownerDocument.activeElement;
  return !(active && active !== editor.view.dom && this.contains(active));
}

// Merge `remote` into the live document. Returns the held blocks
// ([{ id, remote, unsaved }]) or null when it cannot merge here: a block
// without an id or a repeated id, or a reorder across a block the author holds.
function _mergeRemote(remote) {
  const editor = this._editor;
  const { state, view } = editor;
  const base = this._debounceBaselineBlocks || this._blocks;
  const remoteIds = remote.map((block) => block && block.id);
  if (remoteIds.some((id) => id == null) || new Set(remoteIds).size !== remoteIds.length) return null;
  const live = normalizeCanvasDoc(editor.getJSON(), base).content || [];
  const baseNodes = this._rt(base).content || [];
  const remoteNodes = this._rt(remote).content || [];
  if (live.length !== state.doc.childCount || baseNodes.length !== base.length ||
      remoteNodes.length !== remote.length) return null;
  const same = (a, b) => withObjectOverrides(this._objectOverrides(), () => nodeContentEqual(a, b));
  const baseAt = new Map(base.map((block, i) => [block.id, i]));
  const remoteAt = new Map(remoteIds.map((id, i) => [id, i]));
  const awaiting = new Set(this._awaitingOwnEchoes.flatMap((entry) => entry.ids || []));
  const caret = this._caretBlockIndexes();
  const liveIds = live.map((node) => (node.attrs && node.attrs.bpId) ?? null);
  const held = [];
  let holds = false;

  const plan = live.map((json, i) => {
    const id = liveIds[i];
    const r = id == null || !remoteAt.has(id) ? -1 : remoteAt.get(id);
    const b = id == null || !baseAt.has(id) ? -1 : baseAt.get(id);
    const unsaved = b === -1 || !same(baseNodes[b], json);
    if (unsaved || awaiting.has(id)) {
      holds = true;
      const remoteChanged = r === -1
        ? b !== -1
        : !same(remoteNodes[r], json) && (b === -1 || !same(remoteNodes[r], baseNodes[b]));
      if (remoteChanged) held.push({ id, remote: r === -1 ? null : remote[r], unsaved });
      const baseline = unsaved ? (b !== -1 && r !== -1 ? base[b] : null) : base[b];
      return { kind: "keep", i, r, baseline };
    }
    if (r === -1) {
      if (!caret.has(i)) return { kind: "drop", i, r };
      holds = true;
      held.push({ id, remote: null, unsaved: false });
      return { kind: "keep", i, r, baseline: base[b] };
    }
    return { kind: same(remoteNodes[r], json) ? "keep" : "take", i, r, baseline: remote[r] };
  });

  const liveIdSet = new Set(liveIds.filter((id) => id != null));
  const extras = [];
  remote.forEach((block, r) => {
    if (liveIdSet.has(block.id) || awaiting.has(block.id)) return;
    const b = baseAt.has(block.id) ? baseAt.get(block.id) : -1;
    if (b === -1) {
      extras.push({ kind: "insert", r, block });
      return;
    }
    // The author removed it and has not saved that yet: stay removed, and keep
    // it in the baseline so the next batch removes it.
    holds = true;
    if (!same(remoteNodes[r], baseNodes[b])) held.push({ id: block.id, remote: block, unsaved: true });
    extras.push({ kind: "removed", r, block });
  });

  const survivors = plan.filter((entry) => entry.kind !== "drop");
  let last = -1;
  for (const entry of survivors) {
    if (entry.r === -1) continue;
    if (entry.r < last) {
      // A reorder. With nothing to keep, the snapshot is the document.
      if (holds) return null;
      this._applyWholeSnapshot(remote);
      return [];
    }
    last = entry.r;
  }

  const target = [];
  const baseline = [];
  let next = 0;
  const takeExtras = (upTo) => {
    while (next < extras.length && extras[next].r < upTo) {
      const extra = extras[next++];
      if (extra.kind === "insert") target.push(extra);
      baseline.push(extra.block);
    }
  };
  for (const entry of survivors) {
    if (entry.r !== -1) takeExtras(entry.r);
    target.push(entry);
    if (entry.baseline) baseline.push(entry.baseline);
  }
  takeExtras(Infinity);

  const tr = state.tr.setMeta("addToHistory", false).setMeta("preventUpdate", true);
  let position = 0;
  let liveIndex = 0;
  for (const entry of target) {
    if (entry.kind === "insert") {
      const node = state.schema.nodeFromJSON(remoteNodes[entry.r]);
      tr.insert(position, node);
      position += node.nodeSize;
      continue;
    }
    while (liveIndex < entry.i) {
      tr.delete(position, position + state.doc.child(liveIndex++).nodeSize);
    }
    const node = state.doc.child(liveIndex++);
    if (entry.kind === "take") {
      const replacement = state.schema.nodeFromJSON(remoteNodes[entry.r]);
      replaceTopNode(tr, node, replacement, position);
      position += replacement.nodeSize;
    } else {
      position += node.nodeSize;
    }
  }
  while (liveIndex < state.doc.childCount) {
    tr.delete(position, position + state.doc.child(liveIndex++).nodeSize);
  }

  // Text a remote writer put at the caret lands after it: the author's next
  // key goes where it was going.
  const { selection } = state;
  if (tr.docChanged && selection instanceof TextSelection) {
    tr.setSelection(TextSelection.create(tr.doc, tr.mapping.map(selection.anchor, -1), tr.mapping.map(selection.head, -1)));
  }
  this._blocks = deepCloneBlocks(baseline);
  if (this._debounceBaselineBlocks) this._debounceBaselineBlocks = this._blocks;
  this._programmaticApply = true;
  try {
    if (tr.docChanged) view.dispatch(tr);
  } finally {
    this._programmaticApply = false;
  }
  this._restSelectionOffAtom();
  this._consumePendingFocus();
  return held;
}

function _applyWholeSnapshot(remote) {
  this._blocks = deepCloneBlocks(remote);
  if (this._debounceBaselineBlocks) this._debounceBaselineBlocks = this._blocks;
  this._programmaticApply = true;
  try {
    this._applyExternalContent(remote);
  } finally {
    this._programmaticApply = false;
  }
}

// Top-level indexes the selection touches, while the author is in the editor.
function _caretBlockIndexes() {
  const editor = this._editor;
  const indexes = new Set();
  if (!editor || !editor.isFocused) return indexes;
  const { $from, $to } = editor.state.selection;
  const from = $from.index(0);
  const to = Math.max(from, $to.depth === 0 ? $to.index(0) - 1 : $to.index(0));
  for (let i = from; i <= to; i++) indexes.add(i);
  return indexes;
}

// bp-canvas-remote-held, once per block and remote version, for blocks held
// against the author's unsaved typing (or removal).
function _reportHeld(held) {
  const reported = new Map();
  for (const entry of held) {
    if (!entry.unsaved) continue;
    const key = JSON.stringify(entry.remote);
    reported.set(entry.id, key);
    if (this._heldRemote.get(entry.id) === key) continue;
    this.dispatchEvent(new CustomEvent("bp-canvas-remote-held", {
      detail: { blockId: entry.id, remote: entry.remote == null ? null : deepCloneBlocks([entry.remote])[0] },
      bubbles: true,
      composed: true,
    }));
  }
  this._heldRemote = reported;
}

// Queue an external-edit re-render to fire once the user stops editing and any
// local debounce settles. We listen for compositionend (IME release) and the
// editor's blur; the debounce callback also flushes after a zero-op local diff.
// Re-queuing overwrites the pending blocks (only latest authority matters).
function _queueServerBlocks(blocks) {
  this._pendingServerBlocks = blocks;
  if (this._onBlurFlush) return; // listeners already armed

  // TipTap's blur notification can run before `editor.isFocused` flips false.
  // Release on the next task so the focus guard observes the settled state.
  const flush = () => setTimeout(() => this._flushPendingServerBlocks(), 0);

  this._onBlurFlush = flush;
  this._onComposeEnd = flush;
  // The contextual toolbar is mounted under body, outside the canvas. Its
  // focus release must also wake the queued update after link editing ends.
  this.ownerDocument.addEventListener("focusout", this._onBlurFlush);
  // The editor blur fires through TipTap's onBlur; but to catch a blur that
  // happens without a TipTap transaction we also bind the DOM listeners on the
  // editable mount. Both call the same idempotent flush.
  if (this._mount) {
    this._mount.addEventListener("blur", this._onBlurFlush, true);
    this._mount.addEventListener("compositionend", this._onComposeEnd, true);
  }
}

// Apply the queued external-edit echo, if one is pending and the user is no longer
// mid-edit. Called by the blur / compositionend release listeners AND by the
// source-mode exit (so a queued external edit lands once the user is back in rich).
// Idempotent + guarded: focus/composition waits for blur/release, source mode
// waits for exit, a live debounce waits for its callback, and an empty queue no-ops.
function _flushPendingServerBlocks() {
  if (!this._pendingServerBlocks) return;
  if (this._liveRemote && this._mergePendingServerBlocks()) return;
  // Still mid-composition/source mode, or still holding an un-emitted local
  // transaction in the debounce window? Wait for the real release. A blur can
  // be delivered after the server echo armed this listener; applying at that
  // point would overwrite the draft before its debounce gets a chance to emit.
  if (this._editor && this._editor.view && this._editor.view.composing) return;
  if (this._mode === "source" && (!this._flushKeepsSource || this._sourceEl?.value !== this._sourceOriginalMd)) return;
  if (this._editor && this._editor.isFocused) return;
  if (this._bubble?.hasFocus()) return;
  if (this.querySelector('.bp-canvas-note [role="textbox"]:focus, .bp-canvas-note[data-note-pending]')) return;
  if (this._debounceTimer) return;
  if (this._inflightOps || this._dirtyWhileInflight || this._awaitingOwnEchoes.length > 0) return;
  const pending = this._pendingServerBlocks;
  this._clearPendingServerBlocks();
  if (pending) {
    this._blocks = deepCloneBlocks(pending);
    this._applyExternalContent(pending);
  }
}

// Tear down any queued external-edit echo + its release listeners.
function _clearPendingServerBlocks() {
  this._pendingServerBlocks = null;
  this._heldRemote.clear();
  if (this._onBlurFlush) this.ownerDocument.removeEventListener("focusout", this._onBlurFlush);
  if (this._mount) {
    if (this._onBlurFlush) {
      this._mount.removeEventListener("blur", this._onBlurFlush, true);
    }
    if (this._onComposeEnd) {
      this._mount.removeEventListener("compositionend", this._onComposeEnd, true);
    }
  }
  this._onBlurFlush = null;
  this._onComposeEnd = null;
}

export {
  _applyExternalContent, _applyWholeSnapshot, _canMergeRemote, _caretBlockIndexes,
  _clearPendingServerBlocks, _flushPendingServerBlocks, _isEditingNow, _mergePendingServerBlocks,
  _mergeRemote, _queueServerBlocks, _reportHeld, _stampMaterializedIds, _stampOwnEchoIds,
  _takeServerBlocks, applyServerBlocks, applyServerBlocksIfIdle,
};

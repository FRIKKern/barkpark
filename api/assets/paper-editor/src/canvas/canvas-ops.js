import { DEBOUNCE_MS } from "../contract.js";
import { normalizeCanvasDoc } from "./canvas-document.js";


// PURE S0 projector + op-mapper — used verbatim (do NOT reinvent the diff).
// reconcileServerEcho (S4a): the PURE own-echo reconciler — treats a live
// bpId:null node as a wildcard matching the server-minted id at that index, so a
// NEW-block echo (Enter-split / paste / typed paragraph) is recognized as an own
// echo and yields the id-writebacks that make the next diff incremental.
// docToBlocks (P5 source-mode): the LIVE-doc → blocks projection — the SAME node→
// block path runToOps diffs against internally (classify + nextNodeToBlock). Source
// mode derives its baseline from the LIVE doc (getJSON), NOT the echo-confirmed,
// LAGGING this._blocks, so the markdown reflects the user's just-typed edits.
import {
  docToBlocks, hasOverlappingOps, opsRebaseSafe, pendingUploadIndexes,
} from "./run-convert.js";

// The DOM-free tone normalizer (note→info, warn→warning, error→danger, …) shared
// with the per-block `> [!type]` callout shorthand. Reused VERBATIM so the canvas
// shorthand maps tones identically. See _maybeCalloutShorthand below.
// The PURE, DOM-free slash-insert core (split out so it unit-tests in plain Node —
// canvas/index.js itself can't, being a custom element). CANVAS_SLASH_TYPES is the
// insertable-type allowlist; canvasDefaultBlock mirrors default_block/2; slashTypeToNode
// builds the per-type default NODE via runToTiptap (so it round-trips byte-identically);
// CANVAS_SLASH_TEXTABLE_NODES marks which inserted nodes take an into-body caret.
// P5 command palette: the Obsidian Cmd-P analog — a fuzzy, keyboard-triggered (Mod-p)
// launcher over editor COMMANDS (NOT a typed "/" trigger). CommandPalette is a THIN
// subclass of SlashMenu (reuses its render/keyboard/positioning DOM + CSS, only re-
// parameterized: eyebrow / footer / fuzzy filter / centered position). The registry is
// a static { id, label, group, run } array — Insert commands REUSE the slash insert
// seam (insertSlashTypeAtSelection, factored from _chooseSlash → default_block parity),
// Format commands toggle the canvas StarterKit marks, Turn-into commands set the block.
// Canvas-only; <bp-paper-editor> (src/index.js) is byte-unchanged. See _onKeyDown
// (Mod-p trigger + mutual exclusion) and _openPalette / _choosePaletteCommand below.
// The PURE id-realigner + deep-cloner for the exit-source diff (split into its own
// module so it unit-tests in plain Node — canvas/index.js itself calls
// customElements.define at load and can't be imported DOM-free). On EXIT we parse the
// edited markdown (markdownToBlocks → fresh minted ids), then realign those ids onto
// the source baseline so a surviving block keeps its id and runToOps emits a PATCH
// (not remove+insert) for an in-place edit. See ./source-realign.js.
import { deepCloneBlocks } from "./source-realign.js";

// How long after compositionend ProseMirror has read the committed text (it ends the
// composition 20 ms after the event).
const COMPOSE_SETTLE_MS = 50;

// The top-level block ids a save batch touches.
function opBlockIds(ops) {
  const ids = new Set();
  for (const op of ops || []) {
    if (op && op.id != null) ids.add(op.id);
    if (op && op.block && op.block.id != null) ids.add(op.block.id);
  }
  return [...ids];
}

// Synchronously commit any user input that is still local to the Web Component.
// Hosts call this before replacing edit mode with reader mode, then wait for the
// resulting bp-canvas-ops acknowledgement before pushing the mode toggle.
//
// Returns true only when this call dispatched a non-empty operation batch. The
// pending debounce/source state is consumed before dispatch, so an immediate
// repeated call is a no-op even while the server echo is still in flight.
function flushPendingChanges() {
  if (!this._editor || !this._editable) return false;

  if (this._mode === "source") {
    if (!this._flushKeepsSource) return this._exitSourceMode();
    // flushKeepsSource: the Markdown is committed in place (1.20.0).
    const md = this._sourceEl.value;
    return md === this._sourceOriginalMd ? false : this._commitSource(md);
  }

  // Node-view controls (code, captions, field inputs, and component editors)
  // debounce their own attributes before they reach ProseMirror. Commit those
  // islands first; their transactions schedule the canvas batch below.
  this.querySelectorAll("[data-bp-type]").forEach((node) => {
    node.dispatchEvent(new CustomEvent("bp-flush-node"));
  });
  this._readDomTyping();

  // Mid-composition, the text committed around the composing run (see _committedDoc).
  const composing = this._compStart != null && !!this._editor.view?.composing;
  if (!this._debounceTimer && !this._compEndTimer && !composing) return false;
  clearTimeout(this._debounceTimer);
  this._debounceTimer = null;
  clearTimeout(this._compEndTimer);
  this._compEndTimer = null;
  return this._emitOps();
}

function _scheduleEmit() {
  if (!this._editable) return; // read mode emits no ops
  if (!this._debounceTimer) {
    // The reference, not a deep clone: `_blocks` is only ever REPLACED (never
    // edited in place), so a later broadcast cannot change what this holds. The
    // clone cost a full copy of the run at the first key of every window
    // (task-fb938eb8be3bce48).
    this._debounceBaselineBlocks = this._blocks;
  }
  if (this._debounceTimer) clearTimeout(this._debounceTimer);
  this._debounceTimer = setTimeout(() => {
    // An IME composition still open when the debounce fires (a dead key held, a CJK run being
    // picked): ProseMirror has already read the candidate text into the doc, so emitting now would
    // send the half-composed run as a patch, then the committed one as another (Barkdown row 15).
    // Hold the timer instead; compositionend re-arms it and the run lands once.
    // Since task-39cb3d6e4709054e the text committed around it still goes: _emitOps sends the
    // run without the composing range (or holds, when it cannot), and compositionend sends
    // the composed text.
    if (this._editor && this._editor.view && this._editor.view.composing) {
      this._debounceTimer = null;
      this._emitOps();
      return;
    }
    this._debounceTimer = null;
    const emitted = this._emitOps();
    // An external echo can arrive after blur but before this debounce fires.
    // If the local transaction normalized to no PortableDoc change, no save/echo
    // will release it, so apply the queued authority now. A real emitted batch
    // remains protected by the in-flight/own-echo acknowledgement path.
    if (!emitted) this._flushPendingServerBlocks();
  }, DEBOUNCE_MS);
}

// One-shot: when the IME releases, run the debounce path at once (still debounced by
// DEBOUNCE_MS from the release, so a commit followed by more typing stays one batch).
function _armComposeEndEmit() {
  if (this._composeEndEmit || !this._mount) return;
  this._composeEndEmit = () => {
    this._mount.removeEventListener("compositionend", this._composeEndEmit, true);
    this._composeEndEmit = null;
    if (this._debounceTimer) { clearTimeout(this._debounceTimer); this._debounceTimer = null; }
    this._scheduleEmit();
  };
  this._mount.addEventListener("compositionend", this._composeEndEmit, true);
}

function _emitOps() {
  if (!this._editor) return false;
  // Never the half-composed run (see _scheduleEmit): mid-composition the doc holds the IME's
  // candidate text, so the run goes without the composing range (_committedDoc), or waits
  // for compositionend when that range cannot be told apart.
  const composing = !!(this._editor.view && this._editor.view.composing);
  let source = null;
  if (composing) {
    source = this._committedDoc();
    if (!source) { this._armComposeEndEmit(); return false; }
  }
  const diffBaseline = this._debounceBaselineBlocks || this._blocks;
  const nextDoc = this._normalizedDoc(source ? source.toJSON() : this._editor.getJSON());
  // The fast path (task-fb938eb8be3bce48): a top-level node that is the SAME
  // ProseMirror node object it was at the last acknowledged emit is unchanged
  // since then, and when the baseline is exactly that emit's after-state its
  // block, its projection and its (empty) patch are already known. Only the
  // nodes a transaction touched are projected and diffed.
  const liveTop = [];
  (source || this._editor.state.doc).forEach((node) => liveTop.push(node));
  const reuse = this._emitReuse(diffBaseline);
  const reusedAt = new Map();
  const unchangedIds = new Set();
  if (reuse) {
    liveTop.forEach((node, i) => {
      const hit = reuse.get(node);
      const json = (nextDoc.content || [])[i];
      // A duplicated bpId was nulled by normalizeCanvasDoc: that node is new.
      if (hit && json && json.attrs && json.attrs.bpId === hit.block.id) {
        reusedAt.set(i, hit);
        unchangedIds.add(hit.block.id);
      }
    });
  }
  const nextBlocks = docToBlocks(nextDoc, reusedAt.size ? { reuse: (i) => reusedAt.get(i)?.block } : {});
  const stableDoc = reusedAt.size
    ? { type: "doc", content: nextBlocks.map((block, i) => reusedAt.has(i) ? reusedAt.get(i).node : this._rt([block]).content[0]) }
    : this._rt(nextBlocks);

  // runToOps mints ids for null-id nodes. Materialize those ids in the live
  // document before another edit can diff, otherwise each cumulative diff
  // invents a different id for the same inserted paragraph.
  // An id stamp is a transaction, and one mid-composition can break the IME: wait.
  if (composing && this._stampMaterializedIds(stableDoc, nextDoc, { dryRun: true })) { this._armComposeEndEmit(); return false; }
  this._stampMaterializedIds(stableDoc, nextDoc);
  if (this._debounceTimer) {
    clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
  }

  if (this._inflightOps) {
    this._dirtyWhileInflight = true;
    return false;
  }

  this._debounceBaselineBlocks = null;
  // A picture still uploading, or whose upload failed, is not sent (run-convert.js
  // pendingUploadIndexes). stableDoc keeps it above so ids materialize by position.
  const held = pendingUploadIndexes(nextDoc, diffBaseline);
  // Indexes are top-level positions in the live doc; they apply only while the
  // round-trip kept one top-level node per live node (otherwise nothing is held).
  const aligned = (nextDoc.content || []).length === (stableDoc.content || []).length;
  const opsDoc = held.size && aligned ? { ...stableDoc, content: (stableDoc.content || []).filter((_, i) => !held.has(i)) } : stableDoc;
  const ops = this._ro(diffBaseline, opsDoc, { preserveNewIds: true, unchangedIds });
  // Mid-composition with nothing committed to send: not "nothing to save" (bp-noop would
  // tell the page's exit guard all is saved, with the composing run still unsent).
  if (composing && (!ops || !ops.length)) return false;
  if (!ops || !ops.length) {
    // Nothing to save: the edits since the last batch cancelled out (typed,
    // then undone inside one debounce). Say so. The page's exit guard marked
    // this run dirty on the native input, and without this signal no save
    // ever arrives to clear it, so leaving the page warned about unsaved
    // changes that were never there.
    this.dispatchEvent(new CustomEvent("bp-noop", { bubbles: true, composed: true }));
    return false;
  }
  const dispatched = this._dispatchOps(ops, nextBlocks, diffBaseline);
  if (dispatched) this._rememberEmit(liveTop, nextDoc, nextBlocks, stableDoc);
  return dispatched;
}

// The doc to save during an IME composition: the live doc without the composing run
// (compositionstart's position, mapped, to the caret: plain text in one text block, and
// that block grown by exactly that run since compositionstart). null when the run cannot
// be told apart; the emit then waits for compositionend, as before.
function _committedDoc() {
  const { state } = this._editor;
  if (this._compStart == null) return null;
  const head = state.selection.head;
  const from = Math.min(this._compStart, head);
  const to = Math.max(this._compStart, head);
  let $from;
  let $to;
  try {
    $from = state.doc.resolve(from);
    $to = state.doc.resolve(to);
  } catch (_e) {
    return null;
  }
  if (!$from.parent.isTextblock || $from.parent !== $to.parent) return null;
  if ($from.parent.content.size - (to - from) !== this._compBlockSize) return null;
  let textOnly = true;
  state.doc.nodesBetween(from, to, (node) => { if (node.isInline && !node.isText) textOnly = false; });
  if (!textOnly) return null;
  return from === to ? state.doc : state.tr.delete(from, to).doc;
}

// A committed phrase is saved at once, not DEBOUNCE_MS later (by when a CJK writer has
// opened the next composition, and the debounce held again: 0 characters stored in 12.5 s
// of continuous typing). ProseMirror reads the committed text a moment after compositionend.
function _afterComposition() {
  this._compStart = null;
  clearTimeout(this._compEndTimer);
  this._compEndTimer = setTimeout(() => {
    this._compEndTimer = null;
    if (!this._editor || this._editor.isDestroyed || !this._editable || this._mode === "source") return;
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }
    const emitted = this._emitOps();
    if (!emitted && !(this._editor.view && this._editor.view.composing)) this._flushPendingServerBlocks();
  }, COMPOSE_SETTLE_MS);
}

// The fast path's memory of one emit (task-fb938eb8be3bce48): each top-level
// node with a stable id that the id stamp left untouched, keyed by the node
// object, with the block and projection this emit gave it. It becomes usable
// only when the bridge acknowledges this exact batch (acknowledgeOps sets
// `blocks`): from then on a baseline that IS that acknowledged run equals this
// emit's blocks, so an untouched node has nothing to patch.
function _rememberEmit(liveTop, nextDoc, nextBlocks, stableDoc) {
  this._emitCache = null;
  if (!this._inflightOps) return;
  const afterStamp = [];
  this._editor.state.doc.forEach((node) => afterStamp.push(node));
  if (afterStamp.length !== liveTop.length) return;
  const nodes = new Map();
  liveTop.forEach((node, i) => {
    const json = (nextDoc.content || [])[i];
    const block = nextBlocks[i];
    if (afterStamp[i] !== node || !block || !json || !json.attrs) return;
    if (json.attrs.bpId == null || json.attrs.bpId !== block.id) return;
    nodes.set(node, { block, node: stableDoc.content[i] });
  });
  this._emitCache = { nodes, afterBlocks: this._inflightOps.afterBlocks, blocks: null };
}

// The remembered nodes, when `diffBaseline` is exactly the run the remembered
// emit's acknowledgement installed; otherwise null and every node is projected.
// Any other writer of `_blocks` (an echo, a remote update, setContent) replaces
// the array, so the identity check sends it down the full path.
function _emitReuse(diffBaseline) {
  const cache = this._emitCache;
  if (!cache || !cache.blocks || diffBaseline !== cache.blocks) return null;
  return cache.nodes;
}

// Dispatch one op array for the LiveView hook to fold and retain its after-state
// until the hook acknowledges the exact sequence. A zero-length array is a no-op.
function _dispatchOps(ops, nextBlocks = null, diffBaseline = this._blocks) {
  if (!ops || !ops.length) return false;
  const conflictBlocks = hasOverlappingOps(ops, diffBaseline, this._pendingServerBlocks)
    ? deepCloneBlocks(this._pendingServerBlocks)
    : null;
  const seq = this._acknowledgedSaves ? ++this._opsSeq : undefined;
  if (this._acknowledgedSaves) {
    this._inflightOps = {
      seq,
      ops,
      // A fresh array over this emit's own blocks: nextBlocks was built for this
      // call (its reused entries are shared, never edited in place), so a deep
      // copy of the whole run per keystroke bought nothing (task-fb938eb8be3bce48).
      afterBlocks: nextBlocks ? nextBlocks.slice() : deepCloneBlocks(this._blocks),
      // The run these ops were diffed against, so the bridge can ask whether
      // they still apply on a newer stored version (rebaseSafe).
      baseline: diffBaseline,
      pendingServerBlocks: this._pendingServerBlocks,
      echoSeen: false,
      requestId: null,
    };
  }
  this.dispatchEvent(
    new CustomEvent("bp-canvas-ops", {
      detail: { ...(seq == null ? { ops } : { ops, seq }),
        ...(conflictBlocks ? { conflictBlocks } : {}) },
      bubbles: true,
      composed: true,
    }),
  );
  return true;
}

// Called by the LiveView bridge after the exact `paper-ops` request settles.
// Failure retains the batch so the bridge can retry it byte-for-byte. Success
// advances the local baseline and releases any edits made while it was pending.
function identifyOpsRequest(seq, requestId, previousRequestId = null) {
  const current = this._inflightOps;
  if (!current || current.seq !== seq || typeof requestId !== "string" || requestId === "") {
    return false;
  }
  // Explicit Keep mine changes the retry identity. Require the bridge to name
  // the exact old request before rebinding an already identified snapshot.
  if (current.requestId && current.requestId !== requestId &&
      previousRequestId !== current.requestId) return false;
  current.requestId = requestId;
  return true;
}

// Whether the in-flight batch `seq` can be resent unchanged on the newer
// stored version `serverBlocks` of this run: its ops address blocks by id and
// touch nothing the other writer changed (opsRebaseSafe). The bridge asks this
// when the server refuses the batch because another session saved first.
function rebaseSafe(seq, serverBlocks) {
  const current = this._inflightOps;
  if (!current || current.seq !== seq) return false;
  return opsRebaseSafe(current.ops, current.baseline || this._blocks, serverBlocks);
}

// Whether the edits this canvas still holds (an in-flight batch and/or a
// draft not yet sent) can ride on top of `serverBlocks`, a newer version
// another session saved: the same test as rebaseSafe, over everything local.
// True means "no conflict to show yet"; the save itself rebases.
function localEditsRebaseSafe(serverBlocks) {
  if (!this._editor || !Array.isArray(serverBlocks)) return false;
  const inflight = this._inflightOps;
  if (inflight && !opsRebaseSafe(inflight.ops, inflight.baseline || this._blocks, serverBlocks)) {
    return false;
  }
  const draftBase = inflight ? inflight.afterBlocks : (this._debounceBaselineBlocks || this._blocks);
  const draft = this._ro(draftBase, normalizeCanvasDoc(this._editor.getJSON(), draftBase), { preserveNewIds: true }) || [];
  if (!draft.length) return true;
  // Behind an in-flight batch the run's shape was already checked above; the
  // draft only must not touch what the other writer changed.
  if (inflight) {
    return draft.every((op) => ["patch-block", "remove-block", "insert-after", "append-block"].includes(op.op)) &&
      !hasOverlappingOps(draft, draftBase, serverBlocks);
  }
  return opsRebaseSafe(draft, draftBase, serverBlocks);
}

function acknowledgeOps(seq, saved) {
  if (!this._acknowledgedSaves) return false;
  const current = this._inflightOps;
  if (!current || current.seq !== seq) return false;
  // A `saved:false` acknowledgement keeps the batch in flight: the Studio host's
  // contract is that a failed head stays pending and its Retry resends the same
  // batch verbatim, with later edits waiting behind it (__save_ack_mounted). A host
  // that wants the other behaviour — drop the refused batch and fold it into the
  // next edit — calls discardInflightOps(seq) instead.
  if (saved !== true) return false;
  this._inlineSavePending = null;

  // Diff against the local snapshot the author still sees. A canonical reply
  // can contain remote sibling changes queued for later display; advancing
  // to those unseen values would turn the next local edit into a reversion.
  this._blocks = deepCloneBlocks(current.afterBlocks);
  if (this._emitCache && this._emitCache.afterBlocks === current.afterBlocks) {
    this._emitCache.blocks = this._blocks;
  }
  // A successful reviewed write supersedes the overlapping fields in the
  // deferred snapshot it was authored against. Keep remote sibling data, but
  // do not compare continued typing against those now-obsolete field values
  // while the canonical echo is still travelling. A newer queued snapshot
  // must retain its authority and still gets an independent overlap check.
  if (current.pendingServerBlocks && this._pendingServerBlocks === current.pendingServerBlocks) {
    const pending = deepCloneBlocks(this._pendingServerBlocks);
    for (const op of current.ops) {
      if (op.op !== "patch-block") continue;
      const block = pending.find((item) => item.id === op.id);
      if (block) Object.assign(block, JSON.parse(JSON.stringify(op.patch)));
    }
    this._pendingServerBlocks = pending;
  }
  // A newer local edit may still be inside its debounce while this earlier
  // batch is acknowledged. Advance that draft's captured baseline with the
  // confirmed local snapshot so its next diff stays incremental.
  if (this._debounceBaselineBlocks) {
    // The run just installed holds the same content; share it (it is never
    // edited in place), so the fast path recognises this baseline too.
    this._debounceBaselineBlocks = this._blocks;
  }
  if (!current.echoSeen) {
    this._awaitingOwnEchoes.push({
      blocks: deepCloneBlocks(current.afterBlocks),
      requestId: current.requestId,
      ids: opBlockIds(current.ops),
    });
  }
  this._inflightOps = null;
  const dirty = this._dirtyWhileInflight;
  this._dirtyWhileInflight = false;
  if (dirty) this._emitOps();
  else this._flushPendingServerBlocks();
  return true;
}

// The host's OTHER answer to a refused batch (a lifecycle veto such as "a published
// paper cannot be hollowed out", or a request that will not succeed by retrying):
// drop the in-flight batch WITHOUT advancing the baseline. `_blocks` still holds the
// last SAVED snapshot, so the next local edit diffs against it and carries the
// refused change along — the author keeps what they see, and it lands as soon as
// the server will take it (a batch that would hollow the paper saves once they
// write again). Edits made while the batch was travelling are emitted now: that
// diff already differs from the refused one. An unchanged vetoed batch is never
// resent on its own; resendPendingOps() is the host's explicit "try again".
// Without this seam a refused batch pinned the pipeline: every later edit queued
// behind it, never sent (found by Barkdown's editor-multiblock row: cut all, type).
//
// `refusal` (optional) is the host's reason for the refusal, `{reason}`. When
// the refused batch carried an inline object the field dialog just saved, the
// dialog reopens on that object with the reason on the field it names
// (task-85fee859cf3bfef6), instead of only the host's generic notice.
function discardInflightOps(seq, refusal) {
  if (!this._acknowledgedSaves) return false;
  const current = this._inflightOps;
  if (!current || current.seq !== seq) return false;
  this._inflightOps = null;
  this._reopenRefusedInlineObject(refusal);
  const dirty = this._dirtyWhileInflight;
  this._dirtyWhileInflight = false;
  if (dirty) this._emitOps();
  return true;
}

// Re-diff the live document against the saved baseline and emit the batch, if any
// and if nothing is in flight. The host's Retry after discardInflightOps: it must
// NOT resend the discarded ops (an insert would land twice); it asks for a fresh diff.
function resendPendingOps() {
  if (this._inflightOps || !this._editor) return false;
  if (this._debounceTimer) {
    clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
  }
  return this._emitOps() === true;
}

export {
  _afterComposition, _armComposeEndEmit, _committedDoc, _dispatchOps, _emitOps, _emitReuse,
  _rememberEmit, _scheduleEmit, acknowledgeOps, discardInflightOps, flushPendingChanges,
  identifyOpsRequest, localEditsRebaseSafe, rebaseSafe, resendPendingOps,
};

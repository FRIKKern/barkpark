import { blocksToMarkdown, changedSentinel, markdownToBlocks } from "../markdown.js";
import { t } from "../i18n.js";
import { docToBlocks } from "./run-convert.js";
import {
  realignAcrossCommits,
  clampLockedPrefix,
  deepCloneBlocks,
  mergeSourceText,
} from "./source-realign.js";
import { sentinelRefusal, sourceStored, sourceWallLoss } from "./source-save.js";
import { isFigureSingletonCanvas } from "./figure-context.js";

  // ── P5 MARKDOWN SOURCE-MODE (Mod-Shift-m / palette "Toggle Markdown source") ──
  //
  // The Obsidian "source mode" analog: swap the rich ProseMirror editor for a plain
  // Markdown <textarea> and back. The SAME toggle method is bound to both triggers
  // (the keyboard shortcut in _onKeyDown and the palette command in
  // buildCommandRegistry → run()), so they are guaranteed identical.
  //
  //   rich → source : serialize the live run to markdown, including unsaved edits, stash
  //                   the original md + a deep clone of those baseline blocks, hide
  //                   the rich editor, close any open popup, show a focused textarea.
  //   source → rich : read the textarea. If the markdown is UNCHANGED (=== the stashed
  //                   original) restore the rich editor UNTOUCHED — NO re-parse, NO
  //                   setContent, ZERO ops (a no-op toggle never perturbs the doc or
  //                   the diff baseline). If EDITED, parse it back (markdownToBlocks),
  //                   REALIGN the parsed blocks' ids against the baseline (so a
  //                   surviving block keeps its id and a single in-place edit emits ONE
  //                   patch-block, not remove+insert), then setContent → onUpdate →
  //                   the existing _emitOps path diffs this._blocks → the new doc and
  //                   emits the bp-canvas-ops for exactly the user's source-mode edits.
export function sourceModeToggle() {
    if (!this._editor || !this._editable) return;
    if (isFigureSingletonCanvas(this)) {
      this._showFigureConstraint(
        t("Markdown source is unavailable inside a Figure because it could create extra blocks."),
      );
      return;
    }
    if (this._mode === "rich") this._enterSourceMode();
    else this._exitSourceMode();
  }

  // ENTER source mode. Capture the baseline (the live diff baseline this._blocks)
  // and its markdown, hide the rich editor + close any popup, mount a focused
  // textarea sized to its content. Idempotent: a second enter while already in
  // source mode is a no-op.
export function sourceModeEnter() {
    if (this._mode === "source" || !this._editor || !this._mount) return;

    // Commit both node-view inputs and the outer batch before capturing source.
    // Otherwise an immediate source toggle serializes stale code/caption attrs.
    this.flushPendingChanges();

    // THE BASELINE — derived from the LIVE doc (L0), NOT this._blocks (C).
    //
    //   C  = this._blocks — the displayed run's save baseline. It advances after
    //        acknowledgement or an applied external update, not while that update
    //        waits unseen for focus release. It can lag unconfirmed local typing.
    //   L0 = the LIVE doc projected back to blocks — docToBlocks(normalizeCanvasDoc(
    //        getJSON())), the SAME projection _emitOps diffs against. It includes the
    //        user's just-typed, not-yet-confirmed edits.
    //
    // Capturing from C would show STALE markdown (missing the just-typed edits) and,
    // on an edited exit, a setContent built from C would DELETE those edits. So the
    // baseline + textarea MUST come from L0. We deep-clone L0 so a later parse +
    // realign never mutates it.
    const L0 = docToBlocks(this._normalizedDoc(this._editor.getJSON()));

    // THE WALL. An edit in source mode saves markdownToBlocks(text) in place of the
    // document. A Paper opens writable only when an unedited save of the text it shows
    // (the live doc's Markdown, saved as sourceModeCommit saves it), folded onto what is
    // stored (this._blocks with the ops in flight), gives back every key that was
    // stored, and its stored blocks' own Markdown does too; anything else opens
    // READ-ONLY: it shows the Markdown, takes no typing, writes nothing back, and one
    // plain line says why and names the block (sourceWallLoss in source-save.js).
    // Typing made while a batch is in flight can open read-only until its echo lands.
    const inflight = this._inflightOps && this._inflightOps.ops;
    const loss = sourceWallLoss(this._blocks || [], L0, sourceView.call(this), { inflight });

    // Close any open popup — in source mode the textarea owns input, so a lingering
    // [[ / # / slash / palette popup would float over a now-hidden editor.
    this._closeWikilink();
    this._closeTag();
    this._closeEmoji();
    this._closeSlash();
    this._closePalette();

    this._sourceBaselineBlocks = deepCloneBlocks(L0);
    this._sourceCommitBlocks = this._sourceBaselineBlocks;
    const md0 = blocksToMarkdown(this._sourceBaselineBlocks);
    this._sourceOriginalMd = md0;

    // The textarea — monospace, full-width, themed by the --paper-* tokens (styled
    // in root.html.heex next to .bp-cmd-*). Mount it as a sibling of the rich body
    // inside the WC so the same surface tokens cascade in.
    const ta = document.createElement("textarea");
    ta.className = "bp-canvas-source";
    ta.value = md0;
    ta.setAttribute("aria-label", t("Markdown source"));
    ta.spellcheck = false;
    ta.autocapitalize = "off";
    ta.autocomplete = "off";
    ta.setAttribute("autocorrect", "off");
    ta.readOnly = this._sourceReadOnly = Boolean(loss);
    // The textarea owns its own toggle-back (Mod-Shift-m) + Escape, since the rich
    // editor's handleKeyDown does NOT fire while source mode is up.
    this._onSourceKeyDown = (e) => {
      if (
        (e.metaKey || e.ctrlKey) &&
        e.shiftKey &&
        !e.altKey &&
        (e.key === "m" || e.key === "M")
      ) {
        e.preventDefault();
        this.toggleSourceMode();
        return;
      }
      if (e.key === "Escape" || e.key === "Esc") {
        e.preventDefault();
        this.toggleSourceMode();
      }
    };
    ta.addEventListener("keydown", this._onSourceKeyDown);
    // Auto-grow to the content on input so the source never scrolls internally.
    ta.addEventListener("input", () => this._sizeSourceTextarea());

    // Hide the rich editor (kept mounted so its state survives a no-op toggle) and
    // show the textarea in its place.
    this._mount.style.display = "none";
    this.appendChild(ta);
    this._sourceEl = ta;
    this._mode = "source";

    // Size + focus after attach (offsetHeight/scrollHeight need layout).
    this._sizeSourceTextarea();
    try {
      ta.focus();
      // Caret at the start, no selection — Obsidian lands the cursor at doc top.
      ta.setSelectionRange(0, 0);
    } catch (_e) {
      // focus is best-effort (e.g. a detached test env).
    }
    // The editor just lost focus to the textarea — drive the format bubble's own
    // hide path (update() hides when !view.hasFocus()) so no stale bubble lingers
    // over the now-hidden editor.
    if (this._bubble) this._bubble.update();
    if (loss) {
      this._showFigureConstraint(
        t("Read only: Markdown cannot carry the %{part} of block %{number}, a %{type}, yet.", {
          part: loss.part,
          number: loss.index + 1,
          type: loss.type,
        }),
      );
    }
  }

  // EXIT source mode → back to the rich editor.
  //   NO EDIT  (textarea value === _sourceOriginalMd, the markdown the rich document
  //            already holds): restore the rich editor UNTOUCHED — no re-parse, no
  //            setContent, ZERO ops.
  //   EDITED   : _commitSource(md) — the same commit a source-mode flush runs.
  // Either way the textarea + its listener are torn down and the rich editor reshown.
export function sourceModeExit() {
    let emitted = false;
    if (this._mode === "source" && this._sourceEl) {
      const md = this._sourceEl.value;
      const edited = !this._sourceReadOnly && md !== this._sourceOriginalMd;
      // An edit to a block shown as JSON is never saved: source mode stays open.
      if (edited && refuseSentinelEdit.call(this, md)) return false;

      // Tear down the textarea + listener and reveal the rich editor FIRST so the
      // setContent (edited path) and the refocus land on the visible editor.
      this._teardownSourceEl();
      if (this._mount) this._mount.style.display = "";
      this._mode = "rich";

      if (edited) emitted = this._commitSource(md);
      // else NO EDIT: the rich editor already holds this markdown — the live doc, the
      // diff baseline, and the caret stay as they are. ZERO ops by construction.

      this._sourceBaselineBlocks = null;
      this._sourceCommitBlocks = null;
      this._sourceOriginalMd = "";
      if (this._sourceReadOnly || this._sourceRefusing) this._clearFigureConstraint();
      this._sourceReadOnly = false;
      this._sourceRefusing = false;
      try {
        this._editor.commands.focus();
      } catch (_e) {
        // focus is best-effort.
      }

      // MAJOR (source-mode external-edit queue): while we were in source mode an
      // external echo may have been QUEUED (applyServerBlocks saw _isEditingNow() ===
      // true because the mode was 'source'). Now that we are back in rich, flush it so
      // the queued external edit lands — the SAME flush the blur / compositionend path
      // runs. Re-applying L1's own diff above does not conflict: the external content
      // is the server-confirmed state and supersedes. We flush AFTER setContent so the
      // external apply is the last word.
      this._flushPendingServerBlocks();
    }
    return emitted;
  }

  // COMMIT the source Markdown into the hidden rich editor and send the change,
  // without touching the textarea (its value, caret, selection and native undo stay).
  //   L1 = the markdown parsed, ids REALIGNED (realignAcrossCommits) first against L0
  //        (this._sourceBaselineBlocks, the live doc captured on ENTER), then against
  //        the last commit (this._sourceCommitBlocks), so a surviving block keeps its id
  //        and runToOps emits a PATCH for an in-place edit, then the locked template
  //        prefix is CLAMPED (a source delete, move or retype of a locked block is
  //        undone; a content edit rides through). L0 first gives a block back its id
  //        when a half-typed construct (an unclosed fence) swallowed it in an earlier
  //        commit; the last commit second keeps the id of a block born in this
  //        session. _emitOps sends with preserveNewIds, so those ids go out as sent.
  //   (1) setContent(L1) WITHOUT auto-emit and outside history: onUpdate does not
  //       re-diff from C, and the reflow is not an undo step of its own.
  //   (2) _emitOps sends L1 through the normal one-in-flight path: if an earlier batch
  //       is pending, the source result waits and goes as its incremental delta.
  // _sourceOriginalMd then holds this markdown, so an unchanged textarea is a no-op
  // for the next flush and for exit.
export function sourceModeCommit(md) {
    if (this._sourceReadOnly || refuseSentinelEdit.call(this, md)) return false;
    const L0 = this._sourceBaselineBlocks;
    const L1 = clampLockedPrefix(L0, realignAcrossCommits(L0, this._sourceCommitBlocks, markdownToBlocks(md)));
    this._editor
      .chain()
      .setContent(this._rt(L1), { emitUpdate: false })
      .command(({ tr }) => {
        tr.setMeta("addToHistory", false);
        return true;
      })
      .run();
    this._sourceOriginalMd = md;
    this._sourceCommitBlocks = L1;
    return this._emitOps();
  }

  // A block source mode cannot write as Markdown shows as its JSON sentinel, which
  // source mode does not edit. Such Markdown is refused, with one line naming the
  // block, until the line is put back; moving or deleting the line is saved as usual.
  // Two checks, the second the wall: changedSentinel (a sentinel line that is not one
  // the textarea already held, whole), then sentinelRefusal on the blocks the save would
  // store (no block gains the marker or a shown sentinel's JSON in its words; a block
  // shown as a sentinel is stored unchanged, or deleted by a save that only deletes,
  // which has a notice of its own; a batch the fold refuses is refused, with a notice
  // that names no block).
function refuseSentinelEdit(md) {
    const edited = changedSentinel(md, this._sourceOriginalMd);
    const refusal = edited !== -1 ? { index: edited, kind: "edit" } : storedSentinelHarm.call(this, md);
    if (!refusal) {
      if (this._sourceRefusing) this._clearFigureConstraint();
      this._sourceRefusing = false;
      return false;
    }
    this._sourceRefusing = true;
    const number = refusal.index + 1;
    this._showFigureConstraint(refusal.kind === "unread"
      ? t("Not saved: source mode could not read this change. Your text is kept.")
      : refusal.kind === "removal"
        ? t("Not saved: block %{number} is shown as JSON. Delete it and save first, then make your other changes.", { number })
        : t("Not saved: block %{number} is shown as JSON, and source mode does not edit it.", { number }));
    return true;
  }

// The editor's projection and runToOps, for the source-save checks.
function sourceView() {
    return {
      toDoc: (blocks) => this._editor.schema.nodeFromJSON(this._rt(blocks)).toJSON(),
      toOps: (...args) => this._ro(...args),
    };
}

// sentinelRefusal over what sourceModeCommit(md) would store: the parse laid out as the
// commit lays it, saved over the run its ops are diffed from.
function storedSentinelHarm(md) {
    const L0 = this._sourceBaselineBlocks || [];
    const laid = clampLockedPrefix(L0, realignAcrossCommits(L0, this._sourceCommitBlocks, markdownToBlocks(md)));
    const base = this._inflightOps ? this._inflightOps.afterBlocks : (this._debounceBaselineBlocks || this._blocks || []);
    const { saved } = sourceStored(base, laid, sourceView.call(this));
    return sentinelRefusal(base, L0, this._sourceOriginalMd, saved);
}

  // An external apply (applyServerBlocks, a queued release, a reseed) landed in the
  // hidden rich editor while source mode is open: show it in the textarea and make it
  // the new baseline, or the next commit would diff the stale text against it and
  // send the external change back reverted. mergeSourceText rewrites only the blocks
  // the change touched and maps each end of the selection by block id, and only the
  // span between the first and last changed character is replaced. A selection is
  // kept only while it still holds the same text; otherwise it collapses where its
  // end went. So a caret stays a caret, follows the block it is in, and the next key
  // never overwrites text the writer did not select.
export function sourceModeSyncText() {
    const blocks = deepCloneBlocks(docToBlocks(this._normalizedDoc(this._editor.getJSON())));
    const ta = this._sourceEl;
    const old = ta.value;
    const { text: md, map } = mergeSourceText(old, this._sourceCommitBlocks, blocks);
    this._sourceBaselineBlocks = blocks;
    this._sourceCommitBlocks = blocks;
    let start = 0;
    while (start < old.length && start < md.length && old[start] === md[start]) start++;
    let tail = 0;
    while (tail < old.length - start && tail < md.length - start &&
      old[old.length - 1 - tail] === md[md.length - 1 - tail]) tail++;
    const [from, to, direction] = [ta.selectionStart, ta.selectionEnd, ta.selectionDirection];
    const head = map(from, false);
    const end = map(to, true);
    const keep = from < to && head < end && md.slice(head, end) === old.slice(from, to);
    const caret = map(to, false);
    ta.setRangeText(md.slice(start, md.length - tail), start, old.length - tail);
    ta.setSelectionRange(keep ? head : caret, keep ? end : caret, direction);
    this._sizeSourceTextarea();
    this._sourceOriginalMd = md;
  }

  // True while the Markdown source textarea owns input (1.20.0).
export function sourceModeActive() {
    return this._mode === "source";
  }

  // Grow the source textarea to fit its content (no internal scroll). Best-effort —
  // a detached test env has no layout, so scrollHeight is 0 and we leave the rows.
export function sourceModeSizeTextarea() {
    const ta = this._sourceEl;
    if (!ta) return;
    try {
      ta.style.height = "auto";
      const h = ta.scrollHeight;
      if (h > 0) ta.style.height = h + "px";
    } catch (_e) {
      // no layout (test env): leave the default rows.
    }
  }

  // Remove the source textarea + its keydown listener (the exact bound identity).
  // Called on exit AND on disconnect so a teardown mid-source-mode leaks nothing.
export function sourceModeTeardown() {
    const ta = this._sourceEl;
    if (!ta) return;
    if (this._onSourceKeyDown) {
      ta.removeEventListener("keydown", this._onSourceKeyDown);
      this._onSourceKeyDown = null;
    }
    if (ta.parentNode) ta.parentNode.removeChild(ta);
    this._sourceEl = null;
  }

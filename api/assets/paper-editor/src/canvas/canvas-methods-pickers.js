import { searchEmoji } from "../emoji.js";
import { WikilinkMenu } from "../wikilink-menu.js";
import {
  emojiReplaceRange,
  parseOpenEmoji,
  parseOpenTag,
  parseOpenWikilink,
  splitAlias,
  tagReplaceRange,
  wikilinkReplaceRange,
} from "../wikilink-trigger.js";
import { refreshWikilinkTitles } from "./wikilink-titles.js";

const triggerText = (block) =>
  block.textBetween(0, block.content.size, undefined, (leaf) =>
    leaf.type.name === "hardBreak" ? "\n" : "\ufffc");

  // The DOMRect of the current caret, used to position the popup at the cursor.
  // Ported from ../index.js:_caretRect (the canvas had no such helper — added
  // here for the popups). Falls back to the mount rect if coordsAtPos throws.
  export function _caretRect() {
    try {
      const { from } = this._editor.state.selection;
      const coords = this._editor.view.coordsAtPos(from);
      return {
        left: coords.left,
        top: coords.top,
        bottom: coords.bottom,
      };
    } catch (_e) {
      const r = this._mount.getBoundingClientRect();
      return { left: r.left, top: r.top, bottom: r.bottom };
    }
  }

  // ── P4 `[[` wikilink autocomplete ──────────────────────────────────────────
  //
  // Obsidian-parity inline page-link picker, ported VERBATIM from ../index.js.
  // Studio-only by construction: gated on `this._editable` (read-mode never runs
  // onUpdate) AND on an injected `this._wikilinkSource` (unset → never opens). On
  // each onUpdate we re-run the PURE parseOpenWikilink seam against the BLOCK-LOCAL
  // text + caret offset of the current run block; an open trigger opens/refreshes
  // the menu at the caret and fires the async source. On a pick we replace the
  // typed "[[query" span with the chosen title carrying a `wikilink` mark — which,
  // in the canvas, makes runToOps emit a patch-block for THAT block (the existing
  // prose patch path). Returns true iff the menu is (now) open, so onUpdate can
  // force the tag popup shut (mutual exclusion).
  export function _maybeWikilink() {
    if (!this._editable || !this._wikilinkSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame. In the canvas
    // doc `$from.parent` is the CURRENT run block's textblock (a paragraph —
    // including the one nested inside a list item), so its triggerText (one char per
    // inline leaf, a hard break as "\n") pairs exactly with `parentOffset`;
    // textContent drops leaves and drifts after a break. Using getText() here would join EVERY block in
    // the run with "\n\n" and desync from the block-local offset — so a `[[` typed
    // in the 2nd-or-later block would never open. parseOpenWikilink's contract is
    // block-local text. This is what makes the trigger frame-correct in the
    // multi-block canvas exactly as it is in the per-block editor.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = triggerText($from.parent);
    const caretOffset = $from.parentOffset;
    const hit = parseOpenWikilink(blockLocalText, caretOffset, {
      mention: this.getAttribute("mention-trigger") !== "off",
    });
    if (!hit) {
      this._closeWikilink();
      return false;
    }

    // Open (or refresh, as the query grows) the popup at the live caret rect, and
    // remember the PM range to replace on pick — anchored to the DOCUMENT position
    // (selection.from), not the block-local offset hit carries.
    const { query, alias } = hit.trigger === "[[" ? splitAlias(hit.query) : { query: hit.query, alias: null };
    this._openWikilink(this._caretRect(), query);
    this._wlRange = wikilinkReplaceRange(this._editor.state.selection.from, hit.query, hit.trigger);
    this._wlAlias = alias || null;

    // Async source with a STALE GUARD: each open/keystroke bumps _wlSeq; a
    // resolved batch is dropped unless it is still the latest request AND the menu
    // is still open — so an out-of-order or post-close response is ignored.
    // A source that throws or rejects reads as no match (contract 1.16.0).
    const seq = ++this._wlSeq;
    const current = () => seq === this._wlSeq && this._wikilink && this._wikilink.isOpen();
    if (!query && alias != null) {
      this._wikilink.setResults([]);
      return true;
    }
    new Promise((resolve) => resolve(this._wikilinkSource(query)))
      .catch(() => [])
      .then((list) => {
        if (current()) this._wikilink.setResults(Array.isArray(list) ? list : []);
      })
      .catch(() => {});
    return true;
  }

export function _openWikilink(rect, query = "") {
    if (!this._wikilink) {
      this._wikilink = new WikilinkMenu({
        onChoose: (c) => this._chooseWikilink(c),
        onDismiss: () => this._dismissWikilink(),
      });
    }
    this._wikilink.open(rect, query);
  }

export function _closeWikilink() {
    if (this._wikilink && this._wikilink.isOpen()) this._wikilink.close();
  }

  // User picked a candidate: replace the typed "[[query" span with the chosen
  // title carrying a `wikilink` mark { target: title, docId: id }, plus a trailing
  // UNMARKED space so typing continues OUTSIDE the link (the mark is
  // inclusive:false, but the space guarantees it across browsers). The pinned
  // `docId` is the picked paper's EXACT id. The marked-text insertion mutates the
  // run block → runToOps emits a patch-block for that block. _wlRange was captured
  // in _maybeWikilink at the moment the menu opened/refreshed.
  export function _chooseWikilink(candidate) {
    const range = this._wlRange;
    if (!range) {
      this._closeWikilink();
      return;
    }
    this._editor
      .chain()
      .focus()
      .insertContentAt({ from: range.from, to: range.to }, [
        {
          type: "text",
          text: this._wlAlias || candidate.title,
          marks: [{ type: "wikilink", attrs: { target: candidate.title, docId: candidate.id, alias: this._wlAlias } }],
        },
        { type: "text", text: " " },
      ])
      .run();
    this._closeWikilink();
  }

  // Esc / outside-click: close the menu but LEAVE the typed "[[query" in place —
  // the user may want to keep editing it. Mirrors ../index.js:_dismissWikilink.
  export function _dismissWikilink() {
    this._closeWikilink();
    this._editor.commands.focus();
  }

  // Writable property so the Studio LiveView hook can inject the async page
  // search: `el.wikilinkSource = (query) => Promise<[{ title, id, type }]>`. Unset
  // → _maybeWikilink early-returns, so the popup NEVER opens (graceful no-op for
  // the harness without a source and the read-mode web embed). Mirrors ../index.js.
  export function setWikilinkSource(fn) {
    this._wikilinkSource = fn;
  }

export function getWikilinkSource() {
    return this._wikilinkSource;
  }

  // ── link hover card: what the host knows about a target ────────────────────
  // async ({ kind: "link" | "wikilink", href, target, docId }) => { title, excerpt, href } | null.
  // Unset → the card shows the address only.
  export function setLinkPreviewSource(fn) {
    this._linkPreviewSource = fn;
  }

export function getLinkPreviewSource() {
    return this._linkPreviewSource;
  }

  // ── live document-link titles (1.17.0): (docId) => { title?, missing? } | null ──
  // Asked once per document id; refreshWikilinks() (a rename, a delete) asks every link again.
  export function setWikilinkResolve(fn) {
    this._wikilinkResolve = typeof fn === "function" ? fn : null;
    refreshWikilinkTitles(this._editor, !this._wikilinkResolve);
  }

export function getWikilinkResolve() {
    return this._wikilinkResolve;
  }

export function refreshWikilinks() {
    refreshWikilinkTitles(this._editor, false);
  }

  // ── P4 `#` tag autocomplete ────────────────────────────────────────────────
  //
  // Obsidian-parity inline tag picker — the `#` analogue of the `[[` wikilink
  // popup, sharing the WikilinkMenu DOM via a thin adapter. Ported VERBATIM from
  // ../index.js. Studio-only by construction: gated on `this._editable` AND on an
  // injected `this._tagSource` (unset → never opens). On each onUpdate we re-run
  // the PURE parseOpenTag seam (block-local text + caret offset); an open trigger
  // opens/refreshes the menu at the caret and fires the async source. The string[]
  // of tag names is mapped to WikilinkMenu's { title, id, type } row shape —
  // "#"+name as the visible title, the bare name as the id we map back on pick. On
  // a pick we replace the typed "#query" span with "#"+name carrying a `tag` mark
  // { name } → runToOps emits a patch-block for that block. Returns true iff the
  // menu is (now) open.
  export function _maybeTag() {
    if (!this._editable || !this._tagSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame — identical
    // rationale to _maybeWikilink: triggerText($from.parent) pairs exactly with
    // `parentOffset`, so a `#` typed in the 2nd-or-later run block still opens.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = triggerText($from.parent);
    const caretOffset = $from.parentOffset;
    const hit = parseOpenTag(blockLocalText, caretOffset);
    if (!hit) {
      this._closeTag();
      return false;
    }

    // Open (or refresh as the query grows) the popup at the live caret rect, and
    // remember the PM range to replace on pick — anchored to the DOCUMENT position
    // (selection.from), not the block-local offset hit carries.
    this._openTag(this._caretRect(), hit.query);
    this._tagRange = tagReplaceRange(this._editor.state.selection.from, hit.query);

    // Async source with a STALE GUARD (own _tagSeq, independent of _wlSeq): each
    // open/keystroke bumps the counter; a resolved batch is dropped unless it is
    // still the latest request AND the menu is still open. The source returns a
    // string[] of tag NAMES; adapt each to WikilinkMenu's row shape here.
    const seq = ++this._tagSeq;
    new Promise((resolve) => resolve(this._tagSource(hit.query)))
      .catch(() => [])
      .then((list) => {
        if (seq !== this._tagSeq || !this._tag || !this._tag.isOpen()) {
          return;
        }
        const rows = (Array.isArray(list) ? list : []).map((name) => ({
          title: "#" + name,
          id: name,
          type: "tag",
        }));
        this._tag.setResults(rows);
      })
      .catch(() => {});
    return true;
  }

  // ── `:` emoji picker ───────────────────────────────────────────────────────
  //
  // GitHub's shorthand: `:` + two letters opens a picker over a local shortcode
  // table (emoji.js); the pick inserts the character as plain text and a space, so
  // the server sees ordinary text. Same popup class as [[ and #, eyebrow "Emoji".
  export function _maybeEmoji() {
    if (!this._editable || !this._editor) return false;
    const $from = this._editor.state.selection.$from;
    const hit = parseOpenEmoji($from.parent.textContent, $from.parentOffset);
    if (!hit) {
      this._closeEmoji();
      return false;
    }
    const rows = searchEmoji(hit.query).map(({ name, char }) => ({ title: char + "  " + name, id: char, type: "emoji" }));
    if (!rows.length) {
      this._closeEmoji();
      return false;
    }
    this._openEmoji(this._caretRect(), hit.query);
    this._emojiRange = emojiReplaceRange(this._editor.state.selection.from, hit.query);
    this._emoji.setResults(rows);
    return true;
  }

export function _openEmoji(rect, query = "") {
    if (!this._emoji) {
      this._emoji = new WikilinkMenu({
        onChoose: (c) => this._chooseEmoji(c),
        onDismiss: () => this._dismissEmoji(),
        eyebrow: "Emoji",
        kind: "emoji",
      });
    }
    this._emoji.open(rect, query);
  }

export function _closeEmoji() {
    if (this._emoji && this._emoji.isOpen()) this._emoji.close();
  }

export function _chooseEmoji(candidate) {
    const range = this._emojiRange;
    if (!range || !candidate || !candidate.id) {
      this._closeEmoji();
      return;
    }
    this._editor
      .chain()
      .focus()
      .insertContentAt({ from: range.from, to: range.to }, [
        { type: "text", text: String(candidate.id) },
        { type: "text", text: " " },
      ])
      .run();
    this._closeEmoji();
  }

export function _dismissEmoji() {
    this._closeEmoji();
    this._editor.commands.focus();
  }

export function _openTag(rect, query = "") {
    if (!this._tag) {
      this._tag = new WikilinkMenu({
        onChoose: (c) => this._chooseTag(c),
        onDismiss: () => this._dismissTag(),
      });
    }
    this._tag.open(rect, query);
  }

export function _closeTag() {
    if (this._tag && this._tag.isOpen()) this._tag.close();
  }

  // User picked a tag: replace the typed "#query" span with "#"+name carrying a
  // `tag` mark { name }, plus a trailing UNMARKED space so typing continues
  // OUTSIDE the tag (mark is inclusive:false; the space guarantees it across
  // browsers). The candidate is a WikilinkMenu row whose `id` is the bare tag
  // name; map it back here. The marked-text insertion mutates the run block →
  // runToOps emits a patch-block for that block. _tagRange was captured in
  // _maybeTag when the menu opened/refreshed. Mirrors _chooseWikilink.
  export function _chooseTag(candidate) {
    const range = this._tagRange;
    if (!range) {
      this._closeTag();
      return;
    }
    const name = candidate && candidate.id != null ? candidate.id : "";
    this._editor
      .chain()
      .focus()
      .insertContentAt({ from: range.from, to: range.to }, [
        {
          type: "text",
          text: "#" + name,
          marks: [{ type: "tag", attrs: { name } }],
        },
        { type: "text", text: " " },
      ])
      .run();
    this._closeTag();
  }

  // Esc / outside-click: close the menu but LEAVE the typed "#query" in place —
  // the user may want to keep editing it. Mirrors _dismissWikilink.
  export function _dismissTag() {
    this._closeTag();
    this._editor.commands.focus();
  }

  // Writable property so the Studio LiveView hook can inject the async tag search:
  // `el.tagSource = (query) => Promise<string[]>`. Unset → _maybeTag early-returns,
  // so the popup NEVER opens (graceful no-op for the harness without a source and
  // the read-mode web embed). Mirrors wikilinkSource exactly.
  export function setTagSource(fn) {
    this._tagSource = fn;
  }

export function getTagSource() {
    return this._tagSource;
  }

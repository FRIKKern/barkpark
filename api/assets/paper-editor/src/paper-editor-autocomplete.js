import { SlashMenu, SLASH_ITEMS } from "./slash-menu.js";
import { WikilinkMenu } from "./wikilink-menu.js";
import {
  parseOpenWikilink,
  splitAlias,
  wikilinkReplaceRange,
  parseOpenTag,
  tagReplaceRange,
} from "./wikilink-trigger.js";
import { normalizeTone } from "./tone.js";

export const paperEditorAutocompleteMethods = Object.freeze({
  // ── slash menu ─────────────────────────────────────────────────────────
  //
  // Trigger rule (deliberately conservative so a "/" inside prose never opens
  // the menu): the menu opens when the editor holds a single block whose text
  // STARTS with "/" and the caret sits at the end of that text — i.e. the user
  // typed "/" at the start of an otherwise-empty line and may keep typing a
  // query ("/head"). The substring after "/" is the live filter query, passed
  // to the menu so it narrows as you type — PortableDoc-editor parity. Text
  // that does NOT start with "/" (a slash mid-prose), a multi-line block, or a
  // non-collapsed selection all keep the menu closed.
  _maybeSlash() {
    if (!this._editable) return; // read mode: no slash menu, no bp-slash-insert
    if (!this._editor) return;

    const { state } = this._editor;
    const { selection, doc } = state;

    // Caret only — never on a range selection.
    if (!selection.empty) {
      this._closeSlash();
      return;
    }

    const text = this._editor.getText(); // plain text across the single block
    const startsSlash = text.length > 0 && text[0] === "/";
    const atEnd = selection.$from.parentOffset === text.length;
    const triggered =
      startsSlash && atEnd && !text.includes("\n") && doc.childCount <= 2;

    if (triggered) {
      this._openSlash(text.slice(1)); // query = everything after the leading "/"
    } else {
      this._closeSlash();
    }
  },

  // ── callout authoring shorthand ────────────────────────────────────────
  //
  // Obsidian-style `> [!type]` gesture: when the user types `> [!note] `,
  // `> [!warn]- `, or `> [!info]+ ` at the start of an otherwise-empty block,
  // turn it into a foldable callout (collapsed when the modifier is "-").
  // Mutually exclusive with _maybeSlash by leading token ('>' vs '/') AND by
  // the explicit `consumed` gate in onUpdate. Returns true iff it consumed the
  // update (origin block wiped + bp-slash-insert dispatched), false otherwise.
  //
  // Predicate parity with _maybeSlash: caret collapsed, caret at end, single
  // line, doc.childCount <= 2 — so it never fires mid-prose or across
  // multi-line / multi-block content. The trailing space in the regex is what
  // commits the gesture (so `> [!note]` alone keeps typing freely).
  _maybeCalloutShorthand() {
    if (!this._editor) return false;

    const { state } = this._editor;
    const { selection, doc } = state;

    // Caret only — never on a range selection.
    if (!selection.empty) return false;

    const text = this._editor.getText();
    const atEnd = selection.$from.parentOffset === text.length;
    if (!atEnd || text.includes("\n") || doc.childCount > 2) return false;

    // ^>\s*\[!(\w+)\]([+-]?)\s$ — the trailing \s (the committing space) plus the
    // no-newline guard above means \s only ever matches that space here.
    const m = /^>\s*\[!(\w+)\]([+-]?)\s$/.exec(text);
    if (!m) return false;

    const tone = normalizeTone(m[1]);
    const collapsed = m[2] === "-";
    this._emitSlashInsert({
      type: "callout",
      afterId: this._blockId,
      tone,
      collapsible: true,
      collapsed,
    });
    return true;
  },

  _openSlash(query = "") {
    if (!this._slash) {
      this._slash = new SlashMenu({
        items: SLASH_ITEMS,
        onChoose: (item) => this._chooseSlash(item),
        onDismiss: () => this._dismissSlash(),
      });
    }
    // Anchor the popup to the live caret rectangle. open() handles both the
    // first open and a re-open with a new filter query (as the user types).
    const rect = this._caretRect();
    this._slash.open(rect, query);
  },

  _closeSlash() {
    if (this._slash) this._slash.close();
  },

  // The DOMRect of the current caret, used to position the popup at the cursor.
  _caretRect() {
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
  },

  // Keyboard handler installed via editorProps.handleKeyDown. Only ACTS when a
  // popup is open; otherwise returns false so TipTap handles the key. The
  // wikilink menu is checked FIRST — the two popups are mutually exclusive, so
  // at most one branch ever owns the keystroke.
  _onKeyDown(event) {
    if (this._wikilink && this._wikilink.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._wikilink.move(1);
          return true;
        case "ArrowUp":
          this._wikilink.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._wikilink.choose();
          return true;
        case "Escape":
          this._dismissWikilink();
          return true;
        default:
          return false;
      }
    }

    // `#` tag menu owns the nav keys while open — same contract as the wikilink
    // branch above. The two are mutually exclusive (only one ever open), so the
    // order here is immaterial, but tag follows wikilink for symmetry.
    if (this._tag && this._tag.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._tag.move(1);
          return true;
        case "ArrowUp":
          this._tag.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._tag.choose();
          return true;
        case "Escape":
          this._dismissTag();
          return true;
        default:
          return false;
      }
    }

    if (this._editorMode === "card-body" && event.key === "Enter") return true;

    if (!this._slash || !this._slash.isOpen()) return false;

    switch (event.key) {
      case "ArrowDown":
        this._slash.move(1);
        return true;
      case "ArrowUp":
        this._slash.move(-1);
        return true;
      case "Enter":
      case "Tab":
        this._slash.choose();
        return true;
      case "Escape":
        this._dismissSlash();
        return true;
      default:
        return false;
    }
  },

  // User picked an item: erase the typed "/" from this block, close the menu,
  // and emit the bubbling/composed `bp-slash-insert` event. The server creates
  // the new block (default_block + insert-after) — this WC does NOT build it.
  //
  // An EXPECTED-group item carries a `fieldName`; we forward it so the server
  // builds a BOUND block (default_block + fieldName). A generic item has no
  // fieldName, so the detail omits it and the server takes the unchanged path.
  _chooseSlash(item) {
    this._closeSlash();
    const detail = { type: item.type, afterId: this._blockId };
    if (item.fieldName) detail.fieldName = item.fieldName;
    this._emitSlashInsert(detail);
  },

  // Shared teardown + dispatch for every slash-style insertion (menu pick AND
  // callout shorthand). Wipes the origin block so the trigger text never
  // persists into the now-empty origin paragraph, then emits the bubbling/
  // composed `bp-slash-insert` the LiveView hook forwards as `paper-slash-insert`.
  _emitSlashInsert(detail) {
    // Remove the ENTIRE typed trigger (not just its first char) so the trigger
    // text never persists in the now-empty origin block.
    this._editor.chain().focus().selectAll().deleteSelection().run();

    this.dispatchEvent(
      new CustomEvent("bp-slash-insert", {
        detail,
        bubbles: true,
        composed: true,
      }),
    );
  },

  // Esc / outside-click: close the menu but LEAVE the typed "/" in place — the
  // user may want to keep typing a real slash.
  _dismissSlash() {
    this._closeSlash();
    this._editor.commands.focus();
  },

  // ── `[[` wikilink autocomplete ─────────────────────────────────────────
  //
  // Obsidian-parity inline page-link picker. Studio-only by construction: it
  // is gated on `this._editable` (read-mode embeds never run onUpdate) AND on
  // an injected `this._wikilinkSource` (unset → the popup never opens). On each
  // onUpdate we re-run the PURE parseOpenWikilink seam against the block-local
  // text + caret offset; an open trigger opens/refreshes the menu at the caret
  // and fires the async source. The result list is server-scoped and rendered
  // verbatim (no local filtering). On a pick we replace the typed "[[query"
  // span with the chosen title carrying a `wikilink` mark — no literal brackets
  // remain in the document.
  //
  // Returns true iff the menu is (now) open, so onUpdate can force the slash
  // menu shut and skip _maybeSlash (mutual exclusion).
  _maybeWikilink() {
    if (!this._editable || !this._wikilinkSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame. `$from.parent`
    // is the current textblock (a paragraph — including the one nested inside a
    // list item), so its `textContent` pairs exactly with `parentOffset`. Using
    // `getText()` here would join EVERY textblock with "\n\n" and desync from the
    // block-local `parentOffset`, so a `[[` typed in the 2nd-or-later list item
    // would never open the popup. parseOpenWikilink's contract is block-local text.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = $from.parent.textContent;
    const caretOffset = $from.parentOffset;
    const hit = parseOpenWikilink(blockLocalText, caretOffset);
    if (!hit) {
      this._closeWikilink();
      return false;
    }

    // Open (or refresh, as the query grows) the popup at the live caret rect,
    // and remember the PM range to replace on pick — anchored to the DOCUMENT
    // position (selection.from), not the block-local offset hit carries.
    const { query, alias } = hit.trigger === "[[" ? splitAlias(hit.query) : { query: hit.query, alias: null };
    this._openWikilink(this._caretRect(), query);
    this._wlRange = wikilinkReplaceRange(this._editor.state.selection.from, hit.query);
    this._wlAlias = alias || null;

    // Async source with a STALE GUARD: each open/keystroke bumps _wlSeq; a
    // resolved batch is dropped unless it is still the latest request AND the
    // menu is still open — so an out-of-order or post-close response is ignored.
    const seq = ++this._wlSeq;
    if (!query && alias != null) {
      this._wikilink.setResults([]);
      return true;
    }
    Promise.resolve(this._wikilinkSource(query))
      .then((list) => {
        if (seq !== this._wlSeq || !this._wikilink || !this._wikilink.isOpen()) {
          return;
        }
        this._wikilink.setResults(Array.isArray(list) ? list : []);
      })
      .catch(() => {});
    return true;
  },

  _openWikilink(rect, query = "") {
    if (!this._wikilink) {
      this._wikilink = new WikilinkMenu({
        onChoose: (c) => this._chooseWikilink(c),
        onDismiss: () => this._dismissWikilink(),
      });
    }
    this._wikilink.open(rect, query);
  },

  _closeWikilink() {
    if (this._wikilink && this._wikilink.isOpen()) this._wikilink.close();
  },

  // User picked a candidate: replace the typed "[[query" span with the chosen
  // title carrying a `wikilink` mark { target: title, docId: id }, plus a
  // trailing UNMARKED space so typing continues OUTSIDE the link (the mark is
  // inclusive:false, but the space guarantees it across browsers). The pinned
  // `docId` is the picked paper's EXACT id — render resolves to that doc, closing
  // the title-collision hole (a typed-not-picked wikilink carries no docId and
  // keeps the existing lower(title) resolution). _wlRange was captured in
  // _maybeWikilink at the moment the menu opened/refreshed.
  _chooseWikilink(candidate) {
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
  },

  // Esc / outside-click: close the menu but LEAVE the typed "[[query" in place —
  // the user may want to keep editing it. Mirrors _dismissSlash.
  _dismissWikilink() {
    this._closeWikilink();
    this._editor.commands.focus();
  },

  // ── `#` tag autocomplete ───────────────────────────────────────────────
  //
  // Obsidian-parity inline tag picker — the `#` analogue of the `[[` wikilink
  // popup, sharing the WikilinkMenu DOM via a thin adapter. Studio-only by
  // construction: gated on `this._editable` AND on an injected `this._tagSource`
  // (unset → never opens). On each onUpdate we re-run the PURE parseOpenTag seam
  // (block-local text + caret offset); an open trigger opens/refreshes the menu
  // at the caret and fires the async source. The string[] of tag names is mapped
  // to WikilinkMenu's { title, id, type } row shape — "#"+name as the visible
  // title, the bare name as the id we map back on pick. On a pick we replace the
  // typed "#query" span with "#"+name carrying a `tag` mark { name }.
  //
  // Returns true iff the menu is (now) open, so onUpdate's mutual-exclusion chain
  // can force the slash menu shut and skip _maybeSlash.
  _maybeTag() {
    if (!this._editable || !this._tagSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame — identical
    // rationale to _maybeWikilink: `$from.parent.textContent` pairs exactly with
    // `parentOffset`, so a `#` typed in the 2nd-or-later list item still opens.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = $from.parent.textContent;
    const caretOffset = $from.parentOffset;
    const hit = parseOpenTag(blockLocalText, caretOffset);
    if (!hit) {
      this._closeTag();
      return false;
    }

    // Open (or refresh as the query grows) the popup at the live caret rect, and
    // remember the PM range to replace on pick — anchored to the DOCUMENT
    // position (selection.from), not the block-local offset hit carries.
    this._openTag(this._caretRect(), hit.query);
    this._tagRange = tagReplaceRange(this._editor.state.selection.from, hit.query);

    // Async source with a STALE GUARD (own _tagSeq, independent of _wlSeq): each
    // open/keystroke bumps the counter; a resolved batch is dropped unless it is
    // still the latest request AND the menu is still open. The source returns a
    // string[] of tag NAMES; adapt each to WikilinkMenu's row shape here.
    const seq = ++this._tagSeq;
    Promise.resolve(this._tagSource(hit.query))
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
  },

  _openTag(rect, query = "") {
    if (!this._tag) {
      this._tag = new WikilinkMenu({
        onChoose: (c) => this._chooseTag(c),
        onDismiss: () => this._dismissTag(),
      });
    }
    this._tag.open(rect, query);
  },

  _closeTag() {
    if (this._tag && this._tag.isOpen()) this._tag.close();
  },

  // User picked a tag: replace the typed "#query" span with "#"+name carrying a
  // `tag` mark { name }, plus a trailing UNMARKED space so typing continues
  // OUTSIDE the tag (mark is inclusive:false; the space guarantees it across
  // browsers). The candidate is a WikilinkMenu row whose `id` is the bare tag
  // name; map it back here. _tagRange was captured in _maybeTag when the menu
  // opened/refreshed. Mirrors _chooseWikilink.
  _chooseTag(candidate) {
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
  },

  // Esc / outside-click: close the menu but LEAVE the typed "#query" in place —
  // the user may want to keep editing it. Mirrors _dismissWikilink.
  _dismissTag() {
    this._closeTag();
    this._editor.commands.focus();
  },
});

